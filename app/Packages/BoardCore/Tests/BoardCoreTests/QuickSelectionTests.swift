import XCTest
@testable import BoardCore

final class QuickSelectionTests: XCTestCase {
    private func config() -> BoardConfiguration {
        var value = BoardConfiguration()
        value.layers += [Layer.blank(id: 2, name: "Source"), Layer.blank(id: 3, name: "Target"), Layer.blank(id: 4, name: "Chain")]
        for id in Control.stickIDs { value.layers[1].bindings[id] = Binding(kind: .shortcut, usage: 4 + id - 16) }
        value.layers[1].bindings[18] = Binding(kind: .cancel)
        return value
    }
    func testAllDirectionsFollowSourceAndRoundTripWithoutSchemaChange() throws {
        var original = config()
        original.layers[2].bindings[13] = Binding(kind: .shortcut, usage: 40)
        let linked = try XCTUnwrap(QuickSelection.inheriting(original, layer: 3, source: 2))
        XCTAssertEqual(QuickSelection.source(in: linked, layer: 3), 2)
        XCTAssertNil(linked.validationError)
        XCTAssertEqual(linked.layers[2].bindings[13], original.layers[2].bindings[13])
        let decoded = try JSONDecoder().decode(BoardConfiguration.self, from: JSONEncoder().encode(linked))
        XCTAssertEqual(decoded, linked)
        XCTAssertEqual(decoded.schemaVersion, 6)
        var edited = linked
        edited.layers[1].bindings[21] = Binding(kind: .disabled)
        XCTAssertEqual(edited.resolved(layer: 3, control: 21)?.kind, .disabled)
        XCTAssertEqual(edited.resolved(layer: 3, control: 18)?.kind, .cancel)
    }
    func testRejectsSelfCodexMissingAndIndirectSingleDirectionCycle() throws {
        var value = config()
        XCTAssertNil(QuickSelection.inheriting(value, layer: 2, source: 2))
        XCTAssertNil(QuickSelection.inheriting(value, layer: 2, source: 1))
        XCTAssertNil(QuickSelection.inheriting(value, layer: 1, source: 2))
        XCTAssertNil(QuickSelection.inheriting(value, layer: 2, source: 99))
        value.layers[1].bindings[21] = Binding(kind: .inherit, source: 4)
        value.layers[3].bindings[21] = Binding(kind: .inherit, source: 3)
        XCTAssertNil(QuickSelection.inheriting(value, layer: 3, source: 2))
    }
    func testDetachCopiesFinalActionAppearanceAndIndependentHostPayloads() throws {
        var value = config()
        value.layers[1].bindings[16] = Binding(kind: .text, source: 7)
        value = try XCTUnwrap(QuickSelection.inheriting(value, layer: 4, source: 2))
        value = try XCTUnwrap(QuickSelection.inheriting(value, layer: 3, source: 4))
        var presentation = PresentationCatalog()
        presentation.keys["2:17"] = KeyPresentation(name: "Test", symbol: "star", image: Data([1, 2]))
        let action = HostAction(kind: .text, value: "Original")
        let result = try XCTUnwrap(QuickSelection.detached(value, layer: 3, presentation: presentation, actions: [7: action], reservedIDs: [1, 2]))
        XCTAssertNil(QuickSelection.source(in: result.configuration, layer: 3))
        XCTAssertEqual(result.presentation.keys["3:17"], presentation.keys["2:17"])
        let id = result.configuration.layers[2].bindings[16].source
        XCTAssertFalse([1, 2, 7].contains(id))
        XCTAssertEqual(result.actions[id]?.value, "Original")
        XCTAssertEqual(result.configuration.layers[2].bindings[18].kind, .cancel)
        var edited = result.configuration
        edited.layers[1].bindings[17] = Binding(kind: .disabled)
        XCTAssertEqual(edited.resolved(layer: 3, control: 17)?.kind, .shortcut)
        XCTAssertNil(QuickSelection.detached(value, layer: 3, presentation: presentation, actions: [:]))
    }
    func testMixedPerDirectionInheritanceIsNotWholeGroup() {
        var value = config()
        value.layers[2].bindings[16] = Binding(kind: .inherit, source: 2)
        XCTAssertNil(QuickSelection.source(in: value, layer: 3))
    }
}
