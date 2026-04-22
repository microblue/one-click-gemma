mod chat_test;
mod commands;
mod model_pull;
mod ollama_install;
mod ollama_service;
mod openclaw;
mod sysinfo;

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    tauri::Builder::default()
        .plugin(tauri_plugin_clipboard_manager::init())
        .plugin(tauri_plugin_shell::init())
        .plugin(tauri_plugin_dialog::init())
        .invoke_handler(tauri::generate_handler![
            commands::run_preflight,
            commands::install_ollama,
            commands::wait_ollama,
            commands::pull_model,
            commands::inject_openclaw,
            commands::send_chat_test,
            commands::copy_to_clipboard,
            commands::get_api_url,
        ])
        .run(tauri::generate_context!())
        .expect("error while running tauri application");
}
