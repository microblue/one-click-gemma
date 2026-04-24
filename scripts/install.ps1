<#
.SYNOPSIS
  Gemma one-click installer for Windows — installs Ollama + Gemma and
  wires a local-gemma4 provider into OpenClaw. Safe to re-run.

.DESCRIPTION
  Default user invocation:
      irm https://<host>/install.ps1 | iex

  CI / power-user overrides via environment variables:
      $env:GEMMA_MODEL       = 'gemma4:e2b'       (empty = auto-fit by RAM/disk)
      $env:GEMMA_LISTEN      = '127.0.0.1:11434'
      $env:GEMMA_LANG        = 'zh' | 'en'        (default: auto from UI culture)
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

# Empty GEMMA_MODEL means "auto-fit" — Select-Model will pick one post-preflight.
$Model         = Default $env:GEMMA_MODEL  ''
$ModelExplicit = -not [string]::IsNullOrWhiteSpace($env:GEMMA_MODEL)
$Listen        = Default $env:GEMMA_LISTEN '127.0.0.1:11434'
$NoOpenclaw    = $env:GEMMA_NO_OPENCLAW -eq '1'
$SkipPull      = $env:GEMMA_SKIP_PULL   -eq '1'
$AssumeYes     = $env:GEMMA_YES         -eq '1'
$LangForce     = Default $env:GEMMA_LANG ''

# ---------------------------------------------------------------------------
# i18n — pick zh vs en from override or current UI culture
# ---------------------------------------------------------------------------
function Resolve-Lang {
    param([string]$Force)
    if ($Force) {
        if ($Force -match '^(?i)zh') { return 'zh' } else { return 'en' }
    }
    try {
        $culture = [System.Globalization.CultureInfo]::CurrentUICulture.Name
    } catch { $culture = '' }
    if ($culture -match '^(?i)zh') { return 'zh' } else { return 'en' }
}
$Lang = Resolve-Lang -Force $LangForce

