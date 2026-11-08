# 📦 Установка и развёртывание

Пошаговое руководство по установке голосового ассистента Джарвис на Яндекс Станцию Лайт (YNDX-00028).

---

## 0. Предварительные требования

| Параметр | Требование | Метод проверки |
| --- | --- | --- |
| Устройство | Яндекс Станция Лайт (модель `YNDX-00028`) | Маркировка на нижней крышке корпуса |
| Привилегии ОС | Права **root** на колонке | `adb shell id` $\to$ `uid=0(root)` |
| Сетевой интерфейс | Включённый сервер ADB по Wi-Fi (порт 5555) | `adb connect <STATION_IP>:5555` $\to$ `connected` |
| Локальная сеть | ПК и колонка в одном широковещательном сегменте Wi-Fi | `ping <STATION_IP>` |
| Окружение ПК | Python 3.10+ с менеджером пакетов `pip` | `python --version` |
| Утилиты ОС | Пакет `platform-tools` (ADB) на ПК | `adb version` |
| Облачный сервис | Аккаунт Cloudflare с доступом к Workers AI | Авторизация на [dash.cloudflare.com](https://dash.cloudflare.com) |

> ⚠️ Установка ADB:
> - **Windows:** `winget install Google.PlatformTools`
> - **macOS:** `brew install android-platform-tools`
> - **Linux:** `sudo apt install android-tools-adb`

---

## 1. Подключение к Станции по ADB

Подключитесь к колонке через сетевой интерфейс ADB:

```powershell
adb connect <STATION_IP>:5555
adb devices
```

Убедитесь, что устройство отображается со статусом `device` (не `offline` и не `unauthorized`).

Проверьте уровень привилегий и аппаратную архитектуру:

```powershell
adb -s <STATION_IP>:5555 shell "id; uname -m; cat /proc/version"
```

> ⚠️ **Архитектурная особенность Станции Лайт:**  
> Ядро Linux сообщает `aarch64` (`uname -m`), однако пользовательское окружение Buildroot является **32-битным (ARMv7 / `armv7l`)**.  
> Попытка запуска 64-битных бинарников (`linux-arm64`) вызывает системную ошибку `-sh: ./binary: cannot execute binary file: Exec format error`.  
> Все исполняемые файлы для колонки (`quasar-bridge`, `jarvis-led`, `wakeword`) обязаны быть собраны строго под **ARMv7** (`GOOS=linux GOARCH=arm GOARM=7`).

---

## 2. Развёртывание облачного «мозга» (Cloudflare Workers AI)

### 2.1. Создание API-токена Cloudflare

1. Откройте консоль управления [dash.cloudflare.com](https://dash.cloudflare.com).
2. Перейдите в **My Profile** $\to$ **API Tokens** $\to$ **Create Token**.
3. Выберите шаблон **Edit Cloudflare Workers** (права `Workers Scripts:Edit`).
4. Нажмите **Continue to summary** $\to$ **Create Token**. Скопируйте сгенерированный токен.
5. На главной странице панели Cloudflare в правой колонке скопируйте **Account ID**.

### 2.2. Настройка виртуального окружения и `.env`

Создайте изолированное окружение Python и установите зависимости деплоя:

```powershell
python -m venv .venv
.\.venv\Scripts\Activate.ps1
pip install -r requirements.txt
```

Создайте рабочий файл `.env` из шаблона:

```powershell
Copy-Item .env.example .env
notepad .env
```

Заполните обязательные переменные:

```ini
CF_API_TOKEN=<ВАШ_CLOUDFLARE_API_ТОКЕН>
CF_ACCOUNT_ID=<ВАШ_CLOUDFLARE_ACCOUNT_ID>
WORKER_NAME=alice-jarvis-llm
JARVIS_KEY=<ДЛИННАЯ_СЛУЧАЙНАЯ_СТРОКА_АВТОРИЗАЦИИ>
STATION_IP=<STATION_IP>
STATION_ADB_PORT=5555
```

Генерация ключа `JARVIS_KEY`:

```powershell
python -c "import secrets; print(secrets.token_urlsafe(24))"
```

### 2.3. Публикация воркера

Запустите скрипт автоматического деплоя:

```powershell
python scripts\deploy_worker.py
```

Скрипт выполняет:
1. Загрузку исходного кода `src/worker/cloudflare-proxy.js`.
2. Привязку среды инференса Cloudflare Workers AI (`AI`).
3. Регистрацию секрета `JARVIS_KEY` в окружении воркера.
4. Настройку Cron Triggers (`*/10 * * * *`) для фонового прогрева модели каждые 10 минут.
5. Тестовый инференс модели `@cf/mistralai/mistral-small-3.1-24b-instruct`.

После завершения скрипт выведет публичный URL:
```
https://alice-jarvis-llm.<ВАШ_ПОДДОМЕН>.workers.dev
```

Проверьте работу эндпоинта напрямую с ПК:

```powershell
curl.exe -s -H "Authorization: Bearer <JARVIS_KEY>" `
  -H "Content-Type: application/json" `
  -d "{\"messages\":[{\"role\":\"user\",\"content\":\"кто ты?\"}],\"max_tokens\":80}" `
  https://alice-jarvis-llm.<ВАШ_ПОДДОМЕН>.workers.dev/cf/v1/chat/completions
```

Ожидаемый ответ: JSON-объект в стандарте OpenAI с репликой персонажа J.A.R.V.I.S. и обращением «сэр/мисс».

---

## 3. Установка и настройка `quasar-bridge`

Мост `quasar-bridge` выполняет перехват голосового сеанса, локальную классификацию намерений и проксирование запросов.

### 3.1. Получение бинарного файла

Скачайте скомпилированный бинарник для ARM32 (`quasar-bridge-linux-arm`) со страницы релизов [skrashevich/quasar-bridge](https://github.com/skrashevich/quasar-bridge/releases/latest) и поместите его в каталог `vendor/`:

```
alice-jarvis/
└── vendor/
    └── quasar-bridge-linux-arm
```

### 3.2. Конфигурация моста (`config.json` и `runtime.env`)

Создайте файлы конфигурации:

```powershell
Copy-Item config.example.json config.json
Copy-Item runtime.env.example runtime.env
```

В `config.json` укажите адрес опубликованного воркера:

```json
"llm_base_url": "https://alice-jarvis-llm.<ВАШ_ПОДДОМЕН>.workers.dev/cf/v1",
"llm_model": "@cf/mistralai/mistral-small-3.1-24b-instruct"
```

В `runtime.env` задайте параметры рантайма и токен доступа:

```sh
export QUASAR_LLM_API_KEY=<JARVIS_KEY>
export GOMAXPROCS=1
export GOMEMLIMIT=64MiB
export SSL_CERT_FILE=/system/vendor/quasar/ca-certificates.crt
```

> ⚠️ **КРИТИЧЕСКИЕ ТРЕБОВАНИЯ К `runtime.env`:**
> 1. Файл подключается через шелл (`. "$DIR/runtime.env"`). Все переменные объявляются с директивой `export`.
> 2. **Формат строк строго LF (Unix)**. Наличие символов возврата каретки CRLF (`0x0D` / `\r`) приводит к фатальным сбоям:
>    - `GOMEMLIMIT="64MiB\r"` вызывает панику Go-рантайма при старте бинарника: `invalid GOMEMLIMIT value`.
>    - `QUASAR_LLM_API_KEY="key\r"` отправляет токен с невидимым переводом строки в заголовке `Authorization`, вызывая `401 Unauthorized` от Cloudflare Worker.

### 3.3. Развёртывание на колонку через PowerShell

```powershell
powershell -ExecutionPolicy Bypass -File scripts\deploy_bridge.ps1 `
  -Device <STATION_IP>:5555 `
  -BinaryPath vendor\quasar-bridge-linux-arm
```

### 3.4. Ручное развёртывание (Linux / macOS)

```bash
# 1. Создание каталогов
adb -s <STATION_IP>:5555 shell "mkdir -p /data/opt/quasar-bridge/bin"

# 2. Передача файлов с сохранением кодировки UTF-8 и прав
adb -s <STATION_IP>:5555 push vendor/quasar-bridge-linux-arm /data/opt/quasar-bridge/bin/quasar-bridge
adb -s <STATION_IP>:5555 push config.json /data/opt/quasar-bridge/config.json
adb -s <STATION_IP>:5555 push runtime.env /data/opt/quasar-bridge/runtime.env
adb -s <STATION_IP>:5555 push src/bridge/start.sh /data/opt/quasar-bridge/start.sh

adb -s <STATION_IP>:5555 shell "chmod 755 /data/opt/quasar-bridge/bin/quasar-bridge /data/opt/quasar-bridge/start.sh"
adb -s <STATION_IP>:5555 shell "chmod 600 /data/opt/quasar-bridge/config.json /data/opt/quasar-bridge/runtime.env"

# 3. Установка init-скрипта на read-only раздел
adb -s <STATION_IP>:5555 shell "mount -o remount,rw /"
adb -s <STATION_IP>:5555 push src/bridge/S99quasar-bridge /etc/init.d/S99quasar-bridge
adb -s <STATION_IP>:5555 shell "chmod 755 /etc/init.d/S99quasar-bridge; sync; mount -o remount,ro /"

# 4. Запуск службы
adb -s <STATION_IP>:5555 shell "/etc/init.d/S99quasar-bridge restart"
```

Проверьте статус службы моста:

```powershell
adb -s <STATION_IP>:5555 shell "wget -q -O - http://127.0.0.1:8443/healthz"
```

Ожидаемый ответ: JSON с полями `"status":"ok"` и валидным хешем `routing_revision`.

---

## 3.5. Привязка IPv4-пинов Cloudflare (предотвращение таймаутов IPv6)

В сетевом стеке Buildroot на Станции Лайт наблюдается проблема зависания IPv6-трафика (blackhole): при обращении к `*.workers.dev` соединение инициируется через IPv6, но пакеты данных отбрасываются. Мост ожидает ответа 60 секунд и отдаёт голосовую заглушку («Сейчас не получилось получить ответ локальной модели»).

Запустите скрипт принудительной фиксации IPv4 A-записей в `/etc/hosts`:

```powershell
powershell -ExecutionPolicy Bypass -File scripts\update_cf_pins.ps1 `
  -Station <STATION_IP>:5555 `
  -HostName alice-jarvis-llm.<ВАШ_ПОДДОМЕН>.workers.dev
```

Скрипт безопасно перемонтирует rootfs в `rw`, обновляет `/etc/hosts` и возвращает раздел в `ro`.

---

## 4. Переключение голосового тракта колонки

Переключение адреса Uniproxy в системном файле `/system/vendor/quasar/quasar.cfg`:

```powershell
powershell -ExecutionPolicy Bypass -File scripts\apply_endpoint.ps1 -Device <STATION_IP>:5555
```

Скрипт выполняет:
1. Резервное копирование оригинального файла в `.backup/quasar.cfg.orig`.
2. Замену `aliced.uniProxyUrl` на `ws://127.0.0.1:8443/uni.ws`.
3. Перезагрузку колонки (`adb reboot`).

После перезагрузки (спустя ~45 секунд) произнесите проверочную фразу:
> «Алиса, который час»

Если колонка штатно озвучивает текущее время, голосовой перехват функционирует корректно.

---

## 5. Настройка слова активации «Джарвис»

1. Разверните бинарник споттера `station-wakeword` и модель отрицательных примеров `negatives.bin`:

```powershell
adb -s <STATION_IP>:5555 shell "mkdir -p /data/wakeword"
adb -s <STATION_IP>:5555 push wakeword /data/wakeword/wakeword
adb -s <STATION_IP>:5555 push negatives.bin /data/wakeword/negatives.bin
adb -s <STATION_IP>:5555 shell "chmod 755 /data/wakeword/wakeword"
```

2. Установите службу автозапуска:

```powershell
adb -s <STATION_IP>:5555 shell "mount -o remount,rw /"
adb -s <STATION_IP>:5555 push src/wakeword/S97wakeword /etc/init.d/S97wakeword
adb -s <STATION_IP>:5555 shell "chmod 755 /etc/init.d/S97wakeword; sync; mount -o remount,ro /"
adb -s <STATION_IP>:5555 shell "/etc/init.d/S97wakeword start"
```

3. Откройте веб-интерфейс обучения по адресу `http://<STATION_IP>:8780`:
   - Запишите 8 секунд фонового шума помещения.
   - Запишите 10–15 образцов ключевого слова «Джарвис» с различных дистанций и разной интонацией.
   - Нажмите **Train Model**.

---

## 6. Служба индикации светодиодного кольца (`jarvis-led`)

### 6.1. Сборка бинарника (опционально)

Готовый скомпилированный бинарник находится в репозитории по пути `src/led/jarvis-led`. Для самостоятельной сборки из исходников выполните:

```bash
cd src/led
GOOS=linux GOARCH=arm GOARM=7 CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o jarvis-led .
```

### 6.2. Установка бинарника и init-скрипта

```powershell
# 1. Загрузка бинарника в постоянный раздел
adb -s <STATION_IP>:5555 shell "mkdir -p /data/opt/jarvis-led"
adb -s <STATION_IP>:5555 push src\led\jarvis-led /data/opt/jarvis-led/jarvis-led
adb -s <STATION_IP>:5555 shell "chmod 755 /data/opt/jarvis-led/jarvis-led"

# 2. Безопасное обновление init-скрипта с перемонтированием rootfs
adb -s <STATION_IP>:5555 shell "mount -o remount,rw /"
adb -s <STATION_IP>:5555 push src\led\S99jarvis-led /etc/init.d/S99jarvis-led
adb -s <STATION_IP>:5555 shell "chmod 755 /etc/init.d/S99jarvis-led; sync; mount -o remount,ro /"
```

> ⚠️ **КРИТИЧЕСКОЕ ИЗМЕНЕНИЕ: УДАЛЕНИЕ ФЛАГА `-speed`**  
> В актуальной версии демона `jarvis-led` флаг `-speed` **полностью удалён**.  
> Если передать скрипту или демону устаревший флаг `-speed`, стандартная функция парсинга аргументов Go `flag.Parse()` генерирует фатальную ошибку:  
> `flag provided but not defined: -speed` и аварийно завершает процесс с кодом возврата `2`.  
> Скрипт `src/led/S99jarvis-led` передаёт исключительно флаг яркости:  
> `start-stop-daemon ... --startas "$binary" -- -bright "$bright"`.

### 6.3. Логика и поведение подсветки

- **Режим озвучки ответа**: Кольцо светится равномерным голубым цветом `RGB(40,150,255)` с мягким синусоидальным «дыханием» (яркость модулируется от 0.55 до 1.0 на частоте 0.9 Гц) **строго во время воспроизведения речи Джарвиса**.
- **Оценка длительности речи**: Длительность свечения рассчитывается автоматически по объёму текста:  
  $$T = 2.5 + \frac{\text{len(runes)}}{14.0}$$  
  Значение жёстко ограничено интервалом `[4.0s, 28.0s]`.
- **Режим покоя (Idle)**: После завершения фразы светодиодное кольцо полностью отключается (`RGB(0,0,0)`). Демон освобождает доступ к аппаратным узлам sysfs `/sys/class/leds/micro:{red,green,blue}:ring{1,2,3}/brightness`, возвращая управление штатному процессу Алисы (`maind`). Все системные анимации (фиолетовая волна активации, шкала громкости, красный индикатор mute) работают в штатном режиме.

### 6.4. Проверка и запуск службы

Тестовый прогон аппаратного свечения на 4 секунды без голоса:

```powershell
adb -s <STATION_IP>:5555 shell "/data/opt/jarvis-led/jarvis-led -demo 4s"
```

Запуск службы и проверка PID:

```powershell
adb -s <STATION_IP>:5555 shell "/etc/init.d/S99jarvis-led restart"
adb -s <STATION_IP>:5555 shell "pidof jarvis-led"
```

Настройка пользовательской яркости (значение от `0.1` до `1.0`, по умолчанию `0.75`):

```powershell
adb -s <STATION_IP>:5555 shell "echo 0.8 > /data/opt/jarvis-led/brightness && /etc/init.d/S99jarvis-led restart"
```

---

## 7. Комплексная проверка системы

1. **Проверка активных служб**:

```powershell
adb -s <STATION_IP>:5555 shell "pidof quasar-bridge && pidof jarvis-led && pidof wakeword"
```

2. **Голосовой тест ИИ-ассистента**:  
   Произнесите: «Джарвис, кто ты?».  
   *Критерий успеха*: Колонка озвучивает ответ персонажа J.A.R.V.I.S. Задержка до начала речи составляет 2–3 секунды. В момент начала речи кольцо загорается голубым цветом с мягкой пульсацией и полностью гаснет сразу после окончания речи.

3. **Проверка штатного умного дома**:  
   Произнесите: «Алиса, включи свет» или «Алиса, который час».  
   *Критерий успеха*: Команда обрабатывается мгновенно штатным сервисом Яндекса. Подсветка `jarvis-led` не активируется.

---

## 8. Автозапуск и устойчивость к перезагрузкам

Все службы зарегистрированы в `/etc/init.d/` и запускаются системой инициализации BusyBox в алфавитном порядке:

| Скрипт | Назначение | Порядок старта |
| --- | --- | --- |
| `/etc/init.d/S97wakeword` | Фоновый аудио-споттер слова «Джарвис» | 97 |
| `/etc/init.d/S99quasar-bridge` | Сетевой мост и маршрутизатор WebSocket | 99 |
| `/etc/init.d/S99jarvis-led` | Демон адаптивной светодиодной индикации | 99 |

Проверьте устойчивость после перезагрузки:

```powershell
adb -s <STATION_IP>:5555 reboot
```

Спустя 60 секунд восстановите соединение и проверьте работу служб:

```powershell
adb connect <STATION_IP>:5555
adb -s <STATION_IP>:5555 shell "wget -q -O - http://127.0.0.1:8443/healthz && pidof jarvis-led"
```

---

## 9. Регламент обновления

- **Обновление системного промпта или воркера**:  
  Отредактируйте `src/worker/cloudflare-proxy.js` $\to$ выполните `python scripts\deploy_worker.py`.
- **Обновление правил маршрутизации**:  
  Отредактируйте `config.json` на ПК $\to$ загрузите strictly через `adb push`:  
  ```powershell
  adb -s <STATION_IP>:5555 push config.json /data/opt/quasar-bridge/config.json
  adb -s <STATION_IP>:5555 shell "/etc/init.d/S99quasar-bridge restart"
  ```
  *(Категорически запрещено применять PowerShell `Set-Content` во избежание повреждения UTF-8).*

---

## 10. Процедура полного отката

Для возврата Станции к штатному заводскому состоянию:

```powershell
# 1. Возврат оригинального голосового тракта quasar.cfg
powershell -ExecutionPolicy Bypass -File scripts\apply_endpoint.ps1 -Device <STATION_IP>:5555 -Rollback

# 2. Остановка кастомных служб
adb -s <STATION_IP>:5555 shell "/etc/init.d/S99quasar-bridge stop"
adb -s <STATION_IP>:5555 shell "/etc/init.d/S99jarvis-led stop"
adb -s <STATION_IP>:5555 shell "/etc/init.d/S97wakeword stop"

# 3. Восстановление исходного /etc/hosts
adb -s <STATION_IP>:5555 shell "mount -o remount,rw / && cp /data/opt/quasar-bridge/hosts.orig /etc/hosts && sync && mount -o remount,ro /"
```
