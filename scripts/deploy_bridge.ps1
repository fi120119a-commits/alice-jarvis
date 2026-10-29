<#
.SYNOPSIS
    Устанавливает quasar-bridge и настройки на Яндекс Станцию (root + ADB).

.DESCRIPTION
    Копирует бинарник моста, config.json, runtime.env и start.sh в
    /data/opt/quasar-bridge, ставит автозапуск S99quasar-bridge и проверяет
    healthz. Прошивка не переписывается.

    Бинарник quasar-bridge в репозиторий не входит: скачайте его со страницы
    релизов https://github.com/skrashevich/quasar-bridge/releases/latest
    и положите в vendor/ (или передайте путь через -BinaryPath).

.PARAMETER Device
    Адрес колонки для ADB, например 192.168.1.50:5555.

.PARAMETER BinaryPath
    Путь к скачанному бинарнику. По умолчанию ищется в vendor/.

.PARAMETER AdbPath
    Путь к adb.exe. По умолчанию ищется в PATH и в пакетах WinGet.

.PARAMETER ApplyEndpoint
    Сразу переключить голосовой тракт колонки на мост (шаг 4 инструкции).

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File scripts\deploy_bridge.ps1 `
      -Device 192.168.1.50:5555 -BinaryPath vendor\quasar-bridge-linux-arm64
#>
param(
    [string]$Device,
    [string]$BinaryPath,
    [string]$AdbPath,
    [switch]$ApplyEndpoint
)

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$remote = "/data/opt/quasar-bridge"

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

# Адрес колонки и adb можно не передавать: они берутся из .env.
$dotenv = Read-DotEnv (Join-Path $root ".env")
if (-not $Device -and $dotenv["STATION_IP"]) {
    $port = if ($dotenv["STATION_ADB_PORT"]) { $dotenv["STATION_ADB_PORT"] } else { "5555" }
    $Device = "$($dotenv["STATION_IP"]):$port"
}
if (-not $Device) { throw "укажите -Device <IP>:5555 или заполните STATION_IP в .env" }
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

function Adb([string[]]$cmd) {
    & $adb -s $Device @cmd
    if ($LASTEXITCODE -ne 0) { throw "adb $($cmd -join ' ') завершился с ошибкой" }
}

$adb = Resolve-Adb $AdbPath

# --- Что копируем ---
$config = Join-Path $root "config.json"
$runtime = Join-Path $root "runtime.env"
$start = Join-Path $root "src\bridge\start.sh"
$init = Join-Path $root "src\bridge\S99quasar-bridge"

foreach ($file in @($config, $runtime, $start, $init)) {
    if (-not (Test-Path $file)) { throw "не найден файл: $file (см. docs\INSTALL.md)" }
}

if (-not $BinaryPath) {
    foreach ($candidate in @("$root\vendor\quasar-bridge-linux-arm64", "$root\vendor\quasar-bridge-linux-arm")) {
        if (Test-Path $candidate) { $BinaryPath = $candidate; break }
    }
}
if (-not $BinaryPath -or -not (Test-Path $BinaryPath)) {
    throw @"
бинарник quasar-bridge не найден.

Скачайте его со страницы релизов:
  https://github.com/skrashevich/quasar-bridge/releases/latest
Файл quasar-bridge-linux-arm64 (для aarch64) или quasar-bridge-linux-arm (armv7)
положите в vendor\ и запустите скрипт снова, либо передайте -BinaryPath.
"@
}

# --- Проверки локальных файлов ---
$envBytes = [IO.File]::ReadAllBytes($runtime)
if ($envBytes -contains 13) {
    throw @"
runtime.env содержит CRLF. Значения приедут с \r: ключ не пройдёт авторизацию,
а GOMEMLIMIT=64MiB\r уронит бинарник.

Сохраните файл с переводами строк LF (в VS Code: правый нижний угол → CRLF → LF)
и запустите скрипт снова.
"@
}
$envText = [IO.File]::ReadAllText($runtime)
if ($envText -match 'PASTE_YOUR_JARVIS_KEY_HERE') {
    throw "в runtime.env не заполнен QUASAR_LLM_API_KEY. Впишите JARVIS_KEY из деплоя воркера."
}

# --- Подключение ---
Write-Host "Подключаюсь к колонке $Device ..."
& $adb connect $Device | Out-Null
$devices = (& $adb devices) -join "`n"
if ($devices -notmatch [regex]::Escape($Device)) {
    throw "колонка не подключилась: $Device (проверьте, что она в той же Wi-Fi сети и ADB включён)"
}

Write-Host "Копирую бинарник и настройки ..."
Adb @("shell", "mkdir -p $remote/bin")
& $adb -s $Device push $BinaryPath "$remote/bin/quasar-bridge" | Out-Null
if ($LASTEXITCODE -ne 0) { throw "не удалось скопировать бинарник" }
& $adb -s $Device push $config "$remote/config.json" | Out-Null
if ($LASTEXITCODE -ne 0) { throw "не удалось скопировать config.json" }
& $adb -s $Device push $runtime "$remote/runtime.env" | Out-Null
if ($LASTEXITCODE -ne 0) { throw "не удалось скопировать runtime.env" }
& $adb -s $Device push $start "$remote/start.sh" | Out-Null
if ($LASTEXITCODE -ne 0) { throw "не удалось скопировать start.sh" }

Adb @("shell", "chmod 755 $remote/bin/quasar-bridge $remote/start.sh")
Adb @("shell", "chmod 600 $remote/config.json $remote/runtime.env")

Write-Host "Проверяю связь с моделью ..."
& $adb -s $Device shell "$remote/bin/quasar-bridge -config $remote/config.json -check-backends 2>&1 | tail -5"

Write-Host "Устанавливаю автозапуск ..."
Adb @("shell", "mount -o remount,rw /")
& $adb -s $Device push $init "/etc/init.d/S99quasar-bridge" | Out-Null
if ($LASTEXITCODE -ne 0) {
    Adb @("shell", "mount -o remount,ro /")
    throw "не удалось записать /etc/init.d/S99quasar-bridge"
}
Adb @("shell", "chmod 755 /etc/init.d/S99quasar-bridge; sync; mount -o remount,ro /")

Write-Host "Запускаю службу ..."
Adb @("shell", "/etc/init.d/S99quasar-bridge restart")
Start-Sleep -Seconds 4
Write-Host "healthz:"
Adb @("shell", "wget -q -O - --timeout=5 http://127.0.0.1:8443/healthz; echo")

if ($ApplyEndpoint) {
    Write-Host "Переключаю голосовой тракт колонки на мост ..."
    & (Join-Path $root "scripts\apply_endpoint.ps1") -Device $Device -AdbPath $adb
}

Write-Host "Готово." -ForegroundColor Green
