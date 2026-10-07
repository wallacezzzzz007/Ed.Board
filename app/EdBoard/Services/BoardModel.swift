import Foundation
import Combine
import AppKit
import UniformTypeIdentifiers
import ImageIO
import BoardCore

@MainActor
final class BoardModel: ObservableObject {
    let firmware = FirmwareUpdater()
    private let joystickOverlay = JoystickOverlayController()
    private var joystickGate = JoystickFrameGate()
    private var joystickToken = Int.random(in: 1...0x7fffffff)
    private var joystickWatchTarget: Bool?
    private var joystickUnavailable = false
    @Published private(set) var firmwareIdentity: FirmwareIdentity?
    @Published private(set) var previewCancelled = false
    @Published var migrationNotice = ""
    @Published var presentation = PresentationCatalog()
    private var savedPresentation = PresentationCatalog()
    private var presentationReadable = true
    @Published var autoDraft = AutoBindings()
    @Published private(set) var configurationConflict = false
    private var directBindings: [String: BoardCore.Binding] = [:]
    @Published private(set) var previewKeys = 0
    @Published private(set) var previewPressed = 0
    @Published private(set) var previewX = 0.0
    @Published private(set) var previewY = 0.0
    @Published private(set) var previewTouch = false
    @Published private(set) var previewTurnLeft = false
    @Published private(set) var previewTurnRight = false
    @Published private(set) var previewUnavailable = false
    @Published var openSystemRequested = false
    var menuStatusVisible = false
    private var statusVisible = false

