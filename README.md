# 🎙️ Alice Jarvis

[![License: MIT](https://img.shields.io/badge/license-MIT-green.svg)](LICENSE)
[![Platform](https://img.shields.io/badge/platform-Yandex%20Station%20Lite-ffcc00.svg)](docs/INSTALL.md)
[![LLM](https://img.shields.io/badge/LLM-Cloudflare%20Workers%20AI-blue.svg)](src/worker/cloudflare-proxy.js)

**«Джарвис, кто ты?»** — и Яндекс Станция отвечает голосом Алисы, но текстом
большой языковой модели в образе J.A.R.V.I.S. из «Железного человека».

Проект превращает обычную колонку в голосового ИИ-ассистента: распознавание речи
и озвучка остаются у Яндекса (знакомый голос, хорошее качество), а «мозгом»
становится бесплатная LLM в облаке. Компьютер для работы **не нужен**.

> ⚠️ Проект неофициальный и не связан с Яндексом. Для установки нужен root
> и ADB на колонке. Всё, что вы делаете, — на ваш риск.

---

## ✨ Что это умеет

- 🗣️ **Своё слово активации** — «Джарвис» вместо (или вместе с) «Алисы».
- 🧠 **Ответы от LLM** — Cloudflare Workers AI, бесплатно, без карты и VPN.
- 🎭 **Характер J.A.R.V.I.S.** — формальный тон, «сэр/мисс», лёгкий сарказм.
- 🏠 **Умный дом не ломается** — свет, розетки, шторы, музыка, погода, таймеры
  по-прежнему уходят штатной Алисе.
- 💡 **Подсветка кольца** — ровный голубой, пока Джарвис отвечает; в покое кольцо выключено.
- 🔌 **Работает без ПК** — весь путь живёт на колонке и в облаке.
- 🩺 **Понятная диагностика** — журнал разговоров, маршруты, healthz.

## 🧠 Как это работает

```
«Джарвис, почему небо голубое»
        │
        ▼
[wakeword на колонке]  услышал слово → включает микрофон
        │
        ▼
[облако Яндекса]  ASR: текст  +  TTS: озвучка ответа
        │  ws://127.0.0.1:8443/uni.ws
        ▼
[quasar-bridge на колонке]  решает, кому отдать запрос
        ├─ погода / музыка / таймеры / свет  → Яндекс
        └─ всё остальное                     → LLM
        ▼
[Cloudflare Worker]  вшивает персонажа → Workers AI (mistral-small / llama)
        │
        ▼
текст → назад в мост → Алиса говорит
```

Колонка **не перепрошивается**: подменяется только адрес голосового WebSocket
в `/system/vendor/quasar/quasar.cfg` — штатный механизм, который используют
другие проекты для Яндекс Станций.

Подробности — в [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).

## 🚀 Что нужно

| Что | Зачем |
| --- | --- |
| Яндекс Станция Лайт (YNDX-00028) | железо; нужен **root + ADB** |
| Wi-Fi сеть, ПК в ней же | установка и обслуживание |
| [ADB](https://developer.android.com/tools/releases/platform-tools) | доступ к колонке |
| Аккаунт Cloudflare (бесплатный) | воркер + Workers AI |
| Python 3.10+ | деплой воркера (`scripts/deploy_worker.py`) |
| Go 1.21+ (опционально) | только для сборки подсветки |

Карта, VPN и платные подписки не нужны.

## 📦 Установка

Полная пошаговая инструкция — **[docs/INSTALL.md](docs/INSTALL.md)**.
Коротко:

```powershell
# 1. Клонируем и готовим конфиги
git clone https://github.com/fi120119a-commits/alice-jarvis.git
cd alice-jarvis
Copy-Item config.example.json config.json
Copy-Item runtime.env.example runtime.env
Copy-Item .env.example .env       # заполните CF_API_TOKEN, CF_ACCOUNT_ID, JARVIS_KEY, STATION_IP

# 2. Деплоим облачный мозг (ключи берутся из .env)
python -m pip install -r requirements.txt
python scripts\deploy_worker.py

# 3. Вписываем выданный адрес в .env (LLM_BASE_URL) и config.json (llm_base_url),
#    а JARVIS_KEY — в runtime.env (QUASAR_LLM_API_KEY).
#    Бинарник моста скачайте в vendor/ — см. docs/INSTALL.md, шаг 3.

# 4. Ставим мост и настройки на колонку (адрес тоже берётся из .env)
powershell -ExecutionPolicy Bypass -File scripts\deploy_bridge.ps1

# 5. Переключаем голосовой тракт (с бэкапом и откатом)
powershell -ExecutionPolicy Bypass -File scripts\apply_endpoint.ps1

# 6. Проверяем
adb -s 192.168.1.50:5555 shell "wget -q -O - http://127.0.0.1:8443/healthz"
```

Слово активации «Джарвис» ставится отдельно — см.
[docs/WAKE_WORD.md](docs/WAKE_WORD.md) (демон
[tangenx/station-wakeword](https://github.com/tangenx/station-wakeword)).

## 🗣️ Примеры

| Вы говорите | Что происходит |
| --- | --- |
| «Джарвис, кто ты?» | ответ в образе J.A.R.V.I.S. |
| «Джарвис, почему небо голубое?» | короткое объяснение от LLM |
| «Джарвис, что такое квантовая запутанность?» | технический ответ |
| «Алиса, выключи свет» | штатный умный дом Яндекса |
| «Алиса, погода на завтра» | штатный сервис Яндекса |
| «Алиса, поставь таймер на 10 минут» | штатный таймер |

Команды ПК (хром, громкость, скриншот) в текущей конфигурации **отключены** —
их можно вернуть, направив правило `pc_commands` на свой OpenAI-совместимый
сервер (см. [docs/INSTALL.md](docs/INSTALL.md#9-необязательно-режим-пк)).

## 🎛️ Настройка

- **Персонаж** — константа `DEFAULT_SYSTEM` в `src/worker/cloudflare-proxy.js`
  (или секрет воркера `JARVIS_SYSTEM`). Меняете текст →
  `python scripts/deploy_worker.py`.
- **Модель** — `llm_model` в `config.json`. По умолчанию
  `@cf/mistralai/mistral-small-3.1-24b-instruct`; в воркере есть цепочка
  отказов на 8B и 70B.
- **Маршруты** — `routing.rules` в `config.json`: какие фразы отдавать Яндексу,
  а какие — модели.
- **Слово активации** — веб-интерфейс `http://<IP-колонки>:8780`.
- **Смена «мозга»** — `scripts/bridge_brain.ps1` (cloud / pc / openrouter / custom).

## 🩺 Диагностика

```powershell
# состояние моста
adb -s 192.168.1.50:5555 shell "wget -q -O - http://127.0.0.1:8443/healthz"

# последние ответы: маршрут, текст, задержка
adb -s 192.168.1.50:5555 shell "grep '\"event\":\"response\"' /data/opt/quasar-bridge/conversations.jsonl | tail -5"

# почему выбран маршрут
adb -s 192.168.1.50:5555 shell "grep native_route_decision /data/opt/quasar-bridge/bridge.log | tail -10"
```

Если колонка молчит — [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md).

## 🤝 Благодарности

Проект не существовал бы без этих людей и их открытого кода:

- **Сергей Крашевич ([@skrashevich](https://github.com/skrashevich))** —
  автор **[quasar-bridge](https://github.com/skrashevich/quasar-bridge)**,
  Apache-2.0. Именно этот проект перехватывает голосовой трафик станции и
  позволяет Алисе отвечать через стороннюю LLM. Наша конфигурация, маршрутизация
  и установка построены вокруг него — **основа и вдохновение проекта**.
- **[tangenx](https://github.com/tangenx)** — автор
  **[station-wakeword](https://github.com/tangenx/station-wakeword)**,
  демона своего слова активации.
- **Яндекс** — за Алису, её ASR/TTS и умный дом, которыми мы пользуемся как есть.
- **Cloudflare** — за бесплатный Workers AI.

Если вы используете код quasar-bridge в своих сборках, соблюдайте условия
Apache-2.0: сохраняйте уведомления и указывайте изменения (см. [NOTICE](NOTICE)).

## 📄 Лицензия

Код этого репозитория — **MIT**, см. [LICENSE](LICENSE).
Сторонние компоненты сохраняют свои лицензии: quasar-bridge — Apache-2.0,
station-wakeword — см. репозиторий автора.
