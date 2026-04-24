use crate::progress::TauriReporter;
use crate::{chat_test, model_pull, ollama_install, ollama_service, openclaw, sysinfo};
use tauri::AppHandle;
use tauri_plugin_clipboard_manager::ClipboardExt;
use tauri_plugin_shell::ShellExt;

fn err<E: std::fmt::Display>(e: E) -> String {
    e.to_string()
}

#[tauri::command]
pub async fn run_preflight() -> Result<sysinfo::PreflightReport, String> {
    Ok(sysinfo::run_preflight().await)
}

#[tauri::command]
pub async fn install_ollama(app: AppHandle) -> Result<(), String> {
    let reporter = TauriReporter(app);
    ollama_install::install_ollama(&reporter).await.map_err(err)
}

#[tauri::command]
pub async fn wait_ollama() -> Result<String, String> {
    ollama_service::wait_until_ready(ollama_service::DEFAULT_ENDPOINT, 60)
        .await
        .map_err(err)
}

#[tauri::command]
pub async fn pull_model(app: AppHandle, model: String) -> Result<(), String> {
    let reporter = TauriReporter(app);
    model_pull::pull(&reporter, ollama_service::DEFAULT_ENDPOINT, &model)
        .await
        .map_err(err)
}

#[tauri::command]
pub async fn inject_openclaw(model: String) -> Result<openclaw::OpenclawInjection, String> {
    tokio::task::spawn_blocking(move || openclaw::inject(&model))
        .await
        .map_err(err)?
        .map_err(err)
}

#[tauri::command]
pub async fn send_chat_test(model: String, prompt: String) -> Result<String, String> {
    chat_test::send(ollama_service::DEFAULT_ENDPOINT, &model, &prompt)
        .await
        .map_err(err)
}

#[tauri::command]
pub async fn copy_to_clipboard(app: AppHandle, text: String) -> Result<(), String> {
    app.clipboard().write_text(text).map_err(err)
}

#[tauri::command]
pub fn get_api_url() -> String {
    format!("{}/v1", ollama_service::DEFAULT_ENDPOINT)
}

/// Open https://myclaw.one in the user's default browser. URL is hardcoded
/// so a compromised frontend can't trick us into opening arbitrary links.
#[tauri::command]
pub fn open_myclaw(app: AppHandle) -> Result<(), String> {
    // tauri-plugin-shell's Shell::open is deprecated in favor of
    // tauri-plugin-opener, but still works in 2.x and keeps the plugin
    // surface tiny. Revisit when upgrading Tauri past the deprecation cliff.
    #[allow(deprecated)]
    app.shell()
        .open("https://myclaw.one", None)
        .map_err(err)
}
