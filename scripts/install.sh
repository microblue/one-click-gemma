#!/usr/bin/env sh
# Gemma one-click installer for Linux + macOS — installs Ollama + Gemma
# and wires a local-gemma4 provider into OpenClaw. Safe to re-run.
#
# Usage:
#   curl -fsSL https://<host>/install.sh | sh
#
# Flags (advanced / CI):
#   --model <tag>     Ollama model tag to pull            (default: auto-fit by RAM/disk)
#   --listen <addr>   OLLAMA_HOST value                    (default: 127.0.0.1:11434)
#   --lang <zh|en>    force UI language                    (default: auto from $LANG)
#   --no-openclaw     skip OpenClaw config injection
#   --skip-pull       skip model download (CI smoke tests)
#   --yes             non-interactive, auto-confirm all prompts
#   --help            show this help and exit

set -eu

# ---------------------------------------------------------------------------
# defaults & flag parsing
# ---------------------------------------------------------------------------
MODEL=""                # empty = auto-fit; select_model() will populate
MODEL_EXPLICIT="0"
LISTEN="127.0.0.1:11434"
SKIP_OPENCLAW="0"
SKIP_PULL="0"
ASSUME_YES="0"
LANG_FORCE=""
RAM_GB=0
DISK_GB=0

# Per-model minimums. RAM reflects "Ollama can load + run with headroom"
# on CPU; disk reflects "download + unpack + working room" (~1.5× model).
# Order: ascending by size. MUST end with a trailing newline for the
# POSIX `while read` loop to pick up the last line.
#   id            min_ram_gb  min_disk_gb
MODEL_CATALOG='gemma3:270m 1 1
gemma3:1b 2 2
gemma3:4b 6 5
gemma4:e2b 9 11
'
DEFAULT_MODEL="gemma4:e2b"

while [ $# -gt 0 ]; do
    case "$1" in
        --model)        MODEL="$2"; MODEL_EXPLICIT="1"; shift 2 ;;
        --model=*)      MODEL="${1#*=}"; MODEL_EXPLICIT="1"; shift ;;
        --listen)       LISTEN="$2"; shift 2 ;;
        --listen=*)     LISTEN="${1#*=}"; shift ;;
        --lang)         LANG_FORCE="$2"; shift 2 ;;
        --lang=*)       LANG_FORCE="${1#*=}"; shift ;;
        --no-openclaw)  SKIP_OPENCLAW="1"; shift ;;
        --skip-pull)    SKIP_PULL="1"; shift ;;
        --yes|-y)       ASSUME_YES="1"; shift ;;
        --help|-h)
            sed -n '2,16p' "$0" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *)
            printf 'unknown flag: %s\n' "$1" >&2
            exit 2
            ;;
    esac
done

OS=$(uname -s)

# ---------------------------------------------------------------------------
# i18n: detect language from $LANG / --lang override. Only zh vs. en.
# ---------------------------------------------------------------------------
if [ -n "$LANG_FORCE" ]; then
    case "$LANG_FORCE" in
        zh*|ZH*) LANG_ZH="1" ;;
        *)       LANG_ZH="0" ;;
    esac
else
    case "${LANG:-}${LC_ALL:-}${LC_MESSAGES:-}" in
        *zh*|*ZH*) LANG_ZH="1" ;;
        *)         LANG_ZH="0" ;;
    esac
fi

