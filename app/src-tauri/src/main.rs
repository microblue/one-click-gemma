#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

// When launched with `--headless`, run the CI smoke entrypoint instead of
// booting the Tauri window. All remaining argv is parsed by `headless::run`.
//
// Also attaches a Windows console when possible so stdout/stderr land in
// the parent pwsh/cmd session — Tauri release builds compile with
// `windows_subsystem="windows"` which detaches stdio by default.
fn main() {
    let mut argv: Vec<String> = std::env::args().collect();
    if argv.iter().any(|a| a == "--headless") {
        #[cfg(windows)]
        unsafe {
            // SAFETY: AttachConsole is FFI, and we ignore the return value —
            // if we're not launched from a console we just fall back to the
            // default behavior (stdout discarded). Safe either way.
            extern "system" {
                fn AttachConsole(dw_process_id: u32) -> i32;
            }
            const ATTACH_PARENT_PROCESS: u32 = 0xFFFFFFFF;
            AttachConsole(ATTACH_PARENT_PROCESS);
        }

        // Strip program name and the --headless flag itself before parsing.
        argv.remove(0);
        argv.retain(|a| a != "--headless");
        let args = match gemma_installer::headless::parse_args(argv.iter()) {
            Ok(a) => a,
            Err(e) => {
                eprintln!("headless arg error: {e}");
                std::process::exit(2);
            }
        };
        let rt = tokio::runtime::Runtime::new().expect("tokio runtime");
        let code = rt.block_on(gemma_installer::headless::run(args));
        std::process::exit(code);
    }

    gemma_installer::run();
}
