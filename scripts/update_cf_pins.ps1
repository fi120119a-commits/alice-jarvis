<#
.SYNOPSIS
    Обновляет IPv4-пины Cloudflare в /etc/hosts колонки.

.DESCRIPTION
    Зачем: мост обязан ходить к воркеру только по IPv4. По IPv6 соединение
    открывается, но данные не идут, и через 60 секунд мост отдаёт fallback
    («Сейчас не получилось получить ответ локальной модели»).

    Скрипт резолвит актуальные A-записи вашего воркера, переписывает строки
    с этим именем в /etc/hosts, возвращает rootfs в ro и проверяет результат.
    Первый запуск сохраняет исходный hosts в /data/opt/quasar-bridge/hosts.orig.

.PARAMETER Station
    Адрес колонки для ADB, например 192.168.1.50:5555.

.PARAMETER HostName
    Имя воркера без схемы, например alice-jarvis-llm.ваш-поддомен.workers.dev

.PARAMETER AdbPath
    Путь к adb.exe. По умолчанию ищется в PATH и в пакетах WinGet.

.PARAMETER Restart
    Перезапустить мост после обновления и проверить healthz.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File scripts\update_cf_pins.ps1 `
      -Station 192.168.1.50:5555 -HostName alice-jarvis-llm.ваш-поддомен.workers.dev
#>
param(
    [string]$Station,
    [string]$HostName,
    [string]$AdbPath,
    [switch]$Restart
)

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)

function Read-DotEnv([string]$path) {
    $map = @{}
    if (-not (Test-Path $path)) { return $map }
    foreach ($line in [IO.File]::ReadAllLines($path, [Text.Encoding]::UTF8)) {
        $text = $line.Trim()
        if (-not $text -or $text.StartsWith("#")) { continue }
        $eq = $text.IndexOf("=")
        if ($eq -lt 1) { continue }
        $map[$text.Substring(0, $eq).Trim()] = $text.Substring($eq + 1).Trim().Trim('"').Trim("'")
    }
    return $map
}

# Станция и имя воркера берутся из .env, если не переданы параметрами.
$dotenv = Read-DotEnv (Join-Path $root ".env")
if (-not $Station -and $dotenv["STATION_IP"]) {
    $port = if ($dotenv["STATION_ADB_PORT"]) { $dotenv["STATION_ADB_PORT"] } else { "5555" }
    $Station = "$($dotenv["STATION_IP"]):$port"
}
if (-not $HostName -and $dotenv["LLM_BASE_URL"]) {
    try { $HostName = ([Uri]$dotenv["LLM_BASE_URL"]).Host } catch { }
}
if (-not $Station) { throw "укажите -Station <IP>:5555 или заполните STATION_IP в .env" }
if (-not $HostName) { throw "укажите -HostName <воркер>.workers.dev или заполните LLM_BASE_URL в .env" }
if (-not $AdbPath -and $dotenv["ADB_PATH"]) { $AdbPath = $dotenv["ADB_PATH"] }

function Resolve-Adb {
    param([string]$Hint)
    if ($Hint) {
        if (-not (Test-Path $Hint)) { throw "adb не найден по пути: $Hint" }
        return (Resolve-Path $Hint).Path
    }
    $cmd = Get-Command adb -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    $found = Get-ChildItem "$env:LOCALAPPDATA\Microsoft\WinGet\Packages" -Filter adb.exe -Recurse -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if ($found) { return $found.FullName }
    throw "adb.exe не найден. Установите: winget install Google.PlatformTools, либо укажите -AdbPath C:\path\to\adb.exe"
}

$adb = Resolve-Adb $AdbPath

Write-Host "1) Резолвлю $HostName ..."
$ips = @()
try {
    $ips = @(Resolve-DnsName -Name $HostName -Type A -ErrorAction Stop |
        Where-Object { $_.IPAddress } |
        Select-Object -ExpandProperty IPAddress -Unique)
}
catch { }
if (-not $ips -or $ips.Count -eq 0) {
    $ips = @([System.Net.Dns]::GetHostAddresses($HostName) |
        Where-Object { $_.AddressFamily -eq 'InterNetwork' } |
        ForEach-Object { $_.IPAddressToString } |
        Select-Object -Unique)
}
if (-not $ips -or $ips.Count -eq 0) { throw "не удалось получить IPv4 для $HostName" }
Write-Host ("   IPv4: " + ($ips -join ", "))

Write-Host "2) Подключаюсь к колонке $Station ..."
& $adb connect $Station | Out-Null
$devices = (& $adb devices) -join "`n"
if ($devices -notmatch [regex]::Escape($Station)) {
    throw "колонка не подключилась: $Station (проверьте, что она в той же Wi-Fi сети)"
}

Write-Host "3) Читаю текущий /etc/hosts ..."
$tmp = Join-Path $env:TEMP "hosts.jarvis"
& $adb -s $Station pull /etc/hosts $tmp | Out-Null
if ($LASTEXITCODE -ne 0) { throw "не удалось прочитать /etc/hosts" }

# Один раз сохраняем исходный файл — пригодится для полного отката.
$backupCheck = (& $adb -s $Station shell "test -f /data/opt/quasar-bridge/hosts.orig && echo yes || echo no") -join ""
if ($backupCheck -notmatch "yes") {
    & $adb -s $Station shell "mkdir -p /data/opt/quasar-bridge; cp /etc/hosts /data/opt/quasar-bridge/hosts.orig" | Out-Null
    Write-Host "   исходный hosts сохранён в /data/opt/quasar-bridge/hosts.orig"
}

$lines = @(Get-Content $tmp)
$kept = @($lines | Where-Object { $_ -notmatch [regex]::Escape($HostName) })
$new = $kept + @($ips | ForEach-Object { "$_ $HostName" })
$text = (($new | Where-Object { $_ -ne "" }) -join "`n") + "`n"
[IO.File]::WriteAllText($tmp, $text, (New-Object System.Text.UTF8Encoding($false)))

Write-Host "4) Пишу обратно (rootfs rw -> ro) ..."
& $adb -s $Station shell "mount -o remount,rw /" | Out-Null
& $adb -s $Station push $tmp /etc/hosts | Out-Null
if ($LASTEXITCODE -ne 0) {
    & $adb -s $Station shell "mount -o remount,ro /" | Out-Null
    throw "не удалось записать /etc/hosts"
}
& $adb -s $Station shell "sync; mount -o remount,ro /" | Out-Null

Write-Host "5) Проверяю ..."
& $adb -s $Station shell "grep -n '$HostName' /etc/hosts"
$rootState = (& $adb -s $Station shell "mount | grep ' / '") -join " "
if ($rootState -match "\bro[,\s]") { Write-Host "   rootfs: ro (как надо)" }
else { Write-Host "   ВНИМАНИЕ: rootfs не вернулся в ro -> $rootState" -ForegroundColor Yellow }

if ($Restart) {
    Write-Host "6) Перезапускаю мост ..."
    & $adb -s $Station shell "/etc/init.d/S99quasar-bridge restart" | Out-Null
    Start-Sleep -Seconds 8
    & $adb -s $Station shell "wget -q -O - --timeout=5 http://127.0.0.1:8443/healthz"
}

Remove-Item $tmp -Force -ErrorAction SilentlyContinue
Write-Host "Готово." -ForegroundColor Green
