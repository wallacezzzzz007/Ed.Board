import Foundation
import Combine
import Network
import Security
import Darwin
import BoardCore

// Credentials and layer mappings stay in per-user Application Support, never in
// the Obsidian vault or a release resource. Replacements are atomic and mode 0600.
enum ObsidianPluginStore {
    static func read(_ url: URL) throws -> ObsidianPluginSettings {
        guard (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) <= 16384 else { throw RPCError(code: "settings_too_large") }
        let value = try JSONDecoder().decode(ObsidianPluginSettings.self, from: Data(contentsOf: url))
        guard value.isValid else { throw RPCError(code: "invalid_plugin_settings") }
        return value
    }
    static func write(_ value: ObsidianPluginSettings, to url: URL) throws {
        guard value.isValid else { throw RPCError(code: "invalid_plugin_settings") }
        let data = try JSONEncoder().encode(value)
        guard data.count <= 16384 else { throw RPCError(code: "settings_too_large") }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".obsidian-\(UUID().uuidString).tmp")
        defer { try? FileManager.default.removeItem(at: temporary) }
        try data.write(to: temporary, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporary.path)
        guard rename(temporary.path, url.path) == 0 else { throw RPCError(code: "plugin_settings_write_failed") }
    }
}

@MainActor
final class ObsidianPlugin: ObservableObject {
    @Published private(set) var settings = ObsidianPluginSettings()
    @Published private(set) var connectionStatus = "Off"
    @Published private(set) var pairingAvailable = false
    @Published private(set) var listening = false
    @Published private(set) var error: String?
    private(set) var readable = true
    var onChange: (() -> Void)?
    private var bridge = ObsidianBridgeSession()
    private var obsidianForeground = false
    private var listener: NWListener?
    private var timer: Timer?
    private var clients: [UUID: (NWConnection, DispatchWorkItem)] = [:]
    private let url: URL?
    init() {
        url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Ed.Board/Settings/obsidian-plugin.json")
        guard let url else { readable = false; error = "Plugin settings storage is unavailable."; return }
        if FileManager.default.fileExists(atPath: url.path) {
            do { settings = try ObsidianPluginStore.read(url) }
            catch { readable = false; self.error = "Cannot read Obsidian plugin settings. Integration remains off."; return }
        }
        if settings.enabled { start() }
    }
    var enabled: Bool { settings.enabled }
    func mapping(serial: String?) -> ObsidianLayerMapping { settings.devices[serial ?? ""] ?? ObsidianLayerMapping() }
    func setMapping(serial: String?, defaultLayer: Int? = nil, excalidrawLayer: Int? = nil) {
        guard let serial, !serial.isEmpty else { return }
        var next = settings; var mapping = self.mapping(serial: serial)
        if let defaultLayer { mapping.defaultLayer = defaultLayer }
        if let excalidrawLayer { mapping.excalidrawLayer = excalidrawLayer }
        next.devices[serial] = mapping
        if save(next) { onChange?() }
    }
    private func save(_ next: ObsidianPluginSettings) -> Bool {
        guard readable, let url else { return false }
        do { try ObsidianPluginStore.write(next, to: url); settings = next; error = nil; return true }
        catch { self.error = "Could not save Obsidian plugin settings. Previous settings remain in use."; return false }
    }
    func setEnabled(_ enabled: Bool) {
        guard readable, enabled != settings.enabled else { return }
        var next = settings; next.enabled = enabled
        guard save(next) else { return }
        if enabled { start() } else { stop() }
        onChange?()
    }
    func pair() {
        guard enabled, listening, let code = Self.secret() else { return }
        bridge.beginPairing(code: code, now: Date().timeIntervalSince1970)
        refreshStatus()
    }
    var pairingCode: String? { bridge.pairingCode.map { "edboard1:\($0)" } }
    func revoke() {
        var next = settings; next.credential = nil
        guard save(next) else { return }
        bridge.activate(credential: nil); bridge.setForeground(obsidianForeground, now: Date().timeIntervalSince1970)
        refreshStatus(); onChange?()
    }
    func setForeground(_ active: Bool) {
        let changed = obsidianForeground != active
        obsidianForeground = active
        let old = bridge.view
        bridge.setForeground(active, now: Date().timeIntervalSince1970)
        if changed || old != bridge.view { refreshStatus() }
        if old != bridge.view { onChange?() }
    }
    func clearTransientState() { bridge.clearView(); refreshStatus(); onChange?() }
    func matchingLayer(serial: String, bundleID: String?, available: Set<Int>) -> Int? {
        bridge.matchingLayer(settings: settings, serial: serial, bundleID: bundleID, available: available, now: Date().timeIntervalSince1970)
    }
    private static func secret() -> String? {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { return nil }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }
    func retry() { guard enabled, readable else { return }; start() }
    private func start() {
        stop(); bridge.activate(credential: settings.credential)
        bridge.setForeground(obsidianForeground, now: Date().timeIntervalSince1970)
        do {
            let parameters = NWParameters.tcp
            parameters.requiredLocalEndpoint = .hostPort(host: NWEndpoint.Host("127.0.0.1"), port: NWEndpoint.Port(rawValue: BridgeHTTPRequest.port)!)
            let listener = try NWListener(using: parameters)
            self.listener = listener; connectionStatus = "Starting…"
            listener.stateUpdateHandler = { [weak self, weak listener] state in
                Task { @MainActor in
                    guard let self, let listener, self.listener === listener else { return }
                    switch state {
                    case .ready: self.listening = true; self.error = nil; self.refreshStatus()
                    case .failed:
                        self.stop(); self.connectionStatus = "Unavailable"
                        self.error = "Local connection unavailable. Close other Ed.Board copies, then retry."
                        self.onChange?()
                    default: break
                    }
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                Task { @MainActor in self?.accept(connection) }
            }
            listener.start(queue: .main)
            let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }
                    let old = self.bridge.view
                    self.bridge.expire(now: Date().timeIntervalSince1970); self.refreshStatus()
                    if old != self.bridge.view { self.onChange?() }
                }
            }
            self.timer = timer; timer.tolerance = 0.2; RunLoop.main.add(timer, forMode: .common)
        } catch {
            stop(); connectionStatus = "Unavailable"; self.error = "Could not start the local Obsidian connection. Retry to try again."
        }
    }
    private func stop() {
        let old = listener; listener = nil; old?.cancel()
        for (connection, timeout) in clients.values { timeout.cancel(); connection.cancel() }
        clients.removeAll(); timer?.invalidate(); timer = nil; bridge.stop()
        listening = false; pairingAvailable = false; connectionStatus = "Off"
    }
    private func refreshStatus() {
        pairingAvailable = bridge.pairingCode != nil
        if !enabled { connectionStatus = "Off" }
        else if !listening { connectionStatus = "Starting…" }
        else if pairingAvailable { connectionStatus = "Waiting for pairing" }
        else if settings.credential != nil && !obsidianForeground { connectionStatus = "Paired · Obsidian in background" }
        else if bridge.isConnected(now: Date().timeIntervalSince1970) { connectionStatus = "Connected" }
        else { connectionStatus = settings.credential == nil ? "Not paired" : "Waiting for Obsidian" }
    }
    private func accept(_ connection: NWConnection) {
        guard enabled, listening, clients.count < 8 else { connection.cancel(); return }
        let id = UUID()
        let timeout = DispatchWorkItem { [weak self] in self?.close(id) }
        clients[id] = (connection, timeout)
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: timeout)
        connection.start(queue: .main); receive(id, buffer: Data())
    }
    private func close(_ id: UUID) {
        guard let (connection, timeout) = clients.removeValue(forKey: id) else { return }
        timeout.cancel(); connection.cancel()
    }
    private func receive(_ id: UUID, buffer: Data) {
        guard let (connection, _) = clients[id] else { return }
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, complete, error in
            Task { @MainActor in
                guard let self, self.clients[id] != nil else { return }
                let next = buffer + (data ?? Data())
                switch BridgeHTTPRequest.parse(next) {
                case .incomplete:
                    if complete || error != nil { self.close(id) } else { self.receive(id, buffer: next) }
                case .invalid: self.respond(id, reply: BridgeHTTPReply(400))
                case .request(let request):
                    guard self.enabled else { self.close(id); return }
                    let oldView = self.bridge.view
                    // Persist before returning a token. No request bodies, headers,
                    // view names, credentials or nearby app data are logged.
                    var candidate = self.bridge
                    let reply = candidate.handle(request, now: Date().timeIntervalSince1970,
                        issueToken: { Self.secret() ?? "" }, persistToken: { token in
                            var next = self.settings; next.credential = token; return self.save(next)
                        })
                    self.bridge = candidate; self.refreshStatus()
                    if oldView != candidate.view { self.onChange?() }
                    self.respond(id, reply: reply)
                }
            }
        }
    }
    private func respond(_ id: UUID, reply: BridgeHTTPReply) {
        guard let (connection, _) = clients[id] else { return }
        connection.send(content: reply.wireData, completion: .contentProcessed { [weak self] _ in
            Task { @MainActor in self?.close(id) }
        })
    }
}
