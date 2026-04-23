# Gemma · 一鍵安裝

**[English](README.md) · [简体中文](README.zh-CN.md) · [繁體中文](README.zh-TW.md) · [日本語](README.ja.md) · [한국어](README.ko.md) · [Español](README.es.md) · [Français](README.fr.md) · [Deutsch](README.de.md)**

為 [OpenClaw](https://github.com/openclaw/openclaw) 在本機跑起 Google Gemma,暴露 OpenAI 相容 API。macOS / Windows 雙擊即裝,Linux 一行腳本。

---

## 下載

| 平台 | 安裝方式 |
|---|---|
| macOS 14+ | 雙擊 [DMG](https://github.com/microblue/one-click-gemma/releases/latest/download/GemmaInstaller.dmg) → 拖進 Applications → 打開。或腳本:`curl -fsSL https://gemma.myclaw.one/install.sh \| sh` |
| Windows 10+ | 雙擊 [EXE](https://github.com/microblue/one-click-gemma/releases/latest/download/GemmaInstaller-setup.exe) 跟著精靈走。或 PowerShell:`irm https://gemma.myclaw.one/install.ps1 \| iex` |
| Linux | `curl -fsSL https://gemma.myclaw.one/install.sh \| sh` |

Mac/Win 兩條通道:原生 GUI 安裝包(給非技術使用者)+ 一行腳本(給極客)。Linux 只走腳本 —— 同 Ollama 的做法。

三端都會:裝 Ollama → 拉預設 `gemma4:e2b`(7.2 GB)→ 把 `local-gemma4` provider 寫進 OpenClaw 設定 → `http://127.0.0.1:11434/v1` 對外暴露。模型可在安裝時選(最小 `gemma3:270m` 292 MB,最大 `gemma4:e2b`)。

## 驗證

```bash
curl http://127.0.0.1:11434/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"model":"gemma4:e2b","messages":[{"role":"user","content":"say hi"}]}'
```

## 腳本參數(進階 / CI)

```bash
curl -fsSL https://gemma.myclaw.one/install.sh | sh -s -- [flags]

  --model <tag>      Ollama 模型 tag            (預設: gemma4:e2b)
  --listen <addr>    OLLAMA_HOST                 (預設: 127.0.0.1:11434)
  --no-openclaw      跳過 OpenClaw 注入
  --skip-pull        跳過模型下載
  --yes              非互動
  --help             說明
```

Windows PowerShell:在 `irm … | iex` 之前設定 `$env:GEMMA_MODEL` / `GEMMA_LISTEN` / `GEMMA_NO_OPENCLAW` / `GEMMA_SKIP_PULL` / `GEMMA_YES`。

## 從原始碼建置

### 準備

- Rust 1.80+(`rustup default stable`)
- macOS:Xcode Command Line Tools
- Windows:MSVC Build Tools
- Linux(僅用於 `cargo test`,不建置 Linux GUI):`libwebkit2gtk-4.1-dev libssl-dev libayatana-appindicator3-dev librsvg2-dev libsoup-3.0-dev libjavascriptcoregtk-4.1-dev`

### 建置

```bash
cd app
cargo tauri build

# 產物
# macOS:   target/release/bundle/dmg/GemmaInstaller.dmg
# Windows: target/release/bundle/nsis/GemmaInstaller-setup.exe
# (Linux 不建置 GUI, 用 scripts/install.sh)
```

### 結構

```
.
├── app/                  Tauri 圖形安裝器(僅 macOS + Windows)
│   ├── src-tauri/        Rust 後端
│   └── src/              前端(純 HTML/JS/CSS)
├── scripts/              install.sh (Linux + macOS) + install.ps1 (Windows)
├── tests/                單元 + 整合測試
├── website/              下載站 (https://gemma.myclaw.one/)
├── openclaw/             OpenClaw provider 範本
└── .github/workflows/    CI + 發佈流水線
```

### 跑測試

```bash
# install.sh 行為測試(flag 解析、錯誤分支、預設值)
bash tests/install_sh_test.sh

# OpenClaw provider 注入的 Rust 單元測試
cd app/src-tauri && cargo test
```

CI(`.github/workflows/release.yml`)把這兩組測試當作前置檢查,並在三端跑真實端到端冒煙:Ubuntu docker 拉 `gemma3:270m` 小模型、斷言 `/v1/chat/completions` 回傳非空文字、驗證 OpenClaw upsert;macOS / Windows runner 用 `install.sh` / `install.ps1` 跑相同斷言,另加 GUI 安裝器的靜默裝 + 啟動 + 截圖。

## 授權

Apache License 2.0 — 見 [LICENSE](./LICENSE)。本工具安裝的 Ollama 與 Gemma 模型權重各自沿用其上游授權條款。
