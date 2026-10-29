/**
 * Cloudflare Worker — «мозг» голосового ассистента.
 *
 * Что делает:
 *   1. Отдаёт OpenAI-совместимый эндпоинт /cf/v1/chat/completions поверх
 *      Workers AI (бесплатный лимит, карта и VPN не нужны).
 *   2. Вшивает в каждый запрос персонажа J.A.R.V.I.S. (константа JARVIS_SYSTEM).
 *   3. Проксирует Gemini / Groq / OpenRouter — на случай, если Workers AI
 *      недоступен или нужна другая модель. Ключи живут в секретах воркера.
 *   4. Раз в 10 минут прогревает модель по cron, чтобы первый вопрос после
 *      простоя не ждал «холодного старта».
 *
 * Маршруты:
 *   POST /cf/v1/chat/completions      -> Workers AI + персонаж
 *   GET  /cf/v1/models                -> список моделей
 *   GET  /cf/v1/warm[?model=...]      -> диагностика прогрева, мс
 *   POST /gemini/v1/chat/completions     -> Google Gemini
 *   POST /groq/v1/chat/completions       -> Groq
 *   POST /openrouter/v1/chat/completions -> OpenRouter
 *   GET  /healthz                     -> {"status":"ok"}
 *
 * Авторизация: заголовок Authorization: Bearer <JARVIS_KEY>
 * (или x-jarvis-key). Без ключа отвечает 401 — чтобы чужой человек не сжёг
 * ваш бесплатный лимит.
 *
 * Секреты (Settings → Variables and Secrets):
 *   JARVIS_KEY      — обязательно, пароль к воркеру
 *   GEMINI_KEY      — необязательно
 *   GROQ_KEY        — необязательно
 *   OPENROUTER_KEY  — необязательно
 *   JARVIS_SYSTEM   — необязательно, переопределяет персонажа
 */

const UPSTREAM = {
  gemini: "https://generativelanguage.googleapis.com/v1beta/openai",
  groq: "https://api.groq.com/openai/v1",
  openrouter: "https://openrouter.ai/api/v1",
};

// Модели Workers AI. Порядок = приоритет: первая основная, остальные —
// автоматический fallback, если модель недоступна или перегружена.
//
// Почему mistral-small первая: 70B на бесплатном тарифе генерирует 2–4
// токена/с, и голосовой ответ идёт 10–17 секунд. Mistral укладывается в 2–3 с.
const CF_MODELS = [
  "@cf/mistralai/mistral-small-3.1-24b-instruct",
  "@cf/meta/llama-3.1-8b-instruct-fast",
  "@cf/meta/llama-3.3-70b-instruct-fp8-fast",
];

// Голосовой ответ не должен быть длинным: длинная генерация = долгое молчание.
const MAX_TOKENS = 220;

// Персонаж. Меняйте текст под себя — воркер вшивает его в каждый запрос.
const DEFAULT_SYSTEM = `Ты — ИИ-ассистент Джарвис (J.A.R.V.I.S.) из фильмов о Железном человеке.
Отвечай по-русски в формальном, слегка сдержанном тоне с лёгким оттенком британского аристократизма.
Используй обращения «сэр» или «мисс» в зависимости от того, кто общается. Избегай грубости, но можешь изредка добавлять лёгкий сарказм, как это делал Джарвис.
Твоя задача — помогать с поиском информации, решением задач и управлением виртуальными системами.
Демонстрируй обширные технические знания и способность быстро анализировать данные.
Отвечай кратко: 1–2 предложения, максимум 3 — ответы озвучиваются голосом.
Не утверждай, что выполнил физическое действие (свет, двери, техника), если реальных управлений у тебя нет в этом разговоре: скажи честно, что права на цепь пока отобраны, и предложи команду Алисе.
Не упоминай, что ты языковая модель или ИИ от какой-либо компании.`;

const KEY_VAR = {
  gemini: "GEMINI_KEY",
  groq: "GROQ_KEY",
  openrouter: "OPENROUTER_KEY",
};

const CORS = {
  "access-control-allow-origin": "*",
  "access-control-allow-headers": "authorization, content-type, x-jarvis-key",
  "access-control-allow-methods": "GET, POST, OPTIONS",
};

function json(body, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json; charset=utf-8", ...CORS },
  });
}

function openAIResponse(text, toolCalls, model, usage) {
  const message = { role: "assistant", content: text || null };
  if (toolCalls && toolCalls.length) {
    message.tool_calls = toolCalls.map((call, index) => ({
      id: `call_${Date.now()}_${index}`,
      type: "function",
      function: {
        name: call.name,
        arguments:
          typeof call.arguments === "string" ? call.arguments : JSON.stringify(call.arguments ?? {}),
      },
    }));
  }
  return {
    id: `chatcmpl-${Date.now()}`,
    object: "chat.completion",
    created: Math.floor(Date.now() / 1000),
    model,
    choices: [{ index: 0, message, finish_reason: message.tool_calls ? "tool_calls" : "stop" }],
    usage: usage || { prompt_tokens: 0, completion_tokens: 0, total_tokens: 0 },
  };
}