# t <key> [args...]   translates a message by key; positional args interpolate
#                     into %s placeholders (safe — no shell eval on the format).
t() {
    key="$1"
    shift
    if [ "$LANG_ZH" = "1" ]; then
        case "$key" in
            made_by)         fmt='MyClaw.One 出品' ;;
            banner_title)    fmt='Gemma · 一键安装 · for OpenClaw' ;;
            banner_sub)      fmt='本地 Gemma,兼容 OpenAI API v1' ;;
            step_preflight)  fmt='体检 Preflight' ;;
            step_install)    fmt='安装 Ollama 运行时' ;;
            step_service)    fmt='启动 Ollama 服务' ;;
            step_pull)       fmt='拉取模型 %s' ;;
            step_openclaw)   fmt='接入 OpenClaw' ;;
            os_linux)        fmt='操作系统: Linux %s' ;;
            os_macos)        fmt='操作系统: macOS %s' ;;
            os_unsup)        fmt='不支持的系统: %s (仅 Linux / macOS,Windows 请用 install.ps1)' ;;
            deps_ok)         fmt='依赖齐全 (curl, awk, grep, sed)' ;;
            deps_missing)    fmt='缺少依赖: %s' ;;
            zstd_installing) fmt='Ollama 需要 zstd 来解压安装包,正在自动安装...' ;;
            zstd_ok)         fmt='zstd 已就绪' ;;
            zstd_fail)       fmt='zstd 安装失败,请手动装后重跑' ;;
            zstd_unknown_pm) fmt='未知包管理器,请手动安装 zstd 后重跑' ;;
            ram_detected)    fmt='内存: %s GB' ;;
            disk_detected)   fmt='磁盘可用: %s GB (在 %s)' ;;
            gpu_found)       fmt='GPU: %s' ;;
            gpu_nvidia_void) fmt='有 nvidia-smi 但没返回 GPU 信息,将回退 CPU 推理' ;;
            gpu_amd)         fmt='GPU: AMD ROCm detected' ;;
            gpu_none)        fmt='未检测到 GPU,将用 CPU 推理 (速度会慢,但能跑)' ;;
            gpu_mac)         fmt='GPU: %s' ;;
            gpu_mac_unknown) fmt='未识别显卡,将用 CPU 推理' ;;
            net_fail)        fmt='无法连接 ollama.com,请检查网络' ;;
            net_ok)          fmt='网络可达' ;;
            pick_title)      fmt='选择要安装的模型 (10 秒后自动选默认)' ;;
            pick_hardware)   fmt='当前硬件: 内存 %s GB · 磁盘 %s GB' ;;
            pick_fit)        fmt='适配' ;;
            pick_unfit)      fmt='内存/磁盘不足' ;;
            pick_recommend)  fmt='推荐' ;;
            pick_prompt)     fmt='请输入 1-4 (或回车): ' ;;
            pick_timeout)    fmt='10 秒未输入,用默认 %s' ;;
            pick_unknown)    fmt='未识别输入 "%s",用默认 %s' ;;
            pick_chose)      fmt='已选择 %s' ;;
            autofit_chose)   fmt='根据硬件自动选择: %s' ;;
            autofit_none)    fmt='内存或磁盘都不足以装最小模型 (需 1 GB RAM + 1 GB 磁盘)' ;;
            explicit_unfit)  fmt='你指定的 %s 需要 %s GB 内存 / %s GB 磁盘,本机只有 %s GB / %s GB' ;;
            autoswap)        fmt='自动降级到 %s' ;;
            ask_downgrade)   fmt='硬件不够,是否降级到 %s?' ;;
            keep_risky)      fmt='仍使用 %s (启动可能失败)' ;;
            ollama_have)     fmt='Ollama 已安装 (version %s),跳过' ;;
            ollama_ubuntu)   fmt='从 ollama.com 下载官方安装脚本...' ;;
            ollama_ask_sh)   fmt='即将执行 Ollama 官方 install.sh,会用 sudo 装 systemd 服务,继续?' ;;
            ollama_brew)     fmt='用 brew install ollama...' ;;
            ollama_ask_brew) fmt="即将运行 'brew install ollama',继续?" ;;
            ollama_dmg)      fmt='未检测到 brew,下载 Ollama.dmg...' ;;
            ollama_ask_dmg)  fmt='将从 ollama.com 下载 Ollama.dmg 并拷贝到 /Applications,继续?' ;;
            ollama_attach)   fmt='hdiutil attach 失败' ;;
            ollama_done)     fmt='Ollama 已安装' ;;
            service_ready)   fmt='Ollama 服务就绪 (%s, version %s)' ;;
            service_start)   fmt='在后台启动 ollama serve...' ;;
            service_app)     fmt='启动 Ollama.app...' ;;
            service_fail)    fmt='Ollama 服务 30s 内未就绪,请手动检查' ;;
            pull_skip)       fmt="--skip-pull 已设置,跳过下载 (用 'ollama pull %s' 手动补上)" ;;
            pull_have)       fmt='%s 已存在,跳过' ;;
            pull_go)         fmt='开始下载,进度取决于你的网速...' ;;
            pull_retry)      fmt='首次 pull 失败,1s 后重试' ;;
            pull_fail)       fmt='pull %s 失败,请检查磁盘和网络' ;;
            pull_done)       fmt='模型 %s 已就位' ;;
            oc_skip)         fmt='用户要求跳过 OpenClaw 配置' ;;
            oc_nofile)       fmt='未检测到 OpenClaw 配置,在下面打印 provider,请粘贴到 OpenClaw 设置里' ;;
            oc_saved)        fmt='(同时已保存到 %s)' ;;
            oc_found)        fmt='发现 OpenClaw 配置: %s' ;;
            oc_wrote)        fmt='已把 local-gemma4 provider 写入 %s' ;;
            oc_no_py)        fmt='未找到 python3,跳过自动注入,下面打印 provider 手动粘贴:' ;;
            oc_bad_json)     fmt='openclaw config 不是合法 JSON — 保持原样不动' ;;
            oc_bad_root)     fmt='openclaw config 根不是 JSON 对象' ;;
            done_title)      fmt='全部就绪' ;;
            done_api)        fmt='本地 API' ;;
            done_model)      fmt='模型' ;;
            done_openclaw)   fmt='OpenClaw' ;;
            done_skipped)    fmt='已跳过' ;;
            done_configured) fmt='已自动配置 / 配置已打印' ;;
            done_test)       fmt='发个测试消息:' ;;
            cancel)          fmt='用户取消' ;;
            default_mark)    fmt='默认' ;;
            *)               fmt="$key" ;;
        esac
    else
        case "$key" in
            made_by)         fmt='Made by MyClaw.One' ;;
            banner_title)    fmt='Gemma · One-click Installer for OpenClaw' ;;
            banner_sub)      fmt='Local Gemma behind an OpenAI-compatible API v1' ;;
            step_preflight)  fmt='Preflight' ;;
            step_install)    fmt='Install Ollama runtime' ;;
            step_service)    fmt='Start Ollama service' ;;
            step_pull)       fmt='Pull model %s' ;;
            step_openclaw)   fmt='Wire into OpenClaw' ;;
            os_linux)        fmt='OS: Linux %s' ;;
            os_macos)        fmt='OS: macOS %s' ;;
            os_unsup)        fmt='unsupported OS: %s (only Linux / macOS; for Windows use install.ps1)' ;;
            deps_ok)         fmt='dependencies present (curl, awk, grep, sed)' ;;
            deps_missing)    fmt='missing dependency: %s' ;;
            zstd_installing) fmt='Ollama needs zstd to unpack; installing...' ;;
            zstd_ok)         fmt='zstd ready' ;;
            zstd_fail)       fmt='zstd install failed; install manually and retry' ;;
            zstd_unknown_pm) fmt='unknown package manager; install zstd manually and retry' ;;
            ram_detected)    fmt='RAM: %s GB' ;;
            disk_detected)   fmt='disk free: %s GB (at %s)' ;;
            gpu_found)       fmt='GPU: %s' ;;
            gpu_nvidia_void) fmt='nvidia-smi present but returned nothing; CPU fallback' ;;
            gpu_amd)         fmt='GPU: AMD ROCm detected' ;;
            gpu_none)        fmt='no GPU detected; CPU inference (slower, but works)' ;;
            gpu_mac)         fmt='GPU: %s' ;;
            gpu_mac_unknown) fmt='no GPU identified; CPU inference' ;;
            net_fail)        fmt='cannot reach ollama.com; check network' ;;
            net_ok)          fmt='network OK' ;;
            pick_title)      fmt='Pick a model to install (auto-default in 10 s)' ;;
            pick_hardware)   fmt='Hardware: %s GB RAM · %s GB disk' ;;
            pick_fit)        fmt='fits' ;;
            pick_unfit)      fmt='too big for this machine' ;;
            pick_recommend)  fmt='recommended' ;;
            pick_prompt)     fmt='Enter 1-4 (or return): ' ;;
            pick_timeout)    fmt='no input in 10 s, using default %s' ;;
            pick_unknown)    fmt='unrecognized input "%s", using default %s' ;;
            pick_chose)      fmt='selected %s' ;;
            autofit_chose)   fmt='auto-picked by hardware: %s' ;;
            autofit_none)    fmt='RAM/disk too low even for the smallest model (need 1 GB RAM + 1 GB disk)' ;;
            explicit_unfit)  fmt='you asked for %s, which needs %s GB RAM / %s GB disk; machine has %s / %s' ;;
            autoswap)        fmt='downgrading to %s' ;;
            ask_downgrade)   fmt='hardware too low; downgrade to %s?' ;;
            keep_risky)      fmt='keeping %s (may fail to start)' ;;
            ollama_have)     fmt='Ollama already installed (version %s), skipping' ;;
            ollama_ubuntu)   fmt='downloading official install.sh from ollama.com...' ;;
            ollama_ask_sh)   fmt='about to run the Ollama official install.sh with sudo; continue?' ;;
            ollama_brew)     fmt='running brew install ollama...' ;;
            ollama_ask_brew) fmt="about to run 'brew install ollama'; continue?" ;;
            ollama_dmg)      fmt='no brew; downloading Ollama.dmg...' ;;
            ollama_ask_dmg)  fmt='about to download Ollama.dmg and copy to /Applications; continue?' ;;
            ollama_attach)   fmt='hdiutil attach failed' ;;
            ollama_done)     fmt='Ollama installed' ;;
            service_ready)   fmt='Ollama service ready (%s, version %s)' ;;
            service_start)   fmt='starting ollama serve in background...' ;;
            service_app)     fmt='launching Ollama.app...' ;;
            service_fail)    fmt='Ollama service not ready within 30 s; check manually' ;;
            pull_skip)       fmt="--skip-pull set, skipping download (finish later with 'ollama pull %s')" ;;
            pull_have)       fmt='%s already present, skipping' ;;
            pull_go)         fmt='downloading; time depends on your network...' ;;
            pull_retry)      fmt='first pull failed, retrying in 1 s' ;;
            pull_fail)       fmt='pull %s failed; check disk and network' ;;
            pull_done)       fmt='model %s in place' ;;
            oc_skip)         fmt='user asked to skip OpenClaw wiring' ;;
            oc_nofile)       fmt='no OpenClaw config found; printing provider JSON to paste into OpenClaw settings' ;;
            oc_saved)        fmt='(also saved to %s)' ;;
            oc_found)        fmt='found OpenClaw config: %s' ;;
            oc_wrote)        fmt='wrote local-gemma4 provider into %s' ;;
            oc_no_py)        fmt='python3 not found; skipping auto-inject, printing provider to paste manually:' ;;
            oc_bad_json)     fmt='openclaw config is not valid JSON — refuse to touch it' ;;
            oc_bad_root)     fmt='openclaw config root is not an object' ;;
            done_title)      fmt='all set' ;;
            done_api)        fmt='Local API' ;;
            done_model)      fmt='Model' ;;
            done_openclaw)   fmt='OpenClaw' ;;
            done_skipped)    fmt='skipped' ;;
            done_configured) fmt='auto-configured / printed' ;;
            done_test)       fmt='try a chat:' ;;
            cancel)          fmt='user canceled' ;;
            default_mark)    fmt='default' ;;
            *)               fmt="$key" ;;
        esac
    fi
    # `--` terminates printf option parsing — some of our format strings
    # legitimately start with `--` (e.g. "--skip-pull 已设置...") which dash
    # would otherwise treat as an unknown flag.
    # shellcheck disable=SC2059
    printf -- "$fmt" "$@"
}

