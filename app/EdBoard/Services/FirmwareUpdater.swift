import Foundation
import Combine
import CryptoKit
import AppKit
import BoardCore

struct FirmwareIdentity: Codable {
    let device: String
    let serial: String
    let firmware: String
    let schemaVersion: Int
    let runtimeVersion: Int?
    var recognized: Bool { device == "Ed.Board" && serial.range(of: "^CM3-[0-9A-Fa-f]{12}$", options: .regularExpression) != nil }
}

@MainActor
final class FirmwareUpdater: ObservableObject {
    static let required = "0.6.0"
    struct Record: Codable {
        let serial: String
        let target: String
        var source: String?
        let backup: String
        var stage: String
        var verified: Bool?
        var draftHandled: Bool?
        var scopedLog: Bool?
    }
    @Published var showPreparation = false
    @Published var stage = "idle"
    @Published var message = ""
    @Published var progress: Double?
    @Published var details = ""
    @Published private(set) var record: Record?
    private var process: Process?
    private var activity: NSObjectProtocol?
    private var watchdog: Task<Void, Never>?
    private var pipe: Pipe?
    var active: Bool { process != nil || ["preparing", "entering", "backup", "writing", "verifying", "restarting", "checking"].contains(stage) }
    var blocksEditor: Bool { active || stage == "failed" || stage == "interrupted" || stage == "settings" || stage == "awaitingRestart" }
    var title: String {
        switch stage {
        case "preparing": return "Preparing update…"
        case "entering": return "Entering update mode…"
        case "backup": return "Backing up keyboard settings…"
        case "writing": return "Installing firmware…"
        case "verifying": return "Verifying firmware…"
        case "restarting": return "Restarting keyboard…"
        case "checking": return "Checking keyboard…"
        case "success": return "Firmware updated successfully"
        case "settings": return "Firmware updated — settings need attention"
        case "awaitingRestart": return "Firmware installed — waiting for keyboard"
        case "interrupted": return "Update interrupted"
        default: return "Firmware update failed"
        }
    }
    var root: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Ed.Board/Firmware", isDirectory: true)
    }
    var journal: URL { root.appendingPathComponent("update.json") }
    var log: URL {
        if let record, record.scopedLog == true {
            return URL(fileURLWithPath: record.backup).appendingPathComponent("update.log")
        }
        return root.appendingPathComponent("update.log") // Legacy attempts remain readable.
    }
    var package: URL? { Bundle.main.resourceURL?.appendingPathComponent("Firmware", isDirectory: true) }
    init() {
        if let data = try? Data(contentsOf: journal), let saved = try? JSONDecoder().decode(Record.self, from: data) {
            record = saved
            // A completed journal is history, not a successful update in this session.
            // Keep its backup, but start with no success banner until live verification.
            if saved.stage != "success" { stage = saved.verified == true ? "awaitingRestart" : "interrupted"; message = "The previous update was not confirmed. Connect the same keyboard via USB, then check its connection before retrying installation." }
        }
    }
    func append(_ text: String) {
        guard stage != "success" else { return }
        details += text + "\n"
        if details.count > 24000 { details = String(details.suffix(24000)) }
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: log.path) { FileManager.default.createFile(atPath: log.path, contents: nil) }
        do { try AppLog.append(Data((String(text.prefix(24000)) + "\n").utf8), to: log, limit: 2 * 1024 * 1024) }
        catch { AppLog.shared.event("firmware diagnostic log unavailable") }
    }
    private func persist() throws {
        guard let record else { return }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(record)
        try data.write(to: journal, options: .atomic)
        // A per-attempt receipt makes later retention decisions explicit.
        let directory = URL(fileURLWithPath: record.backup).standardizedFileURL
        if directory.deletingLastPathComponent().path == root.standardizedFileURL.path,
           UUID(uuidString: directory.lastPathComponent) != nil,
           directory.resolvingSymlinksInPath().path == directory.path,
           FileManager.default.fileExists(atPath: directory.path) {
            try data.write(to: directory.appendingPathComponent("record.json"), options: .atomic)
        }
    }
    func prepare(serial: String, backup: Data, source: String? = nil) throws -> URL {
        guard !active else { throw failure("An update is already running.") }
        guard let package else { throw failure("Firmware package is missing. Rebuild the application package.") }
        let manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: package.appendingPathComponent("manifest.json"))) as? [String: Any]
        guard manifest?["version"] as? String == Self.required else { throw failure("The bundled firmware does not match this application.") }
        for name in ["firmware", "partitions"] {
            let data = try Data(contentsOf: package.appendingPathComponent(name + ".bin"))
            let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            guard digest == manifest?[name + "SHA256"] as? String else { throw failure("Firmware package checksum failed.") }
        }
        guard FileManager.default.isExecutableFile(atPath: package.appendingPathComponent("helper/edboard-flasher").path) else { throw failure("The bundled USB installer is missing. Run the packaging step before building the app.") }
        // Preserve the old journal before replacing it. Unknown legacy folders remain untouched.
        try persist()
        let previous = record
        let destination = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let retained: Data
        if let old = record, old.serial == serial, old.draftHandled != true {
            retained = try Data(contentsOf: URL(fileURLWithPath: old.backup).appendingPathComponent("app-draft.json"))
        } else { retained = backup }
        try retained.write(to: destination.appendingPathComponent("app-draft.json"), options: .atomic)
        record = Record(serial: serial, target: Self.required, source: source, backup: destination.path, stage: "preparing", scopedLog: true)
        try persist()
        // Only mark the previous draft migrated after the new draft and journal are durable.
        if var old = previous, old.serial == serial, old.draftHandled != true {
            old.draftHandled = true
            let directory = URL(fileURLWithPath: old.backup).standardizedFileURL
            if directory.deletingLastPathComponent().path == root.standardizedFileURL.path,
               UUID(uuidString: directory.lastPathComponent) != nil,
               directory.resolvingSymlinksInPath().path == directory.path,
               FileManager.default.fileExists(atPath: directory.path) {
                do { try JSONEncoder().encode(old).write(to: directory.appendingPathComponent("record.json"), options: .atomic) }
                catch { AppLog.shared.event("firmware history draft migration receipt unavailable; previous recovery retained") }
            }
        }
        do { try FirmwareHistory.prune(root: root, current: destination) }
        catch { AppLog.shared.event("firmware history cleanup incomplete; recovery files retained") }
        stage = "preparing"; message = ""; progress = nil
        AppLog.shared.event("firmware update preparing")
        return destination
    }
    func install(port: String, backup: URL, completion: @escaping (Bool) -> Void) {
        guard let record, let package else { fail("Update preparation is missing."); return }
        let task = Process()
        task.executableURL = package.appendingPathComponent("helper/edboard-flasher")
        task.arguments = ["--package", package.path, "--port", port, "--serial", record.serial, "--backup", backup.path]
        let output = Pipe(); pipe = output; task.standardOutput = output
        // Separate raw esptool diagnostics from structured progress.
        let errorPipe = Pipe(); task.standardError = errorPipe
        let framer = FirmwareOutputFramer()
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil; return }
            let lines = framer.feed(data)
            Task { @MainActor in
                for line in lines { self?.event(line) }
            }
        }
        errorPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil; return }
            Task { @MainActor in self?.append(String(decoding: data, as: UTF8.self)) }
        }
        task.terminationHandler = { [weak self] child in
            Task { @MainActor in
                guard let self else { return }
                self.watchdog?.cancel(); self.process = nil
                // Exit zero is emitted only after write/hash/NVS checks and reset.
                if child.terminationStatus == 0 {
                    self.stage = "checking"; self.progress = nil
                    self.record?.stage = "checking"; self.record?.verified = true; try? self.persist(); completion(true)
                } else {
                    if self.stage != "failed" && self.stage != "awaitingRestart" { self.fail("USB installation stopped. Check the log, reconnect the keyboard and retry.") }
                    self.endActivity(); completion(false)
                }
            }
        }
        do {
            activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .idleSystemSleepDisabled], reason: "Installing keyboard firmware")
            process = task; stage = "entering"; self.record?.stage = stage; try persist()
            append("Update started \(Date()) target=\(Self.required) serial=\(record.serial)")
            try task.run()
            watchdog = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 240_000_000_000)
                guard !Task.isCancelled, let self, self.process?.isRunning == true else { return }
                self.fail("USB installation timed out. The keyboard may need recovery.")
                self.process?.terminate()
            }
        } catch { process = nil; fail(error.localizedDescription); completion(false) }
    }
    private func event(_ line: String) {
        guard stage != "success" else { return }
        append(line)
        guard let data = line.data(using: .utf8), let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let next = value["stage"] as? String else { return }
        if next == "verified" { record?.verified = true; try? persist(); return }
        if next == "failed" { fail(value["message"] as? String ?? "USB installation failed."); return }
        guard process != nil, stage != "failed", stage != "awaitingRestart", next != "written" else { return }
        if stage != next { AppLog.shared.event("firmware update stage=\(next)") }
        stage = next; progress = value["progress"] as? Double
        record?.stage = next
        do { try persist() } catch { append("Could not update recovery journal: \(error)") }
    }
    func confirmed() {
        showPreparation = false
        stage = "success"; message = ""; record?.stage = stage; try? persist(); endActivity()
        AppLog.shared.event("firmware update succeeded from=\(record?.source ?? "unknown") to=\(record?.target ?? Self.required) identity/version/configuration verified")
    }
    func cleanupSuccessfulUpdate(keepDraft: Bool) {
        guard let record, record.stage == "success", process == nil else { return }
        let directory = URL(fileURLWithPath: record.backup).standardizedFileURL
        // Delete only this update's known artifacts within our owned UUID directory.
        guard directory.deletingLastPathComponent().path == root.standardizedFileURL.path,
              UUID(uuidString: directory.lastPathComponent) != nil,
              directory.resolvingSymlinksInPath().path == directory.path else { return }
        do {
            let fm = FileManager.default
            for name in ["device-nvs.bin"] + (keepDraft ? [] : ["app-draft.json"]) {
                let file = directory.appendingPathComponent(name)
                if fm.fileExists(atPath: file.path) { try fm.removeItem(at: file) }
            }
            for index in 0...4 where record.scopedLog == true {
                let file = index == 0 ? log : URL(fileURLWithPath: log.path + ".\(index)")
                if fm.fileExists(atPath: file.path) { try fm.removeItem(at: file) }
            }
            details = ""
            if !keepDraft {
                let receipt = directory.appendingPathComponent("record.json")
                if fm.fileExists(atPath: receipt.path) { try fm.removeItem(at: receipt) }
                if (try fm.contentsOfDirectory(atPath: directory.path)).isEmpty { try fm.removeItem(at: directory) }
                if fm.fileExists(atPath: journal.path) { try fm.removeItem(at: journal) }
                self.record?.draftHandled = true
            }
        } catch { AppLog.shared.event("firmware success cleanup incomplete; recovery files retained") }
    }
    var hasRecoveryFiles: Bool {
        guard let record else { return false }
        return record.stage != "success" || record.draftHandled != true
    }
    func markDraftHandled() {
        record?.draftHandled = true; try? persist()
        cleanupSuccessfulUpdate(keepDraft: false)
    }
    func fail(_ text: String, settings: Bool = false) {
        stage = settings ? "settings" : record?.verified == true ? "awaitingRestart" : "failed"; message = text; progress = nil
        AppLog.shared.event("firmware update needs attention stage=\(stage)")
        record?.stage = stage; try? persist(); append(text)
        if process == nil { endActivity() }
    }
    func checkAgain() { guard !active else { return }; stage = "checking"; message = "" }
    private func endActivity() { if let activity { ProcessInfo.processInfo.endActivity(activity) }; activity = nil }
    private func failure(_ text: String) -> NSError { NSError(domain: "Firmware", code: 1, userInfo: [NSLocalizedDescriptionKey: text]) }
}

// FileHandle invokes its handler off the main actor. Protect the per-process
// partial line buffer; only complete, immutable strings cross into the UI.
private final class FirmwareOutputFramer: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = Data()
    func feed(_ data: Data) -> [String] {
        lock.lock()
        defer { lock.unlock() }
        buffer.append(data)
        var lines = [String]()
        while let range = buffer.firstRange(of: Data([10])) {
            lines.append(String(decoding: buffer[..<range.lowerBound], as: UTF8.self))
            buffer.removeSubrange(..<range.upperBound)
        }
        return lines
    }
}
