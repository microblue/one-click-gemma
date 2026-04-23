# Gemma · ワンクリックインストーラ

**[English](README.md) · [简体中文](README.zh-CN.md) · [繁體中文](README.zh-TW.md) · [日本語](README.ja.md) · [한국어](README.ko.md) · [Español](README.es.md) · [Français](README.fr.md) · [Deutsch](README.de.md)**

[OpenClaw](https://github.com/openclaw/openclaw) のために Google Gemma をローカルで起動し、OpenAI 互換 API を公開します。macOS / Windows はダブルクリックでインストール、Linux はワンライナースクリプトです。

---

## ダウンロード

| プラットフォーム | インストール方法 |
|---|---|
| macOS 14+ | [DMG](https://github.com/microblue/one-click-gemma/releases/latest/download/GemmaInstaller.dmg) をダブルクリック → Applications へドラッグ → 開く。またはスクリプト:`curl -fsSL https://gemma.myclaw.one/install.sh \| sh` |
| Windows 10+ | [EXE](https://github.com/microblue/one-click-gemma/releases/latest/download/GemmaInstaller-setup.exe) をダブルクリックしてウィザードに従う。または PowerShell:`irm https://gemma.myclaw.one/install.ps1 \| iex` |
| Linux | `curl -fsSL https://gemma.myclaw.one/install.sh \| sh` |

macOS と Windows には 2 つのチャンネルがあります:ネイティブ GUI インストーラ(一般ユーザー向け)とワンライナースクリプト(パワーユーザー向け)。Linux はスクリプトのみ —— Ollama と同じ配布モデルです。

3 プラットフォーム共通:Ollama をインストール → デフォルト `gemma4:e2b`(7.2 GB)を pull → `local-gemma4` provider を OpenClaw の設定に書き込み → `http://127.0.0.1:11434/v1` を公開。モデルはインストール時に選択可能(最小 `gemma3:270m` 292 MB、最大 `gemma4:e2b`)。

## 動作確認

```bash
curl http://127.0.0.1:11434/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"model":"gemma4:e2b","messages":[{"role":"user","content":"say hi"}]}'
```

## スクリプトフラグ(上級 / CI)

```bash
curl -fsSL https://gemma.myclaw.one/install.sh | sh -s -- [flags]

  --model <tag>      Ollama モデル tag          (既定: gemma4:e2b)
  --listen <addr>    OLLAMA_HOST                 (既定: 127.0.0.1:11434)
  --no-openclaw      OpenClaw 注入をスキップ
  --skip-pull        モデルダウンロードをスキップ
  --yes              非対話型
  --help             ヘルプ表示
```

Windows PowerShell:`irm … | iex` の前に `$env:GEMMA_MODEL` / `GEMMA_LISTEN` / `GEMMA_NO_OPENCLAW` / `GEMMA_SKIP_PULL` / `GEMMA_YES` を設定します。

## ソースからのビルド

### 事前準備

- Rust 1.80+ (`rustup default stable`)
- macOS:Xcode Command Line Tools
- Windows:MSVC Build Tools
- Linux(`cargo test` のみ、Linux GUI はビルドしません):`libwebkit2gtk-4.1-dev libssl-dev libayatana-appindicator3-dev librsvg2-dev libsoup-3.0-dev libjavascriptcoregtk-4.1-dev`

### ビルド

```bash
cd app
cargo tauri build

# 出力先
# macOS:   target/release/bundle/dmg/GemmaInstaller.dmg
# Windows: target/release/bundle/nsis/GemmaInstaller-setup.exe
# (Linux は GUI を作らず、scripts/install.sh を使用)
```

### レイアウト

```
.
├── app/                  Tauri GUI インストーラ(macOS + Windows のみ)
│   ├── src-tauri/        Rust バックエンド
│   └── src/              フロントエンド(純粋な HTML/JS/CSS)
├── scripts/              install.sh (Linux + macOS) + install.ps1 (Windows)
├── tests/                ユニット + 統合テスト
├── website/              ダウンロードサイト (https://gemma.myclaw.one/)
├── openclaw/             OpenClaw provider テンプレート
└── .github/workflows/    CI + リリースパイプライン
```

### テスト実行

```bash
# install.sh の挙動テスト(フラグ解析、エラー分岐、既定値)
bash tests/install_sh_test.sh

# OpenClaw provider 注入の Rust ユニットテスト
cd app/src-tauri && cargo test
```

CI(`.github/workflows/release.yml`)はこれら 2 つのテストをゲートとして実行し、さらに 3 プラットフォームで実 E2E スモークを実施:Ubuntu docker が `gemma3:270m` を pull し `/v1/chat/completions` が非空テキストを返すことを検証、OpenClaw upsert も検証。macOS / Windows runner は `install.sh` / `install.ps1` で同じ検証 + GUI インストーラのサイレントインストール + 起動 + スクリーンショット。

## ライセンス

Apache License 2.0 — [LICENSE](./LICENSE) を参照。本ツールがインストールする Ollama および Gemma モデルの重みは、それぞれの上流ライセンスに従います。