# ---------------------------------------------------------------------------
# colored logging
# ---------------------------------------------------------------------------
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
    C_RESET=$(printf '\033[0m')
    C_BOLD=$(printf '\033[1m')
    C_DIM=$(printf '\033[2m')
    C_RED=$(printf '\033[31m')
    C_GREEN=$(printf '\033[32m')
    C_YELLOW=$(printf '\033[33m')
    C_BLUE=$(printf '\033[34m')
    C_CYAN=$(printf '\033[36m')
else
    C_RESET="" C_BOLD="" C_DIM="" C_RED="" C_GREEN="" C_YELLOW="" C_BLUE="" C_CYAN=""
fi

info()  { printf '%s▸%s %s\n'            "$C_BLUE"   "$C_RESET" "$*"; }
ok()    { printf '%s✓%s %s\n'            "$C_GREEN"  "$C_RESET" "$*"; }
warn()  { printf '%s!%s %s\n'            "$C_YELLOW" "$C_RESET" "$*" >&2; }
err()   { printf '%s✗%s %s\n'            "$C_RED"    "$C_RESET" "$*" >&2; }
step()  { printf '\n%s%s[%s/%s]%s %s\n'  "$C_BOLD" "$C_CYAN" "$1" "$2" "$C_RESET" "$3"; }
die()   { err "$*"; exit 1; }