    private var statusSent = Date.distantPast
    private var statusRetryAfter = Date.distantPast
    @Published private var statusUnavailable = false
    private struct DeviceStatus: Decodable {
        let batteryValid: Bool; let battery: Int; let charging: Bool; let full: Bool
        let bonds: Int; let connected: Bool; let ready: Bool
    }
    @Published private var deviceStatus: DeviceStatus?
    @Published private(set) var pairingNoticeVisible = false
    private var previewVisible = false
    private var previewPrevious: PreviewFrame?
    private var previewToken = Int.random(in: 1...0x7fffffff)
    private var previewReceived = Date.distantPast
    private var previewWatchSent = Date.distantPast
    private var previewPulseUntil = Date.distantPast
    private struct PowerState: Decodable {
        let revision: Int
        let idleMinutes: Int
        let idleSeconds: Int?
        var seconds: Int { idleSeconds ?? idleMinutes * 60 }
        let enabled: Bool
        let deepMinutes: Int
        let keepConnected: Bool
        let writable: Bool
        let lightsSleeping: Bool
        let wakeReason: String
        let restoredManualLayer: Int
        let wakeCount: Int
        var valid: Bool { (0...0x7fffffff).contains(revision) && PowerOptions.valid(seconds: seconds, lights: enabled, deepMinutes: deepMinutes, keepConnected: keepConnected) }
    }
    private struct PowerParams: Encodable {
        let baseRevision: Int
        let idleSeconds: Int
        let enabled: Bool
        let deepMinutes: Int
        let keepConnected: Bool
    }
    @Published var idleSeconds = 60
    @Published var idleLightsEnabled = true
    @Published var deepMinutes = 15
    @Published var keepConnected = false
    @Published private(set) var powerMessage = "Read power settings after connecting."
    @Published private var powerState: PowerState?
    private var expectedPower: PowerParams?
    var canManagePower: Bool { firmwareReady && connected && info != nil && snapshot != nil && !busy && !pairingBusy }
    var powerSaveBlockReason: String? {
        guard powerDirty else { return nil }
        if !connected { return "Connect the keyboard to save power settings." }
        if powerState == nil { return "Read power settings before saving." }
        if powerState?.writable != true { return "Power storage is unavailable. Check the device log." }
        if busy || pairingBusy { return "Wait for the current device operation to finish." }
        if (powerState?.revision ?? 0) >= 0x7fffffff { return "Power settings revision limit reached." }
        return nil
    }
    var canSavePower: Bool {
        canManagePower && powerState?.writable == true && PowerOptions.valid(seconds: idleSeconds, lights: idleLightsEnabled, deepMinutes: deepMinutes, keepConnected: keepConnected)
            && !legacyPowerIncompatible
            && (powerState?.revision ?? 0x7fffffff) < 0x7fffffff
            && (powerState?.seconds != idleSeconds || powerState?.enabled != idleLightsEnabled
                || powerState?.deepMinutes != deepMinutes || powerState?.keepConnected != keepConnected)
    }
    var legacyPowerIncompatible: Bool { !supportsSeconds && (idleSeconds % 60 != 0 || (idleLightsEnabled && deepMinutes * 60 <= idleSeconds)) }
    var supportsSeconds: Bool { (info?.powerVersion ?? 1) >= 2 }
    var powerTimingInvalid: Bool { !PowerOptions.valid(seconds: idleSeconds, lights: idleLightsEnabled, deepMinutes: deepMinutes, keepConnected: keepConnected) }
    @Published private(set) var pairingBound: Bool?
    @Published private(set) var pairingReady = false
    @Published private(set) var pairingConnected = false
    func readPower() {
        guard canManagePower else { return }
        expectedPower = nil; request("power.get", params: EmptyParams())
    }
    func savePower() {
        guard canSavePower, let powerState else { return }
        let params = PowerParams(baseRevision: powerState.revision, idleSeconds: idleSeconds, enabled: idleLightsEnabled, deepMinutes: deepMinutes, keepConnected: keepConnected)
        expectedPower = params; powerMessage = "Saving power settings…"
        if supportsSeconds { request("power.setSeconds", params: params) }
        else {
            struct LegacyPowerParams: Encodable { let baseRevision: Int; let idleMinutes: Int; let enabled: Bool; let deepMinutes: Int; let keepConnected: Bool }
            request("power.set", params: LegacyPowerParams(baseRevision: params.baseRevision, idleMinutes: idleSeconds / 60, enabled: idleLightsEnabled, deepMinutes: deepMinutes, keepConnected: keepConnected))
        }
    }
    @Published private(set) var pairingMessage = "Hold touch for 3 seconds, then pair Codex Micro in macOS Bluetooth settings."
    @Published private(set) var pairingBusy = false
    private struct BluetoothStatus: Decodable {
        let initialized: Bool
        let bonds: Int
        let clearStatus: Int
        let connected: Bool
        let ready: Bool
    }
    private struct ClearConfirmation: Encodable { let confirm = true }
    private struct ClearAcceptance: Decodable { let accepted: Bool }
    private var pairingBaseline: Snapshot?
    private var pairingPoll: DispatchWorkItem?
    private var pairingDeadline = Date.distantPast
    var canManagePairing: Bool { connected && info != nil && snapshot != nil && !busy && !pairingBusy && !dirty }
    func readPairingStatus() {
        guard canManagePairing else { return }
        errorText = nil
        pairingNoticeVisible = false
        request("bluetooth.status", params: EmptyParams())
    }
    func clearPairing() {
        guard canManagePairing, !usingBluetooth, let snapshot else { return }
        pairingNoticeVisible = true
        joystickOverlay.hide()
        pairingBaseline = snapshot; pairingBusy = true; pairingDeadline = Date().addingTimeInterval(12)
        pairingMessage = "Clearing keyboard pairing…"; errorText = nil
        request("bluetooth.clear", params: ClearConfirmation())
    }
    private func finishPairing(_ message: String) {
        pairingPoll?.cancel(); pairingPoll = nil; pairingBaseline = nil; pairingBusy = false
        pairingMessage = message; pairingNoticeVisible = true
    }
    private func pollPairingStatus() {
        guard pairingBusy else { return }
        guard Date() < pairingDeadline else {
            finishPairing("Pairing clear was not confirmed. Refresh status and inspect the log before retrying."); return
        }
        busy = true
        let token = session
        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                guard let self, self.session == token, self.pairingBusy else { return }
                self.pairingPoll = nil
                self.request("bluetooth.status", params: EmptyParams())
            }
        }
        pairingPoll = work; DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }
    @Published var ports = [SerialPort]()
    @Published var selectedPort = ""
    @Published private(set) var connected = false
    @Published private(set) var usingBluetooth = false
    @Published private(set) var busy = false
    @Published private(set) var status = "Connect a keyboard to load settings"
    @Published private(set) var errorText: String?
    @Published private(set) var lastInfo: DeviceInfo?
    @Published private(set) var info: DeviceInfo?
    @Published private(set) var snapshot: Snapshot? {
        didSet { if snapshot?.revision != oldValue?.revision || snapshot == nil { joystickOverlay.hide() } }
    }
    @Published private(set) var runtime: RuntimeState? {
        didSet { if runtime?.activeLayer != oldValue?.activeLayer { joystickOverlay.hide() } }
    }
    @Published var draft = BoardConfiguration() {
        didSet {
            // Discarding a newly added layer must not leave the editor pointing at it.
            let validSelection = draft.editorLayer(preferred: selectedLayer)
            if selectedLayer != validSelection { selectedLayer = validSelection }
        }
    }
    private var didChooseInitialEditorLayer = false
    @Published var selectedLayer = 1
    @Published var selectedControl = 6
    @Published var diagnosticText = ""
    @Published private(set) var hostMessage = "Ed.Board must be running for host actions."
    @Published private var hostDraft: [Int: HostAction] = [:]
    private var hostSaved: [Int: HostAction] = [:]
    private var hostSerial = ""
    private var hostReadable = true
    private var hostGate = HostActionGate()
    private let hostExecutor = HostActionExecutor()
    @Published private(set) var autoBindings = AutoBindings()
    @Published private(set) var autoError: String?
    @Published var applicationLinkConflict: String?
    @Published private(set) var foregroundName = ""
    private var foregroundID: String?
    private var autoSession = 0
    private var autoSequence = 0
    private var lastAutoLayer = -1
    private var lastAutoSent = Date.distantPast
    private var autoTimer: Timer?
    private var observers = Set<AnyCancellable>()
    private var automaticActivity: NSObjectProtocol?
    private var sleeping = false
    private var settingsReadable = true
    private var restoredFirmwareDraft = false
    var appLog: AppLog { .shared }
    private let serial = SerialConnection()
    private let bluetooth = BluetoothConnection()
    private var session = UUID()
    private var nextID = 1
    private struct Pending { let id: Int; let method: String; let timer: DispatchWorkItem }
    private var pending: Pending?
    private var queuedRequest: (() -> Void)?
    private var portWatcher: SerialPortWatcher?
    private var connectionPreference = ConnectionPreference()
    private var reconnectWork: DispatchWorkItem?
    private var reconnectAttempt = 0
    private var expectedSerial: String?
    private var openPort = ""
    private var detachedDraft: (serial: String, config: BoardConfiguration, base: Snapshot?)?
    private func isBackground(_ method: String) -> Bool { method == "runtime.auto" || method == "runtime.begin" || method == "preview.watch" || method == "joystick.watch" || method == "device.status" }
    private func continueRequests() {
        configureAutoTimer()
        if pending == nil, let next = queuedRequest { queuedRequest = nil; next() }
        else { syncJoystickWatch(); pumpAuto() }
    }
    private var expected: (revision: Int, config: BoardConfiguration)?
    private var preserveDraftOnRead = false
    private var writeNotice: String?

    var dirty: Bool { !migrationNotice.isEmpty || (snapshot.map { $0.config != draft } ?? (detachedDraft != nil)) || presentation != savedPresentation || autoDraft != autoBindings }
    var canSave: Bool { firmwareReady && connected && !busy && !pairingBusy && !configurationConflict && presentationReadable && presentation.isValid && dirty && draft.isValid && hostDraftValid && snapshot?.writable == true && (snapshot?.revision ?? 0x7fffffff) < 0x7fffffff }
    var canEdit: Bool { firmwareReady && connected && !busy && !pairingBusy && snapshot != nil && snapshot?.writable == true }
    private var settingsDirectory: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Ed.Board/Settings", isDirectory: true)
    }

    init() {
        AppLog.shared.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &observers)
        firmware.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &observers)
        loadConnectionPreference(); refreshPorts(); loadAutoBindings()
        portWatcher = SerialPortWatcher { [weak self] in
            Task { @MainActor in self?.portsChanged() }
        }
        if portWatcher?.available != true { errorText = "Device notifications are unavailable. Refresh ports to connect." }
        let center = NSWorkspace.shared.notificationCenter
        center.publisher(for: NSWorkspace.didActivateApplicationNotification).sink { [weak self] _ in
            Task { @MainActor in self?.updateForeground() }
        }.store(in: &observers)
        center.publisher(for: NSWorkspace.willSleepNotification).sink { [weak self] _ in
            Task { @MainActor in guard let self else { return }; self.sleeping = true; self.invalidateJoystick(); self.syncJoystickWatch(); AppLog.shared.event("Mac sleeping"); self.resetPreview(); self.hostExecutor.cancel(); self.hostGate.reset(); self.reconnectWork?.cancel(); self.reconnectWork = nil; self.autoTimer?.invalidate(); self.autoTimer = nil
                if let activity = self.automaticActivity { ProcessInfo.processInfo.endActivity(activity); self.automaticActivity = nil } }
        }.store(in: &observers)
        center.publisher(for: NSWorkspace.didWakeNotification).sink { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }; self.sleeping = false; self.invalidateJoystick(); self.syncJoystickWatch(); AppLog.shared.event("Mac awake")
                self.autoSession = 0; self.lastAutoLayer = -1; self.updateForeground(); self.configureAutoTimer(); self.portsChanged()
            }
        }.store(in: &observers)
        updateForeground()
    }
    func refreshPorts() {
        let current = SerialConnection.ports()
        if ports != current { ports = current }
        if !ports.contains(where: { $0.path == selectedPort }) { selectedPort = ports.first?.path ?? "" }
    }
    func connect(automatically: Bool = false, wireless: Bool = false) {
        guard (!firmware.active || firmware.stage == "checking"), (wireless || !selectedPort.isEmpty), !busy, !connected else { return }
        if wireless, ports.contains(where: { $0.vendor == 0x303a && $0.product == 0x8360 }) {
            errorText = "USB is connected. Use USB or unplug it before connecting Bluetooth."; return
        }
        reconnectWork?.cancel(); reconnectWork = nil
        usingBluetooth = wireless
        openPort = wireless ? "" : selectedPort
        expectedSerial = (automatically || wireless) && !connectionPreference.serial.isEmpty ? connectionPreference.serial : nil
        if wireless { connectionPreference.bluetooth = true; saveConnectionPreference() }
        if !automatically { reconnectAttempt = 0 }
        session = UUID(); let token = session
        busy = true; status = automatically && reconnectAttempt > 6 ? "Waiting for the keyboard to wake…" : "Connecting…"; errorText = nil
        let callback: (SerialConnection.Event) -> Void = { [weak self] event in
            Task { @MainActor in
                guard let self, self.session == token else { return }
                switch event {
                case .opened:
                    self.connected = true
                    self.request("device.info", params: EmptyParams())
                case .lines(let lines):
                    for line in lines { self.receive(line) }
                case .failed(let message):
                    self.disconnect(manual: false); self.errorText = message; self.scheduleReconnect()
                }
            }
        }
        if wireless { bluetooth.open(backgroundWait: automatically && reconnectAttempt > 6, callback: callback) }
        else { serial.open(path: selectedPort, callback: callback) }
    }
    func disconnect(manual: Bool = true) {
        AppLog.shared.connection(manual ? "disconnected manually" : "disconnected")
        invalidateJoystick(); joystickWatchTarget = nil; joystickUnavailable = false
        hostExecutor.cancel(); hostGate.reset(); resetPreview(); deviceStatus = nil; statusSent = .distantPast; statusRetryAfter = .distantPast; statusUnavailable = false
        pairingBound = nil; pairingReady = false; pairingConnected = false
        if pairingBusy { finishPairing("Disconnected. Reconnect and refresh pairing status to confirm the result.") }
        reconnectWork?.cancel(); reconnectWork = nil
        if dirty, let info { detachedDraft = (info.serial, draft, snapshot) }
        if manual { connectionPreference.automatic = false; saveConnectionPreference() }
        expectedSerial = nil
        expectedPower = nil; powerMessage = "Disconnected; power draft preserved."
        if let activity = automaticActivity { ProcessInfo.processInfo.endActivity(activity); automaticActivity = nil }
        autoTimer?.invalidate(); autoTimer = nil; autoSession = 0; lastAutoLayer = -1
        session = UUID(); pending?.timer.cancel(); pending = nil; queuedRequest = nil
        serial.close(); bluetooth.close(); connected = false; busy = false; preserveWorkingDraft(); snapshot = nil; info = nil; runtime = nil
        expected = nil; preserveDraftOnRead = false; writeNotice = nil
        status = "Disconnected"
    }
    func shutdown() { disconnect(manual: false); serial.shutdown(); AppLog.shared.shutdown() }
    func refresh() {
        guard connected, !busy, !dirty else { return }
        expected = nil; preserveDraftOnRead = false; errorText = nil
        request("device.info", params: EmptyParams())
    }
    private func preserveWorkingDraft() {
        if dirty, let info, let snapshot { detachedDraft = (info.serial, draft, snapshot) }
    }
    func discardEdits() { if let snapshot { draft = snapshot.config }; detachedDraft = nil; presentation = savedPresentation; autoDraft = autoBindings; directBindings = [:]; configurationConflict = false; pruneHostDraft(); errorText = nil; status = "Changes discarded" }
    var layerIndex: Int { draft.layers.firstIndex { $0.id == selectedLayer } ?? 0 }
    var layer: Layer {
        get { draft.layers[layerIndex] }
        set { draft.layers[layerIndex] = newValue }
    }
    var binding: BoardCore.Binding {
        get { layer.bindings[selectedControl] }
        set {
            presentation.bindingChanged(layer: layer.id, control: selectedControl, from: binding, to: newValue)
            draft.layers[layerIndex].setBinding(newValue, control: selectedControl)
        }
    }
    var effectiveDescription: String {
        draft.resolved(layer: layer.id, control: selectedControl)?.description ?? "Invalid inheritance"
    }
    var quickSelectionSource: Int { QuickSelection.source(in: draft, layer: selectedLayer) ?? 0 }
    var quickSelectionSources: [Layer] {
        draft.layers.filter { QuickSelection.inheriting(draft, layer: selectedLayer, source: $0.id) != nil }
    }
    var quickSelectionLocked: Bool { Control.isStick(selectedControl) && quickSelectionSource != 0 }
    func setQuickSelectionSource(_ source: Int) {
        guard canEdit, selectedLayer != 1, source != quickSelectionSource else { return }
        if source == 0 {
            guard presentationReadable, hostReadable else { errorText = "Local action data is unavailable. Reconnect before unlinking."; return }
            let reserved = Set(hostSaved.keys).union((snapshot?.config.layers ?? []).flatMap { $0.bindings.filter { $0.kind.isHost }.map(\.source) })
            guard let result = QuickSelection.detached(draft, layer: selectedLayer, presentation: presentation,
                                                       actions: hostDraft, reservedIDs: reserved) else {
                errorText = "Could not keep the inherited actions. Check the source layer and local action data."; return
            }
            hostDraft = result.actions; presentation = result.presentation; draft = result.configuration
        } else {
            guard let result = QuickSelection.inheriting(draft, layer: selectedLayer, source: source) else {
                errorText = "Choose an ordinary layer without an inheritance cycle."; return
            }
            draft = result
        }
        for id in Control.stickIDs { directBindings.removeValue(forKey: "\(selectedLayer):\(id)") }
        pruneHostDraft(); errorText = nil
    }
    @discardableResult func addLayer(favorite: Bool = true) -> Bool {
        guard canEdit else { return false }
        guard draft.layers.count < 16 else { errorText = "You can keep up to 16 layers, including Codex."; return false }
        guard !favorite || draft.favorites.count < 6 else { errorText = "Favorites is full (6). Move a favorite to Extended first."; return false }
        let used = Set(draft.layers.map(\.id) + (snapshot?.config.layers.map(\.id) ?? []))
        let id = (2...255).first { !used.contains($0) }!
        draft.layers.append(Layer.blank(id: id, name: "Layer \(id)"))
        if favorite { draft.favorites.append(id) }
        selectedLayer = id; errorText = nil
        return true
    }
    func setLayerFavorite(_ id: Int, _ enabled: Bool) {
        guard canEdit else { return }
        guard draft.setFavorite(id, enabled: enabled) else {
            errorText = enabled ? "Favorites is full (6). Move a favorite to Extended first." : "Keep at least one favorite for touch switching."
            return
        }
        errorText = nil
    }
    func resetLayer() {
        guard canEdit else { return }
        let id = layer.id, name = layer.name
        draft.layers[layerIndex] = Layer.blank(id: id, name: name)
        presentation.removeLayer(id)
        directBindings = directBindings.filter { !$0.key.hasPrefix("\(id):") }
        autoDraft.devices[info?.serial ?? ""]?.removeAll { $0.layer == id }
        pruneHostDraft()
    }
    func deleteLayer() {
        guard canEdit, draft.canDelete(layer.id) else { return }
        let removed = layer.id
        presentation.removeLayer(removed)
        directBindings = directBindings.filter { !$0.key.hasPrefix("\(removed):") }
        autoDraft.devices[info?.serial ?? ""]?.removeAll { $0.layer == removed }
        draft.deleteLayer(removed); selectedLayer = draft.startupLayerID
    }
    func moveLayer(_ offset: Int) { guard canEdit else { return }; draft.moveLayer(layer.id, offset: offset) }
    func selectManualLayer(_ id: Int) {
        guard canEdit, !dirty, snapshot?.config.favorites.contains(id) == true else { return }
        errorText = nil
        request("runtime.select", params: SelectLayerParams(layer: id))
    }
    func readRuntime() {
        guard connected, !busy, snapshot != nil else { return }
        request("runtime.get", params: EmptyParams())
    }
    func chooseKind(_ kind: ActionKind) {
        guard !quickSelectionLocked, selectedControl < 13 || selectedLayer != 1 else { return }
        guard kind != .native || (selectedLayer == 1 && selectedControl < 13) else { return }
        guard kind != .cancel || Control.isStick(selectedControl) else { return }
        let key = "\(layer.id):\(selectedControl)"
        if kind == .inherit && binding.kind != .inherit { directBindings[key] = binding }
        if binding.kind == .inherit, kind != .inherit, let previous = directBindings[key], previous.kind == kind { binding = previous; return }
        if kind == .media { guard info?.mediaVersion == 1 else { return }; binding = BoardCore.Binding(kind: .media, usage: MediaAction.playPause.rawValue) }
        else if kind == .shortcut { binding = BoardCore.Binding(kind: kind) }
        else if kind == .inherit { binding = BoardCore.Binding(kind: kind, source: selectedControl >= 13 ? (draft.layers.first { $0.id != layer.id && $0.id != 1 }?.id ?? 0) : (layer.id != 1 ? 1 : (draft.layers.first { $0.id != layer.id }?.id ?? 0))) }
        else { binding = BoardCore.Binding(kind: kind) }
        pruneHostDraft()
    }
    func setModifier(_ bit: Int, enabled: Bool) {
        if enabled { binding.modifiers |= bit } else { binding.modifiers &= ~bit }
    }
    func save() {
        guard canSave, let snapshot, snapshot.revision < 0x7fffffff else { return }
        guard persistHostActions(), persistPresentation(markSaved: false) else { return }
        if snapshot.config == draft && migrationNotice.isEmpty { finishLocalSave(); return }
        hostExecutor.cancel()
        expected = (snapshot.revision + 1, draft); writeNotice = nil
        preserveDraftOnRead = true; errorText = nil; status = "Saving…"
        request("config.set", params: SetParams(baseRevision: snapshot.revision, config: draft))
    }
    func showDiagnostics() {
        AppLog.shared.readRecent { [weak self] text in self?.diagnosticText = text }
    }

    private func request<P: Encodable>(_ method: String, params: P) {
        guard connected, (!firmware.active || firmware.stage == "checking"), (!firmwareMismatch || method == "device.info") else { return }
        if let pending {
            // User operations wait for the in-flight heartbeat; never drop the click.
            if isBackground(pending.method), !isBackground(method), queuedRequest == nil {
                queuedRequest = { [weak self] in self?.request(method, params: params) }
                busy = true
            }
            return
        }
        let id = nextID; nextID = nextID == 0x7fffffff ? 1 : nextID + 1
        do {
            let data = try Wire.request(id: id, method: method, params: params)
            let token = session
            let timer = DispatchWorkItem { [weak self] in
                Task { @MainActor in
                    guard let self, self.session == token, self.pending?.id == id else { return }
                    AppLog.shared.event("RPC timeout method=\(method)")
                    self.pending = nil
                    if self.busy && self.queuedRequest == nil { self.busy = false }
                    defer { self.continueRequests() }
                    if method == "device.status" { self.statusReadFailed()
                    } else if method == "joystick.watch" { self.joystickUnavailable = true; self.invalidateJoystick()
                    } else if method == "preview.watch" { self.previewUnavailable = true
                    } else if (method == "power.set" || method == "power.setSeconds") {
                        self.powerMessage = "Save response timed out. Reading back without resending the write."
                        self.request("power.get", params: EmptyParams())
                    } else if method == "power.get" {
                        self.expectedPower = nil
                        self.powerMessage = "Power settings timed out. Read settings again."
                    } else if method.hasPrefix("bluetooth.") || (self.pairingBusy && !self.isBackground(method)) {
                        self.finishPairing("Pairing response timed out. Refresh status and inspect the log.")
                    } else if method == "config.set" {
                        self.writeNotice = "Save response timed out. Reading back to verify."
                        self.request("config.get", params: EmptyParams())
                    } else if method.hasPrefix("runtime.") {
                        if method == "runtime.auto" || method == "runtime.begin" {
                            self.autoSession = 0; self.lastAutoLayer = -1
                            self.autoError = "Auto-link timed out. The keyboard will return to its manual layer when the lease expires."
                        } else { self.runtime = nil; self.errorText = "Layer status timed out. Refresh the keyboard." }
                    } else if method == "device.info" {
                        self.disconnect(manual: false); self.errorText = "No management response. Check the selected port."; self.scheduleReconnect()
                    } else {
                        self.preserveWorkingDraft(); self.snapshot = nil; self.expected = nil; self.configureAutoTimer()
                        self.status = "Configuration state unknown"
                        self.errorText = "Read timed out. Reload settings; saving has not been confirmed."
                    }
                }
            }
            pending = Pending(id: id, method: method, timer: timer)
            if !isBackground(method) && !busy { busy = true }
            if usingBluetooth { bluetooth.send(data) } else { serial.send(data) }
            DispatchQueue.main.asyncAfter(deadline: .now() + (usingBluetooth ? (method.hasPrefix("config.") ? 120 : 30) : 8), execute: timer)
        } catch {
            if busy { busy = false }
            if pairingBusy && !isBackground(method) { finishPairing("Pairing request was not sent. Check the log.") }
            errorText = error.localizedDescription
        }
    }
    private struct RuntimeNotification: Decodable { let `protocol`: Int; let event: String }
    private func receive(_ line: String) {
        if let payload = Wire.payload(line), let frame = try? JSONDecoder().decode(JoystickFrame.self, from: payload), frame.event == "joystick" { receiveJoystick(frame); return }
        if let payload = Wire.payload(line), let frame = try? JSONDecoder().decode(PreviewFrame.self, from: payload), frame.event == "preview" { receivePreview(frame); return }
        if let payload = Wire.payload(line), let event = try? JSONDecoder().decode(HostActionEvent.self, from: payload) {
            receiveHostAction(event); return
        }
        if let payload = Wire.payload(line), let event = try? JSONDecoder().decode(RuntimeNotification.self, from: payload),
           event.protocol == 1, event.event == "runtime", let config = snapshot?.config,
           let state = try? JSONDecoder().decode(RuntimeState.self, from: payload), state.isValid(for: config) {
            if runtime != state { runtime = state }; return
        }
        guard let data = Wire.payload(line), let p = pending,
              let header = try? JSONDecoder().decode(Header.self, from: data), header.id == p.id else { return }
        p.timer.cancel(); pending = nil
        if busy && queuedRequest == nil { busy = false }
        guard header.protocol == 1 else { disconnect(); errorText = "Incompatible management protocol."; return }
        defer { continueRequests() }
        if p.method == "device.status" {
            if header.error != nil { statusReadFailed(); return }
            guard let value = try? JSONDecoder().decode(Envelope<DeviceStatus>.self, from: data).result,
                  (0...100).contains(value.battery), (0...1).contains(value.bonds) else { statusReadFailed(); return }
            statusUnavailable = false; statusRetryAfter = .distantPast
            deviceStatus = value; pairingBound = value.bonds > 0; pairingConnected = value.connected; pairingReady = value.ready
            return
        }
        if p.method == "joystick.watch" {
            struct Acceptance: Decodable { let accepted: Bool }
            if header.error != nil || (try? JSONDecoder().decode(Envelope<Acceptance>.self, from: data).result?.accepted) != true {
                joystickUnavailable = true; invalidateJoystick()
                AppLog.shared.event("joystick overlay subscription unavailable")
            }
            return
        }
        if p.method == "preview.watch" { if header.error != nil { previewUnavailable = true }; return }
        if let error = header.error {
            let inputFailure: String?
            switch error.code {
            case "input_fault": inputFailure = "Keyboard input fault. Release all keys, center the joystick and remove your hand from the touch area. Firmware 0.5.1 or later retries automatically; allow up to 15 seconds. If it persists, check diagnostics or power the keyboard off and on."
            case "inputs_not_ready": inputFailure = "Keyboard inputs are initializing. Release all controls and retry in 5 seconds."
            case "transport_not_ready": inputFailure = "Keyboard input transport is not ready. Retry shortly or reconnect."
            default: inputFailure = nil
            }
            if p.method.hasPrefix("power.") {
                expectedPower = nil
                powerMessage = "Power request failed: \(error.code). Read settings again; firmware 0.4.4 or later is required."
            } else if p.method.hasPrefix("bluetooth.") || (pairingBusy && !isBackground(p.method)) {
                finishPairing("Pairing request failed: \(error.code). Check the diagnostic log.")
            } else if p.method == "config.set" {
                writeNotice = inputFailure.map { $0 + " Your draft is preserved." } ?? (error.code == "inputs_busy" ? "Release all keys, the joystick and touch before saving. Your draft is preserved." :
                    "Save was not confirmed (\(error.code)). Reading again; your draft is preserved.")
                request("config.get", params: EmptyParams())
            } else if p.method == "runtime.auto" || p.method == "runtime.begin" {
                autoError = "Auto-link request rejected: \(error.code)"
                if error.code == "stale_auto_session" { autoSession = 0; lastAutoLayer = -1 }
                // Conflicts require a fresh config read; do not repeatedly send the old revision.
                if error.code == "revision_conflict" { autoTimer?.invalidate(); autoTimer = nil; autoSession = 0; preserveWorkingDraft(); snapshot = nil }
            } else if p.method.hasPrefix("runtime.") {
                errorText = inputFailure ?? (error.code == "inputs_busy" ? "Release all controls before changing layers." : "Layer selection failed: \(error.code)")
            } else {
                preserveWorkingDraft(); snapshot = nil; expected = nil
                errorText = "Device error: \(error.code). Read configuration again."; status = "Request incomplete"
            }
            return
        }
        do {
            if p.method.hasPrefix("power.") {
                let response = try JSONDecoder().decode(Envelope<PowerState>.self, from: data)
                guard let value = response.result, value.valid else { throw RPCError(code: "invalid_power_response") }
                if (p.method == "power.set" || p.method == "power.setSeconds") {
                    request("power.get", params: EmptyParams())
                } else {
                    if let target = expectedPower {
                        if value.revision == target.baseRevision + 1 && value.seconds == target.idleSeconds && value.enabled == target.enabled && value.deepMinutes == target.deepMinutes && value.keepConnected == target.keepConnected && value.writable {
                            powerState = value
                            powerMessage = "Power settings saved and verified."
                            finishRestoredFirmwareDraftIfSaved()
                        } else { powerMessage = "Readback differs from the submitted settings. Saving is not confirmed." }
                        expectedPower = nil
                    } else {
                        powerState = value
                        idleSeconds = value.seconds; idleLightsEnabled = value.enabled
                        deepMinutes = value.deepMinutes; keepConnected = value.keepConnected
                        powerMessage = value.writable ? (value.lightsSleeping ? "Loaded · lights are idle" : "Loaded · lights are awake") : "Power storage unavailable. Check the log."
                        if value.wakeReason == "knob" {
                            powerMessage += " · Knob wake count: \(value.wakeCount); restored manual layer: \(value.restoredManualLayer)"
                        }
                    }
                }
            } else if p.method == "bluetooth.clear" {
                let response = try JSONDecoder().decode(Envelope<ClearAcceptance>.self, from: data)
                guard response.result?.accepted == true, pairingBusy else { throw RPCError(code: "clear_not_accepted") }
                pollPairingStatus()
            } else if p.method == "bluetooth.status" {
                let response = try JSONDecoder().decode(Envelope<BluetoothStatus>.self, from: data)
                guard let result = response.result, (0...1).contains(result.bonds) else { throw RPCError(code: "invalid_bluetooth_status") }
                pairingBound = result.bonds > 0; pairingReady = result.ready; pairingConnected = result.connected
                if pairingBusy {
                    if result.clearStatus == -1 { pollPairingStatus() }
                    else if result.clearStatus == 0 && result.bonds == 0 {
                        pairingMessage = "Pairing cleared. Verifying layer settings…"
                        request("config.get", params: EmptyParams())
                    } else { finishPairing("Pairing clear failed (\(result.clearStatus)). Check the diagnostic log.") }
                } else {
                    pairingMessage = result.initialized
                        ? "Pairing: \(result.bonds == 0 ? "None" : "Paired") · Bluetooth: \(result.ready ? "Input ready" : result.connected ? "Connected" : "Disconnected")"
                        : "Keyboard Bluetooth is not initialized."
                }
            } else if p.method.hasPrefix("runtime.") {
                let response = try JSONDecoder().decode(Envelope<RuntimeState>.self, from: data)
                guard let result = response.result, let config = snapshot?.config, result.isValid(for: config) else { throw RPCError(code: "invalid_runtime") }
                if runtime != result { runtime = result }
                if p.method == "runtime.begin" {
                    guard let token = result.session, token > 0 else { throw RPCError(code: "missing_auto_session") }
                    autoSession = token; autoSequence = 0; lastAutoLayer = -1; lastAutoSent = .distantPast
                }
                if p.method == "runtime.auto", autoError != nil { autoError = nil }
                if p.method == "runtime.get", powerState == nil { readPower() }
            } else if p.method == "device.info" {
                let identityEnvelope = try JSONDecoder().decode(Envelope<FirmwareIdentity>.self, from: data)
                guard let identity = identityEnvelope.result, identity.recognized else { throw RPCError(code: "unrecognized_device") }
                if let target = firmware.record?.serial, firmware.stage == "checking", target != identity.serial { throw RPCError(code: "wrong_keyboard") }
                if let expectedSerial, expectedSerial != identity.serial {
                    disconnect(); errorText = "Device identity differs from the remembered keyboard."; return
                }
                firmwareIdentity = identity
                loadHostActions(serial: identity.serial); loadPresentation(serial: identity.serial)
                if firmwareMismatch {
                    status = "Firmware update required"; errorText = nil
                    return
                }
                let envelope = try JSONDecoder().decode(Envelope<DeviceInfo>.self, from: data)
                guard let result = envelope.result, result.isCompatible else { throw RPCError(code: "incompatible_device") }
                if let expectedSerial, expectedSerial != result.serial {
                    disconnect(); errorText = "Device identity differs from the remembered keyboard. Auto-connect stopped."; return
                }
                if lastInfo?.serial != result.serial { powerState = nil }
                info = result; lastInfo = result; migrationNotice = result.migrationNote ?? ""
                loadHostActions(serial: result.serial); loadPresentation(serial: result.serial)
                connectionPreference = ConnectionPreference(serial: result.serial, automatic: true, bluetooth: connectionPreference.bluetooth)
                saveConnectionPreference(); reconnectAttempt = 0
                if usingBluetooth { bluetooth.rememberVerifiedDevice() }
                AppLog.shared.connection(usingBluetooth ? "bluetooth verified" : "usb verified")
                autoSession = 0; lastAutoLayer = -1
                if !result.writable { errorText = "Configuration storage unavailable: \(result.storageError). Keyboard reverted to native mapping. Check the log." }
                status = "Loading keyboard settings…"
                request("config.get", params: EmptyParams())
            } else if p.method == "config.set" {
                let response = try JSONDecoder().decode(Envelope<Snapshot>.self, from: data)
                guard response.result?.isValid == true else { throw RPCError(code: "invalid_save_response") }
                status = "Verifying saved settings…"
                request("config.get", params: EmptyParams())
            } else {
                let response = try JSONDecoder().decode(Envelope<Snapshot>.self, from: data)
                guard let result = response.result, result.isValid, result.writable != nil else { throw RPCError(code: "invalid_snapshot") }
                if pairingBusy, let baseline = pairingBaseline {
                    guard result.revision == baseline.revision, result.config == baseline.config else {
                        finishPairing("Pairing cleared, but configuration verification failed. Check the log.")
                        errorText = pairingMessage; return
                    }
                    finishPairing("Pairing cleared; layers preserved. Forget Codex Micro in macOS, unplug USB and hold touch for 3 seconds to pair again.")
                }
                let previousRevision = snapshot?.revision
                snapshot = result
                // Local draft bindings are committed only after configuration confirmation.
                if let target = expected {
                    if result.revision == target.revision && result.config == target.config && result.writable == true {
                        migrationNotice = "" // Clear only after the migrated configuration is written and read back.
                        draft = result.config; status = "Saved and verified"; errorText = nil; finishLocalSave()
                    } else {
                        configurationConflict = previousRevision != nil && previousRevision != result.revision
                        status = "Readback received; saving is not confirmed"
                        errorText = writeNotice ?? "Keyboard configuration differs from the draft. Review and save again, or discard changes."
                    }
                } else {
                    if let held = detachedDraft, held.serial == info?.serial {
                        draft = held.config; configurationConflict = held.base.map { $0.revision != result.revision || $0.config != result.config } ?? false; detachedDraft = nil
                    } else if !preserveDraftOnRead { draft = result.config }
                    lastAutoLayer = -1
                    status = draft == result.config ? "Keyboard settings loaded" : "Reconnected; review and save your preserved draft"
                }
                if result.writable != true { errorText = "Storage is read-only: \(result.storageError ?? "unknown"). Check the log before retrying." }
                expected = nil; preserveDraftOnRead = false; writeNotice = nil
                if !didChooseInitialEditorLayer || !draft.layers.contains(where: { $0.id == selectedLayer }) {
                    selectedLayer = draft.startupLayerID
                    didChooseInitialEditorLayer = true
                }
                lastAutoLayer = -1; configureAutoTimer(); readRuntime()
            }
        } catch {
            if (p.method == "power.set" || p.method == "power.setSeconds") {
                powerMessage = "Invalid save response. Reading back to verify."
                request("power.get", params: EmptyParams())
            } else if p.method == "power.get" {
                expectedPower = nil; powerMessage = "Invalid power response. Check the log."
            } else if p.method.hasPrefix("bluetooth.") || (pairingBusy && !isBackground(p.method)) {
                finishPairing("Invalid pairing response. Result unconfirmed; check the log.")
            } else if p.method == "config.set" {
                writeNotice = "Cannot parse save response. Reading keyboard settings again."
                request("config.get", params: EmptyParams())
            } else if p.method == "runtime.auto" || p.method == "runtime.begin" {
                autoSession = 0; lastAutoLayer = -1; autoError = "Invalid auto-link response. Check the log."
            } else {
                preserveWorkingDraft(); snapshot = nil; expected = nil; errorText = "Incompatible response or invalid configuration. Check the log."; status = "Could not load configuration"
            }
        }
    }
}

