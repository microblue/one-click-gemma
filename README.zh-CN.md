# Gemma · 一键安装

**[English](README.md) · [简体中文](README.zh-CN.md) · [繁體中文](README.zh-TW.md) · [日本語](README.ja.md) · [한국어](README.ko.md) · [Español](README.es.md) · [Français](README.fr.md) · [Deutsch](README.de.md)**

为 [OpenClaw](https://github.com/openclaw/openclaw) 在本机跑起 Google Gemma，暴露 OpenAI 兼容 API。macOS / Windows 双击即装，Linux 一行脚本。

---

## 下载

| 平台 | 安装方式 |
|---|---|
| macOS 14+ | 双击 [DMG](https://github.com/microblue/one-click-gemma/releases/latest/download/GemmaInstaller.dmg) → 拖进 Applications → 打开。或脚本：`curl -fsSL https://gemma.myclaw.one/install.sh \| sh` |
| Windows 10+ | 双击 [EXE](https://github.com/microblue/one-click-gemma/releases/latest/download/GemmaInstaller-setup.exe) 跟着向导走。或 PowerShell：`irm https://gemma.myclaw.one/install.ps1 \| iex` |
| Linux | `curl -fsSL https://gemma.myclaw.one/install.sh \| sh` |

Mac/Win 两条通道：原生 GUI 安装包（给非技术用户）+ 一行脚本（给极客）。Linux 只走脚本——同 Ollama 的做法。

三端都会：装 Ollama → 拉默认 `gemma4:e2b`（7.2 GB）→ 把 `local-gemma4` provider 写进 OpenClaw 配置 → `http://127.0.0.1:11434/v1` 对外暴露。模型可在安装时选（最小 `gemma3:270m` 292 MB，最大 `gemma4:e2b`）。

## 验证

```bash
curl http://127.0.0.1:11434/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"model":"gemma4:e2b","messages":[{"role":"user","content":"say hi"}]}'
```

## 脚本参数（高级 / CI）

```bash
curl -fsSL https://gemma.myclaw.one/install.sh | sh -s -- [flags]

  --model <tag>      Ollama 模型 tag            (默认: gemma4:e2b)
  --listen <addr>    OLLAMA_HOST                 (默认: 127.0.0.1:11434)
  --no-openclaw      跳过 OpenClaw 注入
  --skip-pull        跳过模型下载
  --yes              非交互
  --help             帮助
```

Windows PowerShell：`irm … | iex` 之前 set `$env:GEMMA_MODEL` / `GEMMA_LISTEN` / `GEMMA_NO_OPENCLAW` / `GEMMA_SKIP_PULL` / `GEMMA_YES`。

## 从源码构建

### 准备

- Rust 1.80+（`rustup default stable`）
- macOS：Xcode Command Line Tools
- Windows：MSVC Build Tools
- Linux（仅用于 `cargo test`，不构建 Linux GUI）：`libwebkit2gtk-4.1-dev libssl-dev libayatana-appindicator3-dev librsvg2-dev libsoup-3.0-dev libjavascriptcoregtk-4.1-dev`

### 构建

```bash
cd app
cargo tauri build

# 产物
# macOS:   target/release/bundle/dmg/GemmaInstaller.dmg
# Windows: target/release/bundle/nsis/GemmaInstaller-setup.exe
# (Linux 不构建 GUI, 用 scripts/install.sh)
```

### 布局

```
.
├── app/                  Tauri 图形安装器（仅 macOS + Windows）
│   ├── src-tauri/        Rust 后端
│   └── src/              前端（纯 HTML/JS/CSS）
├── scripts/              install.sh (Linux + macOS) + install.ps1 (Windows)
├── tests/                单元 + 集成测试
├── website/              下载站 (https://gemma.myclaw.one/)
├── openclaw/             OpenClaw provider 模板
└── .github/workflows/    CI + 发布流水线
```

### 跑测试

```bash
# install.sh 行为测试（flag 解析、错误分支、默认值）
bash tests/install_sh_test.sh

# OpenClaw provider 注入的 Rust 单元测试
cd app/src-tauri && cargo test
```

CI（`.github/workflows/release.yml`）把这两组测试作为前置门禁，并在三端跑真端到端冒烟：Ubuntu docker 拉 `gemma3:270m` 小模型、断言 `/v1/chat/completions` 返回非空文本、校验 OpenClaw upsert；macOS / Windows runner 用 `install.sh` / `install.ps1` 跑同样的断言，外加 GUI 安装器的静默装 + 启动 + 截屏。

## 许可证

Apache License 2.0 — 见 [LICENSE](./LICENSE)。本工具安装的 Ollama 与 Gemma 模型权重各自沿用其上游许可证。