confirm() {
    if [ "$ASSUME_YES" = "1" ]; then return 0; fi
    printf '%s%s%s [y/N] ' "$C_BOLD" "$1" "$C_RESET"
    read -r reply </dev/tty || return 1
    case "$reply" in
        y|Y|yes|YES) return 0 ;;
        *)           return 1 ;;
    esac
}

# ---------------------------------------------------------------------------
# hardware probes
# ---------------------------------------------------------------------------
probe_ram_gb() {
    case "$OS" in
        Linux)
            awk '/^MemTotal:/{printf "%d", $2/1024/1024}' /proc/meminfo 2>/dev/null || echo 0
            ;;
        Darwin)
            mem_bytes=$(sysctl -n hw.memsize 2>/dev/null || echo 0)
            # bash-style, but POSIX arithmetic is fine here
            echo $((mem_bytes / 1073741824))
            ;;
        *) echo 0 ;;
    esac
}

probe_disk_gb() {
    # df -Pk gives KB in the 4th column of row 2 for the target mount
    df -Pk "$HOME" 2>/dev/null | awk 'NR==2 {print int($4/1024/1024)}'
}

# Catalog lookups — return min_ram_gb / min_disk_gb for a given model.
# Echo 0 for unknown so catalog-unknown ids don't hard-fail (user knows best).
model_need_ram() {
    while IFS=' ' read -r id ram _disk; do
        [ -z "$id" ] && continue
        if [ "$id" = "$1" ]; then printf '%s' "$ram"; return 0; fi
    done <<EOF
$MODEL_CATALOG
EOF
    printf '0'
}
model_need_disk() {
    while IFS=' ' read -r id _ram disk; do
        [ -z "$id" ] && continue
        if [ "$id" = "$1" ]; then printf '%s' "$disk"; return 0; fi
    done <<EOF
$MODEL_CATALOG
EOF
    printf '0'
}

