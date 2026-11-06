/* Ed.Board Bridge. GPL-3.0-only; see the Ed.Board repository LICENSE.
 * This file is both the source and the installable plugin. No build step.
 */
"use strict";
const { Plugin, PluginSettingTab, Setting } = require("obsidian");
const http = require("node:http");
const fs = require("node:fs");
const path = require("node:path");
const os = require("node:os");
const crypto = require("node:crypto");
const PORT = 27124;
const secretPattern = /^[a-f0-9]{64}$/;

// Outside the vault: no token, file name or vault path is written to plugin data.json.
function credentialPath() {
    if (os.platform() !== "darwin") throw new Error("macOS required");
    return path.join(os.homedir(), "Library", "Application Support", "Ed.Board", "ObsidianBridge", "client.json");
}
function readCredential() {
    try {
        const file = credentialPath();
        if (fs.lstatSync(file).isSymbolicLink() || fs.statSync(file).size > 1024) return null;
        const value = JSON.parse(fs.readFileSync(file, "utf8"));
        return secretPattern.test(value.token) ? value.token : null;
    } catch (_) { return null; }
}
function writeCredential(token) {
    if (token !== null && !secretPattern.test(token)) throw new Error("Invalid credential");
    const file = credentialPath();
    if (token === null) { try { fs.unlinkSync(file); } catch (e) { if (e.code !== "ENOENT") throw e; } return; }
    fs.mkdirSync(path.dirname(file), { recursive: true, mode: 0o700 });
    const temporary = file + "." + crypto.randomBytes(8).toString("hex") + ".tmp";
    try {
        fs.writeFileSync(temporary, JSON.stringify({ token }), { mode: 0o600, flag: "wx" });
        fs.renameSync(temporary, file);
    } finally { try { fs.unlinkSync(temporary); } catch (_) { /* already renamed */ } }
}
function request(route, token, body) {
    return new Promise((resolve, reject) => {
        const data = Buffer.from(JSON.stringify(body));
        const req = http.request({ hostname: "127.0.0.1", port: PORT, path: route, method: "POST", agent: false,
            headers: { "Host": "127.0.0.1:" + PORT, "Authorization": "Bearer " + token,
                "Content-Type": "application/json", "Content-Length": data.length, "Connection": "close" } }, res => {
            let chunks = [], length = 0;
            res.on("data", chunk => { length += chunk.length; if (length > 2048) req.destroy(new Error("Response too large")); else chunks.push(chunk); });
            res.on("end", () => {
                try { resolve({ status: res.statusCode, body: JSON.parse(Buffer.concat(chunks).toString("utf8")) }); }
                catch (_) { reject(new Error("Invalid local response")); }
            });
            res.on("error", reject);
        });
        req.setTimeout(2000, () => req.destroy(new Error("Local connection timed out")));
        req.on("error", reject); req.end(data);
    });
}
// Classify the focused editor, including popout windows; never read file paths/content.
function focusedView(app) {
    const leaf = app.workspace.getMostRecentLeaf();
    if (!leaf || !leaf.view || !leaf.view.containerEl.ownerDocument.hasFocus()) return null;
    const type = leaf.view.getViewType();
    if (type === "excalidraw-loading") return null;
    return type === "excalidraw" ? "excalidraw" : type === "markdown" ? "markdown" : "other";
}
class BridgeSettings extends PluginSettingTab {
    constructor(app, plugin) { super(app, plugin); this.plugin = plugin; }
    display() {
        const root = this.containerEl; root.empty(); root.createEl("h2", { text: "Ed.Board Bridge" });
        root.createEl("p", { text: this.plugin.status });
        root.createEl("p", { text: "In Ed.Board, open Settings → Plugins → Obsidian, enable it and choose Pair. Paste the pairing code below. No note contents or file names are sent." });
        let code = "";
        new Setting(root).setName("Pairing code").addText(text => text.setPlaceholder("Paste Ed.Board pairing code").onChange(value => { code = value.trim(); }));
        new Setting(root).addButton(button => button.setButtonText("Pair").onClick(async () => {
            button.setDisabled(true);
            await this.plugin.pair(code); code = ""; this.display();
        }));
        new Setting(root).setName("Disconnect").setDesc("Remove the shared credential for all vaults on this Mac. Layer mappings in Ed.Board are kept.")
            .addButton(button => button.setButtonText("Disconnect this Mac").onClick(async () => { await this.plugin.disconnect(); this.display(); }));
        root.createEl("p", { text: "The connection stays on this Mac. Enable it only for vaults where you want integration. Ed.Board must remain running." });
    }
}
module.exports = class EdBoardBridge extends Plugin {
    async onload() {
        this.token = readCredential(); this.client = crypto.randomBytes(16).toString("hex");
        this.status = this.token ? "Waiting for Ed.Board" : "Not paired";
        this.inFlight = false; this.pending = false; this.stopped = false; this.generation = 0;
        this.focused = false; this.focus = 0; this.sequence = 0; this.pairing = false; this.retryTimer = null;
        this.addSettingTab(new BridgeSettings(this.app, this));
        for (const event of ["active-leaf-change", "layout-change", "file-open"]) {
            this.registerEvent(this.app.workspace.on(event, () => this.schedule()));
        }
        const attach = win => {
            this.registerDomEvent(win, "focus", () => { this.focused = false; this.schedule(); });
            this.registerDomEvent(win, "blur", () => { this.focused = false; this.pending = false; });
        };
        attach(window);
        this.registerEvent(this.app.workspace.on("window-open", win => attach(win.win)));
        this.registerInterval(window.setInterval(() => this.schedule(), 5000));
        this.app.workspace.onLayoutReady(() => this.schedule());
    }
    async pair(code) {
        const match = /^edboard1:([a-f0-9]{64})$/.exec(code);
        if (!match) { this.status = "Paste a valid pairing code from Ed.Board."; return; }
        const generation = ++this.generation;
        this.token = null; this.pairing = true;
        try {
            const reply = await request("/v1/pair", match[1], {});
            if (this.stopped || generation !== this.generation) return;
            if (reply.status !== 200 || !secretPattern.test(reply.body.token)) {
                this.status = "Pairing failed. Generate a fresh code in Ed.Board and try again."; return;
            }
            writeCredential(reply.body.token); this.token = reply.body.token;
            this.status = "Paired on this Mac. Other enabled vaults share this pairing.";
        } catch (_) { if (!this.stopped && generation === this.generation) this.status = "Could not pair. Check that Ed.Board integration is on and try a fresh code."; }
        finally { if (generation === this.generation) { this.pairing = false; this.schedule(); } }
    }
    schedule() {
        if (this.stopped || this.pairing) return;
        if (focusedView(this.app) === null) { this.focused = false; this.pending = false; return; }
        // Every focused vault sees a new/revoked Mac-wide pairing, without
        // per-vault registration, vault identifiers or data.json settings.
        const shared = readCredential();
        if (shared !== this.token) { this.token = shared; ++this.generation; }
        if (!this.token) { this.status = "Not paired"; return; }
        if (!this.focused) { this.focus = Date.now(); this.focused = true; }
        this.pending = true;
        if (!this.inFlight) void this.flush();
    }
    async flush() {
        if (this.inFlight || this.stopped || !this.token || this.pairing) return;
        this.pending = false;
        const view = focusedView(this.app);
        if (view === null) { this.focused = false; return; }
        this.inFlight = true;
        const token = this.token, generation = this.generation, focus = this.focus;
        const operation = request("/v2/view", token, { client: this.client, view, focus, sequence: ++this.sequence });
        this.outstanding = operation;
        try {
            const reply = await operation;
            if (this.stopped || generation !== this.generation) return;
            if (reply.status === 200) { this.status = "Connected"; }
            else if (reply.status === 409) {
                // Equal millisecond focus timestamps or a delayed App foreground
                // notification are retried only by the window that is still focused.
                if (focus === this.focus && focusedView(this.app) !== null && this.retryTimer === null) {
                    this.retryTimer = window.setTimeout(() => {
                        this.retryTimer = null;
                        if (!this.stopped && focus === this.focus && focusedView(this.app) !== null) {
                            this.focus = Math.max(Date.now(), focus + 1); this.schedule();
                        }
                    }, 250);
                }
                this.status = "Waiting for the focused window";
            } else if (reply.status === 401) {
                this.token = null; this.status = "Pairing revoked. Pair again in Ed.Board.";
                try {
                    const shared = readCredential();
                    if (shared === token) writeCredential(null);
                    else if (shared) { this.token = shared; ++this.generation; this.pending = true; }
                } catch (_) { /* no credential details in logs */ }
            } else { this.status = "Ed.Board is unavailable. Retrying while a document is focused."; }
        } catch (_) { if (!this.stopped && generation === this.generation) this.status = "Waiting for Ed.Board"; }
        finally {
            if (this.outstanding === operation) this.outstanding = null;
            this.inFlight = false;
            if (this.pending && !this.stopped) this.schedule();
        }
    }
    async releaseClient(token, focus, sequence) {
        if (this.outstanding) { try { await this.outstanding; } catch (_) { /* still clear */ } }
        try { await request("/v2/clear", token, { client: this.client, focus, sequence }); } catch (_) { /* receiver expires stale state */ }
    }
    async disconnect() {
        const token = this.token, focus = this.focus, sequence = ++this.sequence;
        ++this.generation; this.token = null; this.pending = false; this.pairing = false;
        if (this.retryTimer !== null) { window.clearTimeout(this.retryTimer); this.retryTimer = null; }
        try { writeCredential(null); this.status = "Disconnected"; }
        catch (_) { this.status = "Disconnected for this session; local credential could not be removed."; }
        if (token && focus) await this.releaseClient(token, focus, sequence);
    }
    onunload() {
        this.stopped = true; ++this.generation; this.pending = false;
        if (this.retryTimer !== null) { window.clearTimeout(this.retryTimer); this.retryTimer = null; }
        if (this.token && this.focus) void this.releaseClient(this.token, this.focus, ++this.sequence);
    }
};
