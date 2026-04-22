use serde::Serialize;
use std::time::Duration;

#[derive(Serialize, Clone)]
#[serde(rename_all = "camelCase")]
pub struct PreflightReport {
    pub os: String,
    pub gpu: Option<String>,
    pub ram_gb: u64,
    pub disk_gb: u64,
    pub network_ok: bool,
    pub network_error: Option<String>,
    pub min_disk_gb: u64,
    pub ok: bool,
    pub errors: Vec<String>,
}

const MIN_DISK_GB: u64 = 12;

pub async fn run_preflight() -> PreflightReport {
    let os = os_label();
    let ram_gb = probe_ram_gb();
    let disk_gb = probe_disk_gb();
    let gpu = probe_gpu();
    let (network_ok, network_error) = probe_network().await;

    let mut errors = Vec::new();
    if disk_gb < MIN_DISK_GB {
        errors.push(format!(
            "磁盘可用 {disk_gb} GB, 至少需要 {MIN_DISK_GB} GB"
        ));
    }
    if !network_ok {
        errors.push(format!(
            "无法连接 ollama.com ({}), 请检查网络",
            network_error.as_deref().unwrap_or("未知错误")
        ));
    }

    PreflightReport {
        os,
        gpu,
        ram_gb,
        disk_gb,
        network_ok,
        network_error,
        min_disk_gb: MIN_DISK_GB,
        ok: errors.is_empty(),
        errors,
    }
}

fn os_label() -> String {
    format!("{} {}", std::env::consts::OS, std::env::consts::ARCH)
}

fn probe_ram_gb() -> u64 {
    let mut sys = sysinfo::System::new();
    sys.refresh_memory();
    sys.total_memory() / 1024 / 1024 / 1024
}

fn probe_disk_gb() -> u64 {
    // Ollama stores models under the user's home by default (Linux ~/.ollama,
    // macOS ~/.ollama, Windows %USERPROFILE%\.ollama). Measure that filesystem.
    let home = directories::UserDirs::new()
        .map(|u| u.home_dir().to_path_buf())
        .unwrap_or_else(|| std::path::PathBuf::from("/"));

    let disks = sysinfo::Disks::new_with_refreshed_list();
    disks
        .iter()
        .filter(|d| home.starts_with(d.mount_point()))
        .map(|d| d.available_space() / 1024 / 1024 / 1024)
        .max()
        .unwrap_or(0)
}

fn probe_gpu() -> Option<String> {
    #[cfg(target_os = "linux")]
    {
        if let Ok(out) = std::process::Command::new("nvidia-smi")
            .args([
                "--query-gpu=name,memory.total",
                "--format=csv,noheader",
            ])
            .output()
        {
            if out.status.success() {
                let s = String::from_utf8_lossy(&out.stdout).trim().to_string();
                if !s.is_empty() {
                    return Some(s.lines().next().unwrap_or("").to_string());
                }
            }
        }
    }

    #[cfg(target_os = "macos")]
    {
        if let Ok(out) = std::process::Command::new("system_profiler")
            .args(["SPDisplaysDataType", "-detailLevel", "mini"])
            .output()
        {
            if out.status.success() {
                let s = String::from_utf8_lossy(&out.stdout);
                for line in s.lines() {
                    let line = line.trim();
                    if let Some(rest) = line.strip_prefix("Chipset Model:") {
                        return Some(rest.trim().to_string());
                    }
                }
            }
        }
    }

    #[cfg(target_os = "windows")]
    {
        if let Ok(out) = std::process::Command::new("wmic")
            .args(["path", "win32_VideoController", "get", "name"])
            .output()
        {
            if out.status.success() {
                let s = String::from_utf8_lossy(&out.stdout);
                for line in s.lines().skip(1) {
                    let line = line.trim();
                    if !line.is_empty() {
                        return Some(line.to_string());
                    }
                }
            }
        }
    }

    None
}

async fn probe_network() -> (bool, Option<String>) {
    let client = match reqwest::Client::builder()
        .timeout(Duration::from_secs(5))
        .build()
    {
        Ok(c) => c,
        Err(e) => return (false, Some(format!("build client: {e}"))),
    };
    // HEAD first, fall back to GET — some servers dislike HEAD.
    for method in &["HEAD", "GET"] {
        let req = match *method {
            "HEAD" => client.head("https://ollama.com"),
            _ => client.get("https://ollama.com"),
        };
        match req.send().await {
            Ok(r) if r.status().is_success() || r.status().is_redirection() => {
                return (true, None);
            }
            Ok(r) => {
                return (false, Some(format!("HTTP {}", r.status())));
            }
            Err(e) => {
                // on the last attempt, surface the error
                if *method == "GET" {
                    return (false, Some(e.to_string()));
                }
            }
        }
    }
    (false, Some("all probes failed".to_string()))
}