# Translation table: $Msg[key] = @{ zh='...'; en='...' }
# Values are .NET format strings; use `{0}` placeholders.
$Msg = @{
    made_by         = @{ zh = 'MyClaw.One 出品';                                    en = 'Made by MyClaw.One' }
    banner_title    = @{ zh = 'Gemma · 一键安装 · for OpenClaw';                    en = 'Gemma · One-click Installer for OpenClaw' }
    banner_sub      = @{ zh = '本地 Gemma,兼容 OpenAI API v1';                      en = 'Local Gemma behind an OpenAI-compatible API v1' }
    step_preflight  = @{ zh = '体检 Preflight';                                      en = 'Preflight' }
    step_install    = @{ zh = '安装 Ollama 运行时';                                  en = 'Install Ollama runtime' }
    step_service    = @{ zh = '启动 Ollama 服务';                                   en = 'Start Ollama service' }
    step_pull       = @{ zh = '拉取模型 {0}';                                       en = 'Pull model {0}' }
    step_openclaw   = @{ zh = '接入 OpenClaw';                                      en = 'Wire into OpenClaw' }
    os_win          = @{ zh = '操作系统: {0}';                                      en = 'OS: {0}' }
    ram_detected    = @{ zh = '内存: {0} GB';                                        en = 'RAM: {0} GB' }
    disk_detected   = @{ zh = '磁盘可用: {0} GB (盘符 {1})';                         en = 'disk free: {0} GB (drive {1})' }
    gpu_found       = @{ zh = 'GPU: {0}';                                            en = 'GPU: {0}' }
    gpu_none        = @{ zh = '未检测到 GPU,将用 CPU 推理 (慢,但能跑)';              en = 'no GPU detected; CPU inference (slower, but works)' }
    net_fail        = @{ zh = '无法连接 ollama.com: {0}';                            en = 'cannot reach ollama.com: {0}' }
    net_ok          = @{ zh = '网络可达';                                            en = 'network OK' }
    pick_title      = @{ zh = '选择要安装的模型 (10 秒后自动选默认)';                en = 'Pick a model to install (auto-default in 10 s)' }
    pick_hardware   = @{ zh = '当前硬件: 内存 {0} GB · 磁盘 {1} GB';                  en = 'Hardware: {0} GB RAM · {1} GB disk' }
    pick_fit        = @{ zh = '适配';                                                en = 'fits' }
    pick_unfit      = @{ zh = '内存/磁盘不足';                                       en = 'too big for this machine' }
    pick_recommend  = @{ zh = '推荐';                                                en = 'recommended' }
    pick_prompt     = @{ zh = '请输入 1-4 (或回车): ';                               en = 'Enter 1-4 (or Enter): ' }
    pick_timeout    = @{ zh = '10 秒未输入,用默认 {0}';                              en = 'no input in 10 s, using default {0}' }
    pick_unknown    = @{ zh = '未识别输入 "{0}",用默认 {1}';                         en = 'unrecognized input "{0}", using default {1}' }
    pick_chose      = @{ zh = '已选择 {0}';                                          en = 'selected {0}' }
    autofit_chose   = @{ zh = '根据硬件自动选择: {0}';                               en = 'auto-picked by hardware: {0}' }
    autofit_none    = @{ zh = '内存/磁盘都不足以装最小模型 (需 1 GB RAM + 1 GB 磁盘)'; en = 'RAM/disk too low even for the smallest model (need 1 GB RAM + 1 GB disk)' }
    explicit_unfit  = @{ zh = '你指定的 {0} 需要 {1} GB 内存 / {2} GB 磁盘,本机只有 {3} GB / {4} GB'; en = 'you asked for {0}, which needs {1} GB RAM / {2} GB disk; machine has {3} / {4}' }
    autoswap        = @{ zh = '自动降级到 {0}';                                       en = 'downgrading to {0}' }
    ask_downgrade   = @{ zh = '硬件不够,是否降级到 {0}? [y/N] ';                      en = 'hardware too low; downgrade to {0}? [y/N] ' }
    keep_risky      = @{ zh = '仍使用 {0} (启动可能失败)';                            en = 'keeping {0} (may fail to start)' }
    ollama_have     = @{ zh = 'Ollama 已安装 ({0}),跳过';                             en = 'Ollama already installed ({0}), skipping' }
    ollama_dl       = @{ zh = '从 ollama.com 下载 OllamaSetup.exe...';                en = 'downloading OllamaSetup.exe from ollama.com...' }
    ollama_dl_fail  = @{ zh = '下载 OllamaSetup.exe 失败: {0}';                       en = 'OllamaSetup.exe download failed: {0}' }
    ollama_running  = @{ zh = '静默运行 OllamaSetup.exe /VERYSILENT /NORESTART...';    en = 'running OllamaSetup.exe /VERYSILENT /NORESTART...' }
    ollama_no_exit  = @{ zh = 'OllamaSetup.exe 5 分钟内未退出,中止';                  en = 'OllamaSetup.exe did not exit within 5 min, aborting' }
    ollama_fail     = @{ zh = 'OllamaSetup.exe 退出码 {0}';                           en = 'OllamaSetup.exe exit code {0}' }
    ollama_done     = @{ zh = 'Ollama 已安装';                                        en = 'Ollama installed' }
    service_env     = @{ zh = '已把 OLLAMA_HOST={0} 写入用户环境';                    en = 'wrote OLLAMA_HOST={0} to user env' }
    service_start   = @{ zh = '启动 ollama serve 在后台...';                          en = 'starting ollama serve in background...' }
    service_ready   = @{ zh = 'Ollama 服务就绪 ({0}, version {1})';                    en = 'Ollama service ready ({0}, version {1})' }
    service_fail    = @{ zh = 'Ollama 服务 30s 内未就绪';                             en = 'Ollama service not ready within 30 s' }
    pull_skip       = @{ zh = 'GEMMA_SKIP_PULL=1 已设置,跳过下载';                    en = 'GEMMA_SKIP_PULL=1 set, skipping download' }
    pull_have       = @{ zh = '{0} 已存在,跳过';                                      en = '{0} already present, skipping' }
    pull_go         = @{ zh = '开始 ollama pull {0}...';                              en = 'running ollama pull {0}...' }
    pull_retry      = @{ zh = 'pull 失败,1s 后重试...';                                en = 'pull failed, retrying in 1 s...' }
    pull_fail       = @{ zh = 'ollama pull {0} 失败';                                  en = 'ollama pull {0} failed' }
    pull_done       = @{ zh = '模型 {0} 已就位';                                      en = 'model {0} in place' }
    oc_skip         = @{ zh = 'GEMMA_NO_OPENCLAW=1 已设置,跳过配置';                   en = 'GEMMA_NO_OPENCLAW=1 set, skipping OpenClaw wiring' }
    oc_found        = @{ zh = '发现 OpenClaw 配置: {0}';                               en = 'found OpenClaw config: {0}' }
    oc_bad_json     = @{ zh = 'openclaw 配置不是合法 JSON — 拒绝修改: {0}';             en = 'openclaw config is not valid JSON — refusing to modify: {0}' }
    oc_wrote        = @{ zh = '已把 local-gemma4 provider 写入 {0}';                   en = 'wrote local-gemma4 provider into {0}' }
    oc_nofile       = @{ zh = '未检测到 OpenClaw 配置,下面打印 provider 供你手动粘贴:'; en = 'no OpenClaw config found; printing provider JSON to paste manually:' }
    oc_copied       = @{ zh = '(同时复制到剪贴板)';                                   en = '(also copied to clipboard)' }
    done_title      = @{ zh = '全部就绪';                                              en = 'all set' }
    done_api        = @{ zh = '本地 API';                                              en = 'Local API' }
    done_model      = @{ zh = '模型';                                                  en = 'Model' }
    done_openclaw   = @{ zh = 'OpenClaw';                                              en = 'OpenClaw' }
    done_skipped    = @{ zh = '已跳过';                                                 en = 'skipped' }
    done_configured = @{ zh = '已自动配置 / 配置已打印';                                en = 'auto-configured / printed' }
    done_test       = @{ zh = '测试消息:';                                              en = 'try a chat:' }
}

