<#
.SYNOPSIS
    Переключает «мозг» колонки между облаком, ПК и другими провайдерами.

.DESCRIPTION
    Правит только config.json и runtime.env в /data/opt/quasar-bridge.
    Прошивка и quasar.cfg не трогаются.

    Режимы:
      cloud      — Cloudflare Worker (LLM_BASE_URL и JARVIS_KEY из .env)
      pc         — OpenAI-совместимый сервер на вашем ПК (PC_BASE_URL из .env)
      openrouter — OpenRouter (OPENROUTER_KEY из .env или -Key)
      custom     — любой провайдер: -BaseUrl, -Model и при необходимости -Key
      status     — показать текущие настройки и состояние моста

.PARAMETER Mode
    cloud | pc | openrouter | custom | status

.PARAMETER Device
    Адрес колонки для ADB, например 192.168.1.50:5555.

.PARAMETER BaseUrl
    Адрес OpenAI-совместимого API. Обязателен для custom, переопределяет
    значение из .env для cloud/pc.

.PARAMETER Model
    Имя модели. Обязательно для custom.

.PARAMETER Key
    Ключ провайдера. Если не задан, берётся из .env.

.PARAMETER AdbPath
    Путь к adb.exe. По умолчанию ищется в PATH и в пакетах WinGet.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File scripts\bridge_brain.ps1 -Mode cloud -Device 192.168.1.50:5555

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File scripts\bridge_brain.ps1 -Mode status -Device 192.168.1.50:5555
#>
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet("cloud", "pc", "openrouter", "custom", "status")]
    [string]$Mode,
    [string]$Device,
    [string]$BaseUrl,
    [string]$Model,
    [string]$Key,
    [string]$AdbPath
)

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$cfgPath = Join-Path $root "config.json"
$envPath = Join-Path $root "runtime.env"
$dotenvPath = Join-Path $root ".env"
$remote = "/data/opt/quasar-bridge"

$utf8 = New-Object System.Text.UTF8Encoding($false)

function Read-DotEnv([string]$path) {
    $map = @{}
    if (-not (Test-Path $path)) { return $map }
    foreach ($line in [IO.File]::ReadAllLines($path, [Text.Encoding]::UTF8)) {
        $text = $line.Trim()
        if (-not $text -or $text.StartsWith("#")) { continue }
        $eq = $text.IndexOf("=")
        if ($eq -lt 1) { continue }
        $name = $text.Substring(0, $eq).Trim()
        $value = $text.Substring($eq + 1).Trim().Trim('"').Trim("'")
        $map[$name] = $value
    }
    return $map
}

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
    $out = & $adb -s $Device @cmd 2>&1
    if ($LASTEXITCODE -ne 0) { throw "adb $($cmd -join ' ') вернул ошибку: $out" }
    return $out
}

$dotenv = Read-DotEnv $dotenvPath

if (-not $Device -and $dotenv["STATION_IP"]) {
    $port = if ($dotenv["STATION_ADB_PORT"]) { $dotenv["STATION_ADB_PORT"] } else { "5555" }
    $Device = "$($dotenv["STATION_IP"]):$port"
}
if (-not $Device) { throw "укажите -Device <IP>:5555 или заполните STATION_IP в .env" }
if (-not $AdbPath -and $dotenv["ADB_PATH"]) { $AdbPath = $dotenv["ADB_PATH"] }

$adb = Resolve-Adb $AdbPath
& $adb connect $Device | Out-Null

if ($Mode -eq "status") {
    $cfg = ((Adb @("shell", "cat $remote/config.json")) -join "`n") | ConvertFrom-Json
    $envRaw = (Adb @("shell", "cat $remote/runtime.env")) -join "`n"
    $keySet = ($envRaw -match "(?m)^\s*(export\s+)?QUASAR_LLM_API_KEY=\s*\S")
    "base_url : $($cfg.llm_base_url)"
    "model    : $($cfg.llm_model)"
    "api      : $($cfg.llm_api)"
    "ключ     : " + $(if ($keySet) { "задан" } else { "пустой" })
    switch -Regex ($cfg.llm_base_url) {
        "workers\.dev" { "режим    : облако Cloudflare (ПК не нужен)" }
        "openrouter" { "режим    : OpenRouter" }
        "^http://192\.168\." { "режим    : ПК (OpenAI-совместимый сервер)" }
        default { "режим    : свой адрес" }
    }
    $health = (Adb @("shell", "wget -q -O - --timeout=5 http://127.0.0.1:8443/healthz")) -join ""
    "мост     : " + $(if ($health -match '"status":"ok"') { "работает" } else { "НЕ отвечает" })
    return
}

