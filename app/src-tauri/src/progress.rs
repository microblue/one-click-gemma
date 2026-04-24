use serde::Serialize;
use tauri::{AppHandle, Emitter};

#[derive(Serialize, Clone)]
#[serde(rename_all = "camelCase")]
pub struct InstallPayload {
    pub stage: String,
    pub message: String,
    pub percent: Option<u8>,
}

#[derive(Serialize, Clone)]
#[serde(rename_all = "camelCase")]
pub struct PullPayload {
    pub status: String,
    pub completed: u64,
    pub total: u64,
    pub percent: u8,
}

pub trait Reporter: Send + Sync {
    fn install(&self, stage: &str, message: &str, percent: Option<u8>);
    fn pull(&self, status: &str, completed: u64, total: u64, percent: u8);
}

pub struct TauriReporter(pub AppHandle);

impl Reporter for TauriReporter {
    fn install(&self, stage: &str, message: &str, percent: Option<u8>) {
        let _ = self.0.emit(
            "install:progress",
            InstallPayload {
                stage: stage.to_string(),
                message: message.to_string(),
                percent,
            },
        );
    }
    fn pull(&self, status: &str, completed: u64, total: u64, percent: u8) {
        let _ = self.0.emit(
            "pull:progress",
            PullPayload {
                status: status.to_string(),
                completed,
                total,
                percent,
            },
        );
    }
}

pub struct StdoutReporter;

impl Reporter for StdoutReporter {
    fn install(&self, stage: &str, message: &str, percent: Option<u8>) {
        let pct = percent.map(|p| p.to_string()).unwrap_or_else(|| "--".into());
        println!("[install:{stage}] {pct}% {message}");
    }
    fn pull(&self, status: &str, completed: u64, total: u64, percent: u8) {
        if total > 0 {
            let mb = |b: u64| b / 1_048_576;
            println!(
                "[pull] {percent}% {status} ({} / {} MB)",
                mb(completed),
                mb(total)
            );
        } else {
            println!("[pull] -- {status}");
        }
    }
}
