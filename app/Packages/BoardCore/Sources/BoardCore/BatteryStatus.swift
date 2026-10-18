import Foundation

/// Display policy shared by the editor and menu; no persistence or telemetry.
public struct BatteryStatus: Equatable {
    public let known: Bool
    public let percent: Int
    public let charging: Bool
    public let full: Bool
    public init(known: Bool, percent: Int, charging: Bool, full: Bool) {
        self.known = known
        self.full = known && full
        self.charging = known && charging
        self.percent = known ? (full ? 100 : min(100, max(0, percent))) : 0
    }
    public var warningLevel: Int {
        guard known, !charging, !full else { return 0 }
        return percent <= 5 ? 2 : percent <= 15 ? 1 : 0
    }
}