function T {
    param([string]$Key)
    $args2 = $args
    $entry = $Msg[$Key]
    if (-not $entry) { return $Key }
    $fmt = $entry[$Lang]
    if (-not $fmt) { $fmt = $entry['en'] }
    if ($args2.Count -eq 0) { return $fmt }
    return [string]::Format($fmt, $args2)
}

# ---------------------------------------------------------------------------
# log helpers
# ---------------------------------------------------------------------------
function Info($msg) { Write-Host "▸ $msg" -ForegroundColor Blue }
function Ok  ($msg) { Write-Host "✓ $msg" -ForegroundColor Green }
function Warn($msg) { Write-Host "! $msg" -ForegroundColor Yellow }
function Die ($msg) { Write-Host "✗ $msg" -ForegroundColor Red; exit 1 }
function Step($n, $total, $label) {
    Write-Host ''
    Write-Host ("[{0}/{1}] {2}" -f $n, $total, $label) -ForegroundColor Cyan
}

# ---------------------------------------------------------------------------
# model catalog + hardware probes
# ---------------------------------------------------------------------------
$ModelCatalog = @(
    @{ Id = 'gemma3:270m'; Ram = 1; Disk = 1  },
    @{ Id = 'gemma3:1b';   Ram = 2; Disk = 2  },
    @{ Id = 'gemma3:4b';   Ram = 6; Disk = 5  },
    @{ Id = 'gemma4:e2b';  Ram = 9; Disk = 11 }
)
$DefaultRecommended = 'gemma4:e2b'

function Get-ModelNeed {
    param([string]$Id)
    $row = $ModelCatalog | Where-Object { $_.Id -eq $Id } | Select-Object -First 1
    if ($row) { return $row } else { return @{ Id = $Id; Ram = 0; Disk = 0 } }
}

function Get-LargestFittingModel {
    param([int]$RamGB, [int]$DiskGB)
    $fit = $null
    foreach ($row in $ModelCatalog) {
        if ($RamGB -ge $row.Ram -and $DiskGB -ge $row.Disk) { $fit = $row.Id }
    }
    return $fit
}

function Get-RamGB {
    try {
        $bytes = (Get-CimInstance -ClassName Win32_ComputerSystem).TotalPhysicalMemory
        return [int][math]::Floor($bytes / 1GB)
    } catch { return 0 }
}

function Get-DiskGB {
    try {
        $drive = (Get-Item $env:USERPROFILE).PSDrive
        return [int][math]::Floor($drive.Free / 1GB)
    } catch { return 0 }
}

