use anyhow::{anyhow, Result};
use serde_json::{json, Value};

pub async fn send(endpoint: &str, model: &str, prompt: &str) -> Result<String> {
    let client = reqwest::Client::builder()
        .timeout(std::time::Duration::from_secs(60))
        .build()?;

    let url = build_url(endpoint);
    let body = build_body(model, prompt);

    let resp = client.post(&url).json(&body).send().await?;
    if !resp.status().is_success() {
        return Err(anyhow!(
            "chat/completions HTTP {}: {}",
            resp.status(),
            resp.text().await.unwrap_or_default()
        ));
    }

    let v: Value = resp.json().await?;
    extract_content(&v)
}

/// Build the full /v1/chat/completions URL from an endpoint base.
/// Strips any trailing slash so `http://host/` and `http://host` both work.
pub fn build_url(endpoint: &str) -> String {
    format!("{}/v1/chat/completions", endpoint.trim_end_matches('/'))
}

/// Build the OpenAI-compatible request body for a single-turn chat.
pub fn build_body(model: &str, prompt: &str) -> Value {
    json!({
        "model": model,
        "messages": [{"role": "user", "content": prompt}],
        "stream": false,
    })
}

/// Extract `choices[0].message.content` from an OpenAI-shaped response.
/// Errors with a clear message when the structure is missing a field
/// instead of panicking, so the caller sees what the model actually replied.
pub fn extract_content(v: &Value) -> Result<String> {
    v.pointer("/choices/0/message/content")
        .and_then(|x| x.as_str())
        .map(|s| s.to_string())
        .ok_or_else(|| anyhow!("response has no choices[0].message.content"))
}

// ---------------------------------------------------------------------------
#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn build_url_appends_path() {
        assert_eq!(
            build_url("http://127.0.0.1:11434"),
            "http://127.0.0.1:11434/v1/chat/completions"
        );
    }

    #[test]
    fn build_url_strips_trailing_slash() {
        assert_eq!(
            build_url("http://127.0.0.1:11434/"),
            "http://127.0.0.1:11434/v1/chat/completions"
        );
    }

    #[test]
    fn build_body_has_openai_shape() {
        let b = build_body("gemma3:270m", "say hi");
        assert_eq!(b["model"], "gemma3:270m");
        assert_eq!(b["stream"], false);
        let msgs = b["messages"].as_array().unwrap();
        assert_eq!(msgs.len(), 1);
        assert_eq!(msgs[0]["role"], "user");
        assert_eq!(msgs[0]["content"], "say hi");
    }

    #[test]
    fn extract_content_happy_path() {
        let v: Value = serde_json::from_str(
            r#"{"choices":[{"message":{"role":"assistant","content":"hello there"}}]}"#,
        )
        .unwrap();
        assert_eq!(extract_content(&v).unwrap(), "hello there");
    }

    #[test]
    fn extract_content_errors_on_missing_choices() {
        let v: Value = serde_json::from_str(r#"{"id":"abc","model":"x"}"#).unwrap();
        let err = extract_content(&v).unwrap_err().to_string();
        assert!(err.contains("choices"), "got: {err}");
    }

    #[test]
    fn extract_content_errors_on_missing_content() {
        let v: Value = serde_json::from_str(r#"{"choices":[{"message":{}}]}"#).unwrap();
        let err = extract_content(&v).unwrap_err().to_string();
        assert!(err.contains("content") || err.contains("choices"), "got: {err}");
    }

    #[test]
    fn extract_content_errors_on_empty_choices_array() {
        let v: Value = serde_json::from_str(r#"{"choices":[]}"#).unwrap();
        assert!(extract_content(&v).is_err());
    }

    // ---- tiny in-process HTTP fake for full send() coverage ----------------
    //
    // Uses a raw TcpListener + hand-rolled HTTP/1.1 parser to avoid dragging
    // wiremock into the dependency graph. The fake reads one request, sends
    // one response, and then closes — good enough for a single request.

    async fn spawn_fake(response_body: &'static str, status_line: &'static str) -> String {
        use tokio::io::{AsyncReadExt, AsyncWriteExt};
        use tokio::net::TcpListener;

        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let addr = listener.local_addr().unwrap();
        tokio::spawn(async move {
            if let Ok((mut sock, _)) = listener.accept().await {
                // drain request until \r\n\r\n
                let mut buf = [0u8; 4096];
                let mut read: Vec<u8> = Vec::new();
                loop {
                    let n = sock.read(&mut buf).await.unwrap_or(0);
                    if n == 0 { break; }
                    read.extend_from_slice(&buf[..n]);
                    if read.windows(4).any(|w| w == b"\r\n\r\n") {
                        break;
                    }
                }
                let body = response_body.as_bytes();
                let resp = format!(
                    "{status_line}\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",
                    body.len()
                );
                let _ = sock.write_all(resp.as_bytes()).await;
                let _ = sock.write_all(body).await;
                let _ = sock.shutdown().await;
            }
        });
        format!("http://{}", addr)
    }

    #[tokio::test]
    async fn send_returns_content_from_fake_server() {
        let endpoint = spawn_fake(
            r#"{"choices":[{"message":{"role":"assistant","content":"pong"}}]}"#,
            "HTTP/1.1 200 OK",
        )
        .await;
        let r = send(&endpoint, "gemma3:270m", "ping").await.unwrap();
        assert_eq!(r, "pong");
    }

    #[tokio::test]
    async fn send_errors_on_http_500() {
        let endpoint = spawn_fake(
            r#"{"error":{"message":"model not found"}}"#,
            "HTTP/1.1 500 Internal Server Error",
        )
        .await;
        let err = send(&endpoint, "gemma3:270m", "ping")
            .await
            .unwrap_err()
            .to_string();
        assert!(err.contains("HTTP 500"), "got: {err}");
    }

    #[tokio::test]
    async fn send_errors_on_malformed_body() {
        let endpoint = spawn_fake(r#"{"not_openai":true}"#, "HTTP/1.1 200 OK").await;
        let err = send(&endpoint, "gemma3:270m", "ping")
            .await
            .unwrap_err()
            .to_string();
        assert!(err.contains("choices"), "got: {err}");
    }
}
