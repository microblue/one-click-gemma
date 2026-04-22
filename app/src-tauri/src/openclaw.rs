use anyhow::{Context, Result};
use serde::Serialize;
use serde_json::{json, Value};
use std::path::{Path, PathBuf};

#[derive(Debug, Serialize, Clone)]
#[serde(rename_all = "camelCase")]
pub struct OpenclawInjection {
    pub injected: bool,
    pub config_path: Option<String>,
    pub provider_json: String,
}

pub fn build_provider_json(model: &str) -> Value {
    json!({
        "name": "local-gemma4",
        "baseURL": "http://127.0.0.1:11434/v1",
        "apiKey": "ollama",
        "models": [
            {
                "id": model,
                "name": "Gemma 4 (Local)",
                "contextWindow": 131072,
                "supportsVision": true
            }
        ]
    })
}

pub fn inject(model: &str) -> Result<OpenclawInjection> {
    match locate_config() {
        Some(path) => inject_to(&path, model),
        None => Ok(OpenclawInjection {
            injected: false,
            config_path: None,
            provider_json: serde_json::to_string_pretty(&build_provider_json(model))?,
        }),
    }
}

/// Upsert the local-gemma4 provider into the OpenClaw config at `path`.
/// Idempotent — repeated calls leave exactly one `local-gemma4` entry.
/// Preserves any sibling keys and other providers in the file.
pub fn inject_to(path: &Path, model: &str) -> Result<OpenclawInjection> {
    let provider = build_provider_json(model);
    let provider_pretty = serde_json::to_string_pretty(&provider)?;

    let raw = std::fs::read_to_string(path).context("read openclaw config")?;
    let mut root: Value = serde_json::from_str(&raw)
        .with_context(|| format!("openclaw config at {} is not valid JSON", path.display()))?;
    if !root.is_object() {
        anyhow::bail!("openclaw config root is not a JSON object");
    }

    let providers = root
        .as_object_mut()
        .unwrap()
        .entry("customProviders")
        .or_insert_with(|| Value::Array(Vec::new()));

    let arr = providers
        .as_array_mut()
        .ok_or_else(|| anyhow::anyhow!("customProviders is not an array"))?;

    arr.retain(|p| p.get("name").and_then(|v| v.as_str()) != Some("local-gemma4"));
    arr.push(provider.clone());

    let tmp = path.with_extension("json.tmp");
    std::fs::write(&tmp, serde_json::to_string_pretty(&root)?)
        .context("write openclaw config tmp")?;
    std::fs::rename(&tmp, path).context("rename openclaw config tmp -> final")?;

    Ok(OpenclawInjection {
        injected: true,
        config_path: Some(path.to_string_lossy().into_owned()),
        provider_json: provider_pretty,
    })
}

fn locate_config() -> Option<PathBuf> {
    if let Ok(dir) = std::env::var("OPENCLAW_CONFIG_DIR") {
        let p = PathBuf::from(dir).join("config.json");
        if p.is_file() {
            return Some(p);
        }
    }

    let home = directories::UserDirs::new().map(|u| u.home_dir().to_path_buf())?;
    let candidates: Vec<PathBuf> = vec![
        home.join(".openclaw").join("config.json"),
        home.join(".config").join("openclaw").join("config.json"),
        #[cfg(target_os = "macos")]
        home.join("Library/Application Support/OpenClaw/config.json"),
        #[cfg(target_os = "windows")]
        PathBuf::from(std::env::var("APPDATA").unwrap_or_default())
            .join("OpenClaw")
            .join("config.json"),
    ];

    candidates.into_iter().find(|p| p.is_file())
}

