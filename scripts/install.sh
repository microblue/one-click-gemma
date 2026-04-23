#!/usr/bin/env sh
# Gemma one-click installer for Linux + macOS — installs Ollama + Gemma
# and wires a local-gemma4 provider into OpenClaw. Safe to re-run.
#
# Usage:
#   curl -fsSL https://<host>/install.sh | sh
#
# Flags (advanced / CI):
#   --model <tag>     Ollama model tag to pull            (default: gemma4:e2b)
#   --listen <addr>   OLLAMA_HOST value                    (default: 127.0.0.1:11434)
#   --no-openclaw     skip OpenClaw config injection
#   --skip-pull       skip model download (CI smoke tests)
#   --yes             non-interactive, auto-confirm all prompts
#   --help            show this help and exit

set -eu

# ---------------------------------------------------------------------------
# defaults & flag parsing
# ---------------------------------------------------------------------------
MODEL="gemma4:e2b"
LISTEN="127.0.0.1:11434"
SKIP_OPENCLAW="0"
SKIP_PULL="0"
ASSUME_YES="0"
MIN_DISK_GB=10

while [ $# -gt 0 ]; do
    case "$1" in
        --model)        MODEL="$2"; shift 2 ;;
        --model=*)      MODEL="${1#*=}"; shift ;;
        --listen)       LISTEN="$2"; shift 2 ;;
        --listen=*)     LISTEN="${1#*=}"; shift ;;
        --no-openclaw)  SKIP_OPENCLAW="1"; shift ;;
        --skip-pull)    SKIP_PULL="1"; shift ;;
        --yes|-y)       ASSUME_YES="1"; shift ;;
        --help|-h)
            sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'
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
# banner
# ---------------------------------------------------------------------------
print_banner() {
    cat <<BANNER
${C_BOLD}
  ╔══════════════════════════════════════════════════════╗
  ║         Gemma · 一键安装 · for OpenClaw            ║
  ║  Local Gemma behind an OpenAI-compatible API v1     ║
  ╚══════════════════════════════════════════════════════╝
${C_RESET}${C_DIM}  model    : ${C_RESET}$MODEL
${C_DIM}  listen   : ${C_RESET}$LISTEN
${C_DIM}  openclaw : ${C_RESET}$([ "$SKIP_OPENCLAW" = "1" ] && echo skip || echo auto-inject)
BANNER
}

# ---------------------------------------------------------------------------
# preflight
# ---------------------------------------------------------------------------
preflight() {
    step 1 5 "体检 Preflight"

    case "$OS" in
        Linux)
            ok "OS: Linux $(uname -r)"
            ;;
        Darwin)
            ok "OS: macOS $(sw_vers -productVersion 2>/dev/null || uname -r)"
            ;;
        *)
            die "unsupported OS: $OS (仅支持 Linux / macOS, Windows 请用 install.ps1)"
            ;;
    esac

    for cmd in curl awk grep sed; do
        command -v "$cmd" >/dev/null 2>&1 || die "缺少依赖: $cmd"
    done
    ok "依赖齐全 (curl, awk, grep, sed)"

    # zstd only required by Ollama's Linux install.sh; the macOS .app ships self-contained
    if [ "$OS" = "Linux" ] && ! command -v zstd >/dev/null 2>&1; then
        info "Ollama 需要 zstd 来解压安装包, 正在自动安装..."
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
            die "未知包管理器, 请手动安装 zstd 后重跑"
        fi
        command -v zstd >/dev/null 2>&1 || die "zstd 安装失败, 请手动装后重跑"
        ok "zstd 已就绪"
    fi

    # disk check on $HOME (Ollama stores models under ~/.ollama by default)
    avail_kb=$(df -Pk "$HOME" | awk 'NR==2 {print $4}')
    avail_gb=$((avail_kb / 1024 / 1024))
    if [ "$avail_gb" -lt "$MIN_DISK_GB" ]; then
        die "磁盘可用 ${avail_gb}GB, 至少需要 ${MIN_DISK_GB}GB"
    fi
    ok "磁盘可用 ${avail_gb} GB"

    # GPU (informational only; Ollama handles CPU fallback)
    case "$OS" in
        Linux)
            if command -v nvidia-smi >/dev/null 2>&1; then
                gpu=$(nvidia-smi --query-gpu=name,memory.total --format=csv,noheader 2>/dev/null | head -1 || true)
                if [ -n "$gpu" ]; then
                    ok "GPU: $gpu"
                else
                    warn "有 nvidia-smi 但没返回 GPU 信息, 将回退 CPU 推理"
                fi
            elif command -v rocm-smi >/dev/null 2>&1; then
                ok "GPU: AMD ROCm detected"
            else
                warn "未检测到 GPU, 将用 CPU 推理 (速度会很慢, 但能跑)"
            fi
            ;;
        Darwin)
            gpu=$(system_profiler SPDisplaysDataType 2>/dev/null | awk -F': ' '/Chipset Model/{print $2; exit}')
            if [ -n "$gpu" ]; then
                ok "GPU: $gpu"
            else
                warn "未识别显卡, 将用 CPU 推理"
            fi
            ;;
    esac

    # network
    if ! curl -fsS --max-time 5 --head https://ollama.com >/dev/null 2>&1; then
        die "无法连接 ollama.com, 请检查网络"
    fi
    ok "网络可达"
}

