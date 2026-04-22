use anyhow::{anyhow, Context, Result};
use serde::Serialize;
#[cfg(any(target_os = "macos", target_os = "windows"))]
use std::path::PathBuf;
use std::process::Stdio;
use tauri::{AppHandle, Emitter};
#[cfg(target_os = "linux")]
use tokio::io::{AsyncBufReadExt, BufReader};
use tokio::process::Command;

#[derive(Serialize, Clone)]
#[serde(rename_all = "camelCase")]
pub struct InstallProgress {
    pub stage: String,
    pub message: String,
    pub percent: Option<u8>,
}

fn emit(app: &AppHandle, stage: &str, message: impl Into<String>, percent: Option<u8>) {
    let _ = app.emit(
        "install:progress",
        InstallProgress {
            stage: stage.to_string(),
            message: message.into(),
            percent,
        },
    );
}

pub async fn install_ollama(app: AppHandle) -> Result<()> {
    if which::which("ollama").is_ok() {
        emit(&app, "ollama", "Ollama 已安装, 跳过".to_string(), Some(100));
        return Ok(());
    }

    #[cfg(target_os = "linux")]
    return install_linux(app).await;

    #[cfg(target_os = "macos")]
    return install_macos(app).await;

    #[cfg(target_os = "windows")]
    return install_windows(app).await;

    #[cfg(not(any(target_os = "linux", target_os = "macos", target_os = "windows")))]
    Err(anyhow!("unsupported platform"))
}

// ---------------------------------------------------------------------------
// Linux — delegate to Ollama's official install.sh (sudo/systemd handled inside)
// ---------------------------------------------------------------------------
#[cfg(target_os = "linux")]
async fn install_linux(app: AppHandle) -> Result<()> {
    emit(&app, "ollama", "从 ollama.com 下载官方安装脚本", Some(5));
    let script = reqwest::get("https://ollama.com/install.sh")
        .await?
        .error_for_status()?
        .text()
        .await?;

    let tmp = std::env::temp_dir().join("ollama-install.sh");
    tokio::fs::write(&tmp, &script).await?;

    emit(&app, "ollama", "运行 Ollama 官方安装脚本 (需要 sudo 权限)", Some(20));
    let mut child = Command::new("sh")
        .arg(&tmp)
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .context("spawn sh")?;

    stream_child(&app, &mut child).await?;
    let status = child.wait().await?;
    if !status.success() {
        return Err(anyhow!("Ollama install.sh 失败, 退出码 {:?}", status.code()));
    }

    emit(&app, "ollama", "Ollama 安装完成", Some(100));
    let _ = tokio::fs::remove_file(&tmp).await;
    Ok(())
}

// ---------------------------------------------------------------------------
// macOS — download DMG, mount, copy .app to /Applications, launch
// ---------------------------------------------------------------------------
#[cfg(target_os = "macos")]
async fn install_macos(app: AppHandle) -> Result<()> {
    let dmg_url = "https://ollama.com/download/Ollama.dmg";
    let tmp: PathBuf = std::env::temp_dir().join("Ollama.dmg");

    emit(&app, "ollama", "下载 Ollama.dmg", Some(5));
    download_with_progress(&app, "ollama", dmg_url, &tmp, 5, 70).await?;

    emit(&app, "ollama", "挂载 DMG 并拷贝到 /Applications", Some(75));
    let mount = Command::new("hdiutil")
        .args(["attach", "-nobrowse", "-readonly"])
        .arg(&tmp)
        .output()
        .await?;
    if !mount.status.success() {
        return Err(anyhow!("hdiutil attach failed: {}", String::from_utf8_lossy(&mount.stderr)));
    }
    let mount_output = String::from_utf8_lossy(&mount.stdout);
    let mount_point = mount_output
        .lines()
        .last()
        .and_then(|l| l.split('\t').last())
        .map(|s| s.trim().to_string())
        .ok_or_else(|| anyhow!("couldn't parse hdiutil mount point"))?;

    let src = PathBuf::from(&mount_point).join("Ollama.app");
    let dst = PathBuf::from("/Applications/Ollama.app");
    if dst.exists() {
        let _ = tokio::fs::remove_dir_all(&dst).await;
    }
    let cp = Command::new("cp").args(["-R"]).arg(&src).arg("/Applications/").status().await?;
    if !cp.success() {
        let _ = Command::new("hdiutil").args(["detach"]).arg(&mount_point).status().await;
        return Err(anyhow!("failed to copy Ollama.app to /Applications"));
    }

    let _ = Command::new("hdiutil").args(["detach"]).arg(&mount_point).status().await;
    let _ = tokio::fs::remove_file(&tmp).await;

    emit(&app, "ollama", "启动 Ollama.app", Some(95));
    Command::new("open").arg("/Applications/Ollama.app").status().await?;

    emit(&app, "ollama", "Ollama 安装完成", Some(100));
    Ok(())
}

