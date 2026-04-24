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

/// Pure evaluator: given raw probe results, produce the user-facing errors.
/// Split from `run_preflight` so unit tests can hit the decision logic
/// without reaching real disks/GPUs/DNS on the CI box.
pub fn evaluate(disk_gb: u64, min_disk_gb: u64, network_ok: bool, network_error: Option<&str>)
    -> Vec<String>
{
    let mut errors = Vec::new();
    if disk_gb < min_disk_gb {
        errors.push(format!(
            "磁盘可用 {disk_gb} GB, 至少需要 {min_disk_gb} GB"
        ));
    }
    if !network_ok {
        errors.push(format!(
            "无法连接 ollama.com ({}), 请检查网络",
            network_error.unwrap_or("未知错误")
        ));
    }
    errors
}

pub async fn run_preflight() -> PreflightReport {
    let os = os_label();
    let ram_gb = probe_ram_gb();
    let disk_gb = probe_disk_gb();
    let gpu = probe_gpu();
    let (network_ok, network_error) = probe_network().await;

    let errors = evaluate(disk_gb, MIN_DISK_GB, network_ok, network_error.as_deref());

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

// ---------------------------------------------------------------------------
#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn evaluate_accepts_happy_path() {
        let errs = evaluate(200, MIN_DISK_GB, true, None);
        assert!(errs.is_empty(), "expected no errors, got: {errs:?}");
    }

    #[test]
    fn evaluate_flags_low_disk() {
        let errs = evaluate(4, MIN_DISK_GB, true, None);
        assert_eq!(errs.len(), 1);
        assert!(errs[0].contains("4 GB"));
        assert!(errs[0].contains(&MIN_DISK_GB.to_string()));
    }

    #[test]
    fn evaluate_flags_network_down() {
        let errs = evaluate(200, MIN_DISK_GB, false, Some("dns error: nxdomain"));
        assert_eq!(errs.len(), 1);
        assert!(errs[0].contains("ollama.com"));
        assert!(errs[0].contains("dns error"));
    }

    #[test]
    fn evaluate_stacks_both_failures() {
        let errs = evaluate(0, MIN_DISK_GB, false, None);
        assert_eq!(errs.len(), 2);
        // order is stable: disk first, then network
        assert!(errs[0].contains("磁盘"));
        assert!(errs[1].contains("ollama.com"));
    }

    #[test]
    fn evaluate_network_error_defaults_to_unknown() {
        let errs = evaluate(200, MIN_DISK_GB, false, None);
        assert!(errs[0].contains("未知错误"));
    }

    #[test]
    fn evaluate_exact_boundary_is_acceptable() {
        // disk_gb >= min_disk_gb is OK. Exactly equal must pass.
        let errs = evaluate(MIN_DISK_GB, MIN_DISK_GB, true, None);
        assert!(errs.is_empty());
    }

    #[test]
    fn os_label_is_nonempty_and_contains_arch_hint() {
        let label = os_label();
        assert!(!label.is_empty());
        // env::consts::ARCH yields something like "x86_64" or "aarch64";
        // both contain a digit.
        assert!(label.chars().any(|c| c.is_ascii_digit()), "label: {label}");
    }
}
