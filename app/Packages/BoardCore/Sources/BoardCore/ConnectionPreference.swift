import Foundation

public struct ConnectionPreference: Codable, Equatable {
    public var serial: String
    public var automatic: Bool
    public var bluetooth: Bool?
    public init(serial: String = "", automatic: Bool = false, bluetooth: Bool? = nil) { self.serial = serial; self.automatic = automatic; self.bluetooth = bluetooth }
    public var isValid: Bool { serial.utf8.count <= 128 && (!automatic || !serial.isEmpty) }
    public func matches(serial: String?, vendor: Int?, product: Int?) -> Bool {
        automatic && !self.serial.isEmpty && serial == self.serial && vendor == 0x303a && product == 0x8360
    }
    public static func retryDelay(attempt: Int, knownBluetoothAvailable: Bool = false) -> Double? {
        let delays: [Double] = [1, 2, 4, 8, 16, 30]
        guard attempt >= 0 else { return nil }
        if delays.indices.contains(attempt) { return delays[attempt] }
        guard knownBluetoothAvailable else { return 60 }
        // Enter system-managed waiting immediately after the fast attempts.
        // A subsequent system error backs off instead of creating an immediate loop.
        return attempt == delays.count ? 0 : 5
    }
}
