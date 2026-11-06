/* Offline companion-plugin tests with mocked Obsidian, HTTP and storage. */
"use strict";
const assert = require("node:assert/strict");
const vm = require("node:vm");
const fs = require("node:fs");
const path = require("node:path");
const EventEmitter = require("node:events");
const source = fs.readFileSync(path.join(__dirname, "../../plugins/obsidian/edboard-bridge/main.js"), "utf8");
function fixture(files = new Map(), clock = { now: 100000 }) {
    const requests = [], plans = [], workspaceEvents = new Map();
    const permissions = [], intervals = [], focusHandlers = [], blurHandlers = [], timers = new Map();
    let timerID = 0;
    let focused = true, type = "markdown";
    const document = { hasFocus: () => focused };
    const leaf = { view: { containerEl: { ownerDocument: document }, getViewType: () => type } };
    const workspace = {
        getMostRecentLeaf: () => leaf,
        on: (name, callback) => { workspaceEvents.set(name, callback); return { name }; },
        onLayoutReady: callback => callback()
    };
    const app = { workspace, vault: new Proxy({}, { get() { throw Error("Plugin must not read the vault"); } }) };
    class Plugin {
        constructor() { this.app = app; }
        addSettingTab() {}
        registerEvent() {}
        registerDomEvent(_win, event, callback) {
            assert.ok(event === "focus" || event === "blur");
            (event === "focus" ? focusHandlers : blurHandlers).push(callback);
        }
        registerInterval(interval) { intervals.push(interval); }
        saveData() { throw Error("Credentials must not be saved in the vault"); }
    }
    const storage = {
        lstatSync(file) { if (!files.has(file)) throw Error("missing"); return { isSymbolicLink: () => false }; },
        statSync(file) { return { size: Buffer.byteLength(files.get(file)) }; },
        readFileSync(file) { if (!files.has(file)) throw Error("missing"); return files.get(file); },
        mkdirSync(file, options) { assert.equal(options.mode, 0o700); assert.ok(!file.includes(".obsidian")); },
        writeFileSync(file, data, options) { assert.equal(options.mode, 0o600); assert.equal(options.flag,"wx"); files.set(file, data); permissions.push(options.mode); },
        renameSync(from, to) { assert.ok(files.has(from)); files.set(to, files.get(from)); files.delete(from); },
        unlinkSync(file) { if (!files.delete(file)) { const e = Error("missing"); e.code = "ENOENT"; throw e; } }
    };
    const transport = { request(options, callback) {
        const req = new EventEmitter(); req.setTimeout = () => req;
        req.destroy = error => req.emit("error", error);
        req.end = data => {
            requests.push({ options, body: JSON.parse(data.toString()) });
            const plan = plans.shift() || { status: 200, body: {} };
            const deliver = () => {
                if (plan.error) { req.emit("error", Error("offline")); return; }
                const res = new EventEmitter(); res.statusCode = plan.status;
                callback(res); res.emit("data", Buffer.from(JSON.stringify(plan.body))); res.emit("end");
            };
            if (plan.defer) plan.deliver = deliver; else queueMicrotask(deliver);
        };
        return req;
    } };
    const sandbox = { module: { exports: {} }, Buffer, Date: { now: () => clock.now },
        window: { setInterval: callback => callback,
            setTimeout: callback => { const id = ++timerID; timers.set(id, callback); return id; },
            clearTimeout: id => timers.delete(id) },
        require(name) {
            if (name === "obsidian") return { Plugin, PluginSettingTab: class {}, Setting: class {} };
            if (name === "node:fs") return storage;
            if (name === "node:http") return transport;
            if (name === "node:os") return { platform: () => "darwin", homedir: () => "/synthetic" };
            return require(name);
        } };
    vm.runInNewContext(source + "\n;globalThis.helpers={focusedView,readCredential,writeCredential};", sandbox);
    return { sandbox, files, requests, plans, app, workspaceEvents, focusHandlers, blurHandlers, clock, timers,
        runTimers: () => { const callbacks = [...timers.values()]; timers.clear(); for (const callback of callbacks) callback(); },
        setFocus: value => { focused = value; }, setType: value => { type = value; }, intervals, permissions };
}
const settle = () => new Promise(resolve => setImmediate(resolve));
async function main() {
    let f = fixture(), Plugin = f.sandbox.module.exports, p = new Plugin(); await p.onload(); await settle();
    assert.equal(f.requests.length, 0); assert.equal(f.files.size, 0); assert.equal(p.status, "Not paired");
    const token = "b".repeat(64), code = "edboard1:" + "a".repeat(64);
    f.plans.push({ status: 200, body: { token } });
    await p.pair(code); await settle();
    assert.equal(p.token, token); assert.equal(p.status, "Connected");
    assert.equal(f.requests[0].options.path, "/v1/pair");
    assert.equal(f.requests[1].body.view, "markdown");
    assert.equal(f.permissions.length, 1); assert.equal(f.files.size, 1);
    for (const [file, text] of f.files) {
        assert.ok(file.includes("Application Support/Ed.Board/ObsidianBridge/client.json"));
        assert.ok(!file.includes(".obsidian")); assert.deepEqual(JSON.parse(text), { token });
    }
    f.setType("excalidraw"); f.workspaceEvents.get("active-leaf-change")(); await settle();
    assert.equal(f.requests.at(-1).body.view, "excalidraw");
    f.setType("canvas"); p.schedule(); await settle(); assert.equal(f.requests.at(-1).body.view, "other");
    let count = f.requests.length;
    f.setFocus(false); p.schedule(); await settle(); assert.equal(f.requests.length, count);
    f.setFocus(true); f.setType("excalidraw-loading"); p.schedule(); await settle(); assert.equal(f.requests.length, count);
    // Popouts use their own document focus, without reading the vault.
    f.workspaceEvents.get("window-open")({ win: {} }); assert.equal(f.focusHandlers.length, 2);
    f.setType("markdown"); f.focusHandlers[1](); await settle(); assert.equal(f.requests.at(-1).body.view, "markdown");
    // Coalesce changes while a request is in flight; send the newest focused type next.
    const delayed = { status: 200, body: {}, defer: true }; f.plans.push(delayed);
    p.schedule(); f.setType("excalidraw"); p.schedule(); p.schedule();
    count = f.requests.length; delayed.deliver(); await settle();
    assert.equal(f.requests.length, count + 1); assert.equal(f.requests.at(-1).body.view, "excalidraw");
    // Temporary App exit keeps credentials and retries on the next heartbeat.
    f.plans.push({ error: true }); p.schedule(); await settle(); assert.equal(p.token, token);
    p.schedule(); await settle(); assert.equal(p.status, "Connected");
    for (const request of f.requests) {
        assert.equal(request.options.hostname, "127.0.0.1"); assert.equal(request.options.port, 27124);
        assert.ok(request.options.headers.Authorization.startsWith("Bearer "));
        if (request.options.path === "/v2/view") assert.deepEqual(Object.keys(request.body).sort(), ["client", "focus", "sequence", "view"]);
    }
    f.plans.push({ status: 401, body: {} }); p.schedule(); await settle();
    assert.equal(p.token, null); assert.equal(f.files.size, 0);
    count = f.requests.length; p.schedule(); await settle(); assert.equal(f.requests.length, count);
    // Manual disconnect clears local credentials and releases only this client's lease.
    f.sandbox.helpers.writeCredential(token); p.token = token;
    await p.disconnect(); assert.equal(f.files.size, 0); assert.equal(f.requests.at(-1).options.path, "/v2/clear");
    p.token = token; p.onunload(); await settle();
    count = f.requests.length; p.schedule(); await settle(); assert.equal(f.requests.length, count);
    // An in-flight response cannot reconnect or restore credentials after disconnect.
    f = fixture(); Plugin = f.sandbox.module.exports; p = new Plugin(); await p.onload(); f.sandbox.helpers.writeCredential(token); p.token = token;
    const late = { status: 200, body: {}, defer: true }; f.plans.push(late); p.schedule();
    const disconnecting = p.disconnect(); late.deliver(); await disconnecting; await settle();
    assert.equal(f.requests.at(-1).options.path, "/v2/clear");
    assert.equal(p.token, null); assert.equal(p.status, "Disconnected");
    // Pair once, then focus another already-open vault: it discovers the shared credential.
    const shared = new Map(), clock = { now: 200000 };
    const a = fixture(shared, clock), b = fixture(shared, clock);
    b.setFocus(false);
    const A = a.sandbox.module.exports, B = b.sandbox.module.exports;
    const pa = new A(), pb = new B(); await pa.onload(); await pb.onload();
    a.plans.push({ status: 200, body: { token } }); await pa.pair(code); await settle();
    assert.equal(b.requests.length, 0); assert.equal(pb.token, null);
    const stale = { status: 409, body: {}, defer: true }; a.plans.push(stale); pa.schedule();
    a.setFocus(false); a.blurHandlers[0](); clock.now += 1000;
    b.setFocus(true); b.setType("excalidraw"); b.focusHandlers[0](); await settle();
    assert.equal(pb.token, token); assert.equal(b.requests.length, 1);
    assert.equal(b.requests[0].options.path, "/v2/view"); assert.equal(b.requests[0].body.view, "excalidraw");
    assert.ok(b.requests[0].body.focus > a.requests.at(-1).body.focus);
    stale.deliver(); await settle();
    const aCount = a.requests.length; a.runTimers(); await settle(); assert.equal(a.requests.length, aCount);
    pa.onunload(); await settle(); assert.equal(shared.size, 1); assert.equal(pb.token, token);
    pb.schedule(); await settle(); assert.equal(pb.status, "Connected");
    // A new pairing is picked up by another vault on focus, without deleting it.
    const c = fixture(shared, clock), C = c.sandbox.module.exports; c.setFocus(false);
    const pc = new C(); await pc.onload(); assert.equal(pc.token, token);
    const newer = "e".repeat(64); b.plans.push({ status: 200, body: { token: newer } });
    await pb.pair(code); await settle();
    b.setFocus(false); b.blurHandlers[0](); clock.now += 1000;
    c.setFocus(true); c.focusHandlers[0](); await settle();
    assert.equal(pc.token, newer); assert.equal(c.requests[0].options.headers.Authorization, "Bearer " + newer);
    // Tied focus / delayed foreground notification retries only while truly focused.
    c.plans.push({ status: 409, body: {} }); pc.schedule(); await settle();
    assert.equal(c.timers.size, 1); const oldFocus = pc.focus;
    clock.now += 250; c.runTimers(); await settle(); assert.ok(pc.focus > oldFocus); assert.equal(pc.status, "Connected");
    c.plans.push({ status: 409, body: {} }); pc.schedule(); await settle();
    count = c.requests.length; c.setFocus(false); c.blurHandlers[0](); c.runTimers(); await settle();
    assert.equal(c.requests.length, count);
    // Global credential removal is seen by other vaults, with no unauthorized report loop.
    await pb.disconnect(); c.setFocus(true); pc.schedule(); await settle();
    assert.equal(pc.token, null); assert.equal(shared.size, 0); assert.equal(c.requests.length, count);
    console.log("PASS: shared Mac pairing across vaults, focus ordering, background silence, stale replies, popouts, token rotation, revoke and unload");
}
main().catch(error => { console.error(error); process.exitCode = 1; });
