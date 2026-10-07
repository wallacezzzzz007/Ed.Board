import XCTest
@testable import BoardCore

final class ExtendedLayersTests: XCTestCase {
    private func fixtures() throws -> ProtocolTests.Fixtures {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<6 { root.deleteLastPathComponent() }
        return try JSONDecoder().decode(ProtocolTests.Fixtures.self, from: Data(contentsOf: root.appendingPathComponent("protocol/fixtures/management-v7.json")))
    }
    func testSharedCompactFixturesAndCrossLanguageFields() throws {
        let f = try fixtures(), c = f.validConfig
        XCTAssertTrue(c.isValid); XCTAssertTrue(f.maximumConfig.isValid)
        XCTAssertEqual(c.favorites, [8, 1]); XCTAssertEqual(c.startupLayerID, 8)
        XCTAssertEqual(c.extendedLayers.map(\.id), [240])
        let invalidRuntime = try JSONDecoder().decode(RuntimeState.self, from: Data(#"{"manualLayer":240,"activeLayer":240}"#.utf8))
        XCTAssertFalse(invalidRuntime.isValid(for: c))
        XCTAssertEqual(c.layers[2].name, "扩展")
        XCTAssertEqual(c.resolved(layer: 240, control: 0), Binding(kind: .text, source: 7))
        XCTAssertEqual(c.layers[1].keyLights[0], LightSpec(effect: 4, color: 0xa8932e, brightness: 14, active: 30))
        XCTAssertEqual(c.layers[2].bindings[14].keys, [227, 4])
        for invalid in f.invalidConfigs { XCTAssertFalse(invalid.config?.isValid ?? false, invalid.name) }
        for config in [c, f.maximumConfig] {
            let data = try JSONEncoder().encode(config)
            XCTAssertEqual(try JSONDecoder().decode(BoardConfiguration.self, from: data), config)
        }
    }
    func testMaximumFitsExistingSnapshotAndWireBudgets() throws {
        let c = try fixtures().maximumConfig
        let bytes = try c.compactPayload().utf8.count / 2
        XCTAssertEqual(c.layers.count, 16); XCTAssertEqual(bytes + 4, 8101)
        XCTAssertLessThanOrEqual(bytes + 4, 8192)
        let data = try Wire.request(id: 2147483647, method: "config.set", params: SetParams(baseRevision: 2147483646, config: c))
        XCTAssertLessThan(data.count, 32768)
        var framer = LineFramer(), lines: [String] = []
        for start in stride(from: 0, to: data.count, by: 7) { lines += framer.feed(data.subdata(in: start..<min(start + 7, data.count))) }
        XCTAssertEqual(lines.count, 1); XCTAssertEqual(framer.droppedLines, 0)
    }
    func testAllTruncationsAndInvalidUTF8AreRejected() throws {
        let payload = try fixtures().validConfig.compactPayload()
        for length in stride(from: 0, to: payload.count, by: 2) {
            XCTAssertThrowsError(try BoardConfiguration(compactPayload: String(payload.prefix(length))))
        }
        // Header, two Favorite IDs, layer ID and name length precede the first name.
        var bytes = Array(payload.utf8)
        bytes[14] = 102; bytes[15] = 102 // FF is never a valid UTF-8 lead byte.
        XCTAssertThrowsError(try BoardConfiguration(compactPayload: String(decoding: bytes, as: UTF8.self)))
    }
    func testCategoryMovesPreserveIdentityBindingsAndAppearance() throws {
        var c = try fixtures().validConfig
        let layers = c.layers
        XCTAssertTrue(c.setFavorite(240, enabled: true))
        XCTAssertTrue(c.setFavorite(8, enabled: false))
        XCTAssertEqual(c.layers, layers); XCTAssertEqual(c.favorites, [1, 240])
        XCTAssertEqual(c.nextFavorite(after: 8), 1)
        XCTAssertEqual(c.nextFavorite(after: 1), 240)
        XCTAssertEqual(c.nextFavorite(after: 240), 1)
        c.moveLayer(240, offset: -1)
        XCTAssertEqual(c.favorites, [240, 1]); XCTAssertEqual(c.startupLayerID, 240)
        XCTAssertEqual(c.editorLayer(preferred: 8), 8)
        XCTAssertTrue(c.isValid)
        XCTAssertFalse(c.canDelete(8)) // Extended source remains protected by inheritance.
    }
    func testFavoriteBoundariesAndSixteenLayerInheritance() throws {
        var c = try fixtures().maximumConfig
        XCTAssertFalse(c.setFavorite(16, enabled: true)); XCTAssertEqual(c.favorites.count, 6)
        for id in Array(c.favorites.dropFirst()) { XCTAssertTrue(c.setFavorite(id, enabled: false)) }
        XCTAssertFalse(c.setFavorite(c.favorites[0], enabled: false))
        XCTAssertFalse(c.canDelete(c.favorites[0]))
        for i in 1..<16 { c.layers[i].bindings[0] = Binding(kind: .inherit, source: c.layers[i - 1].id) }
        XCTAssertTrue(c.isValid)
        XCTAssertEqual(c.resolved(layer: 16, control: 0), c.layers[0].bindings[0])
        c.layers[0].bindings[0] = Binding(kind: .inherit, source: 16)
        XCTAssertFalse(c.isValid)
    }
    func testLegacyOrderBecomesFavoritesWithoutDroppingConfiguration() throws {
        let legacy = try ProtocolTests().fixtures().maximumConfig
        XCTAssertEqual(legacy.schemaVersion, 7)
        XCTAssertEqual(legacy.favorites, legacy.layers.map(\.id))
        XCTAssertEqual(try JSONDecoder().decode(BoardConfiguration.self, from: JSONEncoder().encode(legacy)), legacy)
    }
    func testIndicatorsFollowFavoriteOrderAndAreOffForEveryExtendedLayer() throws {
        var c = try fixtures().maximumConfig
        for (index, id) in c.favorites.enumerated() { XCTAssertEqual(c.indicatorMask(for: id), [1,2,4,3,6,7][index]) }
        for layer in c.extendedLayers { XCTAssertEqual(c.indicatorMask(for: layer.id), 0) }
        c.moveLayer(1, offset: -1)
        XCTAssertEqual(c.indicatorMask(for: 1), 6)
        XCTAssertEqual(c.indicatorMask(for: 255), 0)
    }
    func testLocalCatalogsSupportSixteenLayersAndRetainBounds() {
        var presentation = PresentationCatalog(serial: "synthetic")
        for id in 1...16 { for control in 0..<25 { presentation.keys["\(id):\(control)"] = KeyPresentation(name: "Example") } }
        XCTAssertTrue(presentation.isValid)
        presentation.keys["17:0"] = KeyPresentation(); XCTAssertFalse(presentation.isValid)
        var catalog = HostCatalog(serial: "synthetic")
        // Stage new immutable IDs alongside the previous committed catalog.
        for id in 1...800 { catalog.actions[id] = HostAction(kind: .text, value: "Example") }
        XCTAssertTrue(catalog.isValid)
        catalog.actions[801] = HostAction(kind: .text, value: "Example"); XCTAssertFalse(catalog.isValid)
        var auto = AutoBindings()
        auto.devices["synthetic"] = (1...16).map { AutoRule(layer: $0, enabled: true, applications: [LinkedApplication(bundleID: "example.app\($0)", name: "Example")]) }
        XCTAssertTrue(auto.isValid)
        XCTAssertEqual(auto.matchingLayer(serial: "synthetic", bundleID: "example.app16", available: Set(1...16)), 16)
        auto.devices["synthetic"]!.append(AutoRule(layer: 17)); XCTAssertFalse(auto.isValid)
    }
}
