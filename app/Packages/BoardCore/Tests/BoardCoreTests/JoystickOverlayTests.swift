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
    func testLegacyAppearanceDefaultsOnExceptCodex() throws {
        let old = Data(#"{"version":1,"serial":"synthetic","keys":{}}"#.utf8)
        let catalog = try JSONDecoder().decode(PresentationCatalog.self, from: old)
        XCTAssertTrue(catalog.isValid)
        XCTAssertFalse(catalog.showsDesktopOverlay(layer: 1))
        XCTAssertTrue(catalog.showsDesktopOverlay(layer: 2))
        XCTAssertTrue(catalog.showsDesktopOverlay(layer: 255))
        let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(catalog)) as? [String: Any]
        XCTAssertNil(json?["hiddenDesktopOverlayLayers"])
    }
    func testOverlayPreferenceDoesNotFollowInheritedActions() throws {
        var config = BoardConfiguration()
        config.layers += [.blank(id: 2, name: "Source"), .blank(id: 7, name: "Destination")]
        config.layers[1].bindings[16] = Binding(kind: .mouse, usage: 1)
        config = try XCTUnwrap(QuickSelection.inheriting(config, layer: 7, source: 2))
        var catalog = PresentationCatalog(serial: "synthetic")
        catalog.setDesktopOverlay(false, layer: 2)
        XCTAssertFalse(catalog.showsDesktopOverlay(layer: 2))
        XCTAssertTrue(catalog.showsDesktopOverlay(layer: 7))
        XCTAssertEqual(config.resolved(layer: 7, control: 16), Binding(kind: .mouse, usage: 1))
        catalog.setDesktopOverlay(false, layer: 7)
        let decoded = try JSONDecoder().decode(PresentationCatalog.self, from: JSONEncoder().encode(catalog))
        XCTAssertEqual(decoded, catalog)
        config.favorites = [7, 1]; config.layers[2].name = "Renamed"
        XCTAssertFalse(decoded.showsDesktopOverlay(layer: 7))
    }
    func testDraftDiscardAndLayerResetRemoveOnlyOwnPreference() {
        let saved = PresentationCatalog()
        var draft = saved
        draft.setDesktopOverlay(false, layer: 2)
        XCTAssertNotEqual(draft, saved)
        XCTAssertTrue(saved.showsDesktopOverlay(layer: 2))
        draft = saved
        XCTAssertTrue(draft.showsDesktopOverlay(layer: 2))
        draft.setDesktopOverlay(false, layer: 2); draft.setDesktopOverlay(false, layer: 3)
        draft.keys["2:0"] = KeyPresentation(name: "Example")
        draft.removeLayer(2)
        XCTAssertTrue(draft.showsDesktopOverlay(layer: 2))
        XCTAssertFalse(draft.showsDesktopOverlay(layer: 3))
        XCTAssertNil(draft.keys["2:0"])
        draft.setDesktopOverlay(true, layer: 1)
        XCTAssertFalse(draft.showsDesktopOverlay(layer: 1))
    }
    func testMalformedOverlayPreferencesRejected() throws {
        var catalog = PresentationCatalog()
        for id in [0, 1, 256] {
            catalog.hiddenDesktopOverlayLayers = [id]
            XCTAssertFalse(catalog.isValid)
        }
        catalog.hiddenDesktopOverlayLayers = Set(2...18)
        XCTAssertFalse(catalog.isValid)
        let malformed = Data(#"{"version":1,"serial":"synthetic","keys":{},"hiddenDesktopOverlayLayers":"bad"}"#.utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(PresentationCatalog.self, from: malformed))
    }

    func testImportedTemplateBackwardsCompatibilityAndReplacement() throws {
        let old = try JSONDecoder().decode(KeyPresentation.self, from: Data(#"{"name":"sample","symbol":"","image":"AQID"}"#.utf8))
        XCTAssertNil(old.imageIsTemplate)
        var icon = old
        icon.setImportedImage(Data([1,2,3]), template: true)
        XCTAssertEqual(icon.imageIsTemplate, true)
        XCTAssertEqual(try JSONDecoder().decode(KeyPresentation.self, from: JSONEncoder().encode(icon)), icon)
        icon.setImportedImage(Data([4]), template: false)
        XCTAssertNil(icon.imageIsTemplate)
        icon.setImportedImage(Data([5]), template: true)
        icon.clearImage()
        XCTAssertNil(icon.image); XCTAssertNil(icon.imageIsTemplate)
    }
    func testTemplateAppearanceSurvivesActionRenderingAndInheritance() throws {
        let custom = KeyPresentation(name: "sample", image: Data([1,2,3]), imageIsTemplate: true)
        for kind in [ActionKind.shortcut, .mouse, .media] {
            let rendered = ActionPresentation.standard(binding: Binding(kind: kind, usage: 1), custom: custom, target: "")
            XCTAssertEqual(rendered.image, custom.image)
            XCTAssertEqual(rendered.imageIsTemplate, true)
        }
        var config = BoardConfiguration()
        config.layers = [Layer(id: 2, name: "Source", mode: .custom), Layer(id: 7, name: "Target", mode: .custom)]
        config.layers[1].bindings[16] = Binding(kind: .inherit, source: config.layers[0].id)
        var catalog = PresentationCatalog(serial: "synthetic")
        catalog.keys["\(config.layers[0].id):16"] = custom
        XCTAssertEqual(catalog.resolved(config: config, layer: config.layers[1].id, control: 16), custom)
        XCTAssertEqual(try JSONDecoder().decode(PresentationCatalog.self, from: JSONEncoder().encode(catalog)), catalog)
    }

}
