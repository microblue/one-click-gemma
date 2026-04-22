use anyhow::{anyhow, Result};
use futures_util::StreamExt;
use serde::{Deserialize, Serialize};
use tauri::{AppHandle, Emitter};

#[derive(Serialize, Clone)]
#[serde(rename_all = "camelCase")]
pub struct PullProgress {
    pub status: String,
    pub completed: u64,
    pub total: u64,
    pub percent: u8,
}

#[derive(Deserialize)]
struct OllamaPullLine {
    status: String,
    #[serde(default)]
    completed: u64,
    #[serde(default)]
    total: u64,
}

pub async fn pull(app: AppHandle, endpoint: &str, model: &str) -> Result<()> {
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
                    let percent = if parsed.total > 0 {
                        ((parsed.completed.saturating_mul(100)) / parsed.total).min(100) as u8
                    } else {
                        0
                    };
                    let _ = app.emit(
                        "pull:progress",
                        PullProgress {
                            status: parsed.status.clone(),
                            completed: parsed.completed,
                            total: parsed.total,
                            percent,
                        },
                    );
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
                    let _ = app.emit(
                        "pull:progress",
                        PullProgress {
                            status: text.to_string(),
                            completed: 0,
                            total: 0,
                            percent: 0,
                        },
                    );
                }
            }
        }
    }

    Ok(())
}
