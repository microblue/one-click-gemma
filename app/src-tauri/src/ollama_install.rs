use anyhow::{anyhow, Context, Result};
#[cfg(any(target_os = "macos", target_os = "windows"))]
use std::path::PathBuf;
use std::process::Stdio;
#[cfg(target_os = "linux")]
use tokio::io::{AsyncBufReadExt, BufReader};
use tokio::process::Command;

use crate::progress::Reporter;

pub async fn install_ollama(reporter: &dyn Reporter) -> Result<()> {
    if which::which("ollama").is_ok() {
        reporter.install("ollama", "Ollama 已安装, 跳过", Some(100));
        return Ok(());
    }

    #[cfg(target_os = "linux")]
    return install_linux(reporter).await;

    #[cfg(target_os = "macos")]
    return install_macos(reporter).await;

    #[cfg(target_os = "windows")]
    return install_windows(reporter).await;

    #[cfg(not(any(target_os = "linux", target_os = "macos", target_os = "windows")))]
    Err(anyhow!("unsupported platform"))
}

// ---------------------------------------------------------------------------
// Linux — delegate to Ollama's official install.sh (sudo/systemd handled inside)
// ---------------------------------------------------------------------------
#[cfg(target_os = "linux")]
async fn install_linux(reporter: &dyn Reporter) -> Result<()> {
    reporter.install("ollama", "从 ollama.com 下载官方安装脚本", Some(5));
    let script = reqwest::get("https://ollama.com/install.sh")
        .await?
        .error_for_status()?
        .text()
        .await?;

    let tmp = std::env::temp_dir().join("ollama-install.sh");
    tokio::fs::write(&tmp, &script).await?;

    reporter.install(
        "ollama",
        "运行 Ollama 官方安装脚本 (需要 sudo 权限)",
        Some(20),
    );
    let mut child = Command::new("sh")
        .arg(&tmp)
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .context("spawn sh")?;

    stream_child(reporter, &mut child).await?;
    let status = child.wait().await?;
    if !status.success() {
        return Err(anyhow!("Ollama install.sh 失败, 退出码 {:?}", status.code()));
    }

    reporter.install("ollama", "Ollama 安装完成", Some(100));
    let _ = tokio::fs::remove_file(&tmp).await;
    Ok(())
}