# Largest catalog model that fits $RAM_GB + $DISK_GB. Echoes the id, or empty.
largest_fitting_model() {
    fit=""
    while IFS=' ' read -r id ram disk; do
        [ -z "$id" ] && continue
        if [ "$RAM_GB" -ge "$ram" ] && [ "$DISK_GB" -ge "$disk" ]; then
            fit="$id"
        fi
    done <<EOF
$MODEL_CATALOG
EOF
    printf '%s' "$fit"
}

# ---------------------------------------------------------------------------
# banner
# ---------------------------------------------------------------------------
print_banner() {
    title=$(t banner_title)
    sub=$(t banner_sub)
    made=$(t made_by)
    cat <<BANNER
${C_BOLD}
  ╔══════════════════════════════════════════════════════╗
  ║  ${title}
  ║  ${sub}
  ╚══════════════════════════════════════════════════════╝
${C_RESET}${C_BOLD}${C_YELLOW}  ${made}${C_RESET}  ${C_DIM}https://myclaw.one${C_RESET}

${C_DIM}  model    : ${C_RESET}${MODEL:-(auto)}
${C_DIM}  listen   : ${C_RESET}$LISTEN
${C_DIM}  openclaw : ${C_RESET}$([ "$SKIP_OPENCLAW" = "1" ] && echo skip || echo auto-inject)
BANNER
}

# ---------------------------------------------------------------------------
# preflight
# ---------------------------------------------------------------------------
preflight() {
    step 1 5 "$(t step_preflight)"

    case "$OS" in
        Linux)  ok "$(t os_linux "$(uname -r)")" ;;
        Darwin) ok "$(t os_macos "$(sw_vers -productVersion 2>/dev/null || uname -r)")" ;;
        *)      die "$(t os_unsup "$OS")" ;;
    esac

    for cmd in curl awk grep sed; do
        command -v "$cmd" >/dev/null 2>&1 || die "$(t deps_missing "$cmd")"
    done
    ok "$(t deps_ok)"

    if [ "$OS" = "Linux" ] && ! command -v zstd >/dev/null 2>&1; then
        info "$(t zstd_installing)"
        if command -v apt-get >/dev/null 2>&1; then
            sudo apt-get update -qq >/dev/null && sudo apt-get install -qq -y zstd >/dev/null
        elif command -v dnf >/dev/null 2>&1; then
            sudo dnf install -y -q zstd >/dev/null
        elif command -v yum >/dev/null 2>&1; then
            sudo yum install -y -q zstd >/dev/null
        elif command -v pacman >/dev/null 2>&1; then
            sudo pacman -S --noconfirm --quiet zstd >/dev/null
        elif command -v apk >/dev/null 2>&1; then
            sudo apk add -q zstd >/dev/null
        else
            die "$(t zstd_unknown_pm)"
        fi
        command -v zstd >/dev/null 2>&1 || die "$(t zstd_fail)"
        ok "$(t zstd_ok)"
    fi

    RAM_GB=$(probe_ram_gb)
    DISK_GB=$(probe_disk_gb)
    ok "$(t ram_detected "$RAM_GB")"
    ok "$(t disk_detected "$DISK_GB" "$HOME")"

    case "$OS" in
        Linux)
            if command -v nvidia-smi >/dev/null 2>&1; then
                gpu=$(nvidia-smi --query-gpu=name,memory.total --format=csv,noheader 2>/dev/null | head -1 || true)
                if [ -n "$gpu" ]; then ok "$(t gpu_found "$gpu")"; else warn "$(t gpu_nvidia_void)"; fi
            elif command -v rocm-smi >/dev/null 2>&1; then
                ok "$(t gpu_amd)"
            else
                warn "$(t gpu_none)"
            fi
            ;;
        Darwin)
            gpu=$(system_profiler SPDisplaysDataType 2>/dev/null | awk -F': ' '/Chipset Model/{print $2; exit}')
            if [ -n "$gpu" ]; then ok "$(t gpu_mac "$gpu")"; else warn "$(t gpu_mac_unknown)"; fi
            ;;
    esac

    if ! curl -fsS --max-time 5 --head https://ollama.com >/dev/null 2>&1; then
        die "$(t net_fail)"
    fi
    ok "$(t net_ok)"
}

