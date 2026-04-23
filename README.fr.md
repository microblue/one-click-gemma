# Gemma · Installateur en un clic

**[English](README.md) · [简体中文](README.zh-CN.md) · [繁體中文](README.zh-TW.md) · [日本語](README.ja.md) · [한국어](README.ko.md) · [Español](README.es.md) · [Français](README.fr.md) · [Deutsch](README.de.md)**

Exécutez Google Gemma localement pour [OpenClaw](https://github.com/openclaw/openclaw), derrière une API compatible OpenAI. Double-clic pour installer sur macOS / Windows ; script d'une ligne sur Linux.

---

## Téléchargement

| Plateforme | Installation |
|---|---|
| macOS 14+ | Double-cliquez sur le [DMG](https://github.com/microblue/one-click-gemma/releases/latest/download/GemmaInstaller.dmg) → faites-le glisser dans Applications → ouvrez. Ou script : `curl -fsSL https://gemma.myclaw.one/install.sh \| sh` |
| Windows 10+ | Double-cliquez sur l'[EXE](https://github.com/microblue/one-click-gemma/releases/latest/download/GemmaInstaller-setup.exe), suivez l'assistant. Ou PowerShell : `irm https://gemma.myclaw.one/install.ps1 \| iex` |
| Linux | `curl -fsSL https://gemma.myclaw.one/install.sh \| sh` |

macOS et Windows disposent de deux canaux : installateur GUI natif (pour tout le monde) + script en une ligne (pour utilisateurs avancés). Linux n'a que le script — même modèle de distribution qu'Ollama.

Les trois chemins : installer Ollama → télécharger le modèle par défaut `gemma4:e2b` (7,2 Go) → écrire le provider `local-gemma4` dans la configuration OpenClaw → exposer `http://127.0.0.1:11434/v1`. Vous pouvez choisir un modèle plus petit à l'installation (de `gemma3:270m` 292 Mo à `gemma4:e2b`).

## Vérifier

```bash
curl http://127.0.0.1:11434/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"model":"gemma4:e2b","messages":[{"role":"user","content":"say hi"}]}'
```

## Flags du script (avancé / CI)

```bash
curl -fsSL https://gemma.myclaw.one/install.sh | sh -s -- [flags]

  --model <tag>      Tag du modèle Ollama        (défaut : gemma4:e2b)
  --listen <addr>    OLLAMA_HOST                 (défaut : 127.0.0.1:11434)
  --no-openclaw      ignorer l'injection OpenClaw
  --skip-pull        ignorer le téléchargement du modèle
  --yes              non interactif
  --help             aide
```

Windows PowerShell : définissez `$env:GEMMA_MODEL` / `GEMMA_LISTEN` / `GEMMA_NO_OPENCLAW` / `GEMMA_SKIP_PULL` / `GEMMA_YES` avant `irm … | iex`.

## Compilation depuis les sources

### Prérequis

- Rust 1.80+ (`rustup default stable`)
- macOS : Xcode Command Line Tools
- Windows : MSVC Build Tools
- Linux (pour `cargo test` uniquement — pas de GUI Linux construite) : `libwebkit2gtk-4.1-dev libssl-dev libayatana-appindicator3-dev librsvg2-dev libsoup-3.0-dev libjavascriptcoregtk-4.1-dev`

### Compiler

```bash
cd app
cargo tauri build

# sorties
# macOS:   target/release/bundle/dmg/GemmaInstaller.dmg
# Windows: target/release/bundle/nsis/GemmaInstaller-setup.exe
# (pas de GUI sur Linux ; utilisez scripts/install.sh)
```

### Structure

```
.
├── app/                  Installateur GUI Tauri (macOS + Windows uniquement)
│   ├── src-tauri/        backend Rust
│   └── src/              frontend (HTML/JS/CSS pur)
├── scripts/              install.sh (Linux + macOS) + install.ps1 (Windows)
├── tests/                tests unitaires + intégration
├── website/              site de téléchargement (https://gemma.myclaw.one/)
├── openclaw/             modèle de provider OpenClaw
└── .github/workflows/    pipeline CI + release
```

### Exécuter les tests

```bash
# Tests de comportement d'install.sh (parsing des flags, branches d'erreur, valeurs par défaut)
bash tests/install_sh_test.sh

# Tests unitaires Rust pour l'injection du provider OpenClaw
cd app/src-tauri && cargo test
```

Le CI (`.github/workflows/release.yml`) exécute les deux suites comme porte d'entrée, plus un smoke E2E réel sur chaque plateforme : Ubuntu docker télécharge le petit modèle `gemma3:270m`, vérifie que `/v1/chat/completions` renvoie du texte non vide et valide l'upsert OpenClaw. Les runners macOS / Windows exécutent `install.sh` / `install.ps1` avec les mêmes assertions, plus l'installation silencieuse du GUI + lancement + capture d'écran.

## Licence

Apache License 2.0 — voir [LICENSE](./LICENSE). Ollama et les poids du modèle Gemma installés par cet outil suivent leurs licences upstream respectives.
