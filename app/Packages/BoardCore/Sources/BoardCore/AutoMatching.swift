import Foundation

public struct LinkedApplication: Codable, Equatable, Identifiable {
    public var bundleID: String
    public var name: String
    public var id: String { bundleID }
    public init(bundleID: String, name: String) { self.bundleID = bundleID; self.name = name }
}
public struct AutoRule: Codable, Equatable, Identifiable {
    public var layer: Int
    public var enabled: Bool
    public var applications: [LinkedApplication]
    public var id: Int { layer }
    public init(layer: Int, enabled: Bool = false, applications: [LinkedApplication] = []) {
        self.layer = layer; self.enabled = enabled; self.applications = applications
    }
}
public struct AutoBindings: Codable, Equatable {
    public var version = 1
    public var devices: [String: [AutoRule]] = [:]
    public init() {}
    public var isValid: Bool {
        guard version == 1, devices.count <= 16 else { return false }
        for (serial, rules) in devices {
            guard !serial.isEmpty, serial.utf8.count <= 128, rules.count <= 6,
                  Set(rules.map(\.layer)).count == rules.count else { return false }
            var ids = Set<String>()
            for rule in rules {
                guard (1...255).contains(rule.layer), rule.applications.count <= 8 else { return false }
                for app in rule.applications {
                    guard !app.bundleID.isEmpty, app.bundleID.utf8.count <= 255,
                          !app.bundleID.unicodeScalars.contains(where: { $0.value <= 32 || $0.value == 127 }),
                          !app.name.isEmpty, app.name.utf8.count <= 128,
                          ids.insert(app.bundleID).inserted else { return false }
                }
            }
        }
        return true
    }
    public func matchingLayer(serial: String, bundleID: String?, available: Set<Int>) -> Int {
        guard isValid, let bundleID else { return 0 }
        return devices[serial]?.first { $0.enabled && available.contains($0.layer) && $0.applications.contains { $0.bundleID == bundleID } }?.layer ?? 0
    }
}
public struct AutoLayerParams: Encodable {
    public let session: Int
    public let sequence: Int
    public let layer: Int
    public let baseRevision: Int
    public init(session: Int, sequence: Int, layer: Int, baseRevision: Int) {
        self.session = session; self.sequence = sequence; self.layer = layer; self.baseRevision = baseRevision
    }
}
