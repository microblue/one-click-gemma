# Gemma · Ein-Klick-Installer

**[English](README.md) · [简体中文](README.zh-CN.md) · [繁體中文](README.zh-TW.md) · [日本語](README.ja.md) · [한국어](README.ko.md) · [Español](README.es.md) · [Français](README.fr.md) · [Deutsch](README.de.md)**

Google Gemma lokal für [OpenClaw](https://github.com/openclaw/openclaw) betreiben, hinter einer OpenAI-kompatiblen API. Doppelklick-Installation auf macOS / Windows; einzeiliges Skript auf Linux.

---

## Download

| Plattform | Installation |
|---|---|
| macOS 14+ | [DMG](https://github.com/microblue/one-click-gemma/releases/latest/download/GemmaInstaller.dmg) doppelt anklicken → ins Verzeichnis Applications ziehen → öffnen. Oder Skript: `curl -fsSL https://gemma.myclaw.one/install.sh \| sh` |
| Windows 10+ | [EXE](https://github.com/microblue/one-click-gemma/releases/latest/download/GemmaInstaller-setup.exe) doppelt anklicken, Assistent folgen. Oder PowerShell: `irm https://gemma.myclaw.one/install.ps1 \| iex` |
| Linux | `curl -fsSL https://gemma.myclaw.one/install.sh \| sh` |

macOS und Windows haben zwei Kanäle: nativer GUI-Installer (für alle) + einzeiliges Skript (für Power-User). Linux hat nur das Skript — gleiches Distributionsmodell wie Ollama.

Alle drei Wege: Ollama installieren → Standardmodell `gemma4:e2b` (7,2 GB) herunterladen → `local-gemma4`-Provider in die OpenClaw-Konfiguration schreiben → `http://127.0.0.1:11434/v1` bereitstellen. Beim Installieren kann ein kleineres Modell gewählt werden (von `gemma3:270m` mit 292 MB bis `gemma4:e2b`).

## Überprüfen

```bash
curl http://127.0.0.1:11434/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"model":"gemma4:e2b","messages":[{"role":"user","content":"say hi"}]}'
```

## Skript-Flags (fortgeschritten / CI)

```bash
curl -fsSL https://gemma.myclaw.one/install.sh | sh -s -- [flags]

  --model <tag>      Ollama-Modell-Tag          (Standard: gemma4:e2b)
  --listen <addr>    OLLAMA_HOST                 (Standard: 127.0.0.1:11434)
  --no-openclaw      OpenClaw-Injection überspringen
  --skip-pull        Modell-Download überspringen
  --yes              nicht interaktiv
  --help             Hilfe
```

Windows PowerShell: Setze `$env:GEMMA_MODEL` / `GEMMA_LISTEN` / `GEMMA_NO_OPENCLAW` / `GEMMA_SKIP_PULL` / `GEMMA_YES` vor `irm … | iex`.

## Aus Quelltext bauen

### Voraussetzungen

- Rust 1.80+ (`rustup default stable`)
- macOS: Xcode Command Line Tools
- Windows: MSVC Build Tools
- Linux (nur für `cargo test` — keine Linux-GUI wird gebaut): `libwebkit2gtk-4.1-dev libssl-dev libayatana-appindicator3-dev librsvg2-dev libsoup-3.0-dev libjavascriptcoregtk-4.1-dev`

### Bauen

```bash
cd app
cargo tauri build

# Ausgaben
# macOS:   target/release/bundle/dmg/GemmaInstaller.dmg
# Windows: target/release/bundle/nsis/GemmaInstaller-setup.exe
# (keine GUI auf Linux; nutze scripts/install.sh)
```

### Struktur

```
.
├── app/                  Tauri GUI-Installer (nur macOS + Windows)
│   ├── src-tauri/        Rust-Backend
│   └── src/              Frontend (reines HTML/JS/CSS)
├── scripts/              install.sh (Linux + macOS) + install.ps1 (Windows)
├── tests/                Unit- + Integrationstests
├── website/              Download-Seite (https://gemma.myclaw.one/)
├── openclaw/             OpenClaw-Provider-Vorlage
└── .github/workflows/    CI- + Release-Pipeline
```

### Tests ausführen

```bash
# install.sh-Verhaltens-Tests (Flag-Parsing, Fehlerzweige, Standardwerte)
bash tests/install_sh_test.sh

# Rust-Unit-Tests für OpenClaw-Provider-Injection
cd app/src-tauri && cargo test
```

CI (`.github/workflows/release.yml`) führt beide Testsuiten als Gate aus, zusätzlich einen echten E2E-Smoke auf jeder Plattform: Ubuntu-Docker lädt das kleine `gemma3:270m`-Modell herunter, prüft dass `/v1/chat/completions` nicht-leeren Text zurückgibt und validiert den OpenClaw-Upsert. macOS- und Windows-Runner führen `install.sh` / `install.ps1` mit denselben Assertions aus, plus stille GUI-Installation + Start + Screenshot.

## Lizenz

Apache License 2.0 — siehe [LICENSE](./LICENSE). Ollama und die von diesem Tool installierten Gemma-Modellgewichte folgen ihren jeweiligen Upstream-Lizenzen.
