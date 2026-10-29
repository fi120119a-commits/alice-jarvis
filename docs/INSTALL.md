# 📦 Установка с нуля

Инструкция рассчитана на человека, который раньше не ставил ничего на Яндекс
Станцию. Идите по шагам сверху вниз — каждый заканчивается проверкой, после
которой можно двигаться дальше.

**Время:** 1–2 часа. **Паяльник не нужен.** Понадобятся только Wi-Fi, ПК и
аккаунт Cloudflare (бесплатный).

---

## 0. Что должно быть готово заранее

| Требование | Как проверить |
| --- | --- |
| Станция Лайт (YNDX-00028), прошивка 3.21 | наклейка на дне / приложение «Дом с Алисой» |
| На колонке получен **root** | `adb shell id` → `uid=0(root)` |
| Включён **ADB по Wi-Fi** | `adb connect <IP>:5555` → `connected` |
| ПК в той же Wi-Fi сети | `ping <IP>` отвечает |
| Python 3.10+ на ПК | `python --version` |
| Аккаунт Cloudflare | [dash.cloudflare.com](https://dash.cloudflare.com) |

> 🔐 Root и ADB — обязательное условие. Способы их получения зависят от
> прошивки и меняются; ищите актуальную инструкцию в сообществе
> (например, wiki проекта hackalice). Этот репозиторий не распространяет
> эксплойты и не модифицирует прошивку.

Установите ADB:

- **Windows:** `winget install Google.PlatformTools`
- **macOS:** `brew install android-platform-tools`
- **Linux:** `sudo apt install android-tools-adb`

---

## 1. Подключаемся к колонке

```powershell
adb connect 192.168.1.50:5555
adb devices
```

В списке должно появиться `192.168.1.50:5555   device` (не `offline`).

Проверяем root и архитектуру:

```powershell
adb -s 192.168.1.50:5555 shell "id; uname -m; cat /proc/version"
```

Ожидаемо: `uid=0(root)`, `aarch64` (или `armv7l`). Запомните архитектуру —
от неё зависит, какой бинарник моста скачивать.

> 💡 Дальше в инструкции везде `192.168.1.50:5555` — замените на свой адрес.
> Все команды `adb` одинаковы на Windows, macOS и Linux. PowerShell-скрипты
> из `scripts/` — только для Windows; для других ОС в шагах есть ручные команды.

---

## 2. Готовим облачный «мозг»

### 2.1. Аккаунт и Workers AI

1. Зарегистрируйтесь на [dash.cloudflare.com](https://dash.cloudflare.com)
   (карта не нужна).
2. В меню слева откройте **Workers & Pages** → **Create** → **Worker**.
   Имя можно любое, например `alice-jarvis-llm`. Не обязательно создавать его
   вручную — скрипт ниже сам загрузит код, но аккаунт должен быть активен.
3. Убедитесь, что доступен **Workers AI** (раздел **AI** в дашборде).
   Бесплатный лимит — 10 000 neurons/сутки, этого с запасом хватает на
   голосового ассистента.

### 2.2. API-токен

1. Откройте [My Profile → API Tokens](https://dash.cloudflare.com/profile/api-tokens).
2. **Create Token** → шаблон **Edit Cloudflare Workers** → **Continue** →
   **Create Token**.
3. Скопируйте токен (показывается один раз).
4. Там же на главной странице дашборда скопируйте **Account ID**
   (правая колонка).

### 2.3. Заполняем `.env`

```powershell
Copy-Item .env.example .env
notepad .env
```

Минимум, что нужно заполнить:

```ini
CF_API_TOKEN=<токен>
CF_ACCOUNT_ID=<account id>
JARVIS_KEY=<длинная случайная строка>
WORKER_NAME=alice-jarvis-llm
STATION_IP=192.168.1.50
```

`JARVIS_KEY` — это пароль к вашему воркеру. Сгенерировать:

```powershell
python -c "import secrets;print(secrets.token_urlsafe(24))"
```

### 2.4. Деплой воркера

```powershell
python -m pip install -r requirements.txt
python scripts\deploy_worker.py
```

Скрипт сам прочитает `.env` — экспортировать переменные вручную не нужно.
Он загрузит код, включит Workers AI, поставит cron-прогрев, сохранит секреты
и проверит ответ модели. В конце выведет:

```
адрес: https://alice-jarvis-llm.<ваш-поддомен>.workers.dev
healthz: 200, холодный 600 мс, тёплый 180 мс
модель: 2400 мс, @cf/mistralai/mistral-small-3.1-24b-instruct
ответ: «Я — Джарвис, сэр. К вашим услугам.»
```

Если `JARVIS_KEY` не был задан заранее, скрипт сгенерирует его и покажет
один раз — сохраните.

**Сохраните адрес** — он понадобится в `.env` и `config.json`.

Проверка «мозга» без колонки:

```powershell
$key = "<ваш JARVIS_KEY>"
curl.exe -s -H "Authorization: Bearer $key" `
  -H "Content-Type: application/json" `
  -d '{\"messages\":[{\"role\":\"user\",\"content\":\"кто ты?\"}],\"max_tokens\":80}' `
  https://alice-jarvis-llm.<ваш-поддомен>.workers.dev/cf/v1/chat/completions
```

Должен прийти JSON с ответом в стиле Джарвиса и словом «сэр».

> 🧠 **Почему не 70B?** Бесплатный 70B генерирует 2–4 токена/с, и голосовой
> ответ идёт 10–17 секунд. По умолчанию используется mistral-small (2–3 с),
> с автоматическим откатом на 8B и 70B, если модель недоступна.

---

## 3. Ставим мост на колонку

Мост — это `quasar-bridge` Сергея Крашевича. Есть два способа установки.

### Вариант A (рекомендуемый): официальный пакет `.yap` через YAM

Если на колонке стоит [YAM](https://github.com/nyakokitsu/yam):

1. Скачайте со [страницы релизов](https://github.com/skrashevich/quasar-bridge/releases/latest)
   пакет `.yap` под свою архитектуру (`linux-arm64` для aarch64) и файл `.sha256`.
2. Проверьте контрольную сумму и установите:

```sh
shasum -a 256 -c quasar-bridge-<версия>-linux-arm64.yap.sha256
export YAM_URL='http://192.168.1.50:8099'
yam install quasar-bridge-<версия>-linux-arm64.yap
yam service enable quasar-bridge
```

Дальше настройте `/data/opt/quasar-bridge/config.json` по шагу 3.3.

### Вариант B: ручная установка бинарника (как в этом репозитории)

Подходит, если YAM нет. Скачайте бинарник со страницы релизов
(`quasar-bridge-linux-arm64` для aarch64, `quasar-bridge-linux-arm` для armv7)
и положите в `vendor/`:

```
alice-jarvis/
└── vendor/
    └── quasar-bridge-linux-arm64
```

Затем на Windows:

```powershell
powershell -ExecutionPolicy Bypass -File scripts\deploy_bridge.ps1 `
  -Device 192.168.1.50:5555 `
  -BinaryPath vendor\quasar-bridge-linux-arm64
```

Вручную (Linux/macOS) — то же самое по шагам:

```bash
adb shell "mkdir -p /data/opt/quasar-bridge/bin"
adb push vendor/quasar-bridge-linux-arm64 /data/opt/quasar-bridge/bin/quasar-bridge
adb push config.json   /data/opt/quasar-bridge/config.json
adb push runtime.env   /data/opt/quasar-bridge/runtime.env
adb push src/bridge/start.sh /data/opt/quasar-bridge/start.sh
adb shell "chmod 755 /data/opt/quasar-bridge/bin/quasar-bridge /data/opt/quasar-bridge/start.sh"
adb shell "chmod 600 /data/opt/quasar-bridge/config.json /data/opt/quasar-bridge/runtime.env"
```

### 3.3. Настройки моста

Скопируйте шаблоны и заполните:

```powershell
Copy-Item config.example.json config.json
Copy-Item runtime.env.example runtime.env
```

В `config.json` замените:

```json
"llm_base_url": "https://alice-jarvis-llm.<ваш-поддомен>.workers.dev/cf/v1",
"llm_model": "@cf/mistralai/mistral-small-3.1-24b-instruct"
```

В `runtime.env` впишите ключ:

```sh
export QUASAR_LLM_API_KEY=<ваш JARVIS_KEY>
```

Те же значения пропишите в `.env`, чтобы скрипты брали их без параметров:

```ini
LLM_BASE_URL=https://alice-jarvis-llm.<ваш-поддомен>.workers.dev/cf/v1
JARVIS_KEY=<ваш JARVIS_KEY>
STATION_IP=192.168.1.50
```

> 💡 Если используете `scripts\deploy_bridge.ps1`, шаги 3.3 и 3.4 он сделает
> сам: скопирует `config.json`, `runtime.env` и `start.sh`, поставит
> автозапуск и перезапустит мост. Ручные команды ниже — для Linux/macOS и
> для понимания того, что происходит.

> ⚠️ `runtime.env` должен быть **в LF**, без `\r`. Иначе ключ приедет с
> невидимым символом, и воркер ответит 401. В Windows сохраняйте через
> редактор с настройкой «LF» или через `git config core.autocrlf false`.

### 3.4. Автозапуск

```powershell
adb shell "mount -o remount,rw /"
adb push src/bridge/S99quasar-bridge /etc/init.d/S99quasar-bridge
adb shell "chmod 755 /etc/init.d/S99quasar-bridge; sync; mount -o remount,ro /"
adb shell "/etc/init.d/S99quasar-bridge restart"
```

Проверка:

```powershell
adb shell "wget -q -O - http://127.0.0.1:8443/healthz"
```

Ожидаемо: JSON со `"status":"ok"` и `"routing_rules":3`.

### 3.5. IPv4-пины Cloudflare (важно!)

На некоторых прошивках IPv6 до `workers.dev` открывает соединение, но данные
не приходят: мост ждёт 60 секунд и отдаёт «Сейчас не получилось получить ответ
локальной модели». Лечится принудительным IPv4 через `/etc/hosts`.

```powershell
powershell -ExecutionPolicy Bypass -File scripts\update_cf_pins.ps1 `
  -Station 192.168.1.50:5555 `
  -HostName alice-jarvis-llm.<ваш-поддомен>.workers.dev
```

Скрипт сам резолвит актуальные IPv4, переписывает `/etc/hosts`, возвращает
rootfs в `ro` и проверяет результат. Если адреса Cloudflare когда-нибудь
сменятся — просто запустите его снова.

---

## 4. Переключаем голосовой тракт

Пока мост работает «вхолостую»: колонка общается с Яндексом напрямую. Теперь
подменяем адрес WebSocket на локальный мост.

```powershell
powershell -ExecutionPolicy Bypass -File scripts\apply_endpoint.ps1 `
  -Device 192.168.1.50:5555
```

Что делает скрипт:

1. сохраняет исходный `quasar.cfg` в `bridge/backup/quasar.cfg.orig`;
2. ставит `uniProxyUrl = ws://127.0.0.1:8443/uni.ws`;
3. перезагружает колонку и проверяет мост.

Через ~45 секунд после перезагрузки скажите:

> «Алиса, который час»

Если ответила — тракт переключён. Если нет — откат:

```powershell
powershell -ExecutionPolicy Bypass -File scripts\apply_endpoint.ps1 -Rollback
```

---

## 5. Слово активации «Джарвис»

Ставится отдельным демоном
[station-wakeword](https://github.com/tangenx/station-wakeword) — он слушает
поток микрофона после эхоподавления и «нажимает кнопку» Алисы, когда слышит
слово.

Кратко:

1. Скачайте релиз `station-wakeword` (статический бинарник под вашу
   архитектуру) и `negatives.bin`.
2. Разложите на колонке:

```powershell
adb shell "mkdir -p /data/wakeword"
adb push wakeword      /data/wakeword/wakeword
adb push negatives.bin /data/wakeword/negatives.bin
adb shell "chmod 755 /data/wakeword/wakeword"
```

3. Установите автозапуск `S97wakeword` из релиза проекта.
4. Откройте `http://192.168.1.50:8780`, запишите 10–15 раз слово «Джарвис»
   и нажмите «Обучить».

Подробная методика записи — в [WAKE_WORD.md](WAKE_WORD.md).

---

## 6. Проверяем всё вместе

```powershell
# 1. Мост жив
adb shell "wget -q -O - http://127.0.0.1:8443/healthz"

# 2. Маршруты: «свет» → yandex, «Джарвис» → llm
adb shell "grep native_route_decision /data/opt/quasar-bridge/bridge.log | tail -5"

# 3. Последние ответы и задержки
adb shell "grep '\"event\":\"response\"' /data/opt/quasar-bridge/conversations.jsonl | tail -5"
```

Голосом:

| Фраза | Ожидание |
| --- | --- |
| «Джарвис, кто ты?» | ответ LLM, 2–4 с, обращение «сэр» |
| «Джарвис, почему небо голубое?» | короткое объяснение |
| «Алиса, выключи свет» | штатный умный дом |
| «Алиса, погода на завтра» | штатный сервис |

Если первый ответ после долгого простоя идёт 10+ секунд — это нормально для
бесплатного тарифа; прогревочный cron в воркере снижает эффект.

---

## 7. Подсветка кольца (необязательно)

```powershell
cd src\led
$env:GOOS="linux"; $env:GOARCH="arm"; $env:GOARM="7"; $env:CGO_ENABLED="0"
go build -trimpath -ldflags="-s -w" -o jarvis-led .
cd ..\..
adb shell "mkdir -p /data/opt/jarvis-led"
adb push src\led\jarvis-led /data/opt/jarvis-led/jarvis-led
adb push src\led\S99jarvis-led /etc/init.d/S99jarvis-led
adb shell "chmod 755 /data/opt/jarvis-led/jarvis-led /etc/init.d/S99jarvis-led"
adb shell "/etc/init.d/S99jarvis-led restart"
```

Для aarch64 соберите с `GOARCH=arm64` и `GOARM` не задавайте.

Яркость:

```powershell
adb shell "echo 0.4 > /data/opt/jarvis-led/brightness; /etc/init.d/S99jarvis-led restart"
```

---

## 8. Автозапуск после перезагрузки

Всё уже настроено init-скриптами:

| Скрипт | Что запускает |
| --- | --- |
| `/etc/init.d/S97wakeword` | слово активации |
| `/etc/init.d/S99quasar-bridge` | мост + watchdog (перезапуск через 5 с) |
| `/etc/init.d/S99jarvis-led` | подсветка |

Проверка: `adb reboot`, подождите 60 секунд, затем:

```powershell
adb connect 192.168.1.50:5555
adb shell "pidof quasar-bridge; wget -q -O - http://127.0.0.1:8443/healthz"
```

---

## 9. Необязательно: режим ПК

Мост умеет отправлять запросы не в облако, а на ваш ПК — если нужен доступ
к инструментам Windows (громкость, окна, скриншоты, выключение).

1. Поднимите на ПК любой OpenAI-совместимый сервер на `0.0.0.0:8765`.
2. Переключите мозг:

```powershell
powershell -ExecutionPolicy Bypass -File scripts\bridge_brain.ps1 -Mode pc -Device 192.168.1.50:5555
```

3. Вернуть облако:

```powershell
powershell -ExecutionPolicy Bypass -File scripts\bridge_brain.ps1 -Mode cloud -Device 192.168.1.50:5555
```

> В облачном режиме ПК не нужен вообще — это и есть рекомендуемая схема.

---

## 10. Обновление

- **Воркер:** правьте `src/worker/cloudflare-proxy.js` и снова запускайте
  `python scripts\deploy_worker.py`.
- **Конфиг моста:** меняйте `config.json`, затем
  `adb push config.json /data/opt/quasar-bridge/config.json` и
  `/etc/init.d/S99quasar-bridge restart`.
- **Мост:** скачайте новый бинарник и повторите шаг 3 (Вариант B).

> ⚠️ Конфиг на колонку выкатывайте **только** `adb push` исходного файла.
> PowerShell `Get-Content`/`Set-Content` может перекодировать UTF-8, и русские
> фразы в правилах перестанут совпадать (мост будет молча уходить в
> `default_route`).

---

## 11. Полный откат

```powershell
# вернуть голосовой тракт Яндексу
powershell -ExecutionPolicy Bypass -File scripts\apply_endpoint.ps1 -Rollback

# остановить мост
adb shell "/etc/init.d/S99quasar-bridge stop"

# остановить подсветку (если ставили)
adb shell "/etc/init.d/S99jarvis-led stop"
```

Колонка снова полностью в облаке Яндекса. Воркер можно удалить в дашборде
Cloudflare.
