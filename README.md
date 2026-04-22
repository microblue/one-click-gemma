# Gemma 4 一键安装 · Gemma 4 One-Click Installer

为 [OpenClaw](https://github.com/openclaw/openclaw) 在本机跑起 Google Gemma 4，暴露 OpenAI 兼容 API。双击安装、零命令行（macOS / Windows），Linux 一行脚本。

Get Google Gemma 4 running locally for [OpenClaw](https://github.com/openclaw/openclaw), exposing an OpenAI-compatible API. Double-click to install on macOS / Windows; one-line script on Linux.

---

## 下载 · Download

| 平台 Platform | 下载 Download | 运行 Run |
|---|---|---|
| macOS 14+ | `GemmaInstaller-1.0.0-universal.dmg` | 双击 DMG 把图标拖进 Applications，然后打开 |
| Windows 10+ | `GemmaInstaller-1.0.0-x64-setup.exe` | 双击 EXE，跟着向导走 |
| Linux | `install.sh` | `curl -fsSL https://<host>/install.sh \| sh` |

三端都会：装 Ollama → 拉 `gemma4:e4b`（9.6 GB）→ 自动把 `local-gemma4` provider 写进 OpenClaw → 打开 `http://127.0.0.1:11434/v1` 即用。

## Linux 命令行参数

```bash
curl -fsSL https://<host>/install.sh | sh -s -- [flags]

  --model <tag>      模型 tag, 默认 gemma4:e4b
  --listen <addr>    Ollama 绑定地址, 默认 127.0.0.1:11434
  --no-openclaw      跳过 OpenClaw 配置注入
  --yes              非交互, 全部同意
  --help             打印帮助
```

## 验证安装

```bash
curl http://127.0.0.1:11434/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"model":"gemma4:e4b","messages":[{"role":"user","content":"say hi"}]}'
```

## 开发者：从源码构建

### 准备

- Rust 1.80+（`rustup default stable`）
- Node 20+（用于 Tauri 前端资源发布步骤，可选）
- 对应平台：macOS 需要 Xcode CLT；Windows 需要 MSVC Build Tools；Linux 需要 `libwebkit2gtk-4.1-dev` `libssl-dev` `libayatana-appindicator3-dev` `librsvg2-dev`

### 构建

```bash
# 一次构建当前平台的产物
cd app
cargo tauri build

# 产物位置
# macOS:   target/release/bundle/dmg/GemmaInstaller_1.0.0_universal.dmg
# Windows: target/release/bundle/nsis/GemmaInstaller_1.0.0_x64-setup.exe
# Linux:   target/release/bundle/appimage/gemma-installer_1.0.0_amd64.AppImage
#          target/release/bundle/deb/gemma-installer_1.0.0_amd64.deb
```

### 布局

```
.
├── app/                  Tauri 图形安装器
│   ├── src-tauri/        Rust 后端
│   └── src/              前端（纯 HTML/JS/CSS）
├── linux/install.sh      Linux 极客通道脚本
├── website/              下载站静态页
├── openclaw/             OpenClaw provider 模板
└── .github/workflows/    CI 发布流水线
```

## 许可证

Apache License 2.0. 见 [LICENSE](./LICENSE)。
本工具所安装的 Ollama、Gemma 4 权重各自沿用其上游许可证。
