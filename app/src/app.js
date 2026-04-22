// Gemma 4 installer — minimal SPA wizard
// Tauri v2 requires app.withGlobalTauri=true in tauri.conf.json for this to work.
const { invoke } = window.__TAURI__.core;
const { listen } = window.__TAURI__.event;

// Curated from smallest to largest; sizes from ollama.com/library.
// We skip Gemma 4 E4B and above (too large for the "one-click for everyone"
// positioning) and include Gemma 3 small variants so users with modest
// disks/GPUs have a usable option.
const MODELS = [
  { id: "gemma3:270m", name: "Gemma 3 270M", sizeGB: 0.3,
    desc: "超轻量 (~292 MB), 只适合试水 / 最低配" },
  { id: "gemma3:1b",   name: "Gemma 3 1B",   sizeGB: 0.9,
    desc: "实用级最小 (815 MB), 手机 / 老笔记本" },
  { id: "gemma3:4b",   name: "Gemma 3 4B",   sizeGB: 3.3,
    desc: "平衡之选 (3.3 GB), 大多数设备" },
  { id: "gemma4:e2b",  name: "Gemma 4 E2B",  sizeGB: 7.2, recommended: true,
    desc: "最新架构, 多模态 (7.2 GB), 生产推荐" },
];
let selectedModel = MODELS.find(m => m.recommended) || MODELS[0];

// Ollama runtime itself is ~200MB, leave a few GB of working headroom
// after the model lands.
const DISK_HEADROOM_GB = 3;
const diskNeeded = () => Math.ceil(selectedModel.sizeGB + DISK_HEADROOM_GB);

// Each install phase owns a contiguous slice of the global 0-100% bar.
// Weights reflect time cost: Ollama download ~30s, service warm <5s,
// model pull (multi-GB) dominates, OpenClaw write <1s.
const STEP_RANGES = {
  install: [0, 25],   // download + install Ollama
  service: [25, 30],  // wait for /api/version
  pull:    [30, 97],  // the long pole
  config:  [97, 100], // write OpenClaw config
};
let currentRange = STEP_RANGES.install;

// Cache the last preflight report so we can re-evaluate disk viability when
// the user switches models without re-running the probe.
let lastPreflight = null;

const screens = {
  welcome:  document.querySelector('[data-screen="welcome"]'),
  install:  document.querySelector('[data-screen="install"]'),
  done:     document.querySelector('[data-screen="done"]'),
  error:    document.querySelector('[data-screen="error"]'),
};

function show(name) {
  for (const [k, el] of Object.entries(screens)) {
    el.hidden = k !== name;
  }
}

function setCheck(item, ok, value) {
  const row = document.querySelector(`[data-item="${item}"]`);
  if (!row) return;
  row.querySelector(".value").textContent = value;
  const dot = row.querySelector(".dot");
  dot.classList.remove("ok", "err");
  dot.classList.add(ok ? "ok" : "err");
}

function setProgress(pct, label) {
  const clamped = Math.max(0, Math.min(100, Math.round(pct || 0)));
  document.getElementById("progress-bar").style.width = `${clamped}%`;
  document.getElementById("progress-pct").textContent = `${clamped}%`;
  if (label != null) {
    document.getElementById("progress-label").textContent = label;
  }
}

// Map a 0-100 percent within the current step to a 0-100 percent on the
// global bar. Also nudges the bar forward monotonically.
function setGlobalFromLocal(localPct, label) {
  const [lo, hi] = currentRange;
  const g = lo + (Math.max(0, Math.min(100, localPct)) / 100) * (hi - lo);
  setProgress(g, label);
}

function setInstallStep(stepText) {
  document.getElementById("install-step").textContent = stepText;
}

function appendLog(line) {
  const log = document.getElementById("install-log");
  log.textContent += line + "\n";
  log.scrollTop = log.scrollHeight;
}

function showError(message) {
  document.getElementById("error-text").textContent = message;
  show("error");
}

// ---------------------------------------------------------------------------
// model picker
// ---------------------------------------------------------------------------
function renderModelPicker() {
  const root = document.getElementById("model-options");
  root.innerHTML = "";
  MODELS.forEach(m => {
    const el = document.createElement("button");
    el.type = "button";
    el.className = "model-opt" + (m === selectedModel ? " selected" : "");
    el.dataset.id = m.id;
    el.innerHTML = `
      <div class="m-name">
        <span>${m.name}${m.recommended ? '<span class="m-badge">推荐</span>' : ''}</span>
        <span class="m-size">${m.sizeGB} GB</span>
      </div>
      <div class="m-desc">${m.desc}</div>
    `;
    el.addEventListener("click", () => {
      selectedModel = m;
      document.querySelectorAll(".model-opt").forEach(n => n.classList.toggle("selected", n.dataset.id === m.id));
      reevaluate();
    });
    root.appendChild(el);
  });
}

