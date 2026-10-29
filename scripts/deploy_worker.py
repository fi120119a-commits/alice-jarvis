"""Деплой Cloudflare Worker — «мозга» голосового ассистента.

Скрипт загружает src/worker/cloudflare-proxy.js, включает Workers AI,
ставит cron-прогрев раз в 10 минут, сохраняет секреты и проверяет ответ
модели. Node.js и Wrangler не нужны — только Python и httpx.

Переменные окружения (или файл .env в корне репозитория):
    CF_API_TOKEN   — токен Cloudflare, шаблон «Edit Cloudflare Workers»
    CF_ACCOUNT_ID  — Account ID (правая колонка на главной дашборда)

Необязательные:
    JARVIS_KEY      — пароль к воркеру (сгенерируется, если не задан)
    WORKER_NAME     — имя воркера (по умолчанию alice-jarvis-llm)
    GEMINI_KEY      — ключ Google AI Studio
    GROQ_KEY        — ключ Groq
    OPENROUTER_KEY  — ключ OpenRouter

Запуск:
    python -m pip install -r requirements.txt
    python scripts/deploy_worker.py
"""

from __future__ import annotations

import json
import os
import secrets
import sys
import time
from pathlib import Path

import httpx

ROOT = Path(__file__).resolve().parent.parent
WORKER_FILE = ROOT / "src" / "worker" / "cloudflare-proxy.js"
DOTENV_FILE = ROOT / ".env"
API = "https://api.cloudflare.com/client/v4"

try:  # консоль Windows любит cp866/cp1251
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception:  # noqa: BLE001
    pass


def load_dotenv(path: Path) -> None:
    """Читает .env и кладёт значения в os.environ, не перетирая уже заданные."""
    if not path.exists():
        return
    for raw in path.read_text(encoding="utf-8").splitlines():
        line = raw.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        name, value = line.split("=", 1)
        name = name.strip()
        value = value.strip().strip('"').strip("'")
        if name and name not in os.environ:
            os.environ[name] = value


def fail(message: str, payload: object = None) -> None:
    print(f"\nОШИБКА: {message}")
    if payload is not None:
        print(json.dumps(payload, ensure_ascii=False, indent=2)[:1500])
    raise SystemExit(1)


