<#
.SYNOPSIS
    Переключает голосовой тракт колонки на локальный quasar-bridge и обратно.

.DESCRIPTION
    Сохраняет исходный /system/vendor/quasar/quasar.cfg в .backup\quasar.cfg.orig,
    прописывает aliced.uniProxyUrl = ws://127.0.0.1:8443/uni.ws и перезагружает
    колонку. С ключом -Rollback возвращает сохранённую копию.

    Прошивка не модифицируется: меняется только конфигурационный файл.

.PARAMETER Device
    Адрес колонки для ADB, например 192.168.1.50:5555.

.PARAMETER AdbPath
    Путь к adb.exe. По умолчанию ищется в PATH и в пакетах WinGet.

.PARAMETER Rollback
    Вернуть исходный quasar.cfg (голосовой тракт Яндекса).

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File scripts\apply_endpoint.ps1 -Device 192.168.1.50:5555

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File scripts\apply_endpoint.ps1 -Device 192.168.1.50:5555 -Rollback
#>
param(
    [string]$Device,
    [string]$AdbPath,
    [switch]$Rollback
)

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$work = Join-Path $root ".backup"
$remoteCfg = "/system/vendor/quasar/quasar.cfg"

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
New-Item -ItemType Directory -Force -Path $work | Out-Null

Write-Host "Подключаюсь к колонке $Device ..."
& $adb connect $Device | Out-Null
$devices = (& $adb devices) -join "`n"
if ($devices -notmatch [regex]::Escape($Device)) {
    throw "колонка не подключилась: $Device"
}

if ($Rollback) {
    $backup = Join-Path $work "quasar.cfg.orig"
    if (-not (Test-Path $backup)) { throw "нет резервной копии $backup — откат невозможен" }
    Write-Host "Возвращаю исходный quasar.cfg ..."
    $staged = $backup
}
else {
    Write-Host "Сохраняю исходный quasar.cfg ..."
    & $adb -s $Device pull $remoteCfg (Join-Path $work "quasar.cfg.orig") | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "не удалось прочитать $remoteCfg" }

    Write-Host "Готовлю новый конфиг (ws://127.0.0.1:8443/uni.ws) ..."
    $patch = @'
import json, sys

src, dst = sys.argv[1], sys.argv[2]
with open(src, encoding="utf-8") as fh:
    cfg = json.load(fh)

aliced = cfg.setdefault("aliced", {})
aliced["uniProxyUrl"] = "ws://127.0.0.1:8443/uni.ws"
aliced["uniProxyQuicUrl"] = ""

with open(dst, "w", encoding="utf-8") as fh:
    json.dump(cfg, fh, ensure_ascii=False, indent=2)
    fh.write("\n")

print("uniProxyUrl ->", aliced["uniProxyUrl"])
'@
    $patchPath = Join-Path $work "patch_endpoint.py"
    [IO.File]::WriteAllText($patchPath, $patch, (New-Object System.Text.UTF8Encoding($false)))

    $python = (Get-Command python -ErrorAction SilentlyContinue).Source
    if (-not $python) { $python = (Get-Command py -ErrorAction SilentlyContinue).Source }
    if (-not $python) { throw "не найден Python 3. Установите его и повторите запуск." }

    & $python $patchPath (Join-Path $work "quasar.cfg.orig") (Join-Path $work "quasar.cfg.new")
    if ($LASTEXITCODE -ne 0) { throw "не удалось подготовить конфиг" }
    $staged = Join-Path $work "quasar.cfg.new"
}

Adb @("shell", "mount -o remount,rw /")
& $adb -s $Device push $staged "$remoteCfg.new" | Out-Null
if ($LASTEXITCODE -ne 0) {
    Adb @("shell", "mount -o remount,ro /")
    throw "не удалось записать конфиг на колонку"
}
Adb @("shell", "cp $remoteCfg.new $remoteCfg; sync; rm -f $remoteCfg.new; mount -o remount,ro /")
Adb @("shell", "grep -E 'uniProxy' $remoteCfg")

Write-Host "Перезагружаю колонку (это занимает ~45 секунд) ..."
Adb @("reboot")
Start-Sleep -Seconds 45
& $adb connect $Device | Out-Null
Start-Sleep -Seconds 3

Write-Host "Проверяю мост после загрузки:"
& $adb -s $Device shell "wget -q -O - --timeout=5 http://127.0.0.1:8443/healthz; echo"

if ($Rollback) {
    Write-Host "Голосовой тракт возвращён Яндексу." -ForegroundColor Green
}
else {
    Write-Host "Готово. Скажите: «Алиса, который час»." -ForegroundColor Green
    Write-Host "Если ответа нет — откат: scripts\apply_endpoint.ps1 -Device $Device -Rollback"
}
