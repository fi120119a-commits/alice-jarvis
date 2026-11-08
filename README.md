# 🎙️ Alice Jarvis — голосовой ИИ-ассистент на Яндекс Станции

[![License: MIT](https://img.shields.io/badge/license-MIT-green.svg)](LICENSE)
[![Platform](https://img.shields.io/badge/platform-Yandex%20Station%20Lite%20(YNDX--00028)-ffcc00.svg)](docs/INSTALL.md)
[![LLM](https://img.shields.io/badge/LLM-Cloudflare%20Workers%20AI-blue.svg)](src/worker/cloudflare-proxy.js)
[![Architecture](https://img.shields.io/badge/architecture-hybrid%20edge--to--cloud-purple.svg)](docs/ARCHITECTURE.md)

Интеграция голосового ассистента в образе J.A.R.V.I.S. с Яндекс Станцией Лайт.

Голосовой тракт (распознавание ASR и синтез TTS) выполняется сервисами Яндекса (родной голос Алисы, низкая задержка, качественная русская речь), а генерация ответов передаётся в языковую модель: поддерживается **любая нейросеть** с OpenAI-совместимым API (Groq, DeepSeek, OpenRouter, OpenAI или локальные LLM). Для пользователей из РФ по умолчанию рекомендуется бесплатный **Cloudflare Workers AI** (`@cf/mistralai/mistral-small-3.1-24b-instruct`), так как он работает автономно, без VPN и без зарубежных банковских карт. Компьютер для постоянной работы **не требуется** — стек функционирует автономно на колонке и в облаке.

> ⚠️ Проект любительский и не аффилирован с ООО «Яндекс». Требуются права root и доступ по ADB на устройстве.

---

## Возможности

- **Слово активации «Джарвис»** — автономный споттер `station-wakeword` в аудиоканале `vqe_0` после эхоподавления.
- **Любая нейросеть на выбор** — поддержка любого OpenAI-совместимого API (Groq, DeepSeek, OpenRouter, OpenAI, локальные модели). Для жителей РФ рекомендуется **Cloudflare Workers AI** (10 000 нейронов/день бесплатно, без карт, зарубежных номеров и VPN).
- **Характер J.A.R.V.I.S.** — деловой стиль, обращение «сэр/мисс», лёгкая ирония, лаконичные ответы (1–3 предложения, до 220 токенов).
- **Сохранение функций Яндекса** — умный дом (свет, розетки, шторы), погода, музыка, таймеры и будильники обрабатываются штатно.
- **Индикация светодиодного кольца** — ровный голубой цвет `RGB(40,150,255)` с мягким синусоидальным «дыханием» (0.55..1.0, 0.9 Гц) строго во время ответа Джарвиса (`2.5s + runes/14`, ограничено `4..28s`). В покое кольцо полностью выключено (`RGB(0,0,0)`) и остаётся под управлением штатной Алисы (`maind` — волна «слушаю», громкость, красный mute, таймеры).
- **Наблюдаемость** — журнал диалогов `conversations.jsonl`, технический лог `bridge.log`, статус-эндпоинт `/healthz` с контрольным хешем правил `routing_revision`.

---

## Архитектура

```
[Микрофон Станции]
       │
       ▼
[station-wakeword] ──услышал «Джарвис»──► эмуляция активации в maind
       │
       ▼
[Яндекс Uniproxy]  ASR (распознавание речи)
       │  ws://127.0.0.1:8443/uni.ws
       ▼
[quasar-bridge]    маршрутизация запросов (hybrid)
       ├── погода / музыка / таймеры / умный дом  ──► Яндекс
       └── остальные запросы (default / «джарвис») ──► Cloudflare Worker
       │
       ▼
[Cloudflare Worker] вшивает системный промпт ──► Workers AI (mistral-small-3.1-24b)
       │
       ▼
[quasar-bridge]    возврат текста ответа ──► Яндекс TTS (синтез голосом Алисы)
       │
       ├──► воспроизведение через mediad
       └──► запись в conversations.jsonl ──► jarvis-led (голубое кольцо 4..28с)
```

Прошивка колонки **не модифицируется**: изменяется только адрес WebSocket в `/system/vendor/quasar/quasar.cfg` (`aliced.uniProxyUrl = ws://127.0.0.1:8443/uni.ws`).

Подробное описание архитектуры — в [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).

---

## Требования

| Компонент | Назначение |
| --- | --- |
| Яндекс Станция Лайт (YNDX-00028) | Целевое устройство с правами **root** и включённым **ADB по Wi-Fi** |
| Локальная сеть Wi-Fi | Общая подсеть для колонки и ПК при первичной настройке |
| [ADB (Android Debug Bridge)](https://developer.android.com/tools/releases/platform-tools) | Удалённое управление и загрузка файлов на колонку |
| Аккаунт Cloudflare (Free) или любой LLM API | Облачный интеллект (для жителей РФ рекомендуется Cloudflare — бесплатно и без VPN; либо ключ OpenRouter / Groq / DeepSeek / OpenAI) |
| Python 3.10+ на ПК | Деплой облачного воркера (`scripts/deploy_worker.py`) |
| Go 1.21+ (опционально) | Требуется только при самостоятельной сборке демона подсветки `jarvis-led` |

---

## Быстрый старт

Подробное пошаговое руководство — в **[docs/INSTALL.md](docs/INSTALL.md)**.

```powershell
# 1. Клонирование репозитория и создание конфигураций
git clone https://github.com/fi120119a-commits/alice-jarvis.git
cd alice-jarvis
Copy-Item config.example.json config.json
Copy-Item runtime.env.example runtime.env
Copy-Item .env.example .env

# Заполните в .env: CF_API_TOKEN, CF_ACCOUNT_ID, JARVIS_KEY, STATION_IP=<STATION_IP>
notepad .env

# 2. Развёртывание облачного «мозга» в Cloudflare Workers AI
python -m venv .venv
.\.venv\Scripts\Activate.ps1
pip install -r requirements.txt
python scripts\deploy_worker.py

# 3. Внесите выданный URL воркера в .env (LLM_BASE_URL) и config.json (llm_base_url),
#    а значение JARVIS_KEY — в runtime.env (QUASAR_LLM_API_KEY).
#    Поместите бинарник quasar-bridge в vendor/ (см. docs/INSTALL.md, шаг 3).

# 4. Установка моста и автозапуска на колонку
powershell -ExecutionPolicy Bypass -File scripts\deploy_bridge.ps1 -Device <STATION_IP>:5555

# 5. Привязка IPv4-пинов Cloudflare (предотвращение таймаутов IPv6)
powershell -ExecutionPolicy Bypass -File scripts\update_cf_pins.ps1 -Station <STATION_IP>:5555

# 6. Переключение голосового тракта на локальный мост
powershell -ExecutionPolicy Bypass -File scripts\apply_endpoint.ps1 -Device <STATION_IP>:5555

# 7. Проверка работоспособности моста
adb -s <STATION_IP>:5555 shell "wget -q -O - http://127.0.0.1:8443/healthz"
```

Служба распознавания ключевого слова «Джарвис» настраивается отдельно через веб-интерфейс демона `station-wakeword` (`http://<STATION_IP>:8780`) — см. [docs/WAKE_WORD.md](docs/WAKE_WORD.md).

---

## Примеры маршрутизации голосовых команд

| Фраза | Обработчик | Поведение |
| --- | --- | --- |
| «Джарвис, кто ты?» | Workers AI (`llm`) | Ответ в образе J.A.R.V.I.S., голубое кольцо LED |
| «Джарвис, почему небо голубое?» | Workers AI (`llm`) | Лаконичное научное объяснение от LLM |
| «Джарвис, что такое квантовая запутанность?» | Workers AI (`llm`) | Технический ответ 1–3 предложения |
| «Алиса, выключи свет» | Яндекс (`yandex`) | Штатное реле умного дома, кольцо не активно |
| «Алиса, какая погода на завтра?» | Яндекс (`yandex`) | Прогноз погоды Яндекса |
| «Алиса, поставь таймер на 10 минут» | Яндекс (`yandex`) | Штатный таймер с анимацией кольца Алисы |

---

## Управление и конфигурация

- **Переключение нейросети (провайдера)**: скрипт `scripts/bridge_brain.ps1` позволяет в одну команду сменить источник инференса:
  - `cloud` — Cloudflare Workers AI (по умолчанию, **рекомендуется для жителей РФ**: бесплатно, без карт и без VPN);
  - `openrouter` — каталог моделей OpenRouter (включая бесплатные `meta-llama/llama-3.3-70b-instruct:free`);
  - `custom` — любая внешняя нейросеть с API-ключом (Groq, DeepSeek, OpenAI): `-BaseUrl "https://api.groq.com/openai/v1" -Model "llama-3.3-70b-versatile" -Key "gsk_..."`;
  - `pc` — локальная модель на домашнем ПК (Ollama / LM Studio): `-BaseUrl "http://192.168.1.X:11434/v1"`.
- **Системный промпт**: константа `DEFAULT_SYSTEM` в `src/worker/cloudflare-proxy.js` (или секрет воркера `JARVIS_SYSTEM`). После правки: `python scripts/deploy_worker.py`.
- **Языковая модель в config.json**: параметр `llm_model` (по умолчанию `@cf/mistralai/mistral-small-3.1-24b-instruct`).
- **Правила маршрутизации**: блок `routing.rules` в `config.json`. При обновлении выкатывать строго через `adb push` для сохранения UTF-8.

---

## Диагностика

```powershell
# 1. Проверка состояния моста и ревизии правил
adb -s <STATION_IP>:5555 shell "wget -q -O - http://127.0.0.1:8443/healthz"

# 2. Журнал последних ответов (маршрут, текст, задержка)
adb -s <STATION_IP>:5555 shell "grep '\"event\":\"response\"' /data/opt/quasar-bridge/conversations.jsonl | tail -5"

# 3. Решения классификатора маршрутов
adb -s <STATION_IP>:5555 shell "grep native_route_decision /data/opt/quasar-bridge/bridge.log | tail -10"

# 4. Проверка работы демона подсветки
adb -s <STATION_IP>:5555 shell "pidof jarvis-led && cat /data/opt/jarvis-led/led.log"
```

При возникновении неполадок обратитесь к руководству [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md).

---

## Благодарности

- **Сергей Крашевич ([@skrashevich](https://github.com/skrashevich))** — автор проекта [quasar-bridge](https://github.com/skrashevich/quasar-bridge) (Apache-2.0), фундаментальной основы для перехвата голосового тракта Яндекс Станций и маршрутизации запросов.
- **[tangenx](https://github.com/tangenx)** — автор проекта [station-wakeword](https://github.com/tangenx/station-wakeword), легковесного автономного споттера слова активации.
- **Яндекс** — за платформу Станции, качественный речевой стек ASR/TTS и экосистему умного дома.
- **Cloudflare** — за бессерверную платформу Workers и доступ к инференсу Workers AI.

---

## Лицензия

Исходный код репозитория распространяется под лицензией **MIT** (см. [LICENSE](LICENSE)).  
Сторонние компоненты сохраняют исходные лицензии: `quasar-bridge` — Apache-2.0, `station-wakeword` — лицензия автора.
