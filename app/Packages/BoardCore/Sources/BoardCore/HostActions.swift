import Foundation

/// Payloads stay on this Mac. Device configuration contains only immutable IDs.
public struct HostAction: Codable, Equatable {
    public var kind: ActionKind
    public var value: String
    public init(kind: ActionKind, value: String = "") { self.kind = kind; self.value = value }
    public var isValid: Bool {
        guard kind.isHost, !value.isEmpty, value.utf8.count <= 4096, !value.contains("\0") else { return false }
        if kind == .text { return true }
        if value.hasPrefix("/") {
            return kind != .application || URL(fileURLWithPath: value).pathExtension.lowercased() == "app"
        }
        guard kind == .open, let url = URL(string: value),
              ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              let host = url.host, !host.isEmpty, url.user == nil, url.password == nil,
              !value.unicodeScalars.contains(where: { $0.value <= 32 || $0.value == 127 }) else { return false }
        return true
    }
}
public struct HostCatalog: Codable {
    public var version = 1
    public var serial: String
    public var actions: [Int: HostAction] = [:]
    public init(serial: String) { self.serial = serial }
    public var isValid: Bool {
        version == 1 && !serial.isEmpty && actions.count <= 800
            && actions.allSatisfy { (1...0x7fffffff).contains($0.key) && $0.value.isValid }
    }
}
public struct HostActionEvent: Decodable {
    public let `protocol`: Int
    public let event: String
    public let session: Int
    public let sequence: Int
    public let lease: Int
    public let revision: Int
    public let layer: Int
    public let control: Int
    public let source: Int
}
/// Consume once per live session and only against the saved device snapshot.
public struct HostActionGate {
    private var token = 0
    private var lastSequence = 0
    public init() {}
    public mutating func reset() { token = 0; lastSequence = 0 }
    public mutating func accept(_ event: HostActionEvent, session: Int, lease: Int,
                                snapshot: Snapshot) -> Binding? {
        guard session > 0, event.protocol == 1, event.event == "host.action", event.session == session,
              (1...0x7fffffff).contains(event.sequence), event.revision == snapshot.revision,
              event.lease > 0, event.lease <= lease, event.lease >= lease - 1 else { return nil }
        if token != session { token = session; lastSequence = 0 }
        guard event.sequence > lastSequence else { return nil }
        lastSequence = event.sequence
        guard let binding = snapshot.config.resolved(layer: event.layer, control: event.control),
              binding.kind.isHost, binding.source == event.source else { return nil }
        return binding
    }
}
