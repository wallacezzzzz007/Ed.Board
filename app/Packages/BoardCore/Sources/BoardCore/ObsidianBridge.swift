import Foundation
import CoreFoundation

public enum ObsidianView: String, Codable { case markdown, excalidraw, other }
public struct ObsidianLayerMapping: Codable, Equatable {
    public var defaultLayer = 0
    public var excalidrawLayer = 0
    public init() {}
    public var isValid: Bool { (0...255).contains(defaultLayer) && (0...255).contains(excalidrawLayer) }
}
public struct ObsidianPluginSettings: Codable, Equatable {
    public var version = 1
    public var enabled = false
    public var credential: String?
    public var devices: [String: ObsidianLayerMapping] = [:]
    public init() {}
    public var isValid: Bool {
        version == 1 && (credential == nil || ObsidianBridgeSession.validSecret(credential!)) && devices.count <= 16 &&
        devices.allSatisfy { !$0.key.isEmpty && $0.key.utf8.count <= 128 && $0.value.isValid }
    }
}
public struct BridgeHTTPRequest {
    public let path: String
    public let authorization: String
    public let body: Data
    public enum ParseResult { case incomplete, invalid, request(BridgeHTTPRequest) }
    public static let port: UInt16 = 27124
    public static func parse(_ data: Data) -> ParseResult {
        guard data.count <= 8192 else { return .invalid }
        guard let split = data.range(of: Data("\r\n\r\n".utf8)) else {
            return data.count > 4096 ? .invalid : .incomplete
        }
        guard split.lowerBound <= 4096, let head = String(data: data[..<split.lowerBound], encoding: .ascii) else { return .invalid }
        let lines = head.components(separatedBy: "\r\n")
        guard let first = lines.first else { return .invalid }
        let words = first.components(separatedBy: " ")
        guard words.count == 3, words[0] == "POST", words[2] == "HTTP/1.1",
              ["/v1/pair", "/v2/view", "/v2/clear"].contains(words[1]) else { return .invalid }
        var fields: [String: String] = [:]
        for line in lines.dropFirst() {
            guard !line.hasPrefix(" "), !line.hasPrefix("\t"), let colon = line.firstIndex(of: ":") else { return .invalid }
            let key = String(line[..<colon]).lowercased()
            guard !key.isEmpty, key.utf8.allSatisfy({ (97...122).contains($0) || $0 == 45 }), fields[key] == nil else { return .invalid }
            fields[key] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        guard fields["host"] == "127.0.0.1:\(port)", fields["origin"] == nil,
              fields["transfer-encoding"] == nil, fields["expect"] == nil,
              fields["content-type"]?.lowercased() == "application/json",
              let lengthText = fields["content-length"], !lengthText.isEmpty,
              lengthText.utf8.allSatisfy({ (48...57).contains($0) }),
              let length = Int(lengthText), length <= 512,
              let authorization = fields["authorization"], authorization.hasPrefix("Bearer "),
              ObsidianBridgeSession.validSecret(String(authorization.dropFirst(7))) else { return .invalid }
        let remaining = data.count - split.upperBound
        guard remaining <= length else { return .invalid }
        guard remaining == length else { return .incomplete }
        return .request(BridgeHTTPRequest(path: words[1], authorization: String(authorization.dropFirst(7)), body: Data(data[split.upperBound...])))
    }
}
public struct BridgeHTTPReply {
    public let status: Int
    public let body: Data
    public init(_ status: Int, _ values: [String: String] = [:]) {
        self.status = status; body = (try? JSONSerialization.data(withJSONObject: values, options: [.sortedKeys])) ?? Data("{}".utf8)
    }
    public var wireData: Data {
        let head = "HTTP/1.1 \(status) \(status == 200 ? "OK" : "Error")\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\nConnection: close\r\nCache-Control: no-store\r\n\r\n"
        return Data(head.utf8) + body
    }
}
/// Local integration state, separate from device configuration and app-link drafts.
public struct ObsidianBridgeSession {
    public private(set) var enabled = false
    public private(set) var view: ObsidianView?
    public private(set) var lastSeen: TimeInterval?
    public private(set) var credential: String?
    public private(set) var pairingCode: String?
    public private(set) var pairingUntil: TimeInterval = 0
    public private(set) var foreground = false
    private var owner: String?
    private var focusStamp: Int64 = 0
    private var focusClient: String?
    private var focusSequence = 0
    private var minimumFocus: Int64 = 0
    public init() {}
    public static func validSecret(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
    public mutating func activate(credential: String?) { stop(); self.credential = credential; enabled = true }
    public mutating func clearView() { view = nil; lastSeen = nil; owner = nil }
    public mutating func stop() {
        enabled = false; foreground = false; clearView(); pairingCode = nil; pairingUntil = 0; credential = nil
        focusStamp = 0; focusClient = nil; focusSequence = 0; minimumFocus = 0
    }
    public mutating func setForeground(_ active: Bool, now: TimeInterval) {
        guard foreground != active else { return }
        foreground = active
        if !active { clearView(); minimumFocus = Int64((now * 1000).rounded(.down)) }
    }
    private static func integer(_ value: Any?, max: Int64) -> Int64? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite, number.doubleValue >= 1, number.doubleValue <= Double(max),
              number.doubleValue.rounded(.down) == number.doubleValue else { return nil }
        return number.int64Value
    }
    public mutating func beginPairing(code: String, now: TimeInterval) {
        guard enabled, Self.validSecret(code) else { return }
        pairingCode = code; pairingUntil = now + 120
    }
    public mutating func expire(now: TimeInterval) {
        if now >= pairingUntil { pairingCode = nil }
        if !isConnected(now: now) { clearView() }
    }
    public func isConnected(now: TimeInterval) -> Bool {
        enabled && credential != nil && view != nil && lastSeen.map { now >= $0 && now - $0 <= 15 } == true
    }
    public func matchingLayer(settings: ObsidianPluginSettings, serial: String, bundleID: String?, available: Set<Int>, now: TimeInterval) -> Int? {
        guard settings.enabled, foreground, isConnected(now: now), bundleID == "md.obsidian", let mapping = settings.devices[serial] else { return nil }
        let layer = view == .excalidraw && mapping.excalidrawLayer != 0 ? mapping.excalidrawLayer : mapping.defaultLayer
        return layer > 0 && available.contains(layer) ? layer : nil
    }
    public mutating func handle(_ request: BridgeHTTPRequest, now: TimeInterval, issueToken: () -> String,
                                persistToken: (String) -> Bool) -> BridgeHTTPReply {
        guard enabled else { return BridgeHTTPReply(503) }
        guard let json = try? JSONSerialization.jsonObject(with: request.body) as? [String: Any] else { return BridgeHTTPReply(400) }
        if request.path == "/v1/pair" {
            guard request.authorization == pairingCode, now < pairingUntil else { return BridgeHTTPReply(401) }
            guard json.isEmpty else { return BridgeHTTPReply(400) }
            let token = issueToken()
            guard Self.validSecret(token), persistToken(token) else { return BridgeHTTPReply(503) }
            credential = token; pairingCode = nil; pairingUntil = 0; clearView()
            focusStamp = 0; focusClient = nil; focusSequence = 0
            return BridgeHTTPReply(200, ["token": token])
        }
        guard let credential, request.authorization == credential else { return BridgeHTTPReply(401) }
        guard let client = json["client"] as? String, client.utf8.count == 32,
              client.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { return BridgeHTTPReply(400) }
        guard let stamp = Self.integer(json["focus"], max: 253402300799999),
              let sequence = Self.integer(json["sequence"], max: 2147483647),
              Double(stamp) <= now * 1000 + 2000 else { return BridgeHTTPReply(400) }
        if request.path == "/v2/clear" {
            guard Set(json.keys) == ["client", "focus", "sequence"] else { return BridgeHTTPReply(400) }
            // An unloading background vault (or an old focus in this same vault)
            // cannot clear a newer focused editor. Keep the fence after clearing.
            if focusClient == client && stamp == focusStamp && sequence > focusSequence {
                focusSequence = Int(sequence)
                if owner == client { clearView() }
            }
            return BridgeHTTPReply(200)
        }
        guard request.path == "/v2/view", Set(json.keys) == ["view", "client", "focus", "sequence"],
              let raw = json["view"] as? String, let next = ObsidianView(rawValue: raw) else { return BridgeHTTPReply(400) }
        guard foreground else { return BridgeHTTPReply(409) }
        guard stamp >= minimumFocus, stamp >= focusStamp,
              stamp != focusStamp || (focusClient == client && sequence > focusSequence) else {
            return BridgeHTTPReply(409)
        }
        focusStamp = stamp; focusClient = client; focusSequence = Int(sequence)
        view = next; lastSeen = now; owner = client
        return BridgeHTTPReply(200)
    }
}
