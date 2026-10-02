import Foundation

/// At most two frames: a reply may arrive before the final write acknowledgement,
/// allowing the next RPC to be queued before that acknowledgement is delivered.
public struct BLEWriteBuffer {
    private var frames = [Data]()
    private var offset = 0
    private var inFlight = 0
    public init() {}
    public var isEmpty: Bool { frames.isEmpty }
    public mutating func enqueue(_ data: Data) -> Bool {
        guard !data.isEmpty, data.count <= 12289, frames.count < 2 else { return false }
        frames.append(data); return true
    }
    public mutating func next(maximum: Int) -> Data? {
        guard inFlight == 0, let frame = frames.first, maximum > 0 else { return nil }
        inFlight = min(128, min(maximum, frame.count - offset))
        return frame.subdata(in: offset..<(offset + inFlight))
    }
    /// Only for an explicit ATT rejection: no bytes from this chunk were accepted.
    /// Never use for a timeout/unknown outcome or after a successful acknowledgement.
    public mutating func rejectUnacceptedChunk() -> Bool {
        guard inFlight > 0 else { return false }
        inFlight = 0
        return true
    }
    public static func resourceRetryDelay(attempt: Int) -> Double? {
        let delays = [0.05, 0.1, 0.2, 0.4, 0.8]
        return delays.indices.contains(attempt) ? delays[attempt] : nil
    }
    public mutating func acknowledge() {
        guard inFlight > 0 else { return }
        offset += inFlight; inFlight = 0
        if let frame = frames.first, offset == frame.count { frames.removeFirst(); offset = 0 }
    }
}
