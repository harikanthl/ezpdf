// ezpdf browser extension: talks only to the ezpdf Mac app on this Mac (127.0.0.1:7337).
// Safari exposes `browser`, Chrome `chrome`; both support promises in MV3.
// Pattern adapted from utubmp3's extension (call/route + health identity check).
const ext = globalThis.browser ?? globalThis.chrome;
const APP = "http://127.0.0.1:7337";

async function call(path, body) {
    try {
        const res = await fetch(APP + path, body === undefined ? {} : {
            method: "POST",
            headers: { "Content-Type": "application/json" },
            body: JSON.stringify(body),
        });
        const json = await res.json();
        // Something else could be listening on the port; only trust ezpdf.
        if (path === "/ext/health" && json.app !== "ezpdf") throw new Error("not ezpdf");
        if (!res.ok) return { state: "failed", message: json.error || ("HTTP " + res.status) };
        return json;
    } catch (e) {
        return { state: "offline", message: "ezpdf isn't running." };
    }
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

// If the app isn't running, open it through its URL scheme with the same request.
function launchApp(url, flow) {
    const link = "ezpdf://convert?flow=" + encodeURIComponent(flow) + "&url=" + encodeURIComponent(url);
    ext.tabs.create({ url: link, active: false }).then((t) => setTimeout(() => ext.tabs.remove(t.id).catch(() => {}), 1500)).catch(() => {});
}

async function run({ url, flow, preset, tabId, asSeen, title }) {
    const html = asSeen && tabId ? await capture(tabId) : null;
    const r = await call("/ext/run", { url, flow, preset, html, title });
    if (r.state === "offline") { launchApp(url, flow); return { state: "launched", message: "Opening ezpdf…" }; }
    return r;
}

async function route(req) {
    switch (req.action) {
        case "health": return call("/ext/health");
        case "run": return run(req);
        case "status": return call("/ext/status?job=" + encodeURIComponent(req.job));
        case "open": return call("/ext/open", { id: req.id });
        case "reveal": return call("/ext/reveal", { path: req.path });
    }
}

ext.runtime.onMessage.addListener((req, sender, sendResponse) => {
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
    if (!r.job) { await notify(r.state === "launched" ? "↗" : "!"); return; }
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
