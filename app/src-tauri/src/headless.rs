//! Headless CLI mode — exercises the same Rust command sequence the GUI
//! invokes via `window.__TAURI__.core.invoke(...)`, but without the WebView.
//!
//! Purpose: CI smoke tests. We can't reliably drive WebView2/WKWebView on
//! GitHub runners, so we exercise the real install → pull → inject → chat
//! pipeline through this binary entrypoint and assert on its exit code.
//!
//! Usage:
//!   gemma-installer --headless --model <id> [--endpoint <url>] \
//!                   [--no-openclaw] [--skip-install] [--prompt <text>]
//!
//! Exit codes:
//!   0  success (install + pull + chat + optional openclaw write all OK)
//!   2  flag parsing / usage error
//!   3  preflight network probe reported unreachable (if --require-network)
//!   10 install_ollama failed
//!   11 wait_ollama timed out
//!   12 pull_model failed
//!   13 inject_openclaw failed
//!   14 send_chat_test returned empty / non-2xx

use crate::progress::{Reporter, StdoutReporter};
use crate::{chat_test, model_pull, ollama_install, ollama_service, openclaw, sysinfo};
use std::io::Write;
use std::sync::Mutex;

#[derive(Debug)]
pub struct Args {
    pub model: String,
    pub endpoint: String,
    pub no_openclaw: bool,
    pub skip_install: bool,
    pub prompt: String,
    pub require_network: bool,
    /// Budget for `wait_ollama` in seconds. CI error-path smoke uses a short
    /// value so the "unreachable endpoint" case fails in seconds, not minutes.
    pub wait_secs: u64,
}

impl Default for Args {
    fn default() -> Self {
        Self {
            model: "gemma3:270m".to_string(),
            endpoint: ollama_service::DEFAULT_ENDPOINT.to_string(),
            no_openclaw: false,
            skip_install: false,
            prompt: "say hi in 3 words".to_string(),
            require_network: false,
            wait_secs: 60,
        }
    }
}

/// Parse CLI flags, excluding the leading `--headless`. Returns `Err` with a
/// human-readable message on malformed input.
pub fn parse_args<I, S>(iter: I) -> Result<Args, String>
where
    I: IntoIterator<Item = S>,
    S: AsRef<str>,
{
    let mut args = Args::default();
    let mut it = iter.into_iter();
    while let Some(raw) = it.next() {
        match raw.as_ref() {
            "--model" => {
                args.model = it
                    .next()
                    .ok_or_else(|| "--model requires a value".to_string())?
                    .as_ref()
                    .to_string();
            }
            "--endpoint" => {
                args.endpoint = it
                    .next()
                    .ok_or_else(|| "--endpoint requires a value".to_string())?
                    .as_ref()
                    .to_string();
            }
            "--prompt" => {
                args.prompt = it
                    .next()
                    .ok_or_else(|| "--prompt requires a value".to_string())?
                    .as_ref()
                    .to_string();
            }
            "--no-openclaw" => args.no_openclaw = true,
            "--skip-install" => args.skip_install = true,
            "--require-network" => args.require_network = true,
            "--wait-secs" => {
                let raw = it
                    .next()
                    .ok_or_else(|| "--wait-secs requires a value".to_string())?;
                args.wait_secs = raw
                    .as_ref()
                    .parse()
                    .map_err(|_| format!("--wait-secs must be a positive integer, got {:?}", raw.as_ref()))?;
            }
            other => return Err(format!("unknown flag: {other}")),
        }
    }
    Ok(args)
}

/// A reporter that tees the StdoutReporter output into an optional log file.
/// The file path is taken from env var `GEMMA_HEADLESS_LOG` so CI can capture
/// progress even when stdout is detached (Windows release builds compiled
/// with `windows_subsystem="windows"`).
struct TeeReporter {
    inner: StdoutReporter,
    file: Mutex<Option<std::fs::File>>,
}

impl TeeReporter {
    fn new() -> Self {
        let file = std::env::var("GEMMA_HEADLESS_LOG")
            .ok()
            .and_then(|p| std::fs::File::create(p).ok());
        Self {
            inner: StdoutReporter,
            file: Mutex::new(file),
        }
    }

    fn log(&self, line: &str) {
        // stdout first (for the human tailing CI logs)
        println!("{line}");
        if let Ok(mut f) = self.file.lock() {
            if let Some(ref mut f) = *f {
                let _ = writeln!(f, "{line}");
                let _ = f.flush();
            }
        }
    }

    fn errlog(&self, line: &str) {
        eprintln!("{line}");
        if let Ok(mut f) = self.file.lock() {
            if let Some(ref mut f) = *f {
                let _ = writeln!(f, "{line}");
                let _ = f.flush();
            }
        }
    }
}

impl Reporter for TeeReporter {
    fn install(&self, stage: &str, message: &str, percent: Option<u8>) {
        self.inner.install(stage, message, percent);
        if let Ok(mut f) = self.file.lock() {
            if let Some(ref mut f) = *f {
                let pct = percent
                    .map(|p| p.to_string())
                    .unwrap_or_else(|| "--".into());
                let _ = writeln!(f, "[install:{stage}] {pct}% {message}");
                let _ = f.flush();
            }
        }
    }
    fn pull(&self, status: &str, completed: u64, total: u64, percent: u8) {
        self.inner.pull(status, completed, total, percent);
        if let Ok(mut f) = self.file.lock() {
            if let Some(ref mut f) = *f {
                let _ = writeln!(
                    f,
                    "[pull] {percent}% {status} ({completed} / {total})"
                );
                let _ = f.flush();
            }
        }
    }
}