# ---------------------------------------------------------------------------
# select_model — picks the final $MODEL after preflight populated RAM/disk.
# Flow:
#   --model explicit → validate fit; offer downgrade
#   non-interactive  → auto-pick the largest fitting model
#   interactive      → show menu with fit/unfit markers, 10 s timeout
# ---------------------------------------------------------------------------
select_model() {
    best=$(largest_fitting_model)
    if [ -z "$best" ]; then
        die "$(t autofit_none)"
    fi

    if [ "$MODEL_EXPLICIT" = "1" ]; then
        need_ram=$(model_need_ram "$MODEL")
        need_disk=$(model_need_disk "$MODEL")
        if [ "$need_ram" -gt 0 ] && { [ "$RAM_GB" -lt "$need_ram" ] || [ "$DISK_GB" -lt "$need_disk" ]; }; then
            warn "$(t explicit_unfit "$MODEL" "$need_ram" "$need_disk" "$RAM_GB" "$DISK_GB")"
            if [ "$ASSUME_YES" = "1" ] || [ ! -r /dev/tty ]; then
                info "$(t autoswap "$best")"
                MODEL="$best"
            else
                if confirm "$(t ask_downgrade "$best")"; then
                    MODEL="$best"
                else
                    warn "$(t keep_risky "$MODEL")"
                fi
            fi
        fi
        return 0
    fi

    if [ "$ASSUME_YES" = "1" ] || [ ! -r /dev/tty ]; then
        MODEL="$best"
        ok "$(t autofit_chose "$MODEL")"
        return 0
    fi

    pick_model_interactive "$best"
}

# ---------------------------------------------------------------------------
# interactive model picker — 10 s countdown, fit-aware
# ---------------------------------------------------------------------------
pick_model_interactive() {
    default_id="$1"

    printf '\n%s%s%s%s\n' "$C_BOLD" "$C_CYAN" "$(t pick_title)" "$C_RESET"
    printf '%s%s%s\n\n' "$C_DIM" "$(t pick_hardware "$RAM_GB" "$DISK_GB")" "$C_RESET"

    idx=0
    default_idx=4
    while IFS=' ' read -r id ram disk; do
        [ -z "$id" ] && continue
        idx=$((idx + 1))
        # Compute fit marker
        if [ "$RAM_GB" -ge "$ram" ] && [ "$DISK_GB" -ge "$disk" ]; then
            marker=" ${C_GREEN}[$(t pick_fit)]${C_RESET}"
        else
            marker=" ${C_RED}[$(t pick_unfit)]${C_RESET}"
        fi
        if [ "$id" = "$default_id" ]; then
            default_idx=$idx
            marker="${marker} ${C_YELLOW}← $(t pick_recommend)${C_RESET}"
        fi
        printf '  %s) %s%s%s  %s(RAM≥%sG, disk≥%sG)%s%s\n' \
            "$idx" "$C_BOLD" "$id" "$C_RESET" "$C_DIM" "$ram" "$disk" "$C_RESET" "$marker"
    done <<EOF
$MODEL_CATALOG
EOF

    printf '\n%s%s%s' "$C_BOLD" "$(t pick_prompt)" "$C_RESET"

    result_file=$(mktemp 2>/dev/null || printf '/tmp/gemma-pick-%s' "$$")
    : > "$result_file"
    (IFS= read -r line < /dev/tty && printf '%s' "$line" > "$result_file") &
    reader_pid=$!

    i=0
    while [ "$i" -lt 10 ]; do
        sleep 1
        if ! kill -0 "$reader_pid" 2>/dev/null; then break; fi
        i=$((i + 1))
    done
    if kill -0 "$reader_pid" 2>/dev/null; then
        kill "$reader_pid" 2>/dev/null || true
        wait "$reader_pid" 2>/dev/null || true
        printf '\n'
        warn "$(t pick_timeout "$default_id")"
        MODEL="$default_id"
        rm -f "$result_file"
        return 0
    fi
    wait "$reader_pid" 2>/dev/null || true

    choice=""
    [ -f "$result_file" ] && choice=$(cat "$result_file")
    rm -f "$result_file"

    # Map numeric input -> catalog row. Empty input means accept recommended.
    if [ -z "$choice" ]; then
        MODEL="$default_id"
    else
        picked=""
        row=0
        while IFS=' ' read -r id _ram _disk; do
            [ -z "$id" ] && continue
            row=$((row + 1))
            if [ "$row" = "$choice" ]; then
                picked="$id"
                break
            fi
        done <<EOF
$MODEL_CATALOG
EOF
        if [ -z "$picked" ]; then
            warn "$(t pick_unknown "$choice" "$default_id")"
            MODEL="$default_id"
        else
            MODEL="$picked"
            # If they picked an unfit one, warn but honor (users sometimes
            # have swap or know better than our heuristic)
            need_ram=$(model_need_ram "$MODEL")
            need_disk=$(model_need_disk "$MODEL")
            if [ "$RAM_GB" -lt "$need_ram" ] || [ "$DISK_GB" -lt "$need_disk" ]; then
                warn "$(t explicit_unfit "$MODEL" "$need_ram" "$need_disk" "$RAM_GB" "$DISK_GB")"
            fi
        fi
    fi
    ok "$(t pick_chose "$MODEL")"
}