# ---------------------------------------------------------------------------
# interactive model picker (10 s timeout, fit-aware)
# ---------------------------------------------------------------------------
function Invoke-ModelPicker {
    param([int]$RamGB, [int]$DiskGB, [string]$Default)

    Write-Host ''
    Write-Host (T 'pick_title') -ForegroundColor Cyan
    Write-Host (T 'pick_hardware' $RamGB $DiskGB) -ForegroundColor DarkGray
    Write-Host ''

    for ($idx = 0; $idx -lt $ModelCatalog.Count; $idx++) {
        $row = $ModelCatalog[$idx]
        $fitsColor = if ($RamGB -ge $row.Ram -and $DiskGB -ge $row.Disk) { 'Green' } else { 'Red' }
        $fitsTag   = if ($RamGB -ge $row.Ram -and $DiskGB -ge $row.Disk) { T 'pick_fit' } else { T 'pick_unfit' }
        $line = ("  {0}) {1}  (RAM>={2}G, disk>={3}G) [{4}]" -f ($idx + 1), $row.Id, $row.Ram, $row.Disk, $fitsTag)
        if ($row.Id -eq $Default) { $line += ('  <- ' + (T 'pick_recommend')) }
        Write-Host $line -ForegroundColor $fitsColor
    }

    Write-Host ''
    Write-Host -NoNewline (T 'pick_prompt') -ForegroundColor White

    # Timed read — poll Host.UI.RawUI KeyAvailable, assemble line, stop at 10 s
    # or when Enter is pressed. Stays compatible with Windows PowerShell 5.1.
    $deadline = (Get-Date).AddSeconds(10)
    $buf = New-Object System.Text.StringBuilder
    while ((Get-Date) -lt $deadline) {
        if ([System.Console]::KeyAvailable) {
            $k = [System.Console]::ReadKey($true)
            if ($k.Key -eq 'Enter') {
                Write-Host ''
                break
            } elseif ($k.Key -eq 'Backspace') {
                if ($buf.Length -gt 0) {
                    [void]$buf.Remove($buf.Length - 1, 1)
                    Write-Host -NoNewline "`b `b"
                }
            } elseif ($k.KeyChar -and [int]$k.KeyChar -ge 32) {
                [void]$buf.Append($k.KeyChar)
                Write-Host -NoNewline $k.KeyChar
            }
        }
        Start-Sleep -Milliseconds 100
    }
    Write-Host ''
    $choice = $buf.ToString().Trim()

    if ((Get-Date) -ge $deadline -and $choice -eq '') {
        Warn (T 'pick_timeout' $Default)
        return $Default
    }
    if ($choice -eq '') { return $Default }

    $idx = 0
    if ([int]::TryParse($choice, [ref]$idx) -and $idx -ge 1 -and $idx -le $ModelCatalog.Count) {
        return $ModelCatalog[$idx - 1].Id
    }
    Warn (T 'pick_unknown' $choice $Default)
    return $Default
}

function Select-Model {
    param([int]$RamGB, [int]$DiskGB)

    $best = Get-LargestFittingModel -RamGB $RamGB -DiskGB $DiskGB
    if (-not $best) { Die (T 'autofit_none') }

    if ($ModelExplicit) {
        $need = Get-ModelNeed -Id $Model
        if ($need.Ram -gt 0 -and ($RamGB -lt $need.Ram -or $DiskGB -lt $need.Disk)) {
            Warn (T 'explicit_unfit' $Model $need.Ram $need.Disk $RamGB $DiskGB)
            $downgrade = $false
            if ($AssumeYes -or -not $Host.UI.RawUI) {
                $downgrade = $true
            } else {
                Write-Host -NoNewline (T 'ask_downgrade' $best) -ForegroundColor White
                $ans = [System.Console]::ReadLine()
                if ($ans -match '^(y|Y)') { $downgrade = $true }
            }
            if ($downgrade) {
                Info (T 'autoswap' $best)
                $script:Model = $best
            } else {
                Warn (T 'keep_risky' $Model)
            }
        }
        return
    }

    if ($AssumeYes) {
        $script:Model = $best
        Ok (T 'autofit_chose' $Model)
        return
    }

    # Interactive — only if we have a real TTY
    $interactive = $true
    try { if (-not $Host.UI.RawUI) { $interactive = $false } } catch { $interactive = $false }
    if (-not $interactive) {
        $script:Model = $best
        Ok (T 'autofit_chose' $Model)
        return
    }

    # Recommend the largest fitting by default — not a hardcoded e2b.
    $script:Model = Invoke-ModelPicker -RamGB $RamGB -DiskGB $DiskGB -Default $best
    Ok (T 'pick_chose' $Model)
}

