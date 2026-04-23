<#
.SYNOPSIS
  Gemma one-click installer for Windows — installs Ollama + Gemma and
  wires a local-gemma4 provider into OpenClaw. Safe to re-run.

.DESCRIPTION
  Default user invocation:
      irm https://<host>/install.ps1 | iex

  CI / power-user overrides via environment variables:
      $env:GEMMA_MODEL       = 'gemma4:e2b'       (default)
      $env:GEMMA_LISTEN      = '127.0.0.1:11434'
      $env:GEMMA_NO_OPENCLAW = '1'                skip OpenClaw config
      $env:GEMMA_SKIP_PULL   = '1'                skip model download
      $env:GEMMA_YES         = '1'                non-interactive
#>

$ErrorActionPreference = 'Stop'
if ($PSVersionTable.PSVersion.Major -lt 5) {
    Write-Host 'PowerShell 5.1 or newer required.' -ForegroundColor Red
    exit 1
}

# ---------------------------------------------------------------------------
# defaults + env overrides
# ---------------------------------------------------------------------------
function Default($value, $fallback) {
    if ([string]::IsNullOrWhiteSpace($value)) { return $fallback }
    return $value
}

$Model      = Default $env:GEMMA_MODEL  'gemma4:e2b'
$Listen     = Default $env:GEMMA_LISTEN '127.0.0.1:11434'
$NoOpenclaw = $env:GEMMA_NO_OPENCLAW -eq '1'
$SkipPull   = $env:GEMMA_SKIP_PULL   -eq '1'
$MinDiskGB  = 10

# ---------------------------------------------------------------------------
# log helpers
# ---------------------------------------------------------------------------
function Info($msg) { Write-Host "▸ $msg" -ForegroundColor Blue }
function Ok  ($msg) { Write-Host "✓ $msg" -ForegroundColor Green }
function Warn($msg) { Write-Host "! $msg" -ForegroundColor Yellow }
function Die ($msg) { Write-Host "✗ $msg" -ForegroundColor Red; exit 1 }
function Step($n, $total, $label) {
    Write-Host ""
    Write-Host ("[{0}/{1}] {2}" -f $n, $total, $label) -ForegroundColor Cyan
}

# ---------------------------------------------------------------------------
# banner
# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "  ╔══════════════════════════════════════════════════════╗" -ForegroundColor White
Write-Host "  ║         Gemma · 一键安装 · for OpenClaw            ║" -ForegroundColor White
Write-Host "  ║  Local Gemma behind an OpenAI-compatible API v1     ║" -ForegroundColor White
Write-Host "  ╚══════════════════════════════════════════════════════╝" -ForegroundColor White
Write-Host ("  model    : {0}" -f $Model)           -ForegroundColor DarkGray
Write-Host ("  listen   : {0}" -f $Listen)          -ForegroundColor DarkGray
Write-Host ("  openclaw : {0}" -f $(if ($NoOpenclaw) { 'skip' } else { 'auto-inject' })) -ForegroundColor DarkGray

# ---------------------------------------------------------------------------
# [1/5] preflight
# ---------------------------------------------------------------------------
Step 1 5 "体检 Preflight"

$os = (Get-CimInstance -ClassName Win32_OperatingSystem).Caption
Ok "OS: $os"

$homeDrive = (Get-Item $env:USERPROFILE).PSDrive
$freeGB = [math]::Floor($homeDrive.Free / 1GB)
if ($freeGB -lt $MinDiskGB) { Die "磁盘可用 $freeGB GB, 至少需要 $MinDiskGB GB" }
Ok "磁盘可用 $freeGB GB"

try {
    $gpu = (Get-CimInstance -ClassName Win32_VideoController |
            Select-Object -ExpandProperty Name |
            Select-Object -First 1)
} catch { $gpu = $null }
if ($gpu) { Ok "GPU: $gpu" } else { Warn "未检测到 GPU, 将用 CPU 推理" }

try {
    Invoke-WebRequest -Uri 'https://ollama.com' -Method Head -TimeoutSec 5 -UseBasicParsing | Out-Null
    Ok "网络可达"
} catch {
    Die "无法连接 ollama.com: $_"
}