// ---------------------------------------------------------------------------
// macOS — download DMG, mount, copy .app to /Applications, launch
// ---------------------------------------------------------------------------
#[cfg(target_os = "macos")]
async fn install_macos(reporter: &dyn Reporter) -> Result<()> {
    let dmg_url = "https://ollama.com/download/Ollama.dmg";
    let tmp: PathBuf = std::env::temp_dir().join("Ollama.dmg");

    reporter.install("ollama", "下载 Ollama.dmg", Some(5));
    download_with_progress(reporter, "ollama", dmg_url, &tmp, 5, 70).await?;

    reporter.install("ollama", "挂载 DMG 并拷贝到 /Applications", Some(75));
    let mount = Command::new("hdiutil")
        .args(["attach", "-nobrowse", "-readonly"])
        .arg(&tmp)
        .output()
        .await?;
    if !mount.status.success() {
        return Err(anyhow!(
            "hdiutil attach failed: {}",
            String::from_utf8_lossy(&mount.stderr)
        ));
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
    let cp = Command::new("cp")
        .args(["-R"])
        .arg(&src)
        .arg("/Applications/")
        .status()
        .await?;
    if !cp.success() {
        let _ = Command::new("hdiutil")
            .args(["detach"])
            .arg(&mount_point)
            .status()
            .await;
        return Err(anyhow!("failed to copy Ollama.app to /Applications"));
    }

    let _ = Command::new("hdiutil")
        .args(["detach"])
        .arg(&mount_point)
        .status()
        .await;
    let _ = tokio::fs::remove_file(&tmp).await;

    reporter.install("ollama", "启动 Ollama.app", Some(95));
    Command::new("open")
        .arg("/Applications/Ollama.app")
        .status()
        .await?;

    reporter.install("ollama", "Ollama 安装完成", Some(100));
    Ok(())
}

// ---------------------------------------------------------------------------
// Windows — download OllamaSetup.exe, run silently at user level
// ---------------------------------------------------------------------------
#[cfg(target_os = "windows")]
async fn install_windows(reporter: &dyn Reporter) -> Result<()> {
    let url = "https://ollama.com/download/OllamaSetup.exe";
    let tmp: PathBuf = std::env::temp_dir().join("OllamaSetup.exe");

    reporter.install("ollama", "下载 OllamaSetup.exe", Some(5));
    download_with_progress(reporter, "ollama", url, &tmp, 5, 80).await?;

    // Seed the "upgraded" marker so Ollama's tray app starts hidden on first
    // launch (mirrors upstream install.ps1). Harmless if it already exists.
    if let Ok(local) = std::env::var("LOCALAPPDATA") {
        let dir = PathBuf::from(&local).join("Ollama");
        let _ = tokio::fs::create_dir_all(&dir).await;
        let _ = tokio::fs::write(dir.join("upgraded"), b"").await;
    }

    reporter.install("ollama", "静默运行安装程序", Some(85));
    let status = Command::new(&tmp)
        .args(["/VERYSILENT", "/NORESTART", "/SUPPRESSMSGBOXES"])
        .status()
        .await?;

    // Windows exit 5 = ERROR_ACCESS_DENIED; 740 = ERROR_ELEVATION_REQUIRED.
    let code = status.code();
    if !status.success() && matches!(code, Some(5) | Some(740)) {
        reporter.install(
            "ollama",
            &format!("非提权安装被拒 (exit {code:?}), 通过 UAC 重试"),
            Some(85),
        );
        let tmp_str = tmp.display().to_string().replace('\'', "''");
        let ps = format!(
            "try {{ $p = Start-Process -FilePath '{tmp_str}' \
                 -ArgumentList '/VERYSILENT','/NORESTART','/SUPPRESSMSGBOXES' \
                 -Verb RunAs -PassThru -ErrorAction Stop }} \
             catch {{ exit 1223 }} \
             if (-not $p.WaitForExit(300000)) {{ try {{ $p.Kill() }} catch {{}} ; exit 124 }} \
             exit $p.ExitCode"
        );
        let retry = Command::new("powershell")
            .args(["-NoProfile", "-ExecutionPolicy", "Bypass", "-Command", &ps])
            .status()
            .await?;
        if !retry.success() {
            let _ = tokio::fs::remove_file(&tmp).await;
            let c = retry.code();
            let reason = match c {
                Some(1223) => "用户取消了 UAC 授权".to_string(),
                Some(124) => "提权后安装 5 分钟内未完成".to_string(),
                Some(n) => format!("提权后 OllamaSetup.exe 退出码 {n}"),
                None => "提权后 OllamaSetup.exe 异常终止".to_string(),
            };
            return Err(anyhow!(
                "{reason} · 首次非提权尝试返回 {code:?} · \
                 可以右键这个 app → 以管理员身份运行, 再点一次开始安装"
            ));
        }
    } else if !status.success() {
        let _ = tokio::fs::remove_file(&tmp).await;
        return Err(anyhow!("OllamaSetup.exe 退出码 {code:?}"));
    }

    let _ = tokio::fs::remove_file(&tmp).await;

    // Fresh Windows installs: OllamaSetup.exe does NOT always auto-launch
    // the tray app, which means no `ollama serve` is running and the next
    // step's /api/version poll times out. Launch it explicitly here.
    if let Ok(local) = std::env::var("LOCALAPPDATA") {
        let tray = PathBuf::from(&local)
            .join("Programs")
            .join("Ollama")
            .join("ollama app.exe");
        let exe = PathBuf::from(&local)
            .join("Programs")
            .join("Ollama")
            .join("ollama.exe");
        reporter.install("ollama", "启动 Ollama 后台服务", Some(95));
        let launched = if tray.exists() {
            let path = tray.display().to_string().replace('\'', "''");
            let ps = format!(
                "Start-Process -FilePath '{path}' -WindowStyle Hidden -ErrorAction SilentlyContinue"
            );
            let _ = Command::new("powershell")
                .args(["-NoProfile", "-Command", &ps])
                .status()
                .await;
            true
        } else if exe.exists() {
            let path = exe.display().to_string().replace('\'', "''");
            let ps = format!(
                "Start-Process -FilePath '{path}' -ArgumentList 'serve' -WindowStyle Hidden -ErrorAction SilentlyContinue"
            );
            let _ = Command::new("powershell")
                .args(["-NoProfile", "-Command", &ps])
                .status()
                .await;
            true
        } else {
            false
        };
        if !launched {
            reporter.install(
                "ollama",
                "未找到 Ollama 可执行文件, 下一步健康检查可能超时",
                Some(95),
            );
        }
    }

    reporter.install("ollama", "Ollama 安装完成", Some(100));
    Ok(())
}

// ---------------------------------------------------------------------------
// shared helpers
// ---------------------------------------------------------------------------
#[cfg(any(target_os = "macos", target_os = "windows"))]
async fn download_with_progress(
    reporter: &dyn Reporter,
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
                reporter.install(
                    stage,
                    &format!(
                        "下载中 ({} / {} MB)",
                        downloaded / 1_048_576,
                        total / 1_048_576
                    ),
                    Some(pct),
                );
            }
        }
    }
    file.flush().await?;
    Ok(())
}

#[cfg(target_os = "linux")]
async fn stream_child(reporter: &dyn Reporter, child: &mut tokio::process::Child) -> Result<()> {
    // Read both streams in the current task (simpler than the old spawn-two-
    // tasks layout; now that the reporter is a trait object, we'd need Arc.
    // Interleaved reads are fine for install.sh which is linearly chatty).
    let stdout = child.stdout.take();
    let stderr = child.stderr.take();

    if let Some(out) = stdout {
        let mut lines = BufReader::new(out).lines();
        while let Ok(Some(line)) = lines.next_line().await {
            reporter.install("ollama", &line, None);
        }
    }
    if let Some(err) = stderr {
        let mut lines = BufReader::new(err).lines();
        while let Ok(Some(line)) = lines.next_line().await {
            reporter.install("ollama", &line, None);
        }
    }
    Ok(())
}
