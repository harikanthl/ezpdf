// ezpdf browser extension: talks only to the ezpdf Mac app on this Mac (127.0.0.1:7337).
// Safari exposes `browser`, Chrome `chrome`; both support promises in MV3.
// Pattern adapted from utubmp3's extension (call/route + health identity check).
const ext = globalThis.browser ?? globalThis.chrome;
const APP = "http://127.0.0.1:7337";

async function getToken() {
    const { token } = await ext.storage.local.get("token");
    return token || null;
}

async function call(path, body, { auth = true } = {}) {
    try {
        const headers = {};
        if (body !== undefined) headers["Content-Type"] = "application/json";
        const token = auth ? await getToken() : null;
        if (token) headers["X-EzPDF-Ext-Token"] = token;
        const res = await fetch(APP + path, body === undefined ? { headers } : {
            method: "POST", headers, body: JSON.stringify(body),
        });
        const json = await res.json();
        if (path.startsWith("/ext/health") && json.app !== "ezpdf") throw new Error("not ezpdf");
        if (res.status === 401 && json.pair) return { state: "unpaired", message: json.error };
        if (!res.ok) return { state: "failed", message: json.error || ("HTTP " + res.status) };
        return json;
    } catch (e) {
        return { state: "offline", message: "ezpdf isn't running." };
    }
}

// Proves the server is the real ezpdf: only it knows our token, so only it can answer the
// challenge. Nothing is sent to a program squatting on the port.
async function verifyServer() {
    const token = await getToken();
    if (!token) return false;
    const nonce = Array.from(crypto.getRandomValues(new Uint8Array(24)), (b) => b.toString(16).padStart(2, "0")).join("");
    const h = await call("/ext/health?nonce=" + nonce, undefined, { auth: false });
    if (!h || h.app !== "ezpdf" || !h.proof) return false;
    const key = await crypto.subtle.importKey("raw", new TextEncoder().encode(token), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
    const mac = await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(nonce));
    const expected = Array.from(new Uint8Array(mac), (b) => b.toString(16).padStart(2, "0")).join("");
    return expected === h.proof;
}

// First use: ezpdf asks the user to allow this extension, then hands over our own token.
async function pair() {
    const r = await call("/ext/pair", {}, { auth: false });
    if (r && r.token) { await ext.storage.local.set({ token: r.token }); return true; }
    return false;
}

async function ensurePaired() {
    if (await verifyServer()) return { ok: true };
    const h = await call("/ext/health", undefined, { auth: false });
    if (h.state === "offline") return { ok: false, offline: true };
    await ext.storage.local.remove("token");
    if (await pair() && await verifyServer()) return { ok: true };
    return { ok: false, message: "Allow the extension in the ezpdf window to continue." };
}

// The page exactly as the user sees it — works for pages behind a login.
async function capture(tabId) {
    try {
        const [r] = await ext.scripting.executeScript({
            target: { tabId },
            func: () => {
                const c = document.documentElement.cloneNode(true);
                c.querySelectorAll("script, noscript").forEach((e) => e.remove());
                return "<!doctype html>" + c.outerHTML;
            },
        });
        return r && r.result;
    } catch (e) {
        return null;
    }
}

// If the app isn't running, open it with a bare link (no request in it), wait for it, and send
// the request over the paired connection like any other.
async function launchAndWait() {
    try {
        const t = await ext.tabs.create({ url: "ezpdf://", active: false });
        setTimeout(() => ext.tabs.remove(t.id).catch(() => {}), 1500);
    } catch (e) {}
    for (let i = 0; i < 20; i++) {
        await new Promise((r) => setTimeout(r, 750));
        const h = await call("/ext/health", undefined, { auth: false });
        if (h.app === "ezpdf") return true;
    }
    return false;
}

