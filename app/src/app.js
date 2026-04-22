// Gemma 4 installer — minimal SPA wizard
// Tauri v2 globals are exposed via window.__TAURI__ when invoke is enabled;
// we also import from the injected ESM shim for convenience.
const { invoke } = window.__TAURI__.core;
const { listen } = window.__TAURI__.event;

const MODEL = "gemma4:e4b";

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
  document.getElementById("progress-bar").style.width = `${pct || 0}%`;
  if (label != null) {
    document.getElementById("progress-label").textContent = label;
  }
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
// welcome + preflight
// ---------------------------------------------------------------------------
async function preflight() {
  try {
    const r = await invoke("run_preflight");

    setCheck("os", true, r.os);
    setCheck("gpu", !!r.gpu, r.gpu || "未检测到 (将用 CPU, 会慢)");
    setCheck("ram", r.ramGb >= 8, `${r.ramGb} GB`);
    setCheck("disk", r.diskGb >= r.minDiskGb, `${r.diskGb} GB 可用`);
    setCheck("net", r.networkOk, r.networkOk ? "可达 ollama.com" : "不可达");

    const errBox = document.getElementById("preflight-errors");
    if (r.errors && r.errors.length) {
      errBox.textContent = r.errors.join("\n");
      errBox.hidden = false;
    } else {
      errBox.hidden = true;
    }

    document.getElementById("btn-start").disabled = !r.ok;
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

  try {
    setInstallStep("[1/3] 安装 Ollama 运行时");
    setProgress(0, "准备下载 Ollama");
    await invoke("install_ollama");

    setInstallStep("[2/3] 启动 Ollama 服务");
    setProgress(0, "等待服务就绪…");
    const ver = await invoke("wait_ollama");
    appendLog(`Ollama ${ver} ready`);
    setProgress(100, "服务已就绪");

    setInstallStep("[3/3] 下载 Gemma 4 模型 (约 9.6 GB)");
    setProgress(0, "准备拉取 " + MODEL);
    await invoke("pull_model", { model: MODEL });

    setInstallStep("配置 OpenClaw");
    setProgress(100, "完成");
    const inj = await invoke("inject_openclaw", { model: MODEL });

    const apiUrl = await invoke("get_api_url");
    document.getElementById("api-url").textContent = apiUrl;
    renderOpenclaw(inj);

    show("done");
  } catch (e) {
    showError(String(e));
  }
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
    const reply = await invoke("send_chat_test", { model: MODEL, prompt });
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
  if (p.percent != null) setProgress(p.percent, p.message);
  if (p.message) appendLog(`[${p.stage}] ${p.message}`);
});

listen("pull:progress", (ev) => {
  const p = ev.payload;
  const mb = (b) => (b / 1048576).toFixed(0);
  if (p.total > 0) {
    setProgress(p.percent, `${p.status} · ${mb(p.completed)} / ${mb(p.total)} MB`);
  } else {
    setProgress(0, p.status);
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
show("welcome");
preflight();
