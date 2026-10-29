#!/bin/sh
# Запуск quasar-bridge на Яндекс Станции (Buildroot, BusyBox).
#
# Вызывается из /etc/init.d/S99quasar-bridge, вручную запускать не нужно.
# Все настройки — в runtime.env рядом с этим файлом.

DIR=/data/opt/quasar-bridge

# Wi-Fi power save на колонке роняет крупные POST'ы: пинг скачет 70-200 мс,
# теряются пакеты, и запрос к LLM висит до таймаута. Выключаем, если узел есть.
if [ -w /sys/devices/platform/unisoc_wifi/power/control ]; then
    echo on > /sys/devices/platform/unisoc_wifi/power/control 2>/dev/null || true
fi

# runtime.env — обычный shell-скрипт, поэтому переменные должны быть с export.
if [ -f "$DIR/runtime.env" ]; then
    . "$DIR/runtime.env"
fi

# Системные корневые сертификаты прошивки: без них HTTPS к Cloudflare не пройдёт.
export SSL_CERT_FILE="${SSL_CERT_FILE:-/system/vendor/quasar/ca-certificates.crt}"

cd "$DIR" || exit 1
exec "$DIR/bin/quasar-bridge" -config "$DIR/config.json"