async function run({ url, flow, preset, tabId, asSeen, title }) {
    let p = await ensurePaired();
    if (!p.ok && p.offline) {
        if (!(await launchAndWait())) return { state: "offline", message: "Couldn't open ezpdf." };
        p = await ensurePaired();
    }
    if (!p.ok) return { state: "failed", message: p.message || "ezpdf isn't connected." };
    const html = asSeen && tabId ? await capture(tabId) : null;
    return call("/ext/run", { url, flow, preset, html, title });
}

async function route(req) {
    switch (req.action) {
        case "health": return call("/ext/health", undefined, { auth: false });
        case "run": return run(req);
        case "status": return call("/ext/status?job=" + encodeURIComponent(req.job));
        case "open": return call("/ext/open", { id: req.id });
        case "reveal": return call("/ext/reveal", { path: req.path });
    }
}

ext.runtime.onMessage.addListener((req, sender, sendResponse) => {
    // Only this extension's own pages (the popup) may ask for anything.
    if (!sender || sender.id !== ext.runtime.id) return false;
    const p = route(req);
    if (!p) return false;
    p.then(sendResponse);
    return true;  // keep the channel open for the async reply
});

// Context menus: on the page, on links, and on PDFs.
const MENUS = [
    { id: "page-pdf", title: "Make PDF of This Page", contexts: ["page"], flow: "pdf" },
    { id: "page-kindle", title: "Send This Page to Kindle", contexts: ["page"], flow: "kindle" },
    { id: "page-extract", title: "Extract Statement / Invoice Data", contexts: ["page"], flow: "extract" },
    { id: "link-pdf", title: "Make PDF of Link", contexts: ["link"], flow: "pdf", link: true },
    { id: "link-kindle", title: "Send Link to Kindle", contexts: ["link"], flow: "kindle", link: true },
    { id: "link-extract", title: "Extract Data from Linked PDF", contexts: ["link"], flow: "extract", link: true },
];

ext.runtime.onInstalled.addListener(() => {
    ext.contextMenus.removeAll(() => {
        ext.contextMenus.create({ id: "ezpdf", title: "ezpdf", contexts: ["page", "link"] });
        for (const m of MENUS) ext.contextMenus.create({ id: m.id, parentId: "ezpdf", title: m.title, contexts: m.contexts });
    });
});

async function notify(text) {
    // A badge is the least intrusive signal that works in both browsers.
    try {
        await ext.action.setBadgeBackgroundColor({ color: "#E4473F" });
        await ext.action.setBadgeText({ text });
        setTimeout(() => ext.action.setBadgeText({ text: "" }), 4000);
    } catch (e) {}
}

async function runAndWatch(opts) {
    await notify("…");
    const r = await run(opts);
    if (!r.job) { await notify("!"); return; }
    for (let i = 0; i < 180; i++) {
        await new Promise((res) => setTimeout(res, 1500));
        const s = await call("/ext/status?job=" + encodeURIComponent(r.job));
        if (s.state === "done") { await notify("✓"); return; }
        if (s.state === "failed" || s.state === "offline") { await notify("!"); return; }
    }
}

ext.contextMenus.onClicked.addListener(async (info, tab) => {
    const m = MENUS.find((x) => x.id === info.menuItemId);
    if (!m) return;
    const { asSeen = false, preset = "" } = await ext.storage.local.get(["asSeen", "preset"]);
    const url = m.link ? info.linkUrl : (tab && tab.url);
    if (!url) return;
    runAndWatch({ url, flow: m.flow, preset, tabId: m.link ? null : tab.id, asSeen: !m.link && asSeen, title: m.link ? null : tab.title });
});

ext.commands && ext.commands.onCommand.addListener(async (command, tab) => {
    if (command !== "send-to-kindle") return;
    const t = tab || (await ext.tabs.query({ active: true, currentWindow: true }))[0];
    if (t && t.url) runAndWatch({ url: t.url, flow: "kindle", tabId: t.id, asSeen: false, title: t.title });
});