extension BoardModel {
    private var bindingsURL: URL? {
        settingsDirectory?.appendingPathComponent("auto-matches.json")
    }
    var selectedAutoRule: AutoRule {
        autoDraft.devices[info?.serial ?? ""]?.first { $0.layer == layer.id } ?? AutoRule(layer: layer.id)
    }
    var canLinkApplication: Bool {
        canEdit && settingsReadable
    }
    private func loadAutoBindings() {
        guard let url = bindingsURL else { settingsReadable = false; autoError = "App link storage path is missing."; return }
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size <= 131072 else { throw RPCError(code: "settings_too_large") }
            let value = try JSONDecoder().decode(AutoBindings.self, from: Data(contentsOf: url))
            guard value.isValid else { throw RPCError(code: "invalid_bindings") }
            autoBindings = value; autoDraft = value
        } catch { settingsReadable = false; autoError = "Cannot read app links. Auto-link stopped; check the log." }
    }
    private func storeRule(_ rule: AutoRule) {
        guard canLinkApplication, let serial = info?.serial else { return }
        var next = autoDraft
        var rules = next.devices[serial] ?? []
        rules.removeAll { $0.layer == rule.layer }; rules.append(rule)
        next.devices[serial] = rules
        guard next.isValid else { autoError = "Each app can be linked to one layer; maximum eight apps per layer."; return }
        autoDraft = next; autoError = nil
    }
    func setAutoEnabled(_ value: Bool) {
        var rule = selectedAutoRule; rule.enabled = value; storeRule(rule)
    }
    func removeLinkedApplication(_ id: String) {
        var rule = selectedAutoRule; rule.applications.removeAll { $0.bundleID == id }; storeRule(rule)
    }
    func chooseApplication() {
        guard canLinkApplication else { return }
        let layerID = layer.id, serial = info?.serial
        let panel = NSOpenPanel()
        panel.title = "Choose an application to link"
        panel.allowedContentTypes = [.applicationBundle]
        panel.canChooseDirectories = false; panel.canChooseFiles = true
        panel.allowsMultipleSelection = false; panel.treatsFilePackagesAsDirectories = false
        panel.begin { [weak self] response in
            Task { @MainActor in
                guard let self, response == .OK, let url = panel.url,
                      self.info?.serial == serial, self.layer.id == layerID, self.canLinkApplication else { return }
                guard let bundle = Bundle(url: url), let id = bundle.bundleIdentifier, !id.isEmpty else {
                    self.autoError = "This application has no recognizable bundle identifier."; return
                }
                var rule = self.selectedAutoRule
                let name = (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
                    ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String)
                    ?? url.deletingPathExtension().lastPathComponent
                if let owner = self.autoDraft.devices[serial ?? ""]?.first(where: {
                    $0.layer != layerID && $0.applications.contains { $0.bundleID == id }
                }) {
                    let index = self.draft.layers.firstIndex { $0.id == owner.layer }
                    let location = index.map { "Layer \($0 + 1) (\(self.draft.layers[$0].name))" } ?? "another layer"
                    // Separate user-facing validation from runtime.auto status, which refreshes periodically.
                    self.applicationLinkConflict = "\(name) is already linked to \(location). Unlink it there first."
                    return
                }
                guard !rule.applications.contains(where: { $0.bundleID == id }) else { return }
                rule.applications.append(LinkedApplication(bundleID: id, name: name))
                self.storeRule(rule)
            }
        }
    }
    private var hasAutoRules: Bool {
        guard settingsReadable, let serial = info?.serial, let config = snapshot?.config else { return false }
        let ids = Set(config.layers.map(\.id))
        return autoBindings.devices[serial]?.contains { $0.enabled && !$0.applications.isEmpty && ids.contains($0.layer) } == true
    }
    private func updateForeground() {
        let app = NSWorkspace.shared.frontmostApplication
        foregroundID = app?.bundleIdentifier; foregroundName = app?.localizedName ?? "Unknown application"
        pumpAuto()
    }
    private func configureAutoTimer() {
        guard connected, !sleeping, settingsReadable, snapshot != nil, hasAutoRules || hasHostActions || lastAutoLayer > 0 else {
            autoTimer?.invalidate(); autoTimer = nil
            if let activity = automaticActivity { ProcessInfo.processInfo.endActivity(activity); automaticActivity = nil }
            return
        }
        guard autoTimer == nil else { return }
        let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.pumpAuto() }
        }
        timer.tolerance = 0.2; autoTimer = timer; RunLoop.main.add(timer, forMode: .common)
    }
    private func pumpAuto() {
        guard connected, !sleeping, !pairingBusy, pending == nil, let info, let snapshot, settingsReadable else { return }
        let desired = autoBindings.matchingLayer(serial: info.serial, bundleID: foregroundID,
                                                available: Set(snapshot.config.layers.map(\.id)))
        if (desired > 0 || hasHostActions) && automaticActivity == nil {
            automaticActivity = ProcessInfo.processInfo.beginActivity(options: .userInitiatedAllowingIdleSystemSleep, reason: "Maintain keyboard auto-layer lease")
        } else if desired == 0 && !hasHostActions, let activity = automaticActivity {
            ProcessInfo.processInfo.endActivity(activity); automaticActivity = nil
        }
        if autoSession == 0 {
            guard hasAutoRules || hasHostActions, Date().timeIntervalSince(lastAutoSent) >= 2 else { return }
            lastAutoSent = Date(); request("runtime.begin", params: EmptyParams()); return
        }
        guard desired != lastAutoLayer || ((desired != 0 || hasHostActions) && Date().timeIntervalSince(lastAutoSent) >= 1.8) else {
            configureAutoTimer(); return
        }
        if autoSequence == 0x7fffffff { autoSession = 0; return }
        autoSequence += 1; lastAutoLayer = desired; lastAutoSent = Date()
        request("runtime.auto", params: AutoLayerParams(session: autoSession, sequence: autoSequence,
                                                       layer: desired, baseRevision: snapshot.revision))
    }
}

