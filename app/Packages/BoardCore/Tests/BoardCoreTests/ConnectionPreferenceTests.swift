import XCTest
import BoardCore

final class ConnectionPreferenceTests: XCTestCase {
    func testOnlyRememberedRuntimeDeviceMatches() {
        let value = ConnectionPreference(serial: "CM3-test", automatic: true)
        XCTAssertTrue(value.matches(serial: "CM3-test", vendor: 0x303a, product: 0x8360))
        XCTAssertFalse(value.matches(serial: "CM3-test", vendor: 0x303a, product: 0x1001))
        XCTAssertFalse(value.matches(serial: "other", vendor: 0x303a, product: 0x8360))
        XCTAssertFalse(value.matches(serial: nil, vendor: 0x303a, product: 0x8360))
    }
    func testManualDisconnectDisablesAutomaticConnection() {
        let value = ConnectionPreference(serial: "CM3-test", automatic: false)
        XCTAssertFalse(value.matches(serial: "CM3-test", vendor: 0x303a, product: 0x8360))
        XCTAssertFalse(ConnectionPreference().matches(serial: "CM3-test", vendor: 0x303a, product: 0x8360))
    }
    func testPreferenceRoundTripAndValidation() throws {
        let original = ConnectionPreference(serial: "CM3-test", automatic: true)
        XCTAssertEqual(try JSONDecoder().decode(ConnectionPreference.self, from: JSONEncoder().encode(original)), original)
        XCTAssertFalse(ConnectionPreference(serial: "", automatic: true).isValid)
        XCTAssertFalse(ConnectionPreference(serial: String(repeating: "a", count: 129)).isValid)
    }
    func testRetriesContinueAtLowFrequencyAfterFastBackoff() {
        XCTAssertEqual((0..<6).compactMap { ConnectionPreference.retryDelay(attempt: $0) }, [1, 2, 4, 8, 16, 30])
        XCTAssertEqual(ConnectionPreference.retryDelay(attempt: 6), 60)
        XCTAssertEqual(ConnectionPreference.retryDelay(attempt: 10000), 60)
        XCTAssertNil(ConnectionPreference.retryDelay(attempt: -1))
    }
    func testKnownBluetoothEntersPendingConnectionWithoutMinuteGap() {
        XCTAssertEqual((0..<6).compactMap {
            ConnectionPreference.retryDelay(attempt: $0, knownBluetoothAvailable: true)
        }, [1, 2, 4, 8, 16, 30])
        XCTAssertEqual(ConnectionPreference.retryDelay(attempt: 6, knownBluetoothAvailable: true), 0)
        XCTAssertEqual(ConnectionPreference.retryDelay(attempt: 6, knownBluetoothAvailable: false), 60)
    }
    func testSystemFailureAfterPendingConnectionCannotBusyLoop() {
        XCTAssertEqual(ConnectionPreference.retryDelay(attempt: 7, knownBluetoothAvailable: true), 5)
        XCTAssertEqual(ConnectionPreference.retryDelay(attempt: 10000, knownBluetoothAvailable: true), 5)
        XCTAssertEqual(ConnectionPreference.retryDelay(attempt: 7, knownBluetoothAvailable: false), 60)
        XCTAssertNil(ConnectionPreference.retryDelay(attempt: -1, knownBluetoothAvailable: true))
    }

    func testRetryPrefersRememberedUSBAfterBluetooth() {
        let value = ConnectionPreference(serial: "CM3-test", automatic: true, bluetooth: true)
        XCTAssertEqual(value.retryRoute(usbSerials: ["other", "CM3-test"], preferBluetooth: true), .usb(1))
        XCTAssertEqual(value.retryRoute(usbSerials: [], preferBluetooth: true), .bluetooth)
    }
    func testIncompleteUSBIdentityWaitsWithoutFallingBackToBluetooth() {
        let value = ConnectionPreference(serial: "CM3-test", automatic: true, bluetooth: true)
        XCTAssertEqual(value.retryRoute(usbSerials: [nil], preferBluetooth: true), .waitingForUSB)
        XCTAssertEqual(value.retryRoute(usbSerials: ["CM3-test"], preferBluetooth: true), .usb(0))
        XCTAssertEqual(ConnectionPreference.retryDelay(attempt: 7), 60)
    }
    func testRetryNeverAutomaticallyChoosesAnotherKeyboard() {
        let value = ConnectionPreference(serial: "CM3-test", automatic: true)
        XCTAssertEqual(value.retryRoute(usbSerials: ["other"], preferBluetooth: true), .waitingForUSB)
        XCTAssertEqual(value.retryRoute(usbSerials: ["CM3-test", "CM3-test"], preferBluetooth: true), .ambiguousUSB)
        XCTAssertEqual(value.retryRoute(usbSerials: [], preferBluetooth: false), .unavailable)
    }
    func testManualRetryStillFindsKnownUSBWhenAutomaticConnectionIsOff() {
        let value = ConnectionPreference(serial: "CM3-test", automatic: false)
        XCTAssertEqual(value.retryRoute(usbSerials: ["CM3-test"], preferBluetooth: true), .usb(0))
        XCTAssertEqual(ConnectionPreference().retryRoute(usbSerials: ["example"], preferBluetooth: true), .usb(0))
        XCTAssertEqual(ConnectionPreference().retryRoute(usbSerials: ["a", "b"], preferBluetooth: true), .waitingForUSB)
    }

}