# ---------------------------------------------------------------------------
# install Ollama — Linux: curl|sh, macOS: brew or DMG
# ---------------------------------------------------------------------------
install_ollama() {
    step 2 5 "安装 Ollama 运行时"

    if command -v ollama >/dev/null 2>&1; then
        ver=$(ollama --version 2>/dev/null | awk '{print $NF}' || echo unknown)
        ok "Ollama 已安装 (version $ver), 跳过"
        return 0
    fi

    case "$OS" in
        Linux)
            info "从 ollama.com 下载官方安装脚本..."
            if [ "$ASSUME_YES" != "1" ]; then
                confirm "即将执行 Ollama 官方 install.sh, 会用 sudo 装 systemd 服务, 继续?" || die "用户取消"
            fi
            curl -fsSL https://ollama.com/install.sh | sh
            ;;
        Darwin)
            if command -v brew >/dev/null 2>&1; then
                info "用 brew install ollama..."
                if [ "$ASSUME_YES" != "1" ]; then
                    confirm "即将运行 'brew install ollama', 继续?" || die "用户取消"
                fi
                brew install ollama
            else
                info "未检测到 brew, 下载 Ollama.dmg..."
                if [ "$ASSUME_YES" != "1" ]; then
                    confirm "将从 ollama.com 下载 Ollama.dmg 并拷贝到 /Applications, 继续?" || die "用户取消"
                fi
                dmg="$(mktemp -d)/Ollama.dmg"
                curl -fsSL -o "$dmg" https://ollama.com/download/Ollama.dmg
                mount=$(hdiutil attach "$dmg" -nobrowse -readonly | awk '{print $NF}' | tail -1)
                [ -n "$mount" ] || die "hdiutil attach 失败"
                [ -d /Applications/Ollama.app ] && rm -rf /Applications/Ollama.app
                cp -R "$mount/Ollama.app" /Applications/
                hdiutil detach "$mount" >/dev/null
                rm -f "$dmg"
            fi
            ;;
    esac
    ok "Ollama 已安装"
}

# ---------------------------------------------------------------------------
# wait until /api/version responds — branches on OS for service startup
# ---------------------------------------------------------------------------
wait_service() {
    step 3 5 "启动 Ollama 服务"

    case "$OS" in
        Linux)
            # reconfigure listen via systemd drop-in if not default
            if [ "$LISTEN" != "127.0.0.1:11434" ] && command -v systemctl >/dev/null 2>&1; then
                info "配置 OLLAMA_HOST=$LISTEN (systemd drop-in)"
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
                    info "无 systemd, 在后台启动 'ollama serve'"
                    OLLAMA_HOST="$LISTEN" nohup ollama serve >/tmp/ollama-installer.log 2>&1 &
                    sleep 1
                fi
            fi
            ;;
        Darwin)
            # macOS: brew install doesn't auto-start; the DMG app starts a tray menu.
            # Either way, making sure `ollama serve` is running is the simplest
            # cross-path approach. If someone already runs the tray app, that also
            # binds to :11434 so our probe will find it immediately.
            if [ "$LISTEN" != "127.0.0.1:11434" ]; then
                launchctl setenv OLLAMA_HOST "$LISTEN" 2>/dev/null || true
                export OLLAMA_HOST="$LISTEN"
            fi
            if ! pgrep -f 'ollama.*serve' >/dev/null 2>&1 && \
               ! pgrep -x Ollama >/dev/null 2>&1; then
                if [ -d /Applications/Ollama.app ]; then
                    info "启动 Ollama.app..."
                    open -g /Applications/Ollama.app
                elif command -v ollama >/dev/null 2>&1; then
                    info "在后台启动 'ollama serve'..."
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
            ok "Ollama 服务就绪 ($endpoint, version $ver)"
            return 0
        fi
        i=$((i + 1))
        sleep 1
    done
    die "Ollama 服务 30s 内未就绪, 请手动检查 (Linux: systemctl status ollama; macOS: 查看 Ollama.app)"
}