extension BoardModel {
    private var connectionURL: URL? {
        settingsDirectory?.appendingPathComponent("connection.json")
    }
    private func loadConnectionPreference() {
        guard let url = connectionURL, FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            guard (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) <= 4096 else { throw RPCError(code: "settings_too_large") }
            let value = try JSONDecoder().decode(ConnectionPreference.self, from: Data(contentsOf: url))
            guard value.isValid else { throw RPCError(code: "invalid_connection_preference") }
            connectionPreference = value
        } catch { errorText = "Cannot read the remembered device. Connect manually." }
    }
    private func saveConnectionPreference() {
        guard let url = connectionURL else { return }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(connectionPreference).write(to: url, options: .atomic)
        } catch { errorText = "Cannot save connection preferences. This connection remains available." }
    }
    private func portsChanged() {
        refreshPorts()
        guard !firmware.blocksEditor else { return }
        let hasRememberedUSB = ports.contains { connectionPreference.matches(serial: $0.serial, vendor: $0.vendor, product: $0.product) }
        if (connected || busy) && ((!usingBluetooth && !ports.contains(where: { $0.path == openPort })) || (usingBluetooth && hasRememberedUSB)) {
            disconnect(manual: false)
        }
        reconnectAttempt = 0
        scheduleReconnect()
    }
    private func scheduleReconnect() {
        guard !firmware.blocksEditor, !sleeping, !connected, !busy, connectionPreference.automatic, reconnectWork == nil else { return }
        let candidates = ports.filter { connectionPreference.matches(serial: $0.serial, vendor: $0.vendor, product: $0.product) }
        guard candidates.count == 1 || (candidates.isEmpty && connectionPreference.bluetooth == true) else {
            status = candidates.isEmpty ? "Waiting for the remembered keyboard" : "Multiple matching ports found. Select one manually."
            return
        }
        let knownBluetoothAvailable = reconnectAttempt >= 6 && candidates.isEmpty &&
            connectionPreference.bluetooth == true && bluetooth.canRetrieveVerifiedDevice
        guard let delay = ConnectionPreference.retryDelay(attempt: reconnectAttempt,
            knownBluetoothAvailable: knownBluetoothAvailable) else { return }
        status = reconnectAttempt >= 6 ? "Waiting for the keyboard to wake…" : "Waiting to reconnect…"
        if reconnectAttempt >= 6 {
            AppLog.shared.event("reconnect background known_device=\(knownBluetoothAvailable) delay_seconds=\(Int(delay))")
        }
        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                guard let self else { return }; self.reconnectWork = nil
                guard !self.firmware.blocksEditor, !self.sleeping, !self.connected, !self.busy, self.connectionPreference.automatic else { return }
                self.refreshPorts()
                let matches = self.ports.filter { self.connectionPreference.matches(serial: $0.serial, vendor: $0.vendor, product: $0.product) }
                guard matches.count <= 1 else { return }
                self.reconnectAttempt = min(self.reconnectAttempt + 1, 7)
                if let port = matches.first {
                    self.selectedPort = port.path; self.connect(automatically: true)
                } else if self.connectionPreference.bluetooth == true {
                    self.connect(automatically: true, wireless: true)
                }
            }
        }
        reconnectWork = work; DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }
}

