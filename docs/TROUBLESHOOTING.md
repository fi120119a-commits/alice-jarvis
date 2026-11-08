# 🩺 Руководство по устранению неполадок

Справочник по диагностике и решению типовых и нештатных ситуаций при установке и эксплуатации `alice-jarvis`.

---

## Таблица диагностических симптомов

| Симптом | Вероятная первопричина | Раздел решения |
| --- | --- | --- |
| После слова «Джарвис» наступает тишина | Падение моста, сбой классификатора маршрутов или воркера | [Раздел 1](#p1) |
| «Сейчас не получилось получить ответ локальной модели» | Таймаут 60 с: IPv6 blackhole, Wi-Fi sleep или CRLF в ключе | [Раздел 2](#p2) |
| Команда «выключи свет» уходит в LLM вместо выполнения | Отсутствие слова в правиле или повреждение кодировки UTF-8 | [Раздел 3](#p3) |
| `quasar-bridge` не запускается после правки конфига | Синтаксическая ошибка в JSON-файле `config.json` | [Раздел 4](#p4) |
| Ответ формируется с задержкой 10–17 секунд | Вызов тяжёлой модели 70B вместо быстрой 24B | [Раздел 5](#p5) |
| Ошибка 401 Unauthorized от Cloudflare Worker | Несовпадение ключа или символ `\r` (CRLF) в `runtime.env` | [Раздел 6](#p6) |
| Колонка недоступна по ADB (`offline` / `connection refused`) | Смена IP-адреса по DHCP, сбой ADB-сервера или Wi-Fi | [Раздел 7](#p7) |
| Споттер слова активации не реагирует на речь | Не обучена модель или не запущен демон `station-wakeword` | [Раздел 8](#p8) |
| Кольцо LED не горит / служба `jarvis-led` падает | Наличие устаревшего флага `-speed` в init-скрипте (exit code 2) | [Раздел 9](#p9) |
| Ошибка `Read-only file system` при записи в `/etc/` | Системный раздел смонтирован только для чтения | [Раздел 10](#p10) |
| Требуется экстренно вернуть колонку в заводское состояние | Откат изменений в `quasar.cfg` и `/etc/hosts` | [Раздел 11](#p11) |

---

<a id="p1"></a>
## 1. После слова «Джарвис» наступает тишина

Выполните пошаговую диагностическую цепочку:

### 1.1. Проверка статуса сетевого моста
```powershell
adb -s <STATION_IP>:5555 shell "wget -q -O - http://127.0.0.1:8443/healthz"
```
- **Ожидаемый вывод**: JSON со `"status":"ok"` и валидным `routing_revision`.
- **Если вывод пуст или ошибка соединения**: служба моста упала. Проверьте последние 30 строк системного лога:
  ```powershell
  adb -s <STATION_IP>:5555 shell "tail -n 30 /data/opt/quasar-bridge/bridge.log"
  adb -s <STATION_IP>:5555 shell "/etc/init.d/S99quasar-bridge restart"
  ```

### 1.2. Проверка прохождения аудиопотока в журнал
```powershell
adb -s <STATION_IP>:5555 shell "tail -n 10 /data/opt/quasar-bridge/conversations.jsonl"
```
- Если события `request` и `transcript` отсутствуют: ключевое слово не было захвачено споттером или не переключён адрес WebSocket в `quasar.cfg` (см. шаг 4 инструкции по установке).
- Если событие `transcript` зафиксировано, но нет `response`: мост ожидает ответа от облачной модели (перейдите к разделу 2).

### 1.3. Анализ принятого решения о маршрутизации
```powershell
adb -s <STATION_IP>:5555 shell "grep native_route_decision /data/opt/quasar-bridge/bridge.log | tail -n 5"
```
- `route":"llm","source":"default"` — нормальное поведение при вопросе после отдельного слова активации (слово споттера вырезано, срабатывает маршрут по умолчанию).
- `route":"yandex"` на запрос к модели — фраза совпала со списком исключений `yandex_services`.

### 1.4. Прямая проверка доступности Cloudflare Worker
Выполните контрольный запрос с ПК через `curl`:
```powershell
curl.exe -s -H "Authorization: Bearer <JARVIS_KEY>" `
  https://alice-jarvis-llm.<ВАШ_ПОДДОМЕН>.workers.dev/healthz
```
Ответ `{"ok":true}` подтверждает работоспособность облачного шлюза.

---

<a id="p2"></a>
## 2. Фраза «Сейчас не получилось получить ответ локальной модели»

Данная реплика озвучивается штатным fallback-обработчиком `quasar-bridge` по истечении 60-секундного таймаута ожидания ответа от языковой модели.

### 2.1. Зависание трафика по IPv6 (IPv6 Blackhole)
Сетевой интерфейс станции открывает сессию к `workers.dev` через IPv6, но пакеты данных зависают в канале.
Проверьте наличие зависших соединений:
```powershell
adb -s <STATION_IP>:5555 shell "cat /proc/net/tcp6 | grep -c 2606"
```
Если значение больше нуля, зафиксируйте актуальные IPv4-адреса Cloudflare в `/etc/hosts`:
```powershell
powershell -ExecutionPolicy Bypass -File scripts\update_cf_pins.ps1 `
  -Station <STATION_IP>:5555 `
  -HostName alice-jarvis-llm.<ВАШ_ПОДДОМЕН>.workers.dev
```

### 2.2. Активный режим энергосбережения Wi-Fi (Unisoc Wi-Fi Power Save)
Модуль Wi-Fi Станции Лайт засыпает в паузах между пакетами, вызывая задержки до 200 мс и отбрасывание крупных исходящих POST-запросов.
Проверьте текущий режим:
```powershell
adb -s <STATION_IP>:5555 shell "cat /sys/devices/platform/unisoc_wifi/power/control"
```
Если статус `auto` вместо `on`, принудительно отключите спящий режим:
```powershell
adb -s <STATION_IP>:5555 shell "echo on > /sys/devices/platform/unisoc_wifi/power/control"
```
*(Данная команда выполняется автоматически скриптом `src/bridge/start.sh` при старте службы).*

### 2.3. Повреждение ключа авторизации символами CRLF (`\r`)
Если файл `runtime.env` сохранён с окончаниями строк Windows (CRLF), в переменную `QUASAR_LLM_API_KEY` попадает невидимый байт `0x0D` (`\r`), и воркер возвращает статус 401.
Проверьте файл дампом управляющих символов:
```powershell
adb -s <STATION_IP>:5555 shell "grep QUASAR_LLM_API_KEY /data/opt/quasar-bridge/runtime.env | cat -A"
```
- **Правильно**: `export QUASAR_LLM_API_KEY=key$`
- **Ошибка**: `export QUASAR_LLM_API_KEY=key^M$`  
При обнаружении `^M` преобразуйте файл в формат Unix LF и перезапустите мост.

---

<a id="p3"></a>
## 3. Команды умного дома уходят в LLM

**Симптом**: На фразу «Алиса, выключи свет» звучит пространный текстовый ответ модели вместо физического щелчка реле.

**Причина**: Произнесённая фраза не совпала ни с одним шаблоном в правиле `yandex_services.match.contains_any` и попала в `default_route: llm`.

**Решение**:
1. Откройте локальный `config.json` на ПК.
2. Добавьте недостающие ключевые слова (например, «ночник», «подсветку») в массив `contains_any` правила `yandex_services`.
3. Загрузите файл на колонку **строго через `adb push`**:
   ```powershell
   adb -s <STATION_IP>:5555 push config.json /data/opt/quasar-bridge/config.json
   adb -s <STATION_IP>:5555 shell "/etc/init.d/S99quasar-bridge restart"
   ```
   > ⚠️ **Категорически запрещено** использовать для перезаписи конфига команды PowerShell `Get-Content` / `Set-Content`! Они перекодируют кириллицу в кодовую страницу Windows-1251 или UTF-16, в результате чего сломаются все правила маршрутизации.
4. Убедитесь, что контрольный хеш правил изменился:
   ```powershell
   adb -s <STATION_IP>:5555 shell "wget -q -O - http://127.0.0.1:8443/healthz"
   ```

---

<a id="p4"></a>
## 4. Мост не запускается после правки конфигурации

Симптом: `pidof quasar-bridge` возвращает пустоту, эндпоинт `:8443/healthz` недоступен.

**Причина**: Синтаксическая ошибка JSON в `config.json` (пропущенная или лишняя запятая, незакрытая кавычка).

**Диагностика**:
Запустите встроенную валидацию конфигурации через бинарник:
```powershell
adb -s <STATION_IP>:5555 shell "/data/opt/quasar-bridge/bin/quasar-bridge -config /data/opt/quasar-bridge/config.json -check-backends"
```
Или проверьте файл на ПК через Python:
```powershell
python -c "import json; json.load(open('config.json', encoding='utf-8')); print('Синтаксис корректен')"
```

**Восстановление**:
При необходимости восстановите рабочий файл из автоматической резервной копии:
```powershell
adb -s <STATION_IP>:5555 shell "cp /data/opt/quasar-bridge/config.json.bak /data/opt/quasar-bridge/config.json"
adb -s <STATION_IP>:5555 shell "/etc/init.d/S99quasar-bridge restart"
```

---

<a id="p5"></a>
## 5. Ответ формируется с задержкой 10–17 секунд

**Причина**: В конфигурации установлена 70-миллиардная модель (`llama-3.3-70b-instruct`) либо сработал аварийный каскад воркера на 70B из-за недоступности основной модели. Модель 70B на бесплатном тарифе генерирует всего 2–4 токена/с.

**Решение**:
1. Проверьте текущую модель в `config.json`:
   ```powershell
   adb -s <STATION_IP>:5555 shell "grep llm_model /data/opt/quasar-bridge/config.json"
   ```
2. Установите быструю 24B модель с задержкой ответа 2–3 секунды:
   ```json
   "llm_model": "@cf/mistralai/mistral-small-3.1-24b-instruct"
   ```
3. Проверьте время отклика тёплого инстанса напрямую:
   ```powershell
   curl.exe -s -H "Authorization: Bearer <JARVIS_KEY>" `
     "https://alice-jarvis-llm.<ВАШ_ПОДДОМЕН>.workers.dev/cf/v1/warm?model=@cf/mistralai/mistral-small-3.1-24b-instruct"
   ```

---

<a id="p6"></a>
## 6. Воркер возвращает ошибку 401 Unauthorized

**Причины**:
1. Значение `QUASAR_LLM_API_KEY` в `/data/opt/quasar-bridge/runtime.env` не совпадает с секретом `JARVIS_KEY`, зарегистрированным в Cloudflare Worker.
2. В конце строки токена присутствует символ возврата каретки `\r` (CRLF).

**Проверка с ПК**:
```powershell
curl.exe -s -o NUL -w "%{http_code}" -H "Authorization: Bearer <JARVIS_KEY>" `
  https://alice-jarvis-llm.<ВАШ_ПОДДОМЕН>.workers.dev/healthz
```
- Если возвращается `200` — секрет в Cloudflare настроен верно. Проверьте `runtime.env` на колонке.
- Если возвращается `401` — перевыпустите секрет воркера:
  ```powershell
  python scripts\deploy_worker.py
  ```

---

<a id="p7"></a>
## 7. Колонка недоступна по ADB (`offline` / `connection refused`)

1. Проверьте доступность устройства по сетевому уровню ICMP:
   ```powershell
   ping <STATION_IP>
   ```
2. Перезапустите локальный сервер ADB на ПК:
   ```powershell
   adb kill-server
   adb start-server
   adb connect <STATION_IP>:5555
   adb devices
   ```
3. Если статус `offline` — перезагрузите колонку кратковременным отключением кабеля питания.
4. Если `connection refused` — проверьте в настройках роутера, не сменился ли IP-адрес Станции по истечении срока аренды DHCP. Рекомендуется зафиксировать статический IP в роутере по MAC-адресу.

---

<a id="p8"></a>
## 8. Слово активации «Джарвис» не срабатывает

1. Проверьте статус демона споттера и последние записи журнала:
   ```powershell
   adb -s <STATION_IP>:5555 shell "/etc/init.d/S97wakeword status"
   adb -s <STATION_IP>:5555 shell "tail -n 15 /tmp/wakeword.log"
   ```
2. Если в логе фиксируются события `hit`, но колонка не активируется — перезапустите системный процесс `maind`:
   ```powershell
   adb -s <STATION_IP>:5555 shell "killall maind"
   ```
3. При частых ложных срабатываниях или игнорировании речи откройте веб-интерфейс `http://<STATION_IP>:8780` и произведите дообучение:
   - Добавьте 5–8 образцов тишины и обычной речи в категорию отрицательных примеров;
   - Запишите 10–15 чётких произнесений слова «Джарвис» с расстояния 1–3 метра.

---

<a id="p9"></a>
## 9. Проблемы с подсветкой кольца (не горит, горит постоянно, падает демон)

### 9.1. КРИТИЧЕСКИЙ СЛУЧАЙ: Падение службы из-за устаревшего флага `-speed`
**Симптом**: Служба `jarvis-led` не запускается, `pidof jarvis-led` возвращает пустоту, в `/data/opt/jarvis-led/led.log` фиксируется ошибка:
```
flag provided but not defined: -speed
```
Процесс падает с кодом возврата `2`.

**Причина**: В старых версиях init-скрипта передавался флаг `-speed`. В актуальной версии бинарника Go-флаг `-speed` **полностью удалён**.

**Проверка init-скрипта**:
```powershell
adb -s <STATION_IP>:5555 shell "grep start-stop-daemon /etc/init.d/S99jarvis-led"
```
- **Ошибка**: строка содержит `-speed` или `-fps`.
- **Правильно**: аргументы содержат только `-- -bright "$bright"`.

**Исправление**:
Перезапишите init-скрипт из репозитория с безопасным перемонтированием rootfs:
```powershell
adb -s <STATION_IP>:5555 shell "mount -o remount,rw /"
adb -s <STATION_IP>:5555 push src\led\S99jarvis-led /etc/init.d/S99jarvis-led
adb -s <STATION_IP>:5555 shell "chmod 755 /etc/init.d/S99jarvis-led; sync; mount -o remount,ro /"
adb -s <STATION_IP>:5555 shell "/etc/init.d/S99jarvis-led restart"
adb -s <STATION_IP>:5555 shell "pidof jarvis-led"
```

### 9.2. Принудительное гашение «зависшего» свечения
Если кольцо осталось непрерывно светиться после ручных манипуляций с sysfs:
```powershell
adb -s <STATION_IP>:5555 shell "/etc/init.d/S99jarvis-led stop"
adb -s <STATION_IP>:5555 shell "/data/opt/jarvis-led/jarvis-led -mode off"
adb -s <STATION_IP>:5555 shell "/etc/init.d/S99jarvis-led start"
```

### 9.3. Аппаратный самотест светодиодов
Запустите проверочное свечение на 4 секунды в обход голосового тракта:
```powershell
adb -s <STATION_IP>:5555 shell "/data/opt/jarvis-led/jarvis-led -demo 4s"
```
Кольцо обязано равномерно загореться голубым цветом `RGB(40,150,255)` и погаснуть ровно через 4 секунды.

### 9.4. Настройка яркости
Задайте коэффициент яркости в диапазоне `0.1`–`1.0` (по умолчанию `0.75`):
```powershell
adb -s <STATION_IP>:5555 shell "echo 0.8 > /data/opt/jarvis-led/brightness"
adb -s <STATION_IP>:5555 shell "/etc/init.d/S99jarvis-led restart"
```

---

<a id="p10"></a>
## 10. Ошибки файловой системы `Read-only file system`

**Симптом**: При попытке модификации файлов в разделах `/etc/` или `/system/` консоль выводит сообщение `Read-only file system`.

**Причина**: Корневая файловая система Станции смонтирована в режиме защиты от записи (SquashFS / UBIFS `ro`) для предотвращения повреждения флеш-памяти при внезапном отключении питания.

**Безопасный регламент модификации**:
Всегда используйте строгую цепочку с обязательным возвратом в режим `ro` и синхронизацией буферов ядра:
```bash
mount -o remount,rw /
# ... выполнение операций записи или копирования ...
sync
mount -o remount,ro /
```

---

<a id="p11"></a>
## 11. Аварийный откат на штатную прошивку

Для немедленного возврата Станции к оригинальному заводскому состоянию:

```powershell
# 1. Восстановление исходного конфигурационного файла quasar.cfg
powershell -ExecutionPolicy Bypass -File scripts\apply_endpoint.ps1 -Device <STATION_IP>:5555 -Rollback

# 2. Остановка и отключение пользовательских сервисов
adb -s <STATION_IP>:5555 shell "/etc/init.d/S99quasar-bridge stop"
adb -s <STATION_IP>:5555 shell "/etc/init.d/S99jarvis-led stop"
adb -s <STATION_IP>:5555 shell "/etc/init.d/S97wakeword stop"

# 3. Восстановление системного файла /etc/hosts
adb -s <STATION_IP>:5555 shell "mount -o remount,rw / && cp /data/opt/quasar-bridge/hosts.orig /etc/hosts && sync && mount -o remount,ro /"
```

После перезагрузки устройство продолжит функционировать как стандартная Яндекс Станция Лайт.
