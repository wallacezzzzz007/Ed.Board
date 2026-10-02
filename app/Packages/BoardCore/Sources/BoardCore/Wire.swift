import Foundation

public struct RPCError: Decodable, Error {
    public let code: String
    public init(code: String) { self.code = code }
}
public struct Envelope<T: Decodable>: Decodable {
    public let `protocol`: Int
    public let id: Int
    public let result: T?
    public let error: RPCError?
}
public struct Header: Decodable {
    public let `protocol`: Int
    public let id: Int
    public let error: RPCError?
}
public struct EmptyParams: Encodable { public init() {} }
public struct SetParams: Encodable {
    public let baseRevision: Int
    public let config: BoardConfiguration
    public init(baseRevision: Int, config: BoardConfiguration) { self.baseRevision = baseRevision; self.config = config }
}
private struct Request<P: Encodable>: Encodable {
    let `protocol` = 1
    let id: Int
    let method: String
    let params: P
}
public enum Wire {
    public static let prefix = "@edboard "
    public static func request<P: Encodable>(id: Int, method: String, params: P) throws -> Data {
        guard (1...0x7fffffff).contains(id) else { throw RPCError(code: "invalid_id") }
        let json = try JSONEncoder().encode(Request(id: id, method: method, params: params))
        guard json.count + prefix.utf8.count <= 32768 else { throw RPCError(code: "frame_too_large") }
        var data = Data(prefix.utf8); data.append(json); data.append(10); return data
    }
    public static func payload(_ line: String) -> Data? {
        guard line.hasPrefix(prefix) else { return nil }
        return String(line.dropFirst(prefix.count)).data(using: .utf8)
    }
}

/// Bounded incremental framing. A long/partial line never consumes unbounded memory.
public struct LineFramer {
    private var bytes = [UInt8]()
    private var discarding = false
    public private(set) var droppedLines = 0
    public init() { bytes.reserveCapacity(2048) }
    public mutating func feed(_ data: Data) -> [String] {
        var lines = [String]()
        for byte in data {
            if byte == 10 {
                if !discarding, let line = String(bytes: bytes, encoding: .utf8), !line.isEmpty { lines.append(line) }
                bytes.removeAll(keepingCapacity: true); discarding = false
            } else if byte != 13 && !discarding {
                if bytes.count == 32768 { bytes.removeAll(keepingCapacity: true); discarding = true; droppedLines += 1 }
                else { bytes.append(byte) }
            }
        }
        return lines
    }
}

public struct SelectLayerParams: Encodable {
    public let layer: Int
    public init(layer: Int) { self.layer = layer }
}