extension BoardModel {
    private var hostURL: URL? {
        guard !hostSerial.isEmpty, hostSerial.count <= 64,
              hostSerial.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) || $0 == "-" }) else { return nil }
        return bindingsURL?.deletingLastPathComponent().appendingPathComponent("host-actions-\(hostSerial).json")
    }
    private var hasHostActions: Bool {
        snapshot?.config.layers.contains { $0.bindings.contains { $0.kind.isHost } } == true
    }
    private var hostDraftValid: Bool {
        draft.layers.allSatisfy { layer in
            layer.bindings.allSatisfy { b in
                !b.kind.isHost || (hostReadable && hostDraft[b.source]?.kind == b.kind && hostDraft[b.source]?.isValid == true)
            }
        }
    }
    var hostValue: String {
        get { hostDraft[binding.source]?.value ?? "" }
        set {
            guard canEdit, binding.kind.isHost, hostReadable else { return }
            guard hostValue != newValue else { return }
            var id = binding.source
            // Never mutate a saved ID: running device actions keep their saved payload.
            if id == 0 || hostSaved[id] != nil {
                repeat { id = Int.random(in: 1...0x7fffffff) } while hostDraft[id] != nil || (draft.layers + (snapshot?.config.layers ?? [])).contains(where: { $0.bindings.contains(where: { $0.kind.isHost && $0.source == id }) })
                binding.source = id
            }
            hostDraft[id] = HostAction(kind: binding.kind, value: newValue)
            pruneHostDraft()
        }
    }
    var appearanceError: String? { presentation.isValid ? nil : "Action names must be at most 256 UTF-8 bytes; choose a smaller image." }
    var hostEditorHint: String {
        if !hostReadable { return "Local actions are unavailable. Existing data will not be overwritten." }
        if hostDraft[binding.source]?.isValid != true { return "Choose a target or enter valid content. URLs require https:// or http://; text is limited to 4096 UTF-8 bytes." }
        return "Ed.Board must be running. Content is stored locally and activated after saving to the keyboard."
    }
    func chooseHostFile(application: Bool) {
        guard canEdit, binding.kind.isHost else { return }
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseFiles = true; panel.canChooseDirectories = !application
        if application { panel.allowedContentTypes = [.applicationBundle] }
        let originalSession = session, layerID = selectedLayer, control = selectedControl, kind = binding.kind
        panel.begin { [weak self] response in
            Task { @MainActor in
                guard let self, response == .OK, let url = panel.url,
                      self.session == originalSession, self.canEdit, self.selectedLayer == layerID,
                      self.selectedControl == control, self.binding.kind == kind else { return }
                self.hostValue = url.path
            }
        }
    }
    func requestTextPermission() { hostExecutor.requestTextPermission() }
    private func loadHostActions(serial: String) {
        guard hostSerial != serial else { return }
        hostSerial = serial; hostDraft = [:]; hostSaved = [:]; hostReadable = true
        guard let url = hostURL else { hostReadable = false; return }
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            guard (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) <= 20_000_000 else { throw RPCError(code: "host_file_too_large") }
            let catalog = try JSONDecoder().decode(HostCatalog.self, from: Data(contentsOf: url))
            guard catalog.serial == serial, catalog.isValid else { throw RPCError(code: "invalid_host_catalog") }
            hostSaved = catalog.actions; hostDraft = catalog.actions
        } catch { hostReadable = false; hostMessage = "Cannot read local actions. Check the log." }
    }
    private func pruneHostDraft() {
        let ids = Set(draft.layers.flatMap(\.bindings).filter { $0.kind.isHost }.map(\.source))
            .union(hostSaved.keys).union(directBindings.values.filter { $0.kind.isHost }.map(\.source))
        hostDraft = hostDraft.filter { ids.contains($0.key) }
    }
    private func persistHostActions() -> Bool {
        let references = (draft.layers + (snapshot?.config.layers ?? [])).flatMap(\.bindings).filter { $0.kind.isHost }
        guard !references.isEmpty else { return true }
        guard hostReadable, let url = hostURL else { errorText = "Local action storage is unavailable."; return false }
        var catalog = HostCatalog(serial: hostSerial)
        for b in references {
            if let action = hostDraft[b.source], action.isValid, action.kind == b.kind { catalog.actions[b.source] = action }
        }
        guard catalog.isValid, hostDraftValid else { errorText = "Complete the host action settings before saving."; return false }
        do {
            let data = try JSONEncoder().encode(catalog)
            guard data.count <= 20_000_000 else { throw RPCError(code: "host_file_too_large") }
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
            hostSaved = catalog.actions; pruneHostDraft()
            return true
        } catch { errorText = "Could not save local actions. Nothing was written to the keyboard."; return false }
    }
    private func receiveHostAction(_ event: HostActionEvent) {
        guard connected, !sleeping, !pairingBusy, settingsReadable, hostReadable,
              Date().timeIntervalSince(lastAutoSent) <= 4, let snapshot,
              let b = hostGate.accept(event, session: autoSession, lease: autoSequence, snapshot: snapshot) else { return }
        guard let action = hostSaved[b.source], action.kind == b.kind, action.isValid else {
            hostMessage = "This action has no local content. Choose a target and save again."; return
        }
        let token = session
        hostExecutor.execute(action) { [weak self] message in
            guard let self, self.session == token else { return }
            self.hostMessage = message
        }
    }
}

