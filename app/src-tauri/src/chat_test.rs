use anyhow::{anyhow, Result};
use serde_json::json;

pub async fn send(endpoint: &str, model: &str, prompt: &str) -> Result<String> {
    let client = reqwest::Client::builder()
        .timeout(std::time::Duration::from_secs(60))
        .build()?;

    let url = format!("{}/v1/chat/completions", endpoint.trim_end_matches('/'));
    let body = json!({
        "model": model,
        "messages": [{"role": "user", "content": prompt}],
        "stream": false,
    });

    let resp = client.post(&url).json(&body).send().await?;
    if !resp.status().is_success() {
        return Err(anyhow!(
            "chat/completions HTTP {}: {}",
            resp.status(),
            resp.text().await.unwrap_or_default()
        ));
    }

    let v: serde_json::Value = resp.json().await?;
    let content = v
        .pointer("/choices/0/message/content")
        .and_then(|x| x.as_str())
        .ok_or_else(|| anyhow!("response has no choices[0].message.content"))?;

    Ok(content.to_string())
}
