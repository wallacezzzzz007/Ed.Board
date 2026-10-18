import XCTest
@testable import BoardCore

final class BatteryStatusTests: XCTestCase {
    func testFullIndicationAndInvalidReading() {
        XCTAssertEqual(BatteryStatus(known: true, percent: 91, charging: false, full: true).percent, 100)
        let invalid = BatteryStatus(known: false, percent: 0, charging: true, full: true)
        XCTAssertEqual(invalid.warningLevel, 0)
        XCTAssertFalse(invalid.full)
        XCTAssertFalse(invalid.charging)
    }
    func testWarningBoundariesAndChargingSuppression() {
        for (percent, expected) in [(0,2),(5,2),(6,1),(15,1),(16,0),(100,0)] {
            XCTAssertEqual(BatteryStatus(known: true, percent: percent, charging: false, full: false).warningLevel, expected)
            XCTAssertEqual(BatteryStatus(known: true, percent: percent, charging: true, full: false).warningLevel, 0)
            XCTAssertEqual(BatteryStatus(known: true, percent: percent, charging: false, full: true).warningLevel, 0)
        }
        XCTAssertEqual(BatteryStatus(known: true, percent: -1, charging: false, full: false).percent, 0)
        XCTAssertEqual(BatteryStatus(known: true, percent: 200, charging: false, full: false).percent, 100)
    }
}
