use anyhow::{anyhow, Result};
use futures_util::StreamExt;
use serde::Deserialize;

use crate::progress::Reporter;

#[derive(Deserialize)]
struct OllamaPullLine {
    status: String,
    #[serde(default)]
    completed: u64,
    #[serde(default)]
    total: u64,
}

/// Compute the 0-100 percent of a pull line, clamped at 100.
pub fn pull_percent(completed: u64, total: u64) -> u8 {
    if total == 0 {
        return 0;
    }
    ((completed.saturating_mul(100)) / total).min(100) as u8
}

pub async fn pull(reporter: &dyn Reporter, endpoint: &str, model: &str) -> Result<()> {
    let client = reqwest::Client::builder()
        .timeout(std::time::Duration::from_secs(60 * 60))
        .build()?;

    let url = format!("{}/api/pull", endpoint.trim_end_matches('/'));
    let body = serde_json::json!({ "name": model, "stream": true });

    let resp = client.post(&url).json(&body).send().await?;
    if !resp.status().is_success() {
        return Err(anyhow!(
            "/api/pull 返回 HTTP {}: {}",
            resp.status(),
            resp.text().await.unwrap_or_default()
        ));
    }

    let mut stream = resp.bytes_stream();
    let mut buf: Vec<u8> = Vec::with_capacity(4096);

    while let Some(chunk) = stream.next().await {
        let chunk = chunk?;
        buf.extend_from_slice(&chunk);

        while let Some(nl) = buf.iter().position(|b| *b == b'\n') {
            let line: Vec<u8> = buf.drain(..=nl).collect();
            let trimmed = &line[..line.len().saturating_sub(1)];
            if trimmed.is_empty() {
                continue;
            }
            match serde_json::from_slice::<OllamaPullLine>(trimmed) {
                Ok(parsed) => {
                    let percent = pull_percent(parsed.completed, parsed.total);
                    reporter.pull(&parsed.status, parsed.completed, parsed.total, percent);
                    if parsed.status.eq_ignore_ascii_case("success") {
                        return Ok(());
                    }
                    if parsed.status.to_lowercase().starts_with("error") {
                        return Err(anyhow!("pull error: {}", parsed.status));
                    }
                }
                Err(_) => {
                    // ignore non-json or partial — just forward raw
                    let text = String::from_utf8_lossy(trimmed);
                    reporter.pull(&text, 0, 0, 0);
                }
            }
        }
    }

    Ok(())
}

// ---------------------------------------------------------------------------
#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn pull_percent_zero_total_is_zero() {
        assert_eq!(pull_percent(0, 0), 0);
        assert_eq!(pull_percent(12345, 0), 0);
    }

    #[test]
    fn pull_percent_midway_rounds_down() {
        assert_eq!(pull_percent(500, 1000), 50);
        assert_eq!(pull_percent(333, 1000), 33);
        assert_eq!(pull_percent(1, 1000), 0);
    }

    #[test]
    fn pull_percent_complete_is_100() {
        assert_eq!(pull_percent(1000, 1000), 100);
    }

    #[test]
    fn pull_percent_overshoot_is_clamped() {
        // Ollama sometimes reports completed > total when it's appending an
        // extra layer — we must still clamp to 100 rather than overflow.
        assert_eq!(pull_percent(1100, 1000), 100);
    }

    #[test]
    fn pull_percent_large_u64_does_not_overflow() {
        // 100 GB numbers — typical upper end for real Ollama pulls. Must not
        // panic on multiplication, and the percent must fall in 0..=100.
        let total = 100u64 * 1024 * 1024 * 1024;
        let completed = 37u64 * 1024 * 1024 * 1024;
        let p = pull_percent(completed, total);
        assert_eq!(p, 37);

        // Even at values so large that `completed * 100` saturates,
        // `pull_percent` must return a value in the legal 0..=100 range
        // (no panic, no overflow).
        let huge = u64::MAX / 50;
        let p = pull_percent(huge, huge);
        assert!(p <= 100, "out of range: {p}");
    }

    #[test]
    fn parses_a_download_progress_line() {
        let line = br#"{"status":"downloading","completed":500,"total":1000}"#;
        let parsed: OllamaPullLine = serde_json::from_slice(line).unwrap();
        assert_eq!(parsed.status, "downloading");
        assert_eq!(parsed.completed, 500);
        assert_eq!(parsed.total, 1000);
        assert_eq!(pull_percent(parsed.completed, parsed.total), 50);
    }

    #[test]
    fn parses_a_status_only_line() {
        // Ollama emits non-progress lines like {"status":"pulling manifest"}
        // with no completed/total fields — must default to 0 via serde default.
        let line = br#"{"status":"pulling manifest"}"#;
        let parsed: OllamaPullLine = serde_json::from_slice(line).unwrap();
        assert_eq!(parsed.status, "pulling manifest");
        assert_eq!(parsed.completed, 0);
        assert_eq!(parsed.total, 0);
    }

    #[test]
    fn parses_success_line() {
        let line = br#"{"status":"success"}"#;
        let parsed: OllamaPullLine = serde_json::from_slice(line).unwrap();
        assert!(parsed.status.eq_ignore_ascii_case("success"));
    }
}
