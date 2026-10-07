import XCTest
import BoardCore

final class ControlMappingTests: XCTestCase {
    func testDiscardNewLayerRestoresValidEditorSelection() {
        var saved = BoardConfiguration()
        saved.layers.insert(Layer.blank(id: 2, name: "Work"), at: 0)
        saved.favorites = [2, 1]
        var draft = saved
        draft.layers.append(Layer.blank(id: 3, name: "New"))
        var selected = 3
        XCTAssertEqual(draft.editorLayer(preferred: selected), 3)
        draft = saved
        XCTAssertNil(draft.resolved(layer: selected, control: 0))
        selected = draft.editorLayer(preferred: selected)
        XCTAssertEqual(selected, 2)
        for control in Control.all.indices {
            XCTAssertNotNil(draft.resolved(layer: selected, control: control))
        }
        XCTAssertEqual(draft, saved)
        XCTAssertEqual(draft.editorLayer(preferred: 1), 1)
        XCTAssertEqual(draft.editorLayer(preferred: 2), 2)
    }

    func testCodexOwnsComponentsInBothModes() {
        var config = BoardConfiguration()
        for mode in [LayerMode.native, .custom] {
            config.layers[0].mode = mode
            for id in 13..<25 { XCTAssertEqual(config.resolved(layer: 1, control: id)?.kind, .native) }
            XCTAssertTrue(config.isValid)
        }
        config.layers[0].bindings[20] = Binding(kind: .shortcut, usage: 11)
        XCTAssertFalse(config.isValid)
    }
    func testOrdinaryComponentsCannotUseNativeOrCodexInheritance() {
        var config = BoardConfiguration(); config.layers.append(Layer.blank(id: 2, name: "Work"))
        for id in 13..<25 {
            config.layers[1].bindings[id] = Binding()
            XCTAssertFalse(config.isValid)
            config.layers[1].bindings[id] = Binding(kind: .inherit, source: 1)
            XCTAssertFalse(config.isValid)
            config.layers[1].bindings[id] = Binding(kind: .disabled)
        }
        config.layers[1].bindings[0] = Binding(kind: .inherit, source: 1)
        XCTAssertTrue(config.isValid)
    }
    func testOrdinaryInheritanceAndCancelBoundaries() {
        var c = BoardConfiguration(); c.layers += [Layer.blank(id: 2, name: "A"), Layer.blank(id: 3, name: "B")]
        c.layers[1].bindings[21] = Binding(kind: .cancel)
        c.layers[2].bindings[21] = Binding(kind: .inherit, source: 2)
        XCTAssertTrue(c.isValid)
        XCTAssertEqual(c.resolved(layer: 3, control: 21)?.kind, .cancel)
        c.layers[1].bindings[20] = Binding(kind: .cancel)
        XCTAssertFalse(c.isValid)
    }
    func testLegacyControlsMigrateWithoutChangingKeys() throws {
        var c = BoardConfiguration(); c.layers.append(Layer.blank(id: 2, name: "Work"))
        var json: [String: Any] = ["layers": try JSONSerialization.jsonObject(with: JSONEncoder().encode(c.layers))]
        json["schemaVersion"] = 5
        var layers = try XCTUnwrap(json["layers"] as? [[String: Any]])
        for i in layers.indices {
            var bindings = Array((layers[i]["bindings"] as! [[String: Any]]).prefix(20))
            bindings[13] = ["kind": "inherit", "usage": 0, "modifiers": 0, "source": 1]
            layers[i]["bindings"] = bindings
        }
        json["layers"] = layers
        let migrated = try JSONDecoder().decode(BoardConfiguration.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertTrue(migrated.isValid)
        XCTAssertEqual(migrated.schemaVersion, 7)
        XCTAssertEqual(migrated.layers[0].bindings[13].kind, .native)
        XCTAssertEqual(migrated.layers[1].bindings[13].kind, .disabled)
        XCTAssertEqual(Array(migrated.layers[1].bindings.prefix(13)), Array(c.layers[1].bindings.prefix(13)))
    }
    func testNewControlsPresentationAndIdentity() {
        XCTAssertEqual(Control.all.count, 25)
        XCTAssertEqual(Set(Control.knobIDs + Control.stickIDs), Set(13..<25))
        var catalog = PresentationCatalog(serial: "test")
        catalog.keys["2:24"] = KeyPresentation(name: "Upper left", symbol: "star")
        XCTAssertTrue(catalog.isValid)
        XCTAssertEqual(ActionPresentation.standard(binding: Binding(kind: .cancel), custom: KeyPresentation(), target: "").symbol, "xmark")
    }
}
