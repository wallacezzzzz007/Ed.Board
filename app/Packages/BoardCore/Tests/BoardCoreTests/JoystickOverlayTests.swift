import XCTest
@testable import BoardCore

final class JoystickOverlayTests: XCTestCase {
    private func frame(_ sequence: UInt32 = 1, gesture: UInt32 = 1, visible: Bool = true,
                       token: Int = 12, layer: Int = 2, candidate: Int = 16, x: Int = 0) throws -> JoystickFrame {
        let value: [String: Any] = ["protocol": 1, "event": "joystick", "token": token,
            "sequence": sequence, "gesture": gesture, "layer": layer, "revision": 146,
            "visible": visible, "x": x, "y": visible ? -700 : 0, "candidate": visible ? candidate : 0]
        return try JSONDecoder().decode(JoystickFrame.self, from: JSONSerialization.data(withJSONObject: value))
    }
    func testRejectsOldSessionDuplicateAndOutOfOrder() throws {
        var gate = JoystickFrameGate()
        XCTAssertFalse(gate.accept(try frame(token: 13), token: 12))
        XCTAssertTrue(gate.accept(try frame(2), token: 12))
        XCTAssertFalse(gate.accept(try frame(2), token: 12))
        XCTAssertFalse(gate.accept(try frame(1), token: 12))
        XCTAssertTrue(gate.accept(try frame(3), token: 12))
    }
    func testEndedGestureCannotReappearButNextCan() throws {
        var gate = JoystickFrameGate()
        XCTAssertTrue(gate.accept(try frame(), token: 12))
        XCTAssertTrue(gate.accept(try frame(2, visible: false), token: 12))
        XCTAssertFalse(gate.accept(try frame(3), token: 12))
        XCTAssertTrue(gate.accept(try frame(4, gesture: 2), token: 12))
    }
    func testCandidateIsFirmwareControlAndNotXYGuess() throws {
        let value = try frame(candidate: 24, x: 650)
        XCTAssertTrue(value.isValid)
        XCTAssertEqual(value.candidate, 24)
        XCTAssertTrue(try frame(candidate: 0).isValid) // Visible before action threshold.
        XCTAssertFalse(try frame(candidate: 13).isValid)
        XCTAssertFalse(try frame(x: 1001).isValid)
        XCTAssertFalse(try frame(layer: 1).isValid)
        XCTAssertTrue(try frame(visible: false, layer: 1).isValid)
    }
    func testSequenceWrapAndReset() throws {
        var gate = JoystickFrameGate()
        XCTAssertTrue(gate.accept(try frame(UInt32.max), token: 12))
        XCTAssertTrue(gate.accept(try frame(0), token: 12))
        XCTAssertFalse(gate.accept(try frame(UInt32.max), token: 12))
        gate.reset()
        XCTAssertTrue(gate.accept(try frame(0, token: 23), token: 23))
    }
    func testLayerIDsAreNotLimitedByLayerCount() throws {
        for layer in [7, 255] {
            var gate = JoystickFrameGate()
            XCTAssertTrue(gate.accept(try frame(layer: layer), token: 12))
            XCTAssertTrue(gate.accept(try frame(2, visible: false, layer: layer), token: 12))
        }
        for layer in [0, 256] {
            XCTAssertFalse(try frame(layer: layer).isValid)
            XCTAssertFalse(try frame(visible: false, layer: layer).isValid)
        }
    }
    func testGestureWrapAndInitialHiddenSnapshot() throws {
        var gate = JoystickFrameGate()
        XCTAssertTrue(gate.accept(try frame(1, gesture: UInt32.max, visible: false), token: 12))
        XCTAssertTrue(gate.accept(try frame(2, gesture: 0), token: 12))
    }
    func testValidTelemetryExcludedButMalformedRetained() throws {
        let line = "@edboard {\"protocol\":1,\"event\":\"joystick\",\"token\":12,\"sequence\":1,\"gesture\":1,\"layer\":2,\"revision\":146,\"visible\":true,\"x\":0,\"y\":-700,\"candidate\":16}"
        XCTAssertTrue(JoystickFrame.isJoystickLine(line))
        XCTAssertTrue(JoystickFrame.isJoystickLine(line.replacingOccurrences(of: "\"layer\":2", with: "\"layer\":7")))
        XCTAssertFalse(JoystickFrame.isJoystickLine(line.replacingOccurrences(of: "-700", with: "-7000")))
        XCTAssertFalse(JoystickFrame.isJoystickLine("@edboard {\"event\":\"joystick\"}"))
    }
}