function updateSummary() {
  const el = document.getElementById("install-summary");
  if (el) el.textContent =
    `将安装 Ollama 运行时 + ${selectedModel.name} 模型`;
}

// Re-evaluate viability with the cached preflight + currently selected model.
function reevaluate() {
  updateSummary();
  if (!lastPreflight) return;
  renderPreflight(lastPreflight);
}

function renderPreflight(r) {
  const need = diskNeeded();
  const errs = [];

  setCheck("os", true, r.os);
  setCheck("gpu", !!r.gpu, r.gpu || "未检测到 (将用 CPU, 会慢)");
  const ramOk = r.ramGb >= 8;
  setCheck("ram", ramOk, `${r.ramGb} GB`);
  const diskOk = r.diskGb >= need;
  setCheck("disk", diskOk, `${r.diskGb} GB 可用 (需 ${need} GB)`);
  if (!diskOk) errs.push(`磁盘可用 ${r.diskGb} GB, 安装 ${selectedModel.name} 至少需要 ${need} GB`);
  setCheck("net", r.networkOk,
    r.networkOk ? "可达 ollama.com" : `不可达: ${r.networkError || "未知"}`);
  if (!r.networkOk) errs.push(`无法连接 ollama.com (${r.networkError || "未知"})`);

  const errBox = document.getElementById("preflight-errors");
  if (errs.length) {
    errBox.textContent = errs.join("\n");
    errBox.hidden = false;
  } else {
    errBox.hidden = true;
  }

  document.getElementById("btn-start").disabled = errs.length > 0;
}

// ---------------------------------------------------------------------------
// welcome + preflight
// ---------------------------------------------------------------------------
async function preflight() {
  try {
    lastPreflight = await invoke("run_preflight");
    renderPreflight(lastPreflight);
  } catch (e) {
    showError("体检失败: " + e);
  }
}

// ---------------------------------------------------------------------------
// install pipeline
// ---------------------------------------------------------------------------
async function runInstall() {
  show("install");
  setProgress(0, "准备中…");
  const model = selectedModel.id;

  try {
    currentRange = STEP_RANGES.install;
    setInstallStep("[1/4] 安装 Ollama 运行时");
    setGlobalFromLocal(0, "准备下载 Ollama");
    await invoke("install_ollama");
    setGlobalFromLocal(100, "Ollama 已安装");

    currentRange = STEP_RANGES.service;
    setInstallStep("[2/4] 启动 Ollama 服务");
    setGlobalFromLocal(0, "等待服务就绪…");
    const ver = await invoke("wait_ollama");
    appendLog(`Ollama ${ver} ready`);
    setGlobalFromLocal(100, "服务已就绪");

    currentRange = STEP_RANGES.pull;
    setInstallStep(`[3/4] 下载 ${selectedModel.name} 模型 (${selectedModel.sizeGB} GB)`);
    setGlobalFromLocal(0, "准备拉取 " + model);
    await invoke("pull_model", { model });
    setGlobalFromLocal(100, "模型已就位");

    currentRange = STEP_RANGES.config;
    setInstallStep("[4/4] 接入 OpenClaw");
    setGlobalFromLocal(0, "写入 provider 配置…");
    const inj = await invoke("inject_openclaw", { model });

    setProgress(100, "完成");
    const apiUrl = await invoke("get_api_url");
    document.getElementById("api-url").textContent = apiUrl;
    renderOpenclaw(inj);
    renderPrompt(model);

    show("done");
  } catch (e) {
    showError(String(e));
  }
}

function renderPrompt(model) {
  const prompt = buildOpenclawPrompt(model);
  document.getElementById("openclaw-prompt").textContent = prompt;
  document.getElementById("btn-copy-prompt").onclick = async () => {
    await invoke("copy_to_clipboard", { text: prompt });
    const btn = document.getElementById("btn-copy-prompt");
    const old = btn.textContent;
    btn.textContent = "已复制 ✓";
    setTimeout(() => btn.textContent = old, 1500);
  };
}

