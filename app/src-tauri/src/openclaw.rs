use anyhow::{Context, Result};
use serde::Serialize;
use serde_json::{json, Value};
use std::path::PathBuf;

#[derive(Serialize, Clone)]
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
    let provider = build_provider_json(model);
    let provider_pretty = serde_json::to_string_pretty(&provider)?;

    let cfg = match locate_config() {
        Some(p) => p,
        None => {
            return Ok(OpenclawInjection {
                injected: false,
                config_path: None,
                provider_json: provider_pretty,
            });
        }
    };

    let raw = std::fs::read_to_string(&cfg).context("read openclaw config")?;
    let mut root: Value = serde_json::from_str(&raw)
        .with_context(|| format!("openclaw config at {} is not valid JSON", cfg.display()))?;
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

    let tmp = cfg.with_extension("json.tmp");
    std::fs::write(&tmp, serde_json::to_string_pretty(&root)?)
        .context("write openclaw config tmp")?;
    std::fs::rename(&tmp, &cfg).context("rename openclaw config tmp -> final")?;

    Ok(OpenclawInjection {
        injected: true,
        config_path: Some(cfg.to_string_lossy().into_owned()),
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