# ---------------------------------------------------------------------------
# [2/5] install Ollama
# ---------------------------------------------------------------------------
Step 2 5 "安装 Ollama 运行时"

$ollamaCmd = Get-Command ollama -ErrorAction SilentlyContinue
if ($ollamaCmd) {
    Ok "Ollama 已安装 ($($ollamaCmd.Source))"
} else {
    $setup = Join-Path $env:TEMP 'OllamaSetup.exe'
    Info '从 ollama.com 下载 OllamaSetup.exe...'
    try {
        Invoke-WebRequest -Uri 'https://ollama.com/download/OllamaSetup.exe' `
                          -OutFile $setup -UseBasicParsing
    } catch {
        Die "下载 OllamaSetup.exe 失败: $_"
    }

    # Create the "upgraded" marker file so Ollama's tray app starts hidden
    # during silent install (upstream Ollama install.ps1 does this).
    $markerDir = Join-Path $env:LOCALAPPDATA 'Ollama'
    if (-not (Test-Path $markerDir)) { New-Item -ItemType Directory -Path $markerDir -Force | Out-Null }
    New-Item -ItemType File -Path (Join-Path $markerDir 'upgraded') -Force | Out-Null

    Info '静默运行 OllamaSetup.exe /VERYSILENT /NORESTART...'
    # IMPORTANT: no -Wait. -Wait blocks on the Ollama tray app that the
    # installer spawns, and the tray app never exits. We only care about
    # the installer (Inno Setup) process exiting.
    $p = Start-Process -FilePath $setup `
                       -ArgumentList '/VERYSILENT','/NORESTART','/SUPPRESSMSGBOXES' `
                       -PassThru
    if (-not $p.WaitForExit(300000)) {
        try { $p.Kill() } catch { }
        Die 'OllamaSetup.exe did not exit within 5 min — aborting'
    }
    if ($p.ExitCode -ne 0) { Die "OllamaSetup.exe 退出码 $($p.ExitCode)" }
    Remove-Item $setup -ErrorAction SilentlyContinue

    # refresh PATH so `ollama` resolves without reopening the shell
    $env:Path = [System.Environment]::GetEnvironmentVariable('Path','Machine') + ';' + `
                [System.Environment]::GetEnvironmentVariable('Path','User')
    Ok 'Ollama 已安装'
}

# ---------------------------------------------------------------------------
# [3/5] start Ollama and wait for API
# ---------------------------------------------------------------------------
Step 3 5 "启动 Ollama 服务"

if ($Listen -ne '127.0.0.1:11434') {
    [System.Environment]::SetEnvironmentVariable('OLLAMA_HOST', $Listen, 'User')
    $env:OLLAMA_HOST = $Listen
    Info "已把 OLLAMA_HOST=$Listen 写入用户环境"
}

$endpoint = "http://$Listen"
$ready = $false
for ($i = 0; $i -lt 30 -and -not $ready; $i++) {
    try {
        $v = Invoke-RestMethod "$endpoint/api/version" -TimeoutSec 2
        Ok "Ollama 服务就绪 ($endpoint, version $($v.version))"
        $ready = $true
    } catch {
        # On first couple of misses, nudge ollama.exe to start.
        if ($i -eq 2 -and -not (Get-Process ollama -ErrorAction SilentlyContinue)) {
            Info "启动 ollama serve 在后台..."
            Start-Process -FilePath 'ollama' -ArgumentList 'serve' -WindowStyle Hidden -ErrorAction SilentlyContinue
        }
        Start-Sleep -Seconds 1
    }
}
if (-not $ready) { Die 'Ollama 服务 30s 内未就绪' }

# ---------------------------------------------------------------------------
# [4/5] pull the model
# ---------------------------------------------------------------------------
Step 4 5 "拉取模型 $Model"

if ($SkipPull) {
    Ok "GEMMA_SKIP_PULL=1 已设置, 跳过下载"
} else {
    $installed = & ollama list 2>$null | Select-String -Pattern "^$([regex]::Escape($Model))\s" -Quiet
    if ($installed) {
        Ok "$Model 已存在, 跳过"
    } else {
        Info "开始 ollama pull $Model..."
        & ollama pull $Model
        if ($LASTEXITCODE -ne 0) {
            Warn "pull 失败, 1s 后重试..."
            Start-Sleep -Seconds 1
            & ollama pull $Model
            if ($LASTEXITCODE -ne 0) { Die "ollama pull $Model 失败" }
        }
        Ok "模型 $Model 已就位"
    }
}

# ---------------------------------------------------------------------------
# [5/5] inject the provider into OpenClaw
# ---------------------------------------------------------------------------
Step 5 5 "接入 OpenClaw"

$providerObj = [ordered]@{
    name    = 'local-gemma4'
    baseURL = "http://$Listen/v1"
    apiKey  = 'ollama'
    models  = @(
        [ordered]@{
            id             = $Model
            name           = 'Gemma (Local)'
            contextWindow  = 131072
            supportsVision = $true
        }
    )
}
$providerJson = $providerObj | ConvertTo-Json -Depth 10

function Find-OpenclawConfig {
    $candidates = @()
    if ($env:OPENCLAW_CONFIG_DIR) { $candidates += Join-Path $env:OPENCLAW_CONFIG_DIR 'config.json' }
    $candidates += Join-Path $env:APPDATA    'OpenClaw\config.json'
    $candidates += Join-Path $env:USERPROFILE '.openclaw\config.json'
    foreach ($p in $candidates) {
        if (Test-Path $p) { return $p }
    }
    return $null
}

if ($NoOpenclaw) {
    Ok 'GEMMA_NO_OPENCLAW=1 已设置, 跳过配置'
} else {
    $cfg = Find-OpenclawConfig
    if ($cfg) {
        Info "发现 OpenClaw 配置: $cfg"
        $raw  = Get-Content $cfg -Raw
        try {
            $json = $raw | ConvertFrom-Json
        } catch {
            Die "openclaw 配置不是合法 JSON — 拒绝修改: $_"
        }
        # upsert into customProviders (dedupe by name)
        $existing = @()
        if ($json.PSObject.Properties.Name -contains 'customProviders' -and $json.customProviders) {
            $existing = @($json.customProviders | Where-Object { $_.name -ne 'local-gemma4' })
        }
        $merged = $existing + $providerObj
        if ($json.PSObject.Properties.Name -contains 'customProviders') {
            $json.customProviders = $merged
        } else {
            $json | Add-Member -NotePropertyName customProviders -NotePropertyValue $merged
        }
        $tmp = "$cfg.tmp"
        $json | ConvertTo-Json -Depth 20 | Set-Content -Path $tmp -Encoding UTF8
        Move-Item -Path $tmp -Destination $cfg -Force
        Ok "已把 local-gemma4 provider 写入 $cfg"
    } else {
        Warn '未检测到 OpenClaw 配置, 下面打印 provider 供你手动粘贴:'
        $cacheDir = Join-Path $env:USERPROFILE '.gemma-installer'
        if (-not (Test-Path $cacheDir)) { New-Item -ItemType Directory -Path $cacheDir | Out-Null }
        $providerJson | Set-Content -Path (Join-Path $cacheDir 'openclaw-provider.json') -Encoding UTF8
        try { $providerJson | Set-Clipboard; Info '(同时复制到剪贴板)' } catch { }
        Write-Host ''
        Write-Host $providerJson
    }
}

# ---------------------------------------------------------------------------
# final banner
# ---------------------------------------------------------------------------
Write-Host ''
Write-Host '  ✓ 全部就绪' -ForegroundColor Green
Write-Host ''
Write-Host ("  本地 API   : http://$Listen/v1")
Write-Host ("  模型       : $Model")
Write-Host ("  OpenClaw   : {0}" -f $(if ($NoOpenclaw) { '已跳过' } else { '已自动配置 / 配置已打印' }))
Write-Host ''
Write-Host '  测试消息:'
Write-Host "  curl.exe http://$Listen/v1/chat/completions -H 'Content-Type: application/json' -d '{\""model\"":\""$Model\"",\""messages\"":[{\""role\"":\""user\"",\""content\"":\""hi\""}]}'"
Write-Host ''
