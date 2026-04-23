# Gemma · Instalador de un clic

**[English](README.md) · [简体中文](README.zh-CN.md) · [繁體中文](README.zh-TW.md) · [日本語](README.ja.md) · [한국어](README.ko.md) · [Español](README.es.md) · [Français](README.fr.md) · [Deutsch](README.de.md)**

Ejecuta Google Gemma localmente para [OpenClaw](https://github.com/openclaw/openclaw), detrás de una API compatible con OpenAI. Doble clic para instalar en macOS / Windows; una línea de script en Linux.

---

## Descarga

| Plataforma | Instalación |
|---|---|
| macOS 14+ | Doble clic en [DMG](https://github.com/microblue/one-click-gemma/releases/latest/download/GemmaInstaller.dmg) → arrastra a Aplicaciones → abre. O script: `curl -fsSL https://gemma.myclaw.one/install.sh \| sh` |
| Windows 10+ | Doble clic en [EXE](https://github.com/microblue/one-click-gemma/releases/latest/download/GemmaInstaller-setup.exe), sigue el asistente. O PowerShell: `irm https://gemma.myclaw.one/install.ps1 \| iex` |
| Linux | `curl -fsSL https://gemma.myclaw.one/install.sh \| sh` |

macOS y Windows ofrecen dos canales: instalador GUI nativo (para todos) + script de una línea (para usuarios avanzados). Linux solo usa script — mismo modelo de distribución que Ollama.

Los tres caminos: instalar Ollama → descargar el modelo por defecto `gemma4:e2b` (7,2 GB) → escribir el provider `local-gemma4` en la configuración de OpenClaw → exponer `http://127.0.0.1:11434/v1`. Puedes elegir un modelo más pequeño durante la instalación (desde `gemma3:270m` con 292 MB hasta `gemma4:e2b`).

## Verificar

```bash
curl http://127.0.0.1:11434/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"model":"gemma4:e2b","messages":[{"role":"user","content":"say hi"}]}'
```

## Flags del script (avanzado / CI)

```bash
curl -fsSL https://gemma.myclaw.one/install.sh | sh -s -- [flags]

  --model <tag>      Tag del modelo de Ollama    (por defecto: gemma4:e2b)
  --listen <addr>    OLLAMA_HOST                 (por defecto: 127.0.0.1:11434)
  --no-openclaw      omitir inyección en OpenClaw
  --skip-pull        omitir descarga del modelo
  --yes              no interactivo
  --help             ayuda
```

Windows PowerShell: establece `$env:GEMMA_MODEL` / `GEMMA_LISTEN` / `GEMMA_NO_OPENCLAW` / `GEMMA_SKIP_PULL` / `GEMMA_YES` antes de `irm … | iex`.

## Compilar desde fuente

### Requisitos previos

- Rust 1.80+ (`rustup default stable`)
- macOS: Xcode Command Line Tools
- Windows: MSVC Build Tools
- Linux (solo para `cargo test` — no se construye GUI en Linux): `libwebkit2gtk-4.1-dev libssl-dev libayatana-appindicator3-dev librsvg2-dev libsoup-3.0-dev libjavascriptcoregtk-4.1-dev`

### Compilar

```bash
cd app
cargo tauri build

# salidas
# macOS:   target/release/bundle/dmg/GemmaInstaller.dmg
# Windows: target/release/bundle/nsis/GemmaInstaller-setup.exe
# (sin GUI en Linux; usa scripts/install.sh)
```

### Estructura

```
.
├── app/                  Instalador GUI Tauri (solo macOS + Windows)
│   ├── src-tauri/        backend en Rust
│   └── src/              frontend (HTML/JS/CSS puro)
├── scripts/              install.sh (Linux + macOS) + install.ps1 (Windows)
├── tests/                tests unitarios + integración
├── website/              sitio de descargas (https://gemma.myclaw.one/)
├── openclaw/             plantilla de provider OpenClaw
└── .github/workflows/    pipeline CI + release
```

### Ejecutar tests

```bash
# Tests de comportamiento de install.sh (parseo de flags, ramas de error, valores por defecto)
bash tests/install_sh_test.sh

# Tests unitarios Rust para la inyección del provider OpenClaw
cd app/src-tauri && cargo test
```

El CI (`.github/workflows/release.yml`) ejecuta ambos conjuntos de tests como puerta de entrada, más un E2E smoke real en cada plataforma: Ubuntu docker descarga el modelo pequeño `gemma3:270m`, verifica que `/v1/chat/completions` devuelve texto no vacío y valida el upsert de OpenClaw. Los runners macOS / Windows ejecutan `install.sh` / `install.ps1` con las mismas aserciones, más la instalación silenciosa del GUI + lanzamiento + captura de pantalla.

## Licencia

Apache License 2.0 — ver [LICENSE](./LICENSE). Ollama y los pesos del modelo Gemma que instala esta herramienta siguen sus respectivas licencias upstream.
