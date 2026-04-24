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

// ---------------------------------------------------------------------------
#[cfg(test)]
mod tests {
    use super::*;
    use tokio::io::{AsyncReadExt, AsyncWriteExt};
    use tokio::net::TcpListener;

    async fn spawn_version_server(reply: &'static str, status: &'static str) -> String {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let addr = listener.local_addr().unwrap();
        tokio::spawn(async move {
            loop {
                if let Ok((mut sock, _)) = listener.accept().await {
                    let mut buf = [0u8; 4096];
                    let mut read: Vec<u8> = Vec::new();
                    loop {
                        let n = sock.read(&mut buf).await.unwrap_or(0);
                        if n == 0 {
                            break;
                        }
                        read.extend_from_slice(&buf[..n]);
                        if read.windows(4).any(|w| w == b"\r\n\r\n") {
                            break;
                        }
                    }
                    let body = reply.as_bytes();
                    let header = format!(
                        "{status}\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",
                        body.len()
                    );
                    let _ = sock.write_all(header.as_bytes()).await;
                    let _ = sock.write_all(body).await;
                    let _ = sock.shutdown().await;
                }
            }
        });
        format!("http://{}", addr)
    }

    #[tokio::test]
    async fn wait_returns_version_when_server_is_up() {
        let endpoint =
            spawn_version_server(r#"{"version":"0.99.0-test"}"#, "HTTP/1.1 200 OK").await;
        let ver = wait_until_ready(&endpoint, 3).await.unwrap();
        assert_eq!(ver, "0.99.0-test");
    }

    #[tokio::test]
    async fn wait_returns_unknown_when_version_field_missing() {
        let endpoint = spawn_version_server(r#"{}"#, "HTTP/1.1 200 OK").await;
        let ver = wait_until_ready(&endpoint, 3).await.unwrap();
        assert_eq!(ver, "unknown");
    }

    #[tokio::test]
    async fn wait_times_out_on_unreachable_endpoint() {
        // Port 1 is the historical unassigned "tcpmux" — nothing listens there.
        let start = std::time::Instant::now();
        let err = wait_until_ready("http://127.0.0.1:1", 1)
            .await
            .unwrap_err()
            .to_string();
        // Must surface the timeout (not hang, not succeed)
        assert!(err.contains("1s") && err.contains("未就绪"), "got: {err}");
        // Must not run wildly past the declared budget (allow some slack for scheduling)
        assert!(
            start.elapsed() < Duration::from_secs(5),
            "timeout took too long: {:?}",
            start.elapsed()
        );
    }
}