def main() -> int:
    load_dotenv(DOTENV_FILE)

    token = os.environ.get("CF_API_TOKEN", "").strip()
    account = os.environ.get("CF_ACCOUNT_ID", "").strip()
    if not token or not account:
        print(__doc__)
        print("CF_API_TOKEN и CF_ACCOUNT_ID не заданы (в окружении или .env).")
        return 2

    if not WORKER_FILE.exists():
        fail(f"не найден файл воркера: {WORKER_FILE}")

    name = os.environ.get("WORKER_NAME", "alice-jarvis-llm").strip() or "alice-jarvis-llm"
    jarvis_key = os.environ.get("JARVIS_KEY", "").strip() or secrets.token_urlsafe(24)
    provider_keys = {
        "GEMINI_KEY": os.environ.get("GEMINI_KEY", "").strip(),
        "GROQ_KEY": os.environ.get("GROQ_KEY", "").strip(),
        "OPENROUTER_KEY": os.environ.get("OPENROUTER_KEY", "").strip(),
    }

    client = httpx.Client(timeout=60, headers={"Authorization": f"Bearer {token}"})

    # 1. Проверка токена
    check = client.get(f"{API}/user/tokens/verify")
    if check.status_code != 200 or not check.json().get("success"):
        fail("токен Cloudflare не принят", check.text[:500])

    # 2. Загрузка скрипта (ES-модуль) с привязкой Workers AI
    metadata = {
        "main_module": "worker.js",
        "compatibility_date": "2025-01-01",
        "bindings": [
            {"type": "secret_text", "name": "JARVIS_KEY", "text": jarvis_key},
            {"type": "ai", "name": "AI"},
        ],
    }
    upload = client.put(
        f"{API}/accounts/{account}/workers/scripts/{name}",
        data={"metadata": json.dumps(metadata)},
        files={
            "worker.js": (
                "worker.js",
                WORKER_FILE.read_bytes(),
                "application/javascript+module",
            )
        },
    )
    if upload.status_code >= 300:
        fail("не удалось загрузить воркер", upload.text[:1500])
    print(f"воркер загружен: {name}")

    # 2b. Cron-триггер прогрева: первый вопрос после простоя отвечает быстрее
    sched = client.put(
        f"{API}/accounts/{account}/workers/scripts/{name}/schedules",
        json=[{"cron": "*/10 * * * *"}],
    )
    if sched.status_code >= 300:
        print(f"cron-триггер не установлен ({sched.status_code}): {sched.text[:300]}")
    else:
        print("cron-триггер прогрева: каждые 10 минут")

    # 3. Секреты
    all_secrets = {"JARVIS_KEY": jarvis_key, **{k: v for k, v in provider_keys.items() if v}}
    for key, value in all_secrets.items():
        put = client.put(
            f"{API}/accounts/{account}/workers/scripts/{name}/secrets",
            json={"name": key, "text": value, "type": "secret_text"},
        )
        if put.status_code >= 300:
            fail(f"не удалось сохранить секрет {key}", put.text[:1000])
    print("секреты: " + ", ".join(all_secrets))

    # 4. Домен workers.dev
    sub = client.get(f"{API}/accounts/{account}/workers/subdomain")
    if sub.status_code != 200 or not sub.json().get("success"):
        fail(
            "у аккаунта нет workers.dev-поддомена. Откройте дашборд → Workers & Pages → "
            "Choose a subdomain, задайте его и запустите скрипт снова",
            sub.text[:800],
        )
    subdomain = sub.json()["result"]["subdomain"]

    client.put(
        f"{API}/accounts/{account}/workers/scripts/{name}/subdomain",
        json={"enabled": True, "previews_enabled": False},
    )

    url = f"https://{name}.{subdomain}.workers.dev"
    print(f"\nадрес: {url}")

    # 5. Проверка и замеры
    time.sleep(3)
    try:
        started = time.perf_counter()
        health = client.get(f"{url}/healthz")
        cold = (time.perf_counter() - started) * 1000
        started = time.perf_counter()
        client.get(f"{url}/healthz")
        warm = (time.perf_counter() - started) * 1000
        print(f"healthz: {health.status_code}, холодный {cold:.0f} мс, тёплый {warm:.0f} мс")
    except httpx.HTTPError as exc:
        print(f"healthz не ответил: {exc}")
        print("Если это таймаут — проверьте, что workers.dev открывается в браузере.")
        return 1

    # 6. Проверка самого «мозга»: персонаж + скорость
    payload = {
        "messages": [{"role": "user", "content": "Кто ты? Ответь одним предложением."}],
        "max_tokens": 60,
    }
    try:
        started = time.perf_counter()
        answer = client.post(
            f"{url}/cf/v1/chat/completions",
            json=payload,
            headers={"Authorization": f"Bearer {jarvis_key}"},
        )
        elapsed = (time.perf_counter() - started) * 1000
        if answer.status_code >= 400:
            print(f"модель: HTTP {answer.status_code} {answer.text[:300]}")
        else:
            data = answer.json()
            text = (data["choices"][0]["message"].get("content") or "").strip()
            model = data.get("model", "?")
            print(f"модель: {elapsed:.0f} мс, {model}")
            print(f"ответ: «{text[:120]}»")
    except httpx.HTTPError as exc:
        print(f"модель не ответила: {exc}")

    # 7. Необязательные провайдеры
    for provider, env_name, model in (
        ("gemini", "GEMINI_KEY", "gemini-2.5-flash"),
        ("groq", "GROQ_KEY", "llama-3.3-70b-versatile"),
    ):
        if not provider_keys[env_name]:
            continue
        started = time.perf_counter()
        try:
            answer = client.post(
                f"{url}/{provider}/v1/chat/completions",
                json={
                    "model": model,
                    "messages": [{"role": "user", "content": "Скажи одно слово: работает"}],
                    "max_tokens": 20,
                },
                headers={"x-jarvis-key": jarvis_key},
            )
        except httpx.HTTPError as exc:
            print(f"{provider}: не ответил ({exc})")
            continue
        elapsed = (time.perf_counter() - started) * 1000
        if answer.status_code >= 400:
            print(f"{provider}: HTTP {answer.status_code} {answer.text[:300]}")
        else:
            text = answer.json()["choices"][0]["message"].get("content", "").strip()
            print(f"{provider}: {elapsed:.0f} мс, ответ «{text[:60]}»")

    # 8. Что делать дальше
    print("\nДальше:")
    print(f"  1) в config.json:  \"llm_base_url\": \"{url}/cf/v1\"")
    print("  2) в runtime.env:  export QUASAR_LLM_API_KEY=<ваш JARVIS_KEY>")
    print("  3) в .env:         LLM_BASE_URL=" + f"{url}/cf/v1")
    if not os.environ.get("JARVIS_KEY", "").strip():
        print(f"\nJARVIS_KEY (сохраните, он больше не покажется): {jarvis_key}")
    print("  4) установите мост: scripts\\deploy_bridge.ps1")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
