# Gemma · 원클릭 설치

**[English](README.md) · [简体中文](README.zh-CN.md) · [繁體中文](README.zh-TW.md) · [日本語](README.ja.md) · [한국어](README.ko.md) · [Español](README.es.md) · [Français](README.fr.md) · [Deutsch](README.de.md)**

[OpenClaw](https://github.com/openclaw/openclaw)를 위해 Google Gemma를 로컬에서 실행하고 OpenAI 호환 API를 노출합니다. macOS / Windows는 더블 클릭으로 설치, Linux는 한 줄 스크립트입니다.

---

## 다운로드

| 플랫폼 | 설치 방법 |
|---|---|
| macOS 14+ | [DMG](https://github.com/microblue/one-click-gemma/releases/latest/download/GemmaInstaller.dmg) 더블 클릭 → Applications로 드래그 → 실행. 또는 스크립트: `curl -fsSL https://gemma.myclaw.one/install.sh \| sh` |
| Windows 10+ | [EXE](https://github.com/microblue/one-click-gemma/releases/latest/download/GemmaInstaller-setup.exe) 더블 클릭 후 마법사 진행. 또는 PowerShell: `irm https://gemma.myclaw.one/install.ps1 \| iex` |
| Linux | `curl -fsSL https://gemma.myclaw.one/install.sh \| sh` |

macOS와 Windows는 두 채널이 있습니다: 네이티브 GUI 설치 프로그램(일반 사용자용) + 한 줄 스크립트(파워 유저용). Linux는 스크립트만 제공 —— Ollama의 배포 방식과 동일합니다.

세 플랫폼 모두: Ollama 설치 → 기본 `gemma4:e2b`(7.2 GB) pull → `local-gemma4` provider를 OpenClaw 설정에 주입 → `http://127.0.0.1:11434/v1` 노출. 설치 시 모델 선택 가능 (최소 `gemma3:270m` 292 MB, 최대 `gemma4:e2b`).

## 확인

```bash
curl http://127.0.0.1:11434/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"model":"gemma4:e2b","messages":[{"role":"user","content":"say hi"}]}'
```

## 스크립트 플래그 (고급 / CI)

```bash
curl -fsSL https://gemma.myclaw.one/install.sh | sh -s -- [flags]

  --model <tag>      Ollama 모델 tag            (기본값: gemma4:e2b)
  --listen <addr>    OLLAMA_HOST                 (기본값: 127.0.0.1:11434)
  --no-openclaw      OpenClaw 주입 건너뛰기
  --skip-pull        모델 다운로드 건너뛰기
  --yes              비대화형
  --help             도움말
```

Windows PowerShell: `irm … | iex` 전에 `$env:GEMMA_MODEL` / `GEMMA_LISTEN` / `GEMMA_NO_OPENCLAW` / `GEMMA_SKIP_PULL` / `GEMMA_YES`를 설정하세요.

## 소스에서 빌드

### 사전 준비

- Rust 1.80+ (`rustup default stable`)
- macOS: Xcode Command Line Tools
- Windows: MSVC Build Tools
- Linux (`cargo test`만 사용, Linux GUI는 빌드하지 않음): `libwebkit2gtk-4.1-dev libssl-dev libayatana-appindicator3-dev librsvg2-dev libsoup-3.0-dev libjavascriptcoregtk-4.1-dev`

### 빌드

```bash
cd app
cargo tauri build

# 출력
# macOS:   target/release/bundle/dmg/GemmaInstaller.dmg
# Windows: target/release/bundle/nsis/GemmaInstaller-setup.exe
# (Linux는 GUI 빌드 안 함, scripts/install.sh 사용)
```

### 레이아웃

```
.
├── app/                  Tauri GUI 설치 프로그램 (macOS + Windows만)
│   ├── src-tauri/        Rust 백엔드
│   └── src/              프런트엔드 (순수 HTML/JS/CSS)
├── scripts/              install.sh (Linux + macOS) + install.ps1 (Windows)
├── tests/                유닛 + 통합 테스트
├── website/              다운로드 사이트 (https://gemma.myclaw.one/)
├── openclaw/             OpenClaw provider 템플릿
└── .github/workflows/    CI + 릴리스 파이프라인
```

### 테스트 실행

```bash
# install.sh 동작 테스트 (플래그 파싱, 오류 분기, 기본값)
bash tests/install_sh_test.sh

# OpenClaw provider 주입의 Rust 유닛 테스트
cd app/src-tauri && cargo test
```

CI (`.github/workflows/release.yml`)는 이 두 테스트를 게이트로 실행하고, 세 플랫폼에서 실제 E2E 스모크를 수행합니다: Ubuntu docker가 `gemma3:270m`을 pull하고 `/v1/chat/completions`가 비어있지 않은 텍스트를 반환함을 검증, OpenClaw upsert도 검증. macOS / Windows runner는 `install.sh` / `install.ps1`로 동일한 검증 + GUI 설치 프로그램의 사일런트 설치 + 실행 + 스크린샷.

## 라이선스

Apache License 2.0 — [LICENSE](./LICENSE) 참조. 본 도구가 설치하는 Ollama 및 Gemma 모델 가중치는 각자의 업스트림 라이선스를 따릅니다.