/// Runs the full sequence. Returns a CLI exit code.
pub async fn run(args: Args) -> i32 {
    let rep = TeeReporter::new();

    rep.log(&format!(
        "[headless] model={} endpoint={}",
        args.model, args.endpoint
    ));

    // Optional preflight — only exits with code 3 if --require-network was set.
    let pre = sysinfo::run_preflight().await;
    rep.log(&format!(
        "[preflight] os={} ram_gb={} disk_gb={} network_ok={} gpu={:?}",
        pre.os, pre.ram_gb, pre.disk_gb, pre.network_ok, pre.gpu
    ));
    if args.require_network && !pre.network_ok {
        rep.errlog(&format!(
            "[error] --require-network set but network probe failed: {:?}",
            pre.network_error
        ));
        return 3;
    }

    if !args.skip_install {
        rep.log("[1/4] install_ollama");
        if let Err(e) = ollama_install::install_ollama(&rep).await {
            rep.errlog(&format!("[error] install_ollama: {e:#}"));
            return 10;
        }
    } else {
        rep.log("[1/4] install_ollama SKIPPED (--skip-install)");
    }

    rep.log(&format!("[2/4] wait_ollama (up to {}s)", args.wait_secs));
    match ollama_service::wait_until_ready(&args.endpoint, args.wait_secs).await {
        Ok(ver) => rep.log(&format!("[ready] ollama version={ver}")),
        Err(e) => {
            rep.errlog(&format!("[error] wait_ollama: {e:#}"));
            return 11;
        }
    }

    rep.log(&format!("[3/4] pull_model {}", args.model));
    if let Err(e) = model_pull::pull(&rep, &args.endpoint, &args.model).await {
        rep.errlog(&format!("[error] pull_model: {e:#}"));
        return 12;
    }

    if !args.no_openclaw {
        rep.log("[4a/4] inject_openclaw");
        match openclaw::inject(&args.model) {
            Ok(r) => rep.log(&format!(
                "[openclaw] injected={} path={:?}",
                r.injected, r.config_path
            )),
            Err(e) => {
                rep.errlog(&format!("[error] inject_openclaw: {e:#}"));
                return 13;
            }
        }
    } else {
        rep.log("[4a/4] inject_openclaw SKIPPED (--no-openclaw)");
    }

    rep.log(&format!("[4b/4] send_chat_test prompt={:?}", args.prompt));
    match chat_test::send(&args.endpoint, &args.model, &args.prompt).await {
        Ok(reply) => {
            let trimmed = reply.trim();
            if trimmed.is_empty() {
                rep.errlog("[error] chat reply was empty");
                return 14;
            }
            let short: String = trimmed.chars().take(200).collect();
            rep.log(&format!("[chat] OK: {short}"));
        }
        Err(e) => {
            rep.errlog(&format!("[error] send_chat_test: {e:#}"));
            return 14;
        }
    }

    rep.log("[headless] ALL STEPS PASSED");
    0
}

// ---------------------------------------------------------------------------
#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn defaults_match_the_production_smoke_defaults() {
        let a = Args::default();
        assert_eq!(a.model, "gemma3:270m");
        assert_eq!(a.endpoint, "http://127.0.0.1:11434");
        assert!(!a.no_openclaw);
        assert!(!a.skip_install);
        assert_eq!(a.prompt, "say hi in 3 words");
        assert!(!a.require_network);
        assert_eq!(a.wait_secs, 60);
    }

    #[test]
    fn parses_wait_secs() {
        let a = parse_args(["--wait-secs", "3"]).unwrap();
        assert_eq!(a.wait_secs, 3);
    }

    #[test]
    fn rejects_invalid_wait_secs() {
        let err = parse_args(["--wait-secs", "abc"]).unwrap_err();
        assert!(err.contains("--wait-secs"), "got: {err}");
    }

    #[test]
    fn parses_model_and_endpoint_and_flags() {
        let a = parse_args([
            "--model",
            "gemma4:e2b",
            "--endpoint",
            "http://example:1234",
            "--no-openclaw",
            "--require-network",
        ])
        .unwrap();
        assert_eq!(a.model, "gemma4:e2b");
        assert_eq!(a.endpoint, "http://example:1234");
        assert!(a.no_openclaw);
        assert!(a.require_network);
        assert!(!a.skip_install);
    }

    #[test]
    fn parses_prompt_and_skip_install() {
        let a = parse_args(["--skip-install", "--prompt", "hello world"]).unwrap();
        assert!(a.skip_install);
        assert_eq!(a.prompt, "hello world");
    }

    #[test]
    fn missing_value_after_model_errors() {
        let err = parse_args(["--model"]).unwrap_err();
        assert!(err.contains("--model"), "got: {err}");
    }

    #[test]
    fn unknown_flag_errors() {
        let err = parse_args(["--what"]).unwrap_err();
        assert!(err.contains("unknown flag"), "got: {err}");
    }
}
