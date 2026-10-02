import XCTest
import BoardCore

final class PresentationTests: XCTestCase {
    func testInheritanceIncludesNameAndImageButNotLayerLighting() {
        var config = BoardConfiguration()
        config.layers[0].mode = .custom
        config.layers.append(Layer(id: 2, name: "Work", mode: .custom))
        config.layers[1].bindings[0] = Binding(kind: .inherit, source: 1)
        config.layers[1].color = 0x123456
        var catalog = PresentationCatalog(serial: "test")
        catalog.keys["1:0"] = KeyPresentation(name: "Search", symbol: "magnifyingglass", image: Data([1, 2]))
        XCTAssertEqual(catalog.resolved(config: config, layer: 2, control: 0), catalog.keys["1:0"])
        catalog.keys["1:0"]?.name = "Find"
        XCTAssertEqual(catalog.resolved(config: config, layer: 2, control: 0).name, "Find")
        XCTAssertEqual(config.layers[1].color, 0x123456)
        config.moveLayer(2, offset: -1)
        XCTAssertEqual(catalog.resolved(config: config, layer: 2, control: 0).name, "Find")
    }
    func testNativeBypassAndCycleAreBounded() {
        var config = BoardConfiguration()
        config.layers.append(Layer(id: 2, name: "Work", mode: .custom))
        config.layers[0].bindings[0] = Binding(kind: .inherit, source: 2)
        config.layers[1].bindings[0] = Binding(kind: .inherit, source: 1)
        var catalog = PresentationCatalog()
        catalog.keys["1:0"] = KeyPresentation(name: "Native")
        XCTAssertEqual(catalog.resolved(config: config, layer: 2, control: 0).name, "Native")
        config.layers[0].mode = .custom
        XCTAssertEqual(catalog.resolved(config: config, layer: 2, control: 0), KeyPresentation())
        XCTAssertEqual(catalog.resolved(config: config, layer: 2, control: 25), KeyPresentation())
    }
    func testDeletedLayerDoesNotRestoreImagesWhenIDIsReused() throws {
        var catalog = PresentationCatalog(serial: "test")
        catalog.keys["2:0"] = KeyPresentation(name: "Old", image: Data([1]))
        catalog.keys["12:0"] = KeyPresentation(name: "Keep")
        catalog.removeLayer(2)
        let reloaded = try JSONDecoder().decode(PresentationCatalog.self, from: JSONEncoder().encode(catalog))
        XCTAssertNil(reloaded.keys["2:0"])
        XCTAssertEqual(reloaded.keys["12:0"]?.name, "Keep")
        XCTAssertTrue(reloaded.isValid)
    }
    func testPreviewRejectsOtherSessionsDuplicateFramesAndInvalidCoordinates() throws {
        let line = #"@edboard {"protocol":1,"event":"preview","token":42,"sequence":7,"keys":8193,"pressed":2,"left":5,"right":6,"touchCount":1,"touched":false,"x":700,"y":-700}"#
        let frame = try JSONDecoder().decode(PreviewFrame.self, from: XCTUnwrap(Wire.payload(line)))
        XCTAssertTrue(frame.accepts(token: 42, after: 6))
        XCTAssertFalse(frame.accepts(token: 41, after: 6))
        XCTAssertFalse(frame.accepts(token: 42, after: 7))
        XCTAssertTrue(PreviewFrame.isPreviewLine(line))
        XCTAssertFalse(PreviewFrame.isPreviewLine(line.replacingOccurrences(of: "700", with: "1001")))
        XCTAssertFalse(PreviewFrame.isPreviewLine(#"@edboard {"event":"preview"}"#))
        XCTAssertFalse(PreviewFrame.isPreviewLine(#"@edboard {"event":"host.action"}"#))
    }
    func testOnlyShortcutUsesCustomPresentation() {
        let custom = KeyPresentation(name: "Mine", symbol: "star", image: Data([1]))
        XCTAssertEqual(ActionPresentation.standard(binding: Binding(kind: .shortcut), custom: custom, target: ""), custom)
        let native = ActionPresentation.standard(binding: Binding(kind: .native), custom: custom, target: "")
        XCTAssertEqual(native.name, "Codex")
        XCTAssertNil(native.image)
        let text = ActionPresentation.standard(binding: Binding(kind: .text), custom: custom, target: "private text")
        XCTAssertEqual(text.name, "Insert text")
        XCTAssertEqual(text.symbol, "text.alignleft")
        XCTAssertNil(text.image)
    }
    func testStandardNamesUseTargetsAndFolderType() {
        let blank = KeyPresentation()
        XCTAssertEqual(ActionPresentation.standard(binding: Binding(kind: .application), custom: blank, target: "/Applications/Notes.app").name, "Open Notes")
        XCTAssertEqual(ActionPresentation.standard(binding: Binding(kind: .open), custom: blank, target: "https://example.com/private?q=secret").name, "Open example.com")
        XCTAssertEqual(ActionPresentation.standard(binding: Binding(kind: .open), custom: blank, target: "/tmp/Work", folder: true).symbol, "folder")
        XCTAssertEqual(ActionPresentation.standard(binding: Binding(kind: .open), custom: blank, target: "/tmp/file.txt").symbol, "doc")
    }
    func testPowerTimingAndOffSemantics() {
        XCTAssertTrue(PowerOptions.valid(seconds: 30, lights: true, deepMinutes: 15, keepConnected: false))
        XCTAssertFalse(PowerOptions.valid(seconds: 1800, lights: true, deepMinutes: 15, keepConnected: false))
        XCTAssertFalse(PowerOptions.valid(seconds: 900, lights: true, deepMinutes: 15, keepConnected: false))
        XCTAssertTrue(PowerOptions.valid(seconds: 1800, lights: true, deepMinutes: 15, keepConnected: true))
        XCTAssertTrue(PowerOptions.valid(seconds: 1800, lights: false, deepMinutes: 15, keepConnected: false))
        XCTAssertFalse(PowerOptions.valid(seconds: 29, lights: false, deepMinutes: 15, keepConnected: true))
        XCTAssertFalse(PowerOptions.valid(seconds: 60, lights: true, deepMinutes: 0, keepConnected: true))
    }
    func testPowerLabelsPreserveCustomDurations() {
        XCTAssertEqual(PowerOptions.duration(0), "Off")
        XCTAssertEqual(PowerOptions.duration(30), "30 seconds")
        XCTAssertEqual(PowerOptions.duration(120), "2 minutes")
        XCTAssertEqual(PowerOptions.duration(3600), "1 hour")
        XCTAssertEqual(PowerOptions.duration(7200), "2 hours")
    }
    func testBlankLayerDisablesControlsAndUsesVisibleWhiteLighting() {
        let layer = Layer.blank(id: 2, name: "Writing")
        XCTAssertEqual(layer.name, "Writing")
        XCTAssertEqual(layer.bindings.count, 25)
        XCTAssertTrue(layer.bindings.allSatisfy { $0.kind == .disabled })
        XCTAssertEqual(layer.color, 0xffffff)
        XCTAssertEqual(layer.ringColor, 0xffffff)
        XCTAssertEqual(layer.brightness, 15)
        XCTAssertEqual(layer.mode, .custom)
    }
    func testResetCodexKeepsIdentityAndInheritedControlsResolveDisabled() {
        var config = BoardConfiguration()
        config.layers.append(Layer(id: 2, name: "Work", mode: .custom))
        config.layers[1].bindings[0] = Binding(kind: .inherit, source: 1)
        config.layers[0] = Layer.blank(id: 1, name: config.layers[0].name)
        XCTAssertTrue(config.isValid)
        XCTAssertEqual(config.layers[0].name, "Codex")
        XCTAssertEqual(config.resolved(layer: 2, control: 0)?.kind, .disabled)
        XCTAssertFalse(config.canDelete(1))
    }
}
