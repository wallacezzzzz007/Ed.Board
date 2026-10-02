import XCTest
import BoardCore

final class LightingChordTests: XCTestCase {
    private func inherited() -> BoardConfiguration {
        var c = BoardConfiguration(); c.layers[0].mode = .custom
        c.layers[0].bindings[0] = Binding(kind: .disabled)
        c.layers.append(Layer.blank(id: 2, name: "Red")); c.layers[1].color = 0xff0000
        c.layers[1].bindings[0] = Binding(kind: .inherit, source: 1)
        return c
    }
    func testDefaultLightingUsesDestinationLayer() {
        let c = inherited()
        XCTAssertEqual(c.resolvedLight(layer: 2, control: 0)?.color, 0xff0000)
        XCTAssertNil(c.lightOverride(layer: 2, control: 0))
    }
    func testOverrideFollowsChainAndRevertsToDestination() {
        var c = inherited(); let light = LightSpec(effect: 4, color: 0x00ff00, brightness: 20, active: 70)
        c.layers[0].keyLights[0] = light
        c.layers.append(Layer.blank(id: 3, name: "Blue")); c.layers[2].color = 0x0000ff; c.layers[2].bindings[0] = Binding(kind: .inherit, source: 2)
        XCTAssertEqual(c.resolvedLight(layer: 3, control: 0), light)
        c.layers[0].keyLights[0] = nil
        XCTAssertEqual(c.resolvedLight(layer: 3, control: 0)?.color, 0x0000ff)
    }
    func testNativeAgentRetainsDynamicLighting() {
        var c = inherited(); c.layers[0].mode = .native
        XCTAssertNil(c.resolvedLight(layer: 2, control: 0))
    }
    func testChordLimitsAndModifierSides() {
        XCTAssertTrue(ShortcutKeys.valid([224,227,11,41]))
        XCTAssertTrue(ShortcutKeys.valid(Array(224...231) + Array(4...9)))
        XCTAssertFalse(ShortcutKeys.valid(Array(4...10)))
        XCTAssertFalse(ShortcutKeys.valid([11,11]))
        XCTAssertFalse(ShortcutKeys.valid([]))
        XCTAssertTrue(ShortcutKeys.valid([231]))
        XCTAssertNotEqual(ShortcutKeys.title(224), ShortcutKeys.title(228))
    }
    func testOldBindingDecodesAndNewOrderRoundTrips() throws {
        let old = try JSONDecoder().decode(Binding.self, from: Data(#"{"kind":"shortcut","usage":11,"modifiers":9,"source":0}"#.utf8))
        XCTAssertEqual(old.chord, [224,227,11])
        var new = Binding(kind: .shortcut); new.keys = [11,227,224,41]
        XCTAssertTrue(new.isValid)
        XCTAssertEqual(try JSONDecoder().decode(Binding.self, from: JSONEncoder().encode(new)), new)
    }
    func testIndependentBrightnessAndValidation() {
        var c = inherited(); c.layers[1].keysLight.brightness = 35
        XCTAssertEqual(c.layers[1].outerLight.brightness, 15)
        c.layers[1].keyLights[0] = LightSpec(effect: 4, brightness: 80, active: 20)
        XCTAssertFalse(c.isValid)
        c.layers[1].keyLights[0] = nil; c.layers[1].effects[2] = 2
        XCTAssertFalse(c.isValid)
    }
    func testExtendedMaximumFitsWireAndRoundTrips() throws {
        var c = BoardConfiguration(); var b = Binding(kind: .shortcut); b.keys = Array(224...231) + [159,160,161,162,163,164]
        c.layers = (1...6).map { id in
            var l = Layer(id: id, name: String(repeating: "\\", count: 48), mode: .custom, bindings: Array(repeating: b, count: 25))
            l.effects = [4,100,5,100,100]; l.keyLights = Array(repeating: LightSpec(effect: 4, brightness: 100, active: 100), count: 13)
            return l
        }
        XCTAssertTrue(c.isValid)
        let data = try Wire.request(id: 2147483647, method: "config.set", params: SetParams(baseRevision: 2147483646, config: c))
        XCTAssertLessThan(data.count, 32768)
        XCTAssertEqual(try JSONDecoder().decode(BoardConfiguration.self, from: JSONEncoder().encode(c)), c)
    }
    func testFunctionKeyAndKeypadCoverage() {
        for id in Array(104...115) + [41,70,71,72,83,84,85,86,87,88,99,103,130,131,132,133,134] {
            XCTAssertTrue(HIDKey.choices.contains { $0.id == id }, "Missing \(id)")
        }
    }
}