extension BoardModel {
    var currentPresentation: KeyPresentation {
        get { presentation.keys["\(selectedLayer):\(selectedControl)"] ?? KeyPresentation() }
        set { guard binding.kind == .shortcut || binding.kind == .media else { return }; presentation.keys["\(selectedLayer):\(selectedControl)"] = newValue }
    }
    func presentationFor(layer id: Int, control: Int) -> KeyPresentation {
        let custom = presentation.resolved(config: draft, layer: id, control: control)
        guard let effective = draft.resolved(layer: id, control: control) else { return KeyPresentation(name: "Invalid inheritance", symbol: "exclamationmark.triangle") }
        let target = hostDraft[effective.source]?.value ?? ""
        var directory: ObjCBool = false
        if target.hasPrefix("/") { _ = FileManager.default.fileExists(atPath: target, isDirectory: &directory) }
        return ActionPresentation.standard(binding: effective, custom: custom, target: target, folder: directory.boolValue)
    }

    func applicationTarget(_ control: Int) -> String? {
        guard let binding = draft.resolved(layer: selectedLayer, control: control), binding.kind == .application else { return nil }
        return hostDraft[binding.source]?.value
    }
    func actionName(_ control: Int) -> String {
        let label = presentationFor(layer: selectedLayer, control: control).name
        return label.isEmpty ? (draft.resolved(layer: selectedLayer, control: control)?.description ?? "Invalid inheritance") : label
    }
    private var presentationURL: URL? {
        hostURL?.deletingLastPathComponent().appendingPathComponent("appearance-\(hostSerial).json")
    }
    private func loadPresentation(serial: String) {
        guard presentation.serial != serial else { return }
        presentationReadable = true
        presentation = PresentationCatalog(serial: serial); savedPresentation = presentation
        guard let url = presentationURL, FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            guard (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) < 12_000_000 else { throw RPCError(code: "appearance_too_large") }
            let value = try JSONDecoder().decode(PresentationCatalog.self, from: Data(contentsOf: url))
            guard value.isValid, value.serial == serial else { throw RPCError(code: "invalid_appearance") }
            presentation = value; savedPresentation = value
        } catch { presentationReadable = false; errorText = "Could not read key names and images. Existing data will not be overwritten." }
    }
    private func persistPresentation(markSaved: Bool) -> Bool {
        guard presentationReadable, presentation.isValid, let url = presentationURL else { errorText = "Key appearance storage is unavailable."; return false }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            // Stage separately so failed device writes do not change the committed appearance.
            let target = markSaved ? url : url.appendingPathExtension("pending")
            let data = try JSONEncoder().encode(presentation)
            guard data.count < 12_000_000 else { throw RPCError(code: "appearance_too_large") }
            try data.write(to: target, options: .atomic)
            if markSaved { savedPresentation = presentation }
            return true
        } catch { errorText = "Could not save key names and images. Your draft is retained."; return false }
    }
    private func finishLocalSave() {
        guard persistPresentation(markSaved: true), let url = bindingsURL else { return }
        if autoDraft == autoBindings {
            status = "Saved and verified"; errorText = nil
            AppLog.shared.event("configuration saved and verified revision=\(snapshot?.revision ?? 0)")
            finishRestoredFirmwareDraftIfSaved()
            return
        }
        do {
            try JSONEncoder().encode(autoDraft).write(to: url, options: .atomic)
            autoBindings = autoDraft; errorText = nil; status = "Saved and verified"; configureAutoTimer(); updateForeground()
            AppLog.shared.event("configuration saved and verified revision=\(snapshot?.revision ?? 0)")
            finishRestoredFirmwareDraftIfSaved()
        } catch { errorText = "Keyboard saved; app links could not be saved. Retry Save changes." }
    }
    func chooseKeyImage() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.png, .jpeg, .tiff]; panel.allowsMultipleSelection = false
        let layerID = selectedLayer, control = selectedControl, serial = hostSerial
        panel.begin { [weak self] response in
            Task { @MainActor in
                guard let self, response == .OK, let url = panel.url, self.hostSerial == serial,
                      self.selectedLayer == layerID, self.selectedControl == control, self.canEdit,
                      (self.binding.kind == .shortcut || self.binding.kind == .media) else { return }
                guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 8_000_000,
                      let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                      let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                        kCGImageSourceCreateThumbnailFromImageAlways: true,
                        kCGImageSourceThumbnailMaxPixelSize: 128,
                        kCGImageSourceCreateThumbnailWithTransform: true
                      ] as CFDictionary),
                      let data = NSBitmapImageRep(cgImage: thumbnail).representation(using: .png, properties: [:]), data.count <= 131072 else {
                    self.errorText = "Choose a PNG, JPEG or TIFF image smaller than 8 MB."; return
                }
                self.currentPresentation.image = data; self.currentPresentation.symbol = ""

            }
        }
    }
    func discardPower() {
        guard let value = powerState else { return }
        idleSeconds = value.seconds; idleLightsEnabled = value.enabled; deepMinutes = value.deepMinutes; keepConnected = value.keepConnected
    }
    var powerDirty: Bool {
        guard let value = powerState else { return false }
        return idleSeconds != value.seconds || idleLightsEnabled != value.enabled || deepMinutes != value.deepMinutes || keepConnected != value.keepConnected
    }
    func acceptConflict() { configurationConflict = false }
    func retryConnection() {
        if connected && !busy && !dirty { refresh(); return }
        let wireless = usingBluetooth
        disconnect(manual: false); refreshPorts()
        connect(wireless: wireless || selectedPort.isEmpty)
    }
    func beginInitialDiscovery() {
        guard !firmware.blocksEditor, !connected, !busy, connectionPreference.serial.isEmpty else { return }
        let candidates = ports.filter { $0.vendor == 0x303a && $0.product == 0x8360 }
        guard candidates.count == 1 else { return }
        selectedPort = candidates[0].path; connect()
    }
    private func invalidateJoystick() {
        joystickOverlay.hide(); joystickGate.reset()
        joystickToken = Int.random(in: 1...0x7fffffff)
        joystickWatchTarget = nil
    }
    private func syncJoystickWatch() {
        guard connected, pending == nil, info?.joystickVersion == 1, !joystickUnavailable,
              !firmware.active, !firmwareMismatch else { return }
        let enabled = !sleeping && snapshot != nil && !pairingBusy && firmwareReady
        guard joystickWatchTarget != enabled else { return }
        joystickWatchTarget = enabled
        request("joystick.watch", params: PreviewWatch(token: joystickToken, enabled: enabled))
    }
    private func receiveJoystick(_ frame: JoystickFrame) {
        guard connected, !sleeping, !pairingBusy, firmwareReady, joystickWatchTarget == true,
              !joystickUnavailable, joystickGate.accept(frame, token: joystickToken) else { return }
        guard frame.visible, let snapshot, snapshot.revision == frame.revision,
              snapshot.config.layers.contains(where: { $0.id == frame.layer }), frame.layer != 1 else {
            joystickOverlay.hide(); return
        }
        joystickOverlay.update(frame) {
            Control.stickIDs.map { control in
                let binding = snapshot.config.resolved(layer: frame.layer, control: control)
                let custom = savedPresentation.resolved(config: snapshot.config, layer: frame.layer, control: control)
                let target = binding.flatMap { hostSaved[$0.source]?.value } ?? ""
                var folder: ObjCBool = false
                if target.hasPrefix("/") { _ = FileManager.default.fileExists(atPath: target, isDirectory: &folder) }
                let appearance = binding.map { ActionPresentation.standard(binding: $0, custom: custom, target: target, folder: folder.boolValue) }
                    ?? KeyPresentation(name: "Unavailable", symbol: "nosign")
                return JoystickOverlayController.icon(presentation: appearance,
                    application: binding?.kind == .application ? target : nil, disabled: binding == nil || binding?.kind == .disabled)
            }
        }
    }
    private struct PreviewWatch: Encodable { let token: Int; let enabled: Bool }
    func setPreviewVisible(_ visible: Bool) {
        guard previewVisible != visible else { return }
        previewVisible = visible
        // A stop request may have already installed the previous token while hidden.
        // Rotate again on entry so firmware drops accumulated press edges before streaming.
        resetPreview()
        if !visible, connected, pending == nil, info?.previewVersion == 1 {
            request("preview.watch", params: PreviewWatch(token: previewToken, enabled: false))
        }
    }
    func previewTick() {
        guard previewVisible, !sleeping, connected, snapshot != nil, info?.previewVersion == 1 else { return }
        if Date().timeIntervalSince(previewReceived) > 1 { if previewCancelled { previewCancelled = false }; if previewKeys != 0 { previewKeys = 0 }; if previewX != 0 { previewX = 0 }; if previewY != 0 { previewY = 0 }; if previewTouch { previewTouch = false } }
        if Date().timeIntervalSince(previewWatchSent) >= 2, pending == nil, !busy {
            previewWatchSent = Date(); request("preview.watch", params: PreviewWatch(token: previewToken, enabled: true))
        }
        if Date() > previewPulseUntil {
            if previewPressed != 0 { previewPressed = 0 }; if previewTurnLeft { previewTurnLeft = false }; if previewTurnRight { previewTurnRight = false }
            if previewTouch && previewPrevious?.touched != true { previewTouch = false }
        }
    }
    private func resetPreview() {
        previewCancelled = false; previewKeys = 0; previewPressed = 0; previewX = 0; previewY = 0; previewTouch = false; previewTurnLeft = false; previewTurnRight = false
        previewPrevious = nil; previewWatchSent = .distantPast; previewToken = Int.random(in: 1...0x7fffffff)
    }
    private func receivePreview(_ frame: PreviewFrame) {
        guard previewVisible, !sleeping, frame.accepts(token: previewToken, after: previewPrevious?.sequence) else { return }
        previewReceived = Date(); if previewUnavailable { previewUnavailable = false }
        if previewCancelled != (frame.cancelled ?? false) { previewCancelled = frame.cancelled ?? false }
        if previewKeys != frame.keys { previewKeys = frame.keys }
        if previewX != Double(frame.x)/1000 { previewX = Double(frame.x)/1000 }
        if previewY != Double(frame.y)/1000 { previewY = Double(frame.y)/1000 }
        let touching = frame.touched || (previewPrevious.map { frame.touchCount != $0.touchCount } ?? false)
        if previewTouch != touching { previewTouch = touching }
        if let previous = previewPrevious {
            let left = frame.left != previous.left || (previewTurnLeft && Date() < previewPulseUntil)
            let right = frame.right != previous.right || (previewTurnRight && Date() < previewPulseUntil)
            if previewTurnLeft != left { previewTurnLeft = left }
            if previewTurnRight != right { previewTurnRight = right }
        }
        if frame.pressed != 0 || previewPrevious.map({ frame.left != $0.left || frame.right != $0.right || frame.touchCount != $0.touchCount }) == true {
            if (previewPressed | frame.pressed) != previewPressed { previewPressed |= frame.pressed }; previewPulseUntil = Date().addingTimeInterval(0.12)
        }
        previewPrevious = frame
    }
}

