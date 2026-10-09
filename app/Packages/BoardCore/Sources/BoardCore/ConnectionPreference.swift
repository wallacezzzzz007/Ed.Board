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
    public enum RetryRoute: Equatable {
        case usb(Int), bluetooth, waitingForUSB, ambiguousUSB, unavailable
    }
    // Only runtime USB keyboard ports belong in this list. The returned index
    // selects the remembered identity, never an arbitrary neighbouring device.
    public func retryRoute(usbSerials: [String?], preferBluetooth: Bool) -> RetryRoute {
        let matches = usbSerials.indices.filter { !serial.isEmpty && usbSerials[$0] == serial }
        if matches.count == 1 { return .usb(matches[0]) }
        if matches.count > 1 { return .ambiguousUSB }
        if !usbSerials.isEmpty {
            if serial.isEmpty && usbSerials.count == 1 { return .usb(0) }
            return .waitingForUSB
        }
        return preferBluetooth ? .bluetooth : .unavailable
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
