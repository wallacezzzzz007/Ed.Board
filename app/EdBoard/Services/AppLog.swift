import Foundation
import Combine
import BoardCore

// All file IO, counters and rotation are confined to one utility queue. Logs are
// deliberately independent of the transport: disk failure never disconnects input.
final class AppLog: ObservableObject, @unchecked Sendable {
    static let shared = AppLog()
    @Published private(set) var detailed = false
    @Published private(set) var failure: String?
    let directory = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Logs/Ed.Board", isDirectory: true)
    var url: URL { directory.appendingPathComponent("app.log") }
    private let queue = DispatchQueue(label: "EdBoard.log", qos: .utility)
    private let formatter = ISO8601DateFormatter()
    private var timer: DispatchSourceTimer?
    private var detailStop: DispatchWorkItem?
    private var detailUntil: Date?
    private var counts = [String: Int]()
    private var repeated = [String: Int]()
    private var recent = [String]()
    private var requests = [Int: (String, Date)]()
    private var transport = "disconnected"
    private var battery = "unknown"
    private var lastHealth = ""
    private init() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 300, repeating: 300, leeway: .seconds(10))
        timer.setEventHandler { [weak self] in self?.summary() }
        self.timer = timer; timer.resume()
        event("app started version=\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") ?? "unknown") build=\(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") ?? "unknown")")
    }
    func event(_ message: String) {
        queue.async { self.record(String(message.prefix(600))) }
    }
    func connection(_ value: String) {
        queue.async { self.transport = value; self.write("connection \(value)", detailed: false) }
    }
    func setDetailed(_ enabled: Bool) {
        queue.async { [self] in
            self.detailStop?.cancel(); self.detailStop = nil
            self.detailUntil = enabled ? Date().addingTimeInterval(1800) : nil
            DispatchQueue.main.async { self.detailed = enabled }
            self.record(enabled ? "detailed diagnostics started duration=30min" : "detailed diagnostics stopped")
            if enabled {
                let work = DispatchWorkItem { [weak self] in
                    guard let self else { return }
                    self.detailUntil = nil; self.record("detailed diagnostics expired")
                    DispatchQueue.main.async { self.detailed = false }
                }
                self.detailStop = work; self.queue.asyncAfter(wallDeadline: .now() + 1800, execute: work)
            }
        }
    }
    func readRecent(_ completion: @escaping (String) -> Void) {
        queue.async {
            let text = self.recent.joined(separator: "\n")
            DispatchQueue.main.async { completion(text) }
        }
    }
    func shutdown() {
        queue.sync { summary(); record("app exited"); detailStop?.cancel(); timer?.cancel() }
    }
    func ingest(_ text: String, transport: String) {
        queue.async {
            for line in text.split(separator: "\n") { self.consume(String(line), transport: transport) }
        }
    }
    private func consume(_ line: String, transport: String) {
        // Never persist raw protocol payloads: config, text, shortcuts and paths
        // remain private even when detailed diagnostics are enabled.
        if let range = line.range(of: "@edboard "),
           let object = try? JSONSerialization.jsonObject(with: Data(line[range.upperBound...].utf8)) as? [String: Any] {
            let id = object["id"] as? Int
            let method = object["method"] as? String
            let transmitting = line.hasPrefix("app ")
            if transmitting, let id, let method {
                if requests.count >= 256 { requests.removeAll() }
                requests[id] = (method, Date())
                counts["tx", default: 0] += 1
                detail("\(transport) tx id=\(id) method=\(method)")
            } else if let id {
                let request = requests.removeValue(forKey: id)
                let method = request?.0 ?? "unknown"
                let elapsed = request.map { Int(Date().timeIntervalSince($0.1) * 1000) } ?? -1
                let failed = object["error"] != nil
                counts[failed ? "rpc_failed" : "rpc_ok", default: 0] += 1
                detail("\(transport) rx id=\(id) method=\(method) ok=\(!failed) elapsed_ms=\(elapsed)")
                if failed {
                    let raw = (object["error"] as? [String: Any])?["code"] as? String ?? "unknown"
                    let code = String(raw.prefix(80).filter { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") })
                    record("RPC failed method=\(method) code=\(code)")
                }
                if let result = object["result"] as? [String: Any] {
                    if method == "device.status", let value = result["battery"] as? Int {
                        battery = "\(value)% valid=\(result["batteryValid"] as? Bool ?? false) charging=\(result["charging"] as? Bool ?? false) read_at=\(formatter.string(from: Date()))"
                    }
                    if method == "config.set" || method == "config.get" {
                        if let revision = result["revision"] as? Int {
                            record("\(method) ok revision=\(revision)")
                        }
                    }
                }
            } else { counts["events", default: 0] += 1 }
            return
        }
        if line.hasPrefix("@edboard ") {
            counts["invalid_frames", default: 0] += 1
            record("invalid protocol JSON received"); return
        }
        if line.hasPrefix("app error ") || line.hasPrefix("app ble error ") {
            counts["transport_errors", default: 0] += 1
            record(String(line.prefix(400))); return
        }
        if line.contains("Ed.Board BLE session") || line.contains("Ed.Board App session") {
            detail("\(transport) connection attempt"); return
        }
        if line.hasPrefix("app ble ") {
            // Do not persist peripheral identifiers or names of nearby devices.
            if !line.contains("candidate") && !line.contains("peripheral") {
                detail(String(line.prefix(400)))
            }
            return
        }
        if line.hasPrefix("edboard ") {
            counts["firmware_lines", default: 0] += 1
            let fields = line.split(separator: " ").compactMap { part -> (String, String)? in
                let pieces = part.split(separator: "=", maxSplits: 1)
                return pieces.count == 2 ? (String(pieces[0]), String(pieces[1])) : nil
            }
            let allowed: Set<String> = ["ms", "event", "seq", "at_ms", "kind", "a", "b", "c", "lost", "ready", "fault", "armed", "input_drops", "rpc_errors", "light_fault", "management_errors", "tx_failures", "parse_errors", "log_drops", "storage_ok"]
            let faultDetail = fields.contains { $0.0 == "event" && $0.1 == "input_fault_detail" }
            let faultNumbers: Set<String> = ["x", "y", "touch", "x_span", "y_span", "touch_span", "adc_x_error", "adc_y_error", "touch_error", "raw_touch"]
            let safe = fields.filter { allowed.contains($0.0) || (faultDetail &&
                ((faultNumbers.contains($0.0) && Int64($0.1) != nil) ||
                 ($0.0 == "reason" && ["calibration_failed", "sensor_read_failed"].contains($0.1)))) }.map { "\($0.0)=\($0.1)" }.joined(separator: " ")
            detail("firmware \(safe)")
            let faults: Set<String> = ["fault", "input_drops", "rpc_errors", "light_fault", "management_errors", "tx_failures", "parse_errors"]
            let health = fields.filter { faults.contains($0.0) && $0.1 != "0" }.map { "\($0.0)=\($0.1)" }.joined(separator: " ")
            if !health.isEmpty && health != lastHealth { lastHealth = health; record("firmware counters \(health)") }
        }
    }
    private func summary() {
        for (message, count) in repeated.sorted(by: { $0.key < $1.key }) where count > 1 {
            write("repeated count=\(count) \(message)", detailed: false)
        }
        repeated.removeAll()
        let counters = counts.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " ")
        write("summary transport=\(transport) battery=\(battery) \(counters)", detailed: false)
        counts.removeAll()
    }
    private func record(_ value: String) {
        if let count = repeated[value] { repeated[value] = count + 1; return }
        if repeated.count >= 128 { summary() }
        repeated[value] = 1; write(value, detailed: false)
    }
    private func detail(_ value: String) {
        guard let until = detailUntil, Date() < until else { return }
        write(value, detailed: true)
    }
    private func write(_ message: String, detailed: Bool) {
        let line = formatter.string(from: Date()) + " " + message + "\n"
        if !detailed {
            recent.append(String(line.dropLast()))
            if recent.count > 200 { recent.removeFirst(recent.count - 200) }
        }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let target = detailed ? directory.appendingPathComponent("diagnostic.log") : url
            let data = Data(line.utf8)
            try Self.append(data, to: target, limit: detailed ? 4 * 1024 * 1024 : 2 * 1024 * 1024)
            DispatchQueue.main.async { if self.failure != nil { self.failure = nil } }
        } catch {
            DispatchQueue.main.async { self.failure = "Log recording unavailable. Device connection is unaffected." }
        }
    }
    // Five files total, bounded before every append, including across launches.
    static func append(_ data: Data, to url: URL, limit: Int) throws {
        try RotatingLog.append(data, to: url, limit: limit)
    }
}
