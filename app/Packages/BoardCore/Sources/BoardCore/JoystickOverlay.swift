import Foundation

/// Display-only telemetry; candidate is a control ID chosen by firmware.
public struct JoystickFrame: Decodable {
    public let `protocol`: Int
    public let event: String
    public let token: Int
    public let sequence: UInt32
    public let gesture: UInt32
    public let layer: Int
    public let revision: Int
    public let visible: Bool
    public let x: Int
    public let y: Int
    public let candidate: Int
    public var isValid: Bool {
        `protocol` == 1 && event == "joystick" && (1...0x7fffffff).contains(token)
        && (1...6).contains(layer) && (0...0x7fffffff).contains(revision)
        && (-1000...1000).contains(x) && (-1000...1000).contains(y)
        && (candidate == 0 || Control.stickIDs.contains(candidate))
        && (!visible || layer != 1) && (visible || (x == 0 && y == 0 && candidate == 0))
    }
    public static func isJoystickLine(_ line: String) -> Bool {
        guard let payload = Wire.payload(line), let frame = try? JSONDecoder().decode(Self.self, from: payload) else { return false }
        return frame.isValid
    }
}

/// A late frame cannot resurrect a gesture already ended in the same session.
public struct JoystickFrameGate {
    private var sequence: UInt32?
    private var ended: UInt32?
    public init() {}
    public mutating func reset() { sequence = nil; ended = nil }
    public mutating func accept(_ frame: JoystickFrame, token: Int) -> Bool {
        guard frame.isValid, frame.token == token else { return false }
        if let sequence {
            let delta = frame.sequence &- sequence
            guard delta > 0 && delta < 0x80000000 else { return false }
        }
        self.sequence = frame.sequence
        if !frame.visible { ended = frame.gesture; return true }
        if let ended {
            let delta = frame.gesture &- ended
            guard delta > 0 && delta < 0x80000000 else { return false }
        }
        return true
    }
}