# ---------------------------------------------------------------------------
# install Ollama — Linux: curl|sh, macOS: brew or DMG
# ---------------------------------------------------------------------------
install_ollama() {
    step 2 5 "$(t step_install)"

    if command -v ollama >/dev/null 2>&1; then
        ver=$(ollama --version 2>/dev/null | awk '{print $NF}' || echo unknown)
        ok "$(t ollama_have "$ver")"
        return 0
    fi

    case "$OS" in
        Linux)
            info "$(t ollama_ubuntu)"
            if [ "$ASSUME_YES" != "1" ]; then
                confirm "$(t ollama_ask_sh)" || die "$(t cancel)"
            fi
            curl -fsSL https://ollama.com/install.sh | sh
            ;;
        Darwin)
            if command -v brew >/dev/null 2>&1; then
                info "$(t ollama_brew)"
                if [ "$ASSUME_YES" != "1" ]; then
                    confirm "$(t ollama_ask_brew)" || die "$(t cancel)"
                fi
                brew install ollama
            else
                info "$(t ollama_dmg)"
                if [ "$ASSUME_YES" != "1" ]; then
                    confirm "$(t ollama_ask_dmg)" || die "$(t cancel)"
                fi
                dmg="$(mktemp -d)/Ollama.dmg"
                curl -fsSL -o "$dmg" https://ollama.com/download/Ollama.dmg
                mount=$(hdiutil attach "$dmg" -nobrowse -readonly | awk '{print $NF}' | tail -1)
                [ -n "$mount" ] || die "$(t ollama_attach)"
                [ -d /Applications/Ollama.app ] && rm -rf /Applications/Ollama.app
                cp -R "$mount/Ollama.app" /Applications/
                hdiutil detach "$mount" >/dev/null
                rm -f "$dmg"
            fi
            ;;
    esac
    ok "$(t ollama_done)"
}

# ---------------------------------------------------------------------------
# wait_service
# ---------------------------------------------------------------------------
wait_service() {
    step 3 5 "$(t step_service)"

    case "$OS" in
        Linux)
            if [ "$LISTEN" != "127.0.0.1:11434" ] && command -v systemctl >/dev/null 2>&1; then
                info "configuring OLLAMA_HOST=$LISTEN (systemd drop-in)"
                sudo mkdir -p /etc/systemd/system/ollama.service.d
                sudo tee /etc/systemd/system/ollama.service.d/override.conf >/dev/null <<EOF
[Service]
Environment="OLLAMA_HOST=$LISTEN"
Environment="OLLAMA_KEEP_ALIVE=24h"
EOF
                sudo systemctl daemon-reload
                sudo systemctl restart ollama
            fi

            if command -v systemctl >/dev/null 2>&1 && systemctl --no-pager status >/dev/null 2>&1; then
                sudo systemctl enable --now ollama >/dev/null 2>&1 || true
            else
                if ! pgrep -x ollama >/dev/null 2>&1; then
                    info "$(t service_start)"
                    OLLAMA_HOST="$LISTEN" nohup ollama serve >/tmp/ollama-installer.log 2>&1 &
                    sleep 1
                fi
            fi
            ;;
        Darwin)
            if [ "$LISTEN" != "127.0.0.1:11434" ]; then
                launchctl setenv OLLAMA_HOST "$LISTEN" 2>/dev/null || true
                export OLLAMA_HOST="$LISTEN"
            fi
            if ! pgrep -f 'ollama.*serve' >/dev/null 2>&1 && \
               ! pgrep -x Ollama >/dev/null 2>&1; then
                if [ -d /Applications/Ollama.app ]; then
                    info "$(t service_app)"
                    open -g /Applications/Ollama.app
                elif command -v ollama >/dev/null 2>&1; then
                    info "$(t service_start)"
                    OLLAMA_HOST="$LISTEN" nohup ollama serve >/tmp/ollama-installer.log 2>&1 &
                fi
                sleep 1
            fi
            ;;
    esac

    endpoint="http://$LISTEN"
    i=0
    while [ $i -lt 30 ]; do
        if curl -fsS --max-time 2 "$endpoint/api/version" >/dev/null 2>&1; then
            ver=$(curl -fsS "$endpoint/api/version" | sed 's/.*"version":"\([^"]*\)".*/\1/')
            ok "$(t service_ready "$endpoint" "$ver")"
            return 0
        fi
        i=$((i + 1))
        sleep 1
    done
    die "$(t service_fail)"
}