// ---------------------------------------------------------------------------
#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::atomic::{AtomicU64, Ordering};

    static COUNTER: AtomicU64 = AtomicU64::new(0);

    /// Writes `contents` to a fresh unique temp file and returns its path.
    /// The file is created inside std::env::temp_dir() so it survives the
    /// test and can be inspected on failure.
    fn fresh_tmp(contents: &str) -> PathBuf {
        let n = COUNTER.fetch_add(1, Ordering::SeqCst);
        let path = std::env::temp_dir().join(format!(
            "openclaw-test-{}-{}-{}.json",
            std::process::id(),
            n,
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        std::fs::write(&path, contents).expect("seed temp file");
        path
    }

    // ---- build_provider_json -------------------------------------------------
    #[test]
    fn build_provider_json_has_correct_shape() {
        let v = build_provider_json("gemma4:e4b");
        assert_eq!(v["name"], "local-gemma4");
        assert_eq!(v["baseURL"], "http://127.0.0.1:11434/v1");
        assert_eq!(v["apiKey"], "ollama");
        assert_eq!(v["models"][0]["id"], "gemma4:e4b");
        assert_eq!(v["models"][0]["contextWindow"], 131072);
        assert_eq!(v["models"][0]["supportsVision"], true);
    }

    #[test]
    fn build_provider_json_honors_model_parameter() {
        let v = build_provider_json("gemma4:26b");
        assert_eq!(v["models"][0]["id"], "gemma4:26b");
    }

    // ---- inject_to happy paths ----------------------------------------------
    #[test]
    fn injects_into_empty_object_by_creating_array() {
        let p = fresh_tmp("{}");
        let r = inject_to(&p, "gemma4:e4b").unwrap();
        assert!(r.injected);
        let after: Value = serde_json::from_str(&std::fs::read_to_string(&p).unwrap()).unwrap();
        let arr = after["customProviders"].as_array().unwrap();
        assert_eq!(arr.len(), 1);
        assert_eq!(arr[0]["name"], "local-gemma4");
        std::fs::remove_file(&p).ok();
    }

    #[test]
    fn injects_preserving_siblings() {
        let p = fresh_tmp(r#"{
            "theme": "dark",
            "hotkeys": {"submit": "cmd+enter"},
            "customProviders": [
                {"name": "openai-main", "baseURL": "https://api.openai.com/v1", "apiKey": "sk-x"}
            ]
        }"#);
        let r = inject_to(&p, "gemma4:e4b").unwrap();
        assert!(r.injected);
        let after: Value = serde_json::from_str(&std::fs::read_to_string(&p).unwrap()).unwrap();
        assert_eq!(after["theme"], "dark");
        assert_eq!(after["hotkeys"]["submit"], "cmd+enter");
        let names: Vec<&str> = after["customProviders"]
            .as_array().unwrap()
            .iter().map(|p| p["name"].as_str().unwrap()).collect();
        assert_eq!(names, vec!["openai-main", "local-gemma4"]);
        std::fs::remove_file(&p).ok();
    }

    #[test]
    fn upserts_existing_local_gemma4_entry() {
        let p = fresh_tmp(r#"{
            "customProviders": [
                {"name": "other", "baseURL": "https://x", "apiKey": "y"},
                {"name": "local-gemma4", "baseURL": "http://stale", "apiKey": "OLD", "models": []}
            ]
        }"#);
        let r = inject_to(&p, "gemma4:e4b").unwrap();
        assert!(r.injected);
        let after: Value = serde_json::from_str(&std::fs::read_to_string(&p).unwrap()).unwrap();
        let arr = after["customProviders"].as_array().unwrap();
        assert_eq!(arr.len(), 2, "should stay 2 providers, not duplicate");
        let gemma = arr.iter().find(|p| p["name"] == "local-gemma4").unwrap();
        assert_eq!(gemma["apiKey"], "ollama", "stale apiKey should be overwritten");
        assert_eq!(gemma["baseURL"], "http://127.0.0.1:11434/v1");
        assert_eq!(gemma["models"][0]["id"], "gemma4:e4b");
        std::fs::remove_file(&p).ok();
    }

    #[test]
    fn upsert_is_idempotent_across_multiple_runs() {
        let p = fresh_tmp("{}");
        for _ in 0..4 {
            inject_to(&p, "gemma4:e4b").unwrap();
        }
        let after: Value = serde_json::from_str(&std::fs::read_to_string(&p).unwrap()).unwrap();
        assert_eq!(after["customProviders"].as_array().unwrap().len(), 1);
        std::fs::remove_file(&p).ok();
    }

    // ---- inject_to error paths ----------------------------------------------
    #[test]
    fn fails_on_malformed_json() {
        let p = fresh_tmp("{ not valid json ]");
        let err = inject_to(&p, "gemma4:e4b").unwrap_err().to_string();
        assert!(
            err.contains("not valid JSON") || err.to_lowercase().contains("expected"),
            "error message should mention invalid JSON, got: {err}"
        );
        // the malformed file must not be overwritten
        assert_eq!(std::fs::read_to_string(&p).unwrap(), "{ not valid json ]");
        std::fs::remove_file(&p).ok();
    }

    #[test]
    fn fails_when_root_is_an_array() {
        let p = fresh_tmp(r#"["whoops", "this is not an object"]"#);
        let err = inject_to(&p, "gemma4:e4b").unwrap_err().to_string();
        assert!(err.contains("root is not a JSON object"), "got: {err}");
        std::fs::remove_file(&p).ok();
    }

    #[test]
    fn fails_when_customProviders_is_wrong_type() {
        let p = fresh_tmp(r#"{"customProviders": "oops-a-string"}"#);
        let err = inject_to(&p, "gemma4:e4b").unwrap_err().to_string();
        assert!(err.contains("customProviders is not an array"), "got: {err}");
        std::fs::remove_file(&p).ok();
    }

    #[test]
    fn fails_when_file_does_not_exist() {
        let missing = std::env::temp_dir().join(format!(
            "openclaw-definitely-missing-{}-{}.json",
            std::process::id(),
            COUNTER.fetch_add(1, Ordering::SeqCst)
        ));
        let err = inject_to(&missing, "gemma4:e4b").unwrap_err().to_string();
        assert!(
            err.contains("read openclaw config"),
            "error should mention reading config, got: {err}"
        );
    }

    // ---- atomic write invariant ---------------------------------------------
    #[test]
    fn does_not_leave_tmp_file_behind_on_success() {
        let p = fresh_tmp("{}");
        inject_to(&p, "gemma4:e4b").unwrap();
        let tmp = p.with_extension("json.tmp");
        assert!(!tmp.exists(), "temp file {tmp:?} should be cleaned up");
        std::fs::remove_file(&p).ok();
    }

    #[test]
    fn inject_fallback_reports_not_injected_with_valid_json_payload() {
        // Drive the no-config branch of the public `inject` by clearing env overrides
        // and pointing HOME at a directory that contains no OpenClaw config. This
        // exercises the 'copy JSON to clipboard' side of the product.
        let stash_home = std::env::var_os("HOME");
        let stash_env = std::env::var_os("OPENCLAW_CONFIG_DIR");
        let empty_home = std::env::temp_dir().join(format!(
            "openclaw-empty-home-{}-{}",
            std::process::id(),
            COUNTER.fetch_add(1, Ordering::SeqCst)
        ));
        std::fs::create_dir_all(&empty_home).unwrap();
        // SAFETY: tests in this crate run single-threaded through this env swap
        // because they share process global state; we restore below.
        std::env::remove_var("OPENCLAW_CONFIG_DIR");
        std::env::set_var("HOME", &empty_home);

        let r = inject("gemma4:e4b").unwrap();

        // restore
        match stash_home {
            Some(v) => std::env::set_var("HOME", v),
            None => std::env::remove_var("HOME"),
        }
        if let Some(v) = stash_env { std::env::set_var("OPENCLAW_CONFIG_DIR", v); }
        std::fs::remove_dir_all(&empty_home).ok();

        assert!(!r.injected);
        assert!(r.config_path.is_none());
        let v: Value = serde_json::from_str(&r.provider_json).unwrap();
        assert_eq!(v["name"], "local-gemma4");
        assert_eq!(v["models"][0]["id"], "gemma4:e4b");
    }
}