extension BoardModel {
    var batteryPercent: Int { deviceStatus?.battery ?? info?.battery ?? 0 }
    var batteryKnown: Bool { connected && (deviceStatus?.batteryValid ?? info?.batteryValid ?? false) }
    var batteryCharging: Bool { connected && (deviceStatus?.charging ?? info?.charging ?? false) }
    var batteryFull: Bool { connected && (deviceStatus?.full ?? info?.full ?? false) }
    var batteryLabel: String {
        guard connected, deviceStatus?.batteryValid ?? info?.batteryValid ?? false else { return "Unavailable" }
        let percent = deviceStatus?.battery ?? info?.battery ?? 0
        return "\(percent)%" + (statusUnavailable || !supportsSeconds ? " · Last Read" : "")
    }
    var batterySymbol: String {
        let value = deviceStatus?.battery ?? info?.battery ?? 0
        return value > 75 ? "battery.100" : value > 50 ? "battery.75" : value > 25 ? "battery.50" : value > 5 ? "battery.25" : "battery.0"
    }
    func setStatusVisible(_ visible: Bool) { statusVisible = visible; if visible { statusSent = .distantPast } }
    private func statusReadFailed() {
        statusUnavailable = true
        // Reuse the existing visible-page/menu ticks; no background retry timer.
        statusRetryAfter = Date().addingTimeInterval(60)
    }
    func statusTick() {
        guard (statusVisible || menuStatusVisible), connected, !sleeping, !busy, pending == nil, !pairingBusy,
              supportsSeconds, Date() >= statusRetryAfter, Date().timeIntervalSince(statusSent) >= 15 else { return }
        statusSent = Date(); request("device.status", params: EmptyParams())
    }
}

