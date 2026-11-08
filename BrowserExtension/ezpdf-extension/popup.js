const ext = globalThis.browser ?? globalThis.chrome;
const $ = (id) => document.getElementById(id);
let tab = null, preset = "kindle", jobDoc = null, jobPath = null, polling = null;

function send(msg) { return ext.runtime.sendMessage(msg); }

function show(el, on) {
  if (on && el.hidden) { el.hidden = false; el.classList.remove("enter"); void el.offsetWidth; el.classList.add("enter"); }
  else if (!on) el.hidden = true;
}

function setDetail(text) {
  const d = $("detail");
  if (d.textContent === text) return;
  d.classList.add("swap");                       // blur bridges the two texts
  setTimeout(() => { d.textContent = text; d.classList.remove("swap"); }, 110);
}

function choosePreset(p) {
  preset = p;
  document.querySelectorAll(".presets button").forEach((b) => b.setAttribute("aria-checked", String(b.dataset.preset === p)));
  ext.storage.local.set({ preset: p });
}

async function start(flow, url) {
  const target = url || (tab && tab.url);
  if (!target || !/^https?:/.test(target)) { finish({ state: "failed", message: "This page has no web address to convert." }); return; }
  const asSeen = !url && $("asSeen").checked;
  show($("actions"), false); show($("result"), false); show($("progress"), true);
  setDetail("Starting");
  const r = await send({ action: "run", url: target, flow, preset, tabId: url ? null : tab.id, asSeen, title: url ? null : tab.title });
  if (!r || !r.job) { finish(r || { state: "failed", message: "Something went wrong." }); return; }
  clearInterval(polling);
  polling = setInterval(async () => {
    const s = await send({ action: "status", job: r.job });
    if (s.state === "running") { setDetail(s.detail || "Working"); return; }
    clearInterval(polling);
    finish(s);
  }, 700);
}

function finish(s) {
  show($("progress"), false);
  const ok = s.state === "done";
  $("message").textContent = s.message || (ok ? "Done" : "Something went wrong.");
  $("message").classList.toggle("err", !ok);
  jobDoc = s.document || null; jobPath = s.path || null;
  $("open").hidden = !jobDoc; $("reveal").hidden = !jobPath;
  show($("result"), true);
}

async function init() {
  [tab] = await ext.tabs.query({ active: true, currentWindow: true });
  if (tab) {
    $("title").textContent = tab.title || "This page";
    try { $("host").textContent = new URL(tab.url).host; } catch (e) { $("host").textContent = ""; }
    $("launch").href = "ezpdf://";
  }
  const saved = await ext.storage.local.get(["preset", "asSeen"]);
  $("asSeen").checked = !!saved.asSeen;
  const h = await send({ action: "health" });
  const online = h && h.app === "ezpdf";
  $("status").className = "status " + (online ? "on" : "off");
  $("status").title = online ? "Connected to ezpdf" : "ezpdf isn't running";
  show($("offline"), !online);
  if (online && h.paired === false) $("message").textContent = "";
  choosePreset(saved.preset || (h && h.preset) || "kindle");
  $("kindle").title = h && h.kindle === false ? "Add your Kindle address in ezpdf Settings first" : "Email to your Kindle";
}

document.querySelectorAll(".presets button").forEach((b) => b.addEventListener("click", () => choosePreset(b.dataset.preset)));
$("pdf").addEventListener("click", () => start("pdf"));
document.querySelectorAll("[data-flow]").forEach((b) => b.addEventListener("click", () => start(b.dataset.flow)));
$("asSeen").addEventListener("change", (e) => ext.storage.local.set({ asSeen: e.target.checked }));
$("open").addEventListener("click", () => { send({ action: "open", id: jobDoc }); window.close(); });
$("reveal").addEventListener("click", () => send({ action: "reveal", path: jobPath }));
$("again").addEventListener("click", () => { show($("result"), false); show($("actions"), true); });
document.addEventListener("keydown", (e) => { if (e.key === "Enter" && !$("actions").hidden) start("pdf"); });

// Drop a link (from the page, the address bar, or another app) onto the popup.
const drop = $("drop");
["dragenter", "dragover"].forEach((t) => document.addEventListener(t, (e) => { e.preventDefault(); drop.classList.add("over"); }));
["dragleave", "drop"].forEach((t) => document.addEventListener(t, (e) => { e.preventDefault(); if (t === "drop" || e.target === drop) drop.classList.remove("over"); }));
document.addEventListener("drop", (e) => {
  const text = e.dataTransfer.getData("text/uri-list") || e.dataTransfer.getData("text/plain") || "";
  const url = text.split(/\s+/).find((t) => /^https?:\/\//.test(t));
  if (url) start("pdf", url);
});

init();