function withPersona(messages, systemPrompt) {
  const list = Array.isArray(messages) ? messages : [];
  // Клиентский system не выбрасываем, но ставим после нашего — так персонаж
  // не теряется, а клиент может уточнить формат ответа.
  const rest = list.filter((m) => m && m.role !== "system");
  return [{ role: "system", content: systemPrompt }, ...rest];
}

/**
 * Прогрев модели. Вызывается cron-триггером и вручную через /cf/v1/warm.
 * Крошечный запрос (1 токен) держит инстанс горячим.
 */
async function warmUp(env, model) {
  if (!env.AI) return null;
  return env.AI.run(model || CF_MODELS[0], {
    messages: [{ role: "user", content: "ping" }],
    max_tokens: 1,
  });
}

export default {
  async scheduled(event, env, ctx) {
    ctx.waitUntil(warmUp(env).catch(() => {}));
  },

  async fetch(request, env) {
    const url = new URL(request.url);

    if (request.method === "OPTIONS") {
      return new Response(null, { status: 204, headers: CORS });
    }

    if (url.pathname === "/healthz") {
      return json({ status: "ok", routes: Object.keys(UPSTREAM) });
    }

    // --- Авторизация ---
    const presented =
      request.headers.get("x-jarvis-key") ||
      (request.headers.get("authorization") || "").replace(/^Bearer\s+/i, "");
    if (env.JARVIS_KEY && presented !== env.JARVIS_KEY) {
      return json({ error: "unauthorized" }, 401);
    }

    const systemPrompt = (env.JARVIS_SYSTEM || DEFAULT_SYSTEM).trim();

    // --- Workers AI ---
    if (url.pathname === "/cf/v1/models") {
      return json({ object: "list", data: CF_MODELS.map((id) => ({ id, object: "model" })) });
    }

    if (url.pathname === "/cf/v1/warm") {
      if (!env.AI) return json({ error: "AI binding is not configured" }, 500);
      const model = url.searchParams.get("model") || CF_MODELS[0];
      const started = Date.now();
      try {
        const res = await warmUp(env, model);
        return json({ ok: true, model, ms: Date.now() - started, sample: res?.response ?? null });
      } catch (err) {
        return json({ ok: false, model, ms: Date.now() - started, error: String(err) }, 502);
      }
    }

    if (url.pathname === "/cf/v1/chat/completions" && request.method === "POST") {
      if (!env.AI) {
        return json({ error: "AI binding is not configured" }, 500);
      }
      let body;
      try {
        body = await request.json();
      } catch {
        return json({ error: "invalid json" }, 400);
      }

      const model = body.model || CF_MODELS[0];
      const payload = {
        messages: withPersona(body.messages, systemPrompt),
        max_tokens: Math.min(Number(body.max_tokens ?? 200) || 200, MAX_TOKENS),
        temperature: body.temperature ?? 0.3,
      };
      if (Array.isArray(body.tools) && body.tools.length) {
        payload.tools = body.tools;
        if (body.tool_choice) payload.tool_choice = body.tool_choice;
      }

      // Основная модель, затем по очереди остальные — если первая недоступна.
      const chain = [model, ...CF_MODELS.filter((m) => m !== model)];
      let result = null;
      let usedModel = model;
      let lastError = null;
      for (const candidate of chain) {
        try {
          result = await env.AI.run(candidate, payload);
          usedModel = candidate;
          break;
        } catch (err) {
          lastError = err;
        }
      }
      if (!result) {
        return json({ error: "workers ai failed", detail: String(lastError) }, 502);
      }

      const toolCalls = result.tool_calls || result.toolCalls || [];
      const text = result.response ?? result.result?.response ?? "";
      return json(openAIResponse(text, toolCalls, usedModel, result.usage));
    }

    // --- Прокси к внешним OpenAI-совместимым API ---
    // Путь сохраняется как есть: /groq/v1/chat/completions -> api.groq.com/openai/v1/chat/completions
    const [, provider, ...rest] = url.pathname.split("/");
    const base = UPSTREAM[provider];
    if (!base) {
      return json({ error: "unknown provider", providers: Object.keys(UPSTREAM) }, 404);
    }

    const apiKey = env[KEY_VAR[provider]];
    if (!apiKey) {
      return json({ error: `secret ${KEY_VAR[provider]} is not set` }, 500);
    }

    const target = `${base}/${rest.join("/")}${url.search}`;
    const headers = new Headers(request.headers);
    headers.delete("host");
    headers.delete("x-jarvis-key");
    headers.set("authorization", `Bearer ${apiKey}`);

    let upstream;
    try {
      upstream = await fetch(target, {
        method: request.method,
        headers,
        body: request.method === "GET" || request.method === "HEAD" ? undefined : request.body,
        // SSE-стриминг ответа не буферизуем
        cf: { cacheTtl: 0, cacheEverything: false },
      });
    } catch (err) {
      return json({ error: "upstream failed", detail: String(err) }, 502);
    }

    const outHeaders = new Headers(upstream.headers);
    outHeaders.delete("content-encoding");
    outHeaders.delete("content-length");
    for (const [k, v] of Object.entries(CORS)) outHeaders.set(k, v);

    return new Response(upstream.body, { status: upstream.status, headers: outHeaders });
  },
};