extension BoardModel {
    var firmwareUpdateSucceeded: Bool {
        firmware.stage == "success" && connected && snapshot != nil && !firmwareMismatch &&
        firmware.record?.target == FirmwareUpdater.required && firmware.record?.serial == firmwareIdentity?.serial
    }
    var hasCurrentFirmwareAttempt: Bool {
        guard let record = firmware.record else { return false }
        return record.stage != "success" && record.target == FirmwareUpdater.required &&
            (firmwareIdentity == nil || record.serial == firmwareIdentity?.serial)
    }
    var firmwareMismatch: Bool {
        guard let device = firmwareIdentity else { return false }
        return device.firmware != FirmwareUpdater.required || device.schemaVersion != 7 || device.runtimeVersion != 2
    }
    var firmwareReady: Bool { firmwareIdentity != nil && !firmwareMismatch && !firmware.blocksEditor }
    var canBeginFirmware: Bool {
        !firmware.active && !busy && !pairingBusy &&
        ((connected && !usingBluetooth && firmwareIdentity?.recognized == true) || firmware.record != nil)
    }
    func startFirmwareUpdate() {
        guard canBeginFirmware else { return }
        if let identity = firmwareIdentity, !(2...7).contains(identity.schemaVersion) {
            firmware.fail("This configuration version cannot be safely installed by this app. Use a matching newer app; no firmware was written."); return
        }
        let identity = firmwareIdentity?.serial ?? firmware.record?.serial
        guard let identity else { return }
        refreshPorts()
        let matches = ports.filter { $0.serial == identity && $0.vendor == 0x303a && $0.product == 0x8360 }
        let recovery = ports.filter { $0.vendor == 0x303a && ($0.product == 0x1001 || $0.product == 0x0009) }
        guard matches.count == 1 || (matches.isEmpty && recovery.count == 1 && firmware.record?.serial == identity) else {
            firmware.fail("Connect the same keyboard via USB. If multiple download-mode devices are connected, disconnect the others."); return
        }
        let path = (matches.first ?? recovery.first)!.path
        do {
            // Persist all local drafts before releasing the management connection.
            struct Backup: Codable {
                let serial: String; let config: BoardConfiguration; let base: Snapshot?
                let hasUnsavedDraft: Bool
                let appearance: PresentationCatalog; let links: AutoBindings
                let host: [Int: HostAction]
                let idleSeconds: Int; let idleLightsEnabled: Bool; let deepMinutes: Int; let keepConnected: Bool
            }
            let data = try JSONEncoder().encode(Backup(serial: identity, config: detachedDraft?.config ?? draft, base: snapshot ?? detachedDraft?.base, hasUnsavedDraft: dirty || powerDirty,
                appearance: presentation, links: autoDraft, host: hostDraft, idleSeconds: idleSeconds,
                idleLightsEnabled: idleLightsEnabled, deepMinutes: deepMinutes, keepConnected: keepConnected))
            let backup = try firmware.prepare(serial: identity, backup: data, source: firmwareIdentity?.firmware)
            disconnect(manual: false)
            serial.shutdown() // Wait until our serial queue has relinquished ownership.
            firmware.install(port: path, backup: backup) { [weak self] success in
                if success { self?.reconnectAfterFirmware() }
            }
        } catch { firmware.fail("Cannot prepare update: \(error.localizedDescription)") }
    }
    func reconnectAfterFirmware() {
        guard let target = firmware.record?.serial else { return }
        firmware.checkAgain()
        Task { @MainActor [weak self] in
            guard let self else { return }
            for _ in 0..<30 {
                guard self.firmware.stage == "checking" else { return }
                self.refreshPorts()
                if !self.connected && !self.busy,
                   let port = self.ports.first(where: { $0.serial == target && $0.vendor == 0x303a && $0.product == 0x8360 }) {
                    self.selectedPort = port.path; self.connect()
                }
                if self.connected, self.firmwareIdentity?.serial == target, !self.firmwareMismatch, self.snapshot != nil {
                    guard self.snapshot?.writable == true else {
                        self.firmware.fail("Firmware matches, but configuration storage is not writable. Open System and inspect the device log.", settings: true); return
                    }
                    guard self.firmware.record?.verified == true else {
                        self.firmware.fail("Installation verification is missing. Recovery files have been retained."); return
                    }
                    self.firmware.confirmed()
                    self.firmware.cleanupSuccessfulUpdate(keepDraft: self.hasPendingFirmwareDraft)
                    self.readPower(); return
                }
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
            if self.firmware.stage == "checking" {
                self.firmware.fail(self.errorText ?? "The keyboard has not reconnected. Check USB and reconnect before retrying installation.",
                    settings: self.connected && self.firmwareIdentity?.serial == target && !self.firmwareMismatch)
            }
        }
    }
    var hasPendingFirmwareDraft: Bool {
        guard let record = firmware.record, record.stage == "success", record.draftHandled != true,
              record.serial == firmwareIdentity?.serial, firmwareReady, snapshot != nil else { return false }
        struct DraftMetadata: Decodable {
            let hasUnsavedDraft: Bool?
            let config: BoardConfiguration
            let base: Snapshot?
        }
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: record.backup).appendingPathComponent("app-draft.json")),
              let value = try? JSONDecoder().decode(DraftMetadata.self, from: data), let base = value.base else { return true }
        return value.hasUnsavedDraft ?? (value.config != base.config)
    }
    private func finishRestoredFirmwareDraftIfSaved() {
        guard restoredFirmwareDraft, !dirty, !powerDirty, powerState != nil else { return }
        firmware.markDraftHandled(); restoredFirmwareDraft = false
    }
    func restoreFirmwareDraft() {
        guard let record = firmware.record, record.serial == firmwareIdentity?.serial else { return }
        struct Backup: Decodable {
            let config: BoardConfiguration; let base: Snapshot?
            let appearance: PresentationCatalog; let links: AutoBindings; let host: [Int: HostAction]
            let idleSeconds: Int; let idleLightsEnabled: Bool; let deepMinutes: Int; let keepConnected: Bool
        }
        do {
            let value = try JSONDecoder().decode(Backup.self, from: Data(contentsOf: URL(fileURLWithPath: record.backup).appendingPathComponent("app-draft.json")))
            guard value.base != nil, value.config.isValid, value.appearance.isValid, value.links.isValid else { throw RPCError(code: "invalid_backup") }
            draft = value.config; presentation = value.appearance; autoDraft = value.links; hostDraft = value.host
            idleSeconds = value.idleSeconds; idleLightsEnabled = value.idleLightsEnabled; deepMinutes = value.deepMinutes; keepConnected = value.keepConnected
            configurationConflict = value.base.map { $0.config != snapshot?.config } ?? true
            restoredFirmwareDraft = true
            errorText = "Recovered local draft. Review it before saving; device settings were not overwritten."
        } catch { firmware.fail("Could not restore the local draft. The backup is retained for inspection: \(error.localizedDescription)", settings: true) }
    }
}