# ---------------------------------------------------------------------------
# banner
# ---------------------------------------------------------------------------
Write-Host ''
Write-Host '  ╔══════════════════════════════════════════════════════╗' -ForegroundColor White
Write-Host ('  ║  ' + (T 'banner_title'))                                 -ForegroundColor White
Write-Host ('  ║  ' + (T 'banner_sub'))                                   -ForegroundColor White
Write-Host '  ╚══════════════════════════════════════════════════════╝' -ForegroundColor White
Write-Host ('  ' + (T 'made_by') + '  https://myclaw.one')                -ForegroundColor Yellow
Write-Host ''
Write-Host ("  model    : {0}" -f $(if ($Model) { $Model } else { '(auto)' })) -ForegroundColor DarkGray
Write-Host ("  listen   : {0}" -f $Listen)                                     -ForegroundColor DarkGray
Write-Host ("  openclaw : {0}" -f $(if ($NoOpenclaw) { 'skip' } else { 'auto-inject' })) -ForegroundColor DarkGray

# ---------------------------------------------------------------------------
# [1/5] preflight
# ---------------------------------------------------------------------------
Step 1 5 (T 'step_preflight')

$os = (Get-CimInstance -ClassName Win32_OperatingSystem).Caption
Ok (T 'os_win' $os)

$RamGB  = Get-RamGB
$DiskGB = Get-DiskGB
Ok (T 'ram_detected' $RamGB)
$homeDrive = (Get-Item $env:USERPROFILE).PSDrive
Ok (T 'disk_detected' $DiskGB $homeDrive.Name)

try {
    $gpu = (Get-CimInstance -ClassName Win32_VideoController |
            Select-Object -ExpandProperty Name | Select-Object -First 1)
} catch { $gpu = $null }
if ($gpu) { Ok (T 'gpu_found' $gpu) } else { Warn (T 'gpu_none') }

try {
    Invoke-WebRequest -Uri 'https://ollama.com' -Method Head -TimeoutSec 5 -UseBasicParsing | Out-Null
    Ok (T 'net_ok')
} catch {
    Die (T 'net_fail' $_)
}

# ---------------------------------------------------------------------------
# [1.5] pick / auto-fit the model based on RAM+disk
# ---------------------------------------------------------------------------
Select-Model -RamGB $RamGB -DiskGB $DiskGB
if (-not $Model) { $Model = $DefaultRecommended }  # belt-and-suspenders

# ---------------------------------------------------------------------------
# [2/5] install Ollama
# ---------------------------------------------------------------------------
Step 2 5 (T 'step_install')

