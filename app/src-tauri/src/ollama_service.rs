use anyhow::{anyhow, Result};
use std::time::Duration;

pub const DEFAULT_ENDPOINT: &str = "http://127.0.0.1:11434";

pub async fn wait_until_ready(endpoint: &str, timeout_secs: u64) -> Result<String> {
    let client = reqwest::Client::builder()
        .timeout(Duration::from_secs(2))
        .build()?;

    let deadline = std::time::Instant::now() + Duration::from_secs(timeout_secs);
    loop {
        let url = format!("{}/api/version", endpoint.trim_end_matches('/'));
        match client.get(&url).send().await {
            Ok(resp) if resp.status().is_success() => {
                let body: serde_json::Value = resp.json().await.unwrap_or_default();
                let ver = body
                    .get("version")
                    .and_then(|v| v.as_str())
                    .unwrap_or("unknown")
                    .to_string();
                return Ok(ver);
            }
            _ => {
                if std::time::Instant::now() >= deadline {
                    return Err(anyhow!(
                        "Ollama 服务在 {}s 内未就绪 ({})",
                        timeout_secs,
                        endpoint
                    ));
                }
                tokio::time::sleep(Duration::from_millis(800)).await;
            }
        }
    }
}