function buildOpenclawPrompt(model) {
  return `你好 OpenClaw，我刚在本机装好了 ${model} 模型，通过 Ollama 暴露了 OpenAI 兼容的 API。

请帮我把下面这个 LLM provider 加到你的设置里，并把默认模型切换到它：

  · 名称 (name)       : local-gemma4
  · 端点 (baseURL)    : http://127.0.0.1:11434/v1
  · API Key           : ollama
  · 模型 ID           : ${model}
  · 上下文窗口        : 128K
  · 多模态 (vision)   : 是

配置文件位置 (按当前操作系统选其一)：
  · macOS   : ~/Library/Application Support/OpenClaw/config.json
  · Linux   : ~/.openclaw/config.json 或 ~/.config/openclaw/config.json
  · Windows : %APPDATA%\\OpenClaw\\config.json

在根对象的 customProviders 数组里 upsert 这一条 (按 name 去重),
保留其他 providers 不动。

完成后请重启 OpenClaw 或执行 /reload, 并发一条 "你好, 我是 ${model}" 的测试消息确认通路。`;
}

function renderOpenclaw(inj) {
  const box = document.getElementById("openclaw-block");
  box.classList.toggle("ok", inj.injected);
  if (inj.injected) {
    box.innerHTML = `
      <div class="status">已检测到 OpenClaw, 配置已自动写入</div>
      <div class="path">${escapeHtml(inj.configPath)}</div>
    `;
  } else {
    const provider = inj.providerJson;
    box.innerHTML = `
      <div class="status">未检测到 OpenClaw, 配置已复制到剪贴板</div>
      <div class="path">粘贴到 OpenClaw 设置 → customProviders 里即可</div>
      <div class="copy-row">
        <input type="text" readonly value='${escapeAttr(provider.slice(0, 200))}…' />
        <button class="btn" id="btn-copy-again">复制 JSON</button>
      </div>
    `;
    document.getElementById("btn-copy-again").onclick = async () => {
      await invoke("copy_to_clipboard", { text: provider });
      document.getElementById("btn-copy-again").textContent = "已复制 ✓";
    };
    // also copy immediately
    invoke("copy_to_clipboard", { text: provider }).catch(() => {});
  }
}

function escapeHtml(s) {
  return String(s).replace(/[&<>"']/g, c => ({
    '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;'
  }[c]));
}
function escapeAttr(s) { return escapeHtml(s); }

// ---------------------------------------------------------------------------
// chat test panel
// ---------------------------------------------------------------------------
async function sendChat(prompt) {
  const out = document.getElementById("chat-output");
  out.textContent = "（正在生成…）";
  try {
    const reply = await invoke("send_chat_test", { model: selectedModel.id, prompt });
    out.textContent = reply;
  } catch (e) {
    out.textContent = "失败: " + e;
  }
}

// ---------------------------------------------------------------------------
// progress event subscription
// ---------------------------------------------------------------------------
listen("install:progress", (ev) => {
  const p = ev.payload;
  if (p.percent != null) setGlobalFromLocal(p.percent, p.message);
  if (p.message) appendLog(`[${p.stage}] ${p.message}`);
});

listen("pull:progress", (ev) => {
  const p = ev.payload;
  const mb = (b) => (b / 1048576).toFixed(0);
  if (p.total > 0) {
    setGlobalFromLocal(p.percent, `${p.status} · ${mb(p.completed)} / ${mb(p.total)} MB`);
  } else if (p.status) {
    // non-download phases (pulling manifest, verifying digest, writing manifest) — tick slowly
    setGlobalFromLocal(0, p.status);
  }
});

// ---------------------------------------------------------------------------
// bindings
// ---------------------------------------------------------------------------
document.getElementById("btn-start").addEventListener("click", runInstall);

document.getElementById("btn-toggle-log").addEventListener("click", (e) => {
  const log = document.getElementById("install-log");
  log.hidden = !log.hidden;
  e.target.textContent = log.hidden ? "显示详细日志" : "隐藏详细日志";
});

document.getElementById("btn-test").addEventListener("click", () => {
  const panel = document.getElementById("chat-panel");
  panel.hidden = !panel.hidden;
  if (!panel.hidden) document.getElementById("chat-input").focus();
});
document.getElementById("btn-send").addEventListener("click", () => {
  const v = document.getElementById("chat-input").value.trim();
  if (v) sendChat(v);
});
document.getElementById("chat-input").addEventListener("keydown", (e) => {
  if (e.key === "Enter") document.getElementById("btn-send").click();
});

document.getElementById("btn-finish").addEventListener("click", () => {
  window.close?.();
});

document.getElementById("btn-retry").addEventListener("click", () => {
  show("welcome");
  preflight();
});
document.getElementById("btn-quit").addEventListener("click", () => {
  window.close?.();
});

// ---------------------------------------------------------------------------
// boot
// ---------------------------------------------------------------------------
renderModelPicker();
updateSummary();
show("welcome");
preflight();