$ollamaCmd = Get-Command ollama -ErrorAction SilentlyContinue
if ($ollamaCmd) {
    Ok (T 'ollama_have' $ollamaCmd.Source)
} else {
    $setup = Join-Path $env:TEMP 'OllamaSetup.exe'
    Info (T 'ollama_dl')
    try {
        Invoke-WebRequest -Uri 'https://ollama.com/download/OllamaSetup.exe' `
                          -OutFile $setup -UseBasicParsing
    } catch {
        Die (T 'ollama_dl_fail' $_)
    }

    $markerDir = Join-Path $env:LOCALAPPDATA 'Ollama'
    if (-not (Test-Path $markerDir)) { New-Item -ItemType Directory -Path $markerDir -Force | Out-Null }
    New-Item -ItemType File -Path (Join-Path $markerDir 'upgraded') -Force | Out-Null

    Info (T 'ollama_running')
    $p = Start-Process -FilePath $setup `
                       -ArgumentList '/VERYSILENT','/NORESTART','/SUPPRESSMSGBOXES' `
                       -PassThru
    if (-not $p.WaitForExit(300000)) {
        try { $p.Kill() } catch { }
        Die (T 'ollama_no_exit')
    }
    if ($p.ExitCode -ne 0) { Die (T 'ollama_fail' $p.ExitCode) }
    Remove-Item $setup -ErrorAction SilentlyContinue

    $env:Path = [System.Environment]::GetEnvironmentVariable('Path','Machine') + ';' + `
                [System.Environment]::GetEnvironmentVariable('Path','User')
    Ok (T 'ollama_done')
}

# ---------------------------------------------------------------------------
# [3/5] start Ollama and wait for API
# ---------------------------------------------------------------------------
Step 3 5 (T 'step_service')

if ($Listen -ne '127.0.0.1:11434') {
    [System.Environment]::SetEnvironmentVariable('OLLAMA_HOST', $Listen, 'User')
    $env:OLLAMA_HOST = $Listen
    Info (T 'service_env' $Listen)
}

$endpoint = "http://$Listen"
$ready = $false
for ($i = 0; $i -lt 30 -and -not $ready; $i++) {
    try {
        $v = Invoke-RestMethod "$endpoint/api/version" -TimeoutSec 2
        Ok (T 'service_ready' $endpoint $v.version)
        $ready = $true
    } catch {
        if ($i -eq 2 -and -not (Get-Process ollama -ErrorAction SilentlyContinue)) {
            Info (T 'service_start')
            Start-Process -FilePath 'ollama' -ArgumentList 'serve' -WindowStyle Hidden -ErrorAction SilentlyContinue
        }
        Start-Sleep -Seconds 1
    }
}
if (-not $ready) { Die (T 'service_fail') }

# ---------------------------------------------------------------------------
# [4/5] pull the model
# ---------------------------------------------------------------------------
Step 4 5 (T 'step_pull' $Model)

if ($SkipPull) {
    Ok (T 'pull_skip')
} else {
    $installed = & ollama list 2>$null | Select-String -Pattern "^$([regex]::Escape($Model))\s" -Quiet
    if ($installed) {
        Ok (T 'pull_have' $Model)
    } else {
        Info (T 'pull_go' $Model)
        & ollama pull $Model
        if ($LASTEXITCODE -ne 0) {
            Warn (T 'pull_retry')
            Start-Sleep -Seconds 1
            & ollama pull $Model
            if ($LASTEXITCODE -ne 0) { Die (T 'pull_fail' $Model) }
        }
        Ok (T 'pull_done' $Model)
    }
}

# ---------------------------------------------------------------------------
# [5/5] inject the provider into OpenClaw
# ---------------------------------------------------------------------------
Step 5 5 (T 'step_openclaw')

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
    Ok (T 'oc_skip')
} else {
    $cfg = Find-OpenclawConfig
    if ($cfg) {
        Info (T 'oc_found' $cfg)
        $raw  = Get-Content $cfg -Raw
        try {
            $json = $raw | ConvertFrom-Json
        } catch {
            Die (T 'oc_bad_json' $_)
        }
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
        Ok (T 'oc_wrote' $cfg)
    } else {
        Warn (T 'oc_nofile')
        $cacheDir = Join-Path $env:USERPROFILE '.gemma-installer'
        if (-not (Test-Path $cacheDir)) { New-Item -ItemType Directory -Path $cacheDir | Out-Null }
        $providerJson | Set-Content -Path (Join-Path $cacheDir 'openclaw-provider.json') -Encoding UTF8
        try { $providerJson | Set-Clipboard; Info (T 'oc_copied') } catch { }
        Write-Host ''
        Write-Host $providerJson
    }
}

# ---------------------------------------------------------------------------
# final banner
# ---------------------------------------------------------------------------
Write-Host ''
Write-Host ("  ✓ " + (T 'done_title')) -ForegroundColor Green
Write-Host ''
Write-Host ("  {0}   : http://{1}/v1" -f (T 'done_api'), $Listen)
Write-Host ("  {0}       : {1}" -f (T 'done_model'), $Model)
$ocState = if ($NoOpenclaw) { T 'done_skipped' } else { T 'done_configured' }
Write-Host ("  {0}   : {1}" -f (T 'done_openclaw'), $ocState)
Write-Host ''
Write-Host ('  ' + (T 'done_test'))
Write-Host ("  curl.exe http://$Listen/v1/chat/completions -H 'Content-Type: application/json' -d '{\""model\"":\""$Model\"",\""messages\"":[{\""role\"":\""user\"",\""content\"":\""hi\""}]}'")
Write-Host ''
