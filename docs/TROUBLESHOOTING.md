# 🩺 Решение проблем

Сначала — быстрая таблица. Ниже — подробный разбор каждой ситуации.

| Симптом | Куда смотреть |
| --- | --- |
| После «Джарвис» — тишина | [1](#p1) |
| «Сейчас не получилось получить ответ локальной модели» | [2](#p2) |
| «Выключи свет» уходит в LLM и молчит | [3](#p3) |
| Мост не стартует после правки конфига | [4](#p4) |
| Ответ приходит через 10–17 секунд | [5](#p5) |
| Воркер отвечает 401 | [6](#p6) |
| Колонка не подключается по ADB | [7](#p7) |
| Слово активации не срабатывает | [8](#p8) |
| Кольцо мерцает / спорит с Алисой | [9](#p9) |
| Всё сломалось, надо вернуть как было | [10](#p10) |

---

<a id="p1"></a>

## 1. После «Джарвис» — тишина

**Что проверить по порядку.**

1. **Мост жив?**

```powershell
adb shell "wget -q -O - http://127.0.0.1:8443/healthz"
```

Нет ответа → смотрите лог и перезапускайте:

```powershell
adb shell "tail -30 /data/opt/quasar-bridge/bridge.log"
adb shell "/etc/init.d/S99quasar-bridge restart"
```

2. **Запрос дошёл до моста?** В журнале должны быть события `request`,
   `transcript`, `route`:

```powershell
adb shell "tail -10 /data/opt/quasar-bridge/conversations.jsonl"
```

Если `transcript` есть, а `response` нет — проблема на стороне LLM (пункт 2).

3. **Какой маршрут выбран?**

```powershell
adb shell "grep native_route_decision /data/opt/quasar-bridge/bridge.log | tail -5"
```

`route":"llm","source":"default"` — нормально после wake word.
`route":"yandex"` на вопрос к Джарвису — значит фраза попала под правило
`yandex_services` (например, в ней есть «свет» или «погода»).

4. **Воркер отвечает?** Проверьте с ПК:

```powershell
curl.exe -s -H "Authorization: Bearer <JARVIS_KEY>" `
  https://<воркер>.workers.dev/healthz
```

---

<a id="p2"></a>

## 2. Фраза «Сейчас не получилось получить ответ локальной модели»

Это **штатный fallback моста** после 60 секунд ожидания. Значит, запрос ушёл,
но ответ не пришёл. Причины по частоте:

### 2.1. IPv6 до Cloudflare «висит»

Симптом: первый вопрос после перезагрузки висит минуту, потом работает
рывками. Проверка — есть ли IPv6-соединения у моста:

```powershell
adb shell "cat /proc/net/tcp6 | grep -c 2606"
```

Если больше нуля — добавьте IPv4-пины:

```powershell
powershell -ExecutionPolicy Bypass -File scripts\update_cf_pins.ps1 `
  -HostName <воркер>.workers.dev
```

### 2.2. Wi-Fi power save

Симптом: пинг до роутера скачет (70–200 мс), теряются пакеты, крупные
запросы зависают. Проверка:

```powershell
adb shell "cat /sys/devices/platform/unisoc_wifi/power/control"
```

Должно быть `on`. Если `auto` — исправьте (это уже делает `start.sh`):

```powershell
adb shell "echo on > /sys/devices/platform/unisoc_wifi/power/control"
```

### 2.3. Неверный ключ

Воркер вернёт 401, мост — fallback. Проверьте, что ключ в
`/data/opt/quasar-bridge/runtime.env` совпадает с `JARVIS_KEY` воркера и в
файле нет `\r`:

```powershell
adb shell "grep QUASAR_LLM_API_KEY /data/opt/quasar-bridge/runtime.env | cat -A"
```

В конце строки должно быть `$`, а не `^M$`.

### 2.4. Cloudflare недоступен

Проверьте с ПК тот же URL. Если и с ПК не отвечает — временно переключите
мозг на другой провайдер (`scripts/bridge_brain.ps1`) или подождите.

---

<a id="p3"></a>

## 3. Команды умного дома уходят в LLM

Симптом: «выключи свет» → «Для управления светом…» вместо «Выключаю».

Причина: фразы нет в правиле `yandex_services`, и она попадает в
`default_route: llm`.

Решение: добавьте слова в `config.json` → `routing.rules` →
`yandex_services.match.contains_any`, выкатите конфиг и перезапустите мост:

```powershell
adb push config.json /data/opt/quasar-bridge/config.json
adb shell "/etc/init.d/S99quasar-bridge restart"
```

> ⚠️ Только `adb push`. Пересохранение через PowerShell может испортить
> кириллицу, и тогда **все** русские правила перестанут совпадать.

Проверка: `healthz` → `routing_revision` изменился.

---

<a id="p4"></a>

## 4. Мост не стартует после правки конфига

Почти всегда — невалидный JSON (лишняя/пропущенная запятая).

```powershell
adb shell "/data/opt/quasar-bridge/bin/quasar-bridge -config /data/opt/quasar-bridge/config.json -check-backends"
```

Или проверьте локально:

```powershell
python -c "import json;json.load(open('config.json',encoding='utf-8'));print('OK')"
```

Верните последнюю рабочую версию:

```powershell
adb shell "ls -la /data/opt/quasar-bridge/config.json*"
adb shell "cp /data/opt/quasar-bridge/config.json.bak /data/opt/quasar-bridge/config.json"
adb shell "/etc/init.d/S99quasar-bridge restart"
```

---

<a id="p5"></a>

## 5. Ответ идёт 10–17 секунд

Скорее всего, в `config.json` стоит тяжёлая модель (70B) или воркер
переключился на неё как fallback.

1. Проверьте модель:

```powershell
adb shell "grep llm_model /data/opt/quasar-bridge/config.json"
```

2. Поставьте быструю:

```json
"llm_model": "@cf/mistralai/mistral-small-3.1-24b-instruct"
```

3. Проверьте скорость напрямую:

```powershell
curl.exe -s -H "Authorization: Bearer <ключ>" `
  "https://<воркер>.workers.dev/cf/v1/warm?model=@cf/mistralai/mistral-small-3.1-24b-instruct"
```

Ответ `{"ok":true,...,"ms":400}` — модель тёплая. Если `ms` в тысячах —
Cloudflare перегружен, повторите через минуту.

---

<a id="p6"></a>

## 6. Воркер отвечает 401 Unauthorized

- Ключ в заголовке не совпадает с секретом `JARVIS_KEY`.
- В ключе есть пробел/перевод строки.
- Секрет не сохранился при деплое — перезапустите
  `python scripts\deploy_worker.py` с `$env:JARVIS_KEY`.

Проверка:

```powershell
curl.exe -s -o NUL -w "%{http_code}" -H "Authorization: Bearer <ключ>" `
  https://<воркер>.workers.dev/healthz
```

`200` — ключ верный, `401` — нет.

---

<a id="p7"></a>

## 7. Колонка не подключается по ADB

```powershell
ping 192.168.1.50
adb kill-server
adb start-server
adb connect 192.168.1.50:5555
adb devices
```

- `offline` — перезагрузите колонку, повторите.
- `connection refused` — ADB выключен на колонке (включите заново способом,
  которым пользовались при получении root).
- Сменился IP — посмотрите его в приложении роутера или «Дом с Алисой».

---

<a id="p8"></a>

## 8. Слово активации не срабатывает

```powershell
adb shell "/etc/init.d/S97wakeword status"
adb shell "tail -10 /tmp/wakeword.log"
```

- Демон не запущен → `/etc/init.d/S97wakeword restart`.
- В логе `hit` есть, а Алиса не слушает → проблема в связке с `maind`,
  перезагрузите колонку.
- Слишком много ложных срабатываний → добавьте записи «Обычная речь» в
  веб-интерфейсе и переобучите.
- Не слышит вас → запишите слово с разных мест и разной громкостью,
  минимум 10 записей.

Подробнее — [WAKE_WORD.md](WAKE_WORD.md).

---

<a id="p9"></a>

## 9. Кольцо мерцает или спорит с Алисой

`jarvis-led` замечает, что цвет поменял кто-то другой (Алиса), и отступает на
4 секунды. Если мерцание осталось:

```powershell
adb shell "/etc/init.d/S99jarvis-led stop"   # выключить совсем
adb shell "cat /data/opt/jarvis-led/led.log"
```

Убедитесь, что запущен только один экземпляр:

```powershell
adb shell "pidof jarvis-led"
```

---

<a id="p10"></a>

## 10. Полный откат

```powershell
# 1. Голосовой тракт — обратно Яндексу
powershell -ExecutionPolicy Bypass -File scripts\apply_endpoint.ps1 -Rollback

# 2. Остановить мост и подсветку
adb shell "/etc/init.d/S99quasar-bridge stop"
adb shell "/etc/init.d/S99jarvis-led stop"

# 3. (необязательно) убрать IPv4-пины
adb shell "mount -o remount,rw /; cp /data/opt/quasar-bridge/hosts.orig /etc/hosts; sync; mount -o remount,ro /"
```

После этого колонка работает как обычная Алиса. Воркер можно удалить в
дашборде Cloudflare.
