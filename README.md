# Gemma · One-click installer

**[English](README.md) · [简体中文](README.zh-CN.md) · [繁體中文](README.zh-TW.md) · [日本語](README.ja.md) · [한국어](README.ko.md) · [Español](README.es.md) · [Français](README.fr.md) · [Deutsch](README.de.md)**

Get Google Gemma running locally for [OpenClaw](https://github.com/openclaw/openclaw), behind an OpenAI-compatible API. Double-click to install on macOS / Windows; one-line script on Linux.

---

## Download

| Platform | How to install |
|---|---|
| macOS 14+ | Double-click the [DMG](https://github.com/microblue/one-click-gemma/releases/latest/download/GemmaInstaller.dmg), drag into Applications, open. Or: `curl -fsSL https://gemma.myclaw.one/install.sh \| sh` |
| Windows 10+ | Double-click the [EXE](https://github.com/microblue/one-click-gemma/releases/latest/download/GemmaInstaller-setup.exe), follow the wizard. Or PowerShell: `irm https://gemma.myclaw.one/install.ps1 \| iex` |
| Linux | `curl -fsSL https://gemma.myclaw.one/install.sh \| sh` |

macOS and Windows each have two channels: a native GUI installer (for everyone) and a one-line script (for power users). Linux is script-only — same distribution model as Ollama.

All three paths: install Ollama → pull the default `gemma4:e2b` (7.2 GB) → write a `local-gemma4` provider into your OpenClaw config → expose `http://127.0.0.1:11434/v1`. You can pick a smaller model at install time (from `gemma3:270m` at 292 MB up to `gemma4:e2b`).

## Verify

```bash
curl http://127.0.0.1:11434/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"model":"gemma4:e2b","messages":[{"role":"user","content":"say hi"}]}'
```

## Script flags (advanced / CI)

```bash
curl -fsSL https://gemma.myclaw.one/install.sh | sh -s -- [flags]

  --model <tag>      Ollama model tag           (default: gemma4:e2b)
  --listen <addr>    OLLAMA_HOST                 (default: 127.0.0.1:11434)
  --no-openclaw      skip OpenClaw injection
  --skip-pull        skip model download
  --yes              non-interactive
  --help             show help
```

Windows PowerShell: set `$env:GEMMA_MODEL` / `GEMMA_LISTEN` / `GEMMA_NO_OPENCLAW` / `GEMMA_SKIP_PULL` / `GEMMA_YES` before `irm ... | iex`.

## Building from source

### Prerequisites

- Rust 1.80+ (`rustup default stable`)
- macOS: Xcode Command Line Tools
- Windows: MSVC Build Tools
- Linux (for cargo test only — no Linux GUI is built): `libwebkit2gtk-4.1-dev libssl-dev libayatana-appindicator3-dev librsvg2-dev libsoup-3.0-dev libjavascriptcoregtk-4.1-dev`

### Build

```bash
cd app
cargo tauri build

# outputs
# macOS:   target/release/bundle/dmg/GemmaInstaller.dmg
# Windows: target/release/bundle/nsis/GemmaInstaller-setup.exe
# (no GUI on Linux; use scripts/install.sh)
```

### Layout

```
.
├── app/                  Tauri GUI installer (macOS + Windows only)
│   ├── src-tauri/        Rust backend
│   └── src/              frontend (plain HTML/JS/CSS)
├── scripts/              install.sh (Linux + macOS) + install.ps1 (Windows)
├── tests/                unit + integration tests
├── website/              download site (https://gemma.myclaw.one/)
├── openclaw/             OpenClaw provider template
└── .github/workflows/    CI + release pipeline
```

### Tests

```bash
# install.sh behaviour (flag parsing, error branches, defaults)
bash tests/install_sh_test.sh

# Rust unit tests for OpenClaw provider injection
cd app/src-tauri && cargo test
```

CI (`.github/workflows/release.yml`) runs both test suites as a gate, plus a real end-to-end smoke on every platform: Ubuntu Docker pulls the tiny `gemma3:270m`, asserts `/v1/chat/completions` returns non-empty text, and validates the OpenClaw upsert. macOS and Windows runners do the same via `install.sh` / `install.ps1`, in addition to the GUI installer smoke (install silently, launch, screenshot).

## License

Apache License 2.0 — see [LICENSE](./LICENSE). Ollama and the Gemma model weights installed by this tool follow their respective upstream licenses.
