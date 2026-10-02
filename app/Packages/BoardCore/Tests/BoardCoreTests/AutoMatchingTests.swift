import XCTest
import BoardCore

final class AutoMatchingTests: XCTestCase {
    func bindings() -> AutoBindings {
        var result = AutoBindings()
        result.devices["board-a"] = [AutoRule(layer: 6, enabled: true, applications: [
            LinkedApplication(bundleID: "com.example.Editor", name: "Editor"),
            LinkedApplication(bundleID: "com.example.Browser", name: "Browser")])]
        return result
    }
    func testBundleIdentityAndMultipleApps() {
        let value = bindings()
        XCTAssertTrue(value.isValid)
        XCTAssertEqual(value.matchingLayer(serial: "board-a", bundleID: "com.example.Editor", available: [1, 6]), 6)
        XCTAssertEqual(value.matchingLayer(serial: "board-a", bundleID: "com.example.Browser", available: [1, 6]), 6)
        XCTAssertEqual(value.matchingLayer(serial: "board-a", bundleID: "Editor", available: [1, 6]), 0)
    }
    func testUnmatchedDisabledDeletedAndOtherDeviceReturnManualCandidate() {
        var value = bindings()
        XCTAssertEqual(value.matchingLayer(serial: "board-b", bundleID: "com.example.Editor", available: [6]), 0)
        XCTAssertEqual(value.matchingLayer(serial: "board-a", bundleID: nil, available: [6]), 0)
        XCTAssertEqual(value.matchingLayer(serial: "board-a", bundleID: "com.example.Editor", available: [1]), 0)
        value.devices["board-a"]![0].enabled = false
        XCTAssertEqual(value.matchingLayer(serial: "board-a", bundleID: "com.example.Editor", available: [6]), 0)
    }
    func testDuplicatesRejectedEvenWhenDisabled() {
        var value = bindings()
        value.devices["board-a"]!.append(AutoRule(layer: 1, applications: [LinkedApplication(bundleID: "com.example.Editor", name: "Other name")]))
        XCTAssertFalse(value.isValid)
    }
    func testBindingsPersistIndependentlyOfLayerOrder() throws {
        let value = bindings()
        let decoded = try JSONDecoder().decode(AutoBindings.self, from: JSONEncoder().encode(value))
        XCTAssertEqual(decoded, value)
        XCTAssertEqual(decoded.matchingLayer(serial: "board-a", bundleID: "com.example.Editor", available: [6, 1]), 6)
    }
    func testMalformedAndOversizedBindingsRejected() {
        var value = bindings()
        value.devices["board-a"]![0].applications[0].bundleID = "bad id"
        XCTAssertFalse(value.isValid)
        value = bindings()
        value.devices["board-a"]![0].applications = (0..<9).map { LinkedApplication(bundleID: "app.\($0)", name: "App") }
        XCTAssertFalse(value.isValid)
    }
    func testRuntimeDistinguishesPendingAndAppliedAuto() throws {
        var config = BoardConfiguration(); config.layers.append(Layer(id: 6, name: "Six", mode: .custom))
        func decode(_ text: String) throws -> RuntimeState { try JSONDecoder().decode(RuntimeState.self, from: Data(text.utf8)) }
        XCTAssertTrue(try decode(#"{"manualLayer":1,"activeLayer":1,"autoLayer":6,"session":42,"pending":true}"#).isValid(for: config))
        XCTAssertTrue(try decode(#"{"manualLayer":1,"activeLayer":6,"autoLayer":6,"session":42,"pending":false}"#).isValid(for: config))
        XCTAssertFalse(try decode(#"{"manualLayer":1,"activeLayer":1,"autoLayer":6,"session":42,"pending":false}"#).isValid(for: config))
        XCTAssertFalse(try decode(#"{"manualLayer":1,"activeLayer":6,"autoLayer":7,"session":42,"pending":true}"#).isValid(for: config))
    }
    func testRuntimeEqualityIncludesTransitionState() throws {
        func state(_ active: Int = 5, _ pending: Bool = false, _ session: Int = 42) throws -> RuntimeState {
            let text = "{\"manualLayer\":1,\"activeLayer\":\(active),\"autoLayer\":5,\"session\":\(session),\"pending\":\(pending)}"
            return try JSONDecoder().decode(RuntimeState.self, from: Data(text.utf8))
        }
        XCTAssertEqual(try state(), try state())
        XCTAssertNotEqual(try state(), try state(1, true))
        XCTAssertNotEqual(try state(), try state(5, false, 43))
    }
    func testAutoRequestCarriesSessionSequenceAndRevision() throws {
        let data = try Wire.request(id: 7, method: "runtime.auto", params: AutoLayerParams(session: 42, sequence: 2, layer: 6, baseRevision: 58))
        let line = String(decoding: data, as: UTF8.self)
        let payload = try XCTUnwrap(Wire.payload(line))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: payload) as? [String: Any])
        let params = try XCTUnwrap(object["params"] as? [String: Int])
        XCTAssertEqual(params, ["session": 42, "sequence": 2, "layer": 6, "baseRevision": 58])
    }
}