# ---------------------------------------------------------------------------
# pull model
# ---------------------------------------------------------------------------
pull_model() {
    step 4 5 "拉取模型 $MODEL"

    if [ "$SKIP_PULL" = "1" ]; then
        ok "--skip-pull 已设置, 跳过下载 (用 'ollama pull $MODEL' 手动补上)"
        return 0
    fi

    if ollama list 2>/dev/null | awk 'NR>1 {print $1}' | grep -qx "$MODEL"; then
        ok "$MODEL 已存在, 跳过"
        return 0
    fi

    info "开始下载, 进度取决于你的网速..."
    if ! ollama pull "$MODEL"; then
        warn "首次 pull 失败, 1s 后重试"
        sleep 1
        ollama pull "$MODEL" || die "pull $MODEL 失败, 请检查磁盘和网络"
    fi
    ok "模型 $MODEL 已就位"
}

# ---------------------------------------------------------------------------
# openclaw config injection
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
    step 5 5 "接入 OpenClaw"

    if [ "$SKIP_OPENCLAW" = "1" ]; then
        ok "用户要求跳过 OpenClaw 配置"
        return 0
    fi

    provider_json=$(openclaw_config_json | sed "s|__MODEL_ID__|$MODEL|")

    cfg=$(find_openclaw_config)
    if [ -z "$cfg" ]; then
        warn "未检测到 OpenClaw 配置, 在下面打印 provider, 请粘贴到 OpenClaw 设置里"
        cache_dir="$HOME/.gemma-installer"
        mkdir -p "$cache_dir"
        printf '%s\n' "$provider_json" > "$cache_dir/openclaw-provider.json"
        info "(同时已保存到 $cache_dir/openclaw-provider.json)"
        printf '\n%s\n' "$provider_json"
        return 0
    fi

    info "发现 OpenClaw 配置: $cfg"
    if command -v python3 >/dev/null 2>&1; then
        PROVIDER="$provider_json" TARGET="$cfg" python3 - <<'PY'
import json, os, tempfile, sys
target = os.environ["TARGET"]
provider = json.loads(os.environ["PROVIDER"])
try:
    with open(target, "r", encoding="utf-8") as f:
        data = json.load(f)
except json.JSONDecodeError:
    sys.exit("openclaw config is not valid JSON — refuse to touch it")

if not isinstance(data, dict):
    sys.exit("openclaw config root is not an object")

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
        ok "已把 local-gemma4 provider 写入 $cfg"
    else
        warn "未找到 python3, 跳过自动注入, 下面打印 provider 手动粘贴:"
        printf '\n%s\n' "$provider_json"
    fi
}

# ---------------------------------------------------------------------------
# final banner
# ---------------------------------------------------------------------------
done_banner() {
    cat <<DONE

${C_GREEN}${C_BOLD}  ✓ 全部就绪${C_RESET}

  本地 API   : ${C_BOLD}http://$LISTEN/v1${C_RESET}
  模型       : ${C_BOLD}$MODEL${C_RESET}
  OpenClaw   : $([ "$SKIP_OPENCLAW" = "1" ] && echo 已跳过 || echo 已自动配置 / 配置已打印)

  ${C_DIM}发个测试消息:${C_RESET}
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
install_ollama
wait_service
pull_model
inject_openclaw
done_banner