# --- Профили ---
switch ($Mode) {
    "cloud" {
        $base = if ($BaseUrl) { $BaseUrl } else { $dotenv["LLM_BASE_URL"] }
        $mdl = if ($Model) { $Model } else { $dotenv["LLM_MODEL"] }
        $apiKey = if ($Key) { $Key } else { $dotenv["JARVIS_KEY"] }
        if (-not $mdl) { $mdl = "@cf/mistralai/mistral-small-3.1-24b-instruct" }
        if (-not $base -or $base -match "YOUR-WORKER") {
            throw "для режима cloud задайте LLM_BASE_URL в .env (адрес выдаёт scripts\deploy_worker.py)"
        }
    }
    "pc" {
        $base = if ($BaseUrl) { $BaseUrl } else { $dotenv["PC_BASE_URL"] }
        $mdl = if ($Model) { $Model } else { "jarvis" }
        $apiKey = [string]$Key
        if (-not $base) {
            throw "для режима pc задайте PC_BASE_URL в .env, например http://192.168.1.10:8765/v1"
        }
    }
    "openrouter" {
        $base = "https://openrouter.ai/api/v1"
        $mdl = if ($Model) { $Model } else { "meta-llama/llama-3.3-70b-instruct:free" }
        $apiKey = if ($Key) { $Key } else { $dotenv["OPENROUTER_KEY"] }
    }
    "custom" {
        if (-not $BaseUrl -or -not $Model) {
            throw "для -Mode custom нужны -BaseUrl и -Model (и -Key, если провайдер требует ключ)"
        }
        $base = $BaseUrl
        $mdl = $Model
        $apiKey = [string]$Key
    }
}

if (-not $apiKey -and $Mode -ne "pc") {
    Write-Host "ВНИМАНИЕ: ключ для режима '$Mode' не найден — провайдер ответит 401." -ForegroundColor Yellow
    Write-Host "  cloud      -> JARVIS_KEY в .env"
    Write-Host "  openrouter -> OPENROUTER_KEY в .env"
}

if (-not (Test-Path $cfgPath)) { throw "не найден $cfgPath (скопируйте config.example.json в config.json)" }
if (-not (Test-Path $envPath)) { throw "не найден $envPath (скопируйте runtime.env.example в runtime.env)" }

# --- config.json ---
$cfg = [IO.File]::ReadAllText($cfgPath, [Text.Encoding]::UTF8) | ConvertFrom-Json
$cfg.llm_base_url = $base
$cfg.llm_model = $mdl
$cfg.llm_api = "chat_completions"
[IO.File]::WriteAllText($cfgPath, ($cfg | ConvertTo-Json -Depth 32), $utf8)

# --- runtime.env ---
# ВАЖНО: export обязателен, и только LF (CRLF ломает значения).
$lines = [IO.File]::ReadAllLines($envPath, [Text.Encoding]::UTF8)
$found = $false
for ($i = 0; $i -lt $lines.Count; $i++) {
    if ($lines[$i] -match '^(export\s+)?QUASAR_LLM_API_KEY=') {
        $lines[$i] = "export QUASAR_LLM_API_KEY=$apiKey"
        $found = $true
    }
}
if (-not $found) { $lines += "export QUASAR_LLM_API_KEY=$apiKey" }
[IO.File]::WriteAllText($envPath, ($lines -join "`n") + "`n", $utf8)

Write-Host "режим: $Mode -> $base / $mdl"

& $adb -s $Device push $cfgPath "$remote/config.json.new" | Out-Null
if ($LASTEXITCODE -ne 0) { throw "не удалось залить config.json" }
& $adb -s $Device push $envPath "$remote/runtime.env.new" | Out-Null
if ($LASTEXITCODE -ne 0) { throw "не удалось залить runtime.env" }

Adb @("shell", "cd $remote; mv config.json.new config.json; mv runtime.env.new runtime.env; sync") | Out-Null
Adb @("shell", "/etc/init.d/S99quasar-bridge restart") | Out-Null

Start-Sleep -Seconds 8
$health = (Adb @("shell", "wget -q -O - --timeout=5 http://127.0.0.1:8443/healthz")) -join ""
if ($health -match '"status":"ok"') {
    Write-Host "мост перезапущен и отвечает" -ForegroundColor Green
}
else {
    Write-Host "ВНИМАНИЕ: мост не ответил. Лог: /data/opt/quasar-bridge/bridge.log" -ForegroundColor Yellow
}
