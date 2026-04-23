# Gemma 4 一键安装 · Gemma 4 One-Click Installer

为 [OpenClaw](https://github.com/openclaw/openclaw) 在本机跑起 Google Gemma 4，暴露 OpenAI 兼容 API。双击安装、零命令行（macOS / Windows），Linux 一行脚本。

Get Google Gemma 4 running locally for [OpenClaw](https://github.com/openclaw/openclaw), exposing an OpenAI-compatible API. Double-click to install on macOS / Windows; one-line script on Linux.

---

## 下载 · Download

| 平台 Platform | 下载 Download | 运行 Run |
|---|---|---|
| macOS 14+ | `GemmaInstaller-1.0.0-universal.dmg` 或脚本 | 双击 DMG→拖进 Applications→打开, 或 `curl -fsSL https://<host>/install.sh \| sh` |
| Windows 10+ | `GemmaInstaller-1.0.0-x64-setup.exe` 或脚本 | 双击 EXE 走向导, 或 PowerShell: `irm https://<host>/install.ps1 \| iex` |
| Linux | 脚本 | `curl -fsSL https://<host>/install.sh \| sh` |

Mac/Win 两条通道：原生 GUI 安装包（给非技术用户）+ 一行脚本（给极客）。Linux 只有脚本通道（同 Ollama 做法）。

三端都会：装 Ollama → 拉默认 `gemma4:e2b`（7.2 GB）→ 自动把 `local-gemma4` provider 写进 OpenClaw → 打开 `http://127.0.0.1:11434/v1` 即用。模型可在安装时选（270m 到 7.2GB）。

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
# (Linux 不构建 GUI; 只走 scripts/install.sh 脚本)
```

### 布局

```
.
├── app/                  Tauri 图形安装器
│   ├── src-tauri/        Rust 后端
│   └── src/              前端（纯 HTML/JS/CSS）
├── scripts/                install.sh (Linux + macOS) + install.ps1 (Windows)
├── tests/                单元与集成测试
├── website/              下载站静态页
├── openclaw/             OpenClaw provider 模板
└── .github/workflows/    CI 发布流水线
```

### 跑测试

```bash
# install.sh 的行为测试 (flag 解析, 错误分支, 默认值)
bash tests/install_sh_test.sh

# OpenClaw provider 注入的 Rust 单元测试
cd app/src-tauri && cargo test
```

CI（`.github/workflows/release.yml`）把这两组测试作为前置门禁，通过后才跑 20 分钟的 Tauri 三端构建。

## 许可证

Apache License 2.0. 见 [LICENSE](./LICENSE)。
本工具所安装的 Ollama、Gemma 4 权重各自沿用其上游许可证。