// ---------------------------------------------------------------------------
// Windows — download OllamaSetup.exe, run silently at user level
// ---------------------------------------------------------------------------
#[cfg(target_os = "windows")]
async fn install_windows(app: AppHandle) -> Result<()> {
    let url = "https://ollama.com/download/OllamaSetup.exe";
    let tmp: PathBuf = std::env::temp_dir().join("OllamaSetup.exe");

    emit(&app, "ollama", "下载 OllamaSetup.exe", Some(5));
    download_with_progress(&app, "ollama", url, &tmp, 5, 80).await?;

    emit(&app, "ollama", "静默运行安装程序", Some(85));
    let status = Command::new(&tmp)
        .args(["/VERYSILENT", "/NORESTART", "/SUPPRESSMSGBOXES"])
        .status()
        .await?;
    if !status.success() {
        return Err(anyhow!("OllamaSetup.exe 退出码 {:?}", status.code()));
    }

    let _ = tokio::fs::remove_file(&tmp).await;
    emit(&app, "ollama", "Ollama 安装完成", Some(100));
    Ok(())
}

// ---------------------------------------------------------------------------
// shared helpers
// ---------------------------------------------------------------------------
#[cfg(any(target_os = "macos", target_os = "windows"))]
async fn download_with_progress(
    app: &AppHandle,
    stage: &str,
    url: &str,
    to: &std::path::Path,
    base_pct: u8,
    max_pct: u8,
) -> Result<()> {
    use futures_util::StreamExt;
    use tokio::io::AsyncWriteExt;

    let resp = reqwest::get(url).await?.error_for_status()?;
    let total = resp.content_length().unwrap_or(0);
    let mut file = tokio::fs::File::create(to).await?;
    let mut stream = resp.bytes_stream();
    let mut downloaded: u64 = 0;
    let mut last_emit: u8 = base_pct;

    while let Some(chunk) = stream.next().await {
        let chunk = chunk?;
        file.write_all(&chunk).await?;
        downloaded += chunk.len() as u64;

        if total > 0 {
            let span = (max_pct - base_pct) as u64;
            let pct = base_pct as u64 + (downloaded * span / total);
            let pct = pct.min(max_pct as u64) as u8;
            if pct > last_emit {
                last_emit = pct;
                emit(
                    app,
                    stage,
                    format!("下载中 ({} / {} MB)", downloaded / 1_048_576, total / 1_048_576),
                    Some(pct),
                );
            }
        }
    }
    file.flush().await?;
    Ok(())
}

#[cfg(target_os = "linux")]
async fn stream_child(app: &AppHandle, child: &mut tokio::process::Child) -> Result<()> {
    let stdout = child.stdout.take();
    let stderr = child.stderr.take();

    if let Some(out) = stdout {
        let app = app.clone();
        tokio::spawn(async move {
            let mut lines = BufReader::new(out).lines();
            while let Ok(Some(line)) = lines.next_line().await {
                emit(&app, "ollama", line, None);
            }
        });
    }
    if let Some(err) = stderr {
        let app = app.clone();
        tokio::spawn(async move {
            let mut lines = BufReader::new(err).lines();
            while let Ok(Some(line)) = lines.next_line().await {
                emit(&app, "ollama", line, None);
            }
        });
    }
    Ok(())
}