# ---------------------------------------------------------------------------
# pull_model
# ---------------------------------------------------------------------------
pull_model() {
    step 4 5 "$(t step_pull "$MODEL")"

    if [ "$SKIP_PULL" = "1" ]; then
        ok "$(t pull_skip "$MODEL")"
        return 0
    fi

    if ollama list 2>/dev/null | awk 'NR>1 {print $1}' | grep -qx "$MODEL"; then
        ok "$(t pull_have "$MODEL")"
        return 0
    fi

    info "$(t pull_go)"
    if ! ollama pull "$MODEL"; then
        warn "$(t pull_retry)"
        sleep 1
        ollama pull "$MODEL" || die "$(t pull_fail "$MODEL")"
    fi
    ok "$(t pull_done "$MODEL")"
}

# ---------------------------------------------------------------------------
# openclaw injection
# ---------------------------------------------------------------------------
openclaw_config_json() {
    cat <<'JSON'
{
  "name": "local-gemma4",
  "baseURL": "http://127.0.0.1:11434/v1",
  "apiKey": "ollama",
  "models": [
    {
      "id": "__MODEL_ID__",
      "name": "Gemma (Local)",
      "contextWindow": 131072,
      "supportsVision": true
    }
  ]
}
JSON
}

find_openclaw_config() {
    for p in \
        "${OPENCLAW_CONFIG_DIR:-}/config.json" \
        "$HOME/.openclaw/config.json" \
        "$HOME/Library/Application Support/OpenClaw/config.json" \
        "$HOME/.config/openclaw/config.json"
    do
        [ -n "$p" ] && [ -f "$p" ] && printf '%s' "$p" && return 0
    done
    printf ''
}

inject_openclaw() {
    step 5 5 "$(t step_openclaw)"

    if [ "$SKIP_OPENCLAW" = "1" ]; then
        ok "$(t oc_skip)"
        return 0
    fi

    provider_json=$(openclaw_config_json | sed "s|__MODEL_ID__|$MODEL|")

    cfg=$(find_openclaw_config)
    if [ -z "$cfg" ]; then
        warn "$(t oc_nofile)"
        cache_dir="$HOME/.gemma-installer"
        mkdir -p "$cache_dir"
        printf '%s\n' "$provider_json" > "$cache_dir/openclaw-provider.json"
        info "$(t oc_saved "$cache_dir/openclaw-provider.json")"
        printf '\n%s\n' "$provider_json"
        return 0
    fi

    info "$(t oc_found "$cfg")"
    if command -v python3 >/dev/null 2>&1; then
        BAD_JSON_MSG=$(t oc_bad_json) BAD_ROOT_MSG=$(t oc_bad_root) \
        PROVIDER="$provider_json" TARGET="$cfg" python3 - <<'PY'
import json, os, tempfile, sys
target = os.environ["TARGET"]
provider = json.loads(os.environ["PROVIDER"])
try:
    with open(target, "r", encoding="utf-8") as f:
        data = json.load(f)
except json.JSONDecodeError:
    sys.exit(os.environ.get("BAD_JSON_MSG", "openclaw config is not valid JSON"))

if not isinstance(data, dict):
    sys.exit(os.environ.get("BAD_ROOT_MSG", "openclaw config root is not an object"))

providers = data.get("customProviders")
if not isinstance(providers, list):
    providers = []

filtered = [p for p in providers if not (isinstance(p, dict) and p.get("name") == provider["name"])]
filtered.append(provider)
data["customProviders"] = filtered

fd, tmp = tempfile.mkstemp(prefix=".openclaw-", dir=os.path.dirname(target))
try:
    with os.fdopen(fd, "w", encoding="utf-8") as f:
        json.dump(data, f, indent=2, ensure_ascii=False)
    os.replace(tmp, target)
except Exception:
    os.unlink(tmp)
    raise
PY
        ok "$(t oc_wrote "$cfg")"
    else
        warn "$(t oc_no_py)"
        printf '\n%s\n' "$provider_json"
    fi
}

# ---------------------------------------------------------------------------
# final banner
# ---------------------------------------------------------------------------
done_banner() {
    oc_state=$([ "$SKIP_OPENCLAW" = "1" ] && t done_skipped || t done_configured)
    cat <<DONE

${C_GREEN}${C_BOLD}  ✓ $(t done_title)${C_RESET}

  $(t done_api)    : ${C_BOLD}http://$LISTEN/v1${C_RESET}
  $(t done_model)  : ${C_BOLD}$MODEL${C_RESET}
  $(t done_openclaw)  : $oc_state

  ${C_DIM}$(t done_test)${C_RESET}
  curl http://$LISTEN/v1/chat/completions \\
    -H 'Content-Type: application/json' \\
    -d '{"model":"$MODEL","messages":[{"role":"user","content":"say hi"}]}'

DONE
}

# ---------------------------------------------------------------------------
# run
# ---------------------------------------------------------------------------
print_banner
preflight
select_model
install_ollama
wait_service
pull_model
inject_openclaw
done_banner
