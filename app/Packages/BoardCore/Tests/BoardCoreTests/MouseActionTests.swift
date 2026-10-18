import XCTest
@testable import BoardCore

final class MouseActionTests: XCTestCase {
    func testActionsValidationAndPresentation() throws {
        XCTAssertEqual(MouseAction.allCases.map(\.rawValue), [1, 2])
        for action in MouseAction.allCases {
            let b = Binding(kind: .mouse, usage: action.rawValue)
            XCTAssertTrue(b.isValid)
            XCTAssertFalse(b.kind.isHost)
            XCTAssertEqual(try JSONDecoder().decode(Binding.self, from: JSONEncoder().encode(b)), b)
            let icon = ActionPresentation.standard(binding: b, custom: KeyPresentation(), target: "")
            XCTAssertEqual(icon.name, action.title)
            XCTAssertEqual(icon.symbol, action.symbol)
        }
        for value in [0, 3, 115, 233, 256] { XCTAssertFalse(Binding(kind: .mouse, usage: value).isValid) }
        var b = Binding(kind: .mouse, usage: 1)
        b.modifiers = 1; XCTAssertFalse(b.isValid)
        b.modifiers = 0; b.source = 2; XCTAssertFalse(b.isValid)
        b.source = 0; b.keys = [4]; XCTAssertFalse(b.isValid)
        XCTAssertFalse(Binding(kind: .shortcut, usage: 1).isValid)
    }
    func testCompactRoundTripAndInheritedJoystickDetach() throws {
        var c = BoardConfiguration()
        c.layers += [.blank(id: 2, name: "Source"), .blank(id: 3, name: "Destination")]
        c.favorites = [2, 1]
        c.layers[1].bindings[0] = Binding(kind: .mouse, usage: 1)
        c.layers[1].bindings[14] = Binding(kind: .mouse, usage: 2)
        for id in Control.stickIDs { c.layers[1].bindings[id] = Binding(kind: .mouse, usage: id == 16 ? 1 : 2) }
        c = try XCTUnwrap(QuickSelection.inheriting(c, layer: 3, source: 2))
        XCTAssertTrue(c.isValid)
        let saved = try JSONEncoder().encode(c)
        XCTAssertEqual(try JSONDecoder().decode(BoardConfiguration.self, from: saved), c)
        XCTAssertEqual(c.resolved(layer: 3, control: 16)?.kind, .mouse)
        let custom = KeyPresentation(name: "Read", symbol: "book")
        var p = PresentationCatalog(); p.keys["2:16"] = custom
        let detached = try XCTUnwrap(QuickSelection.detached(c, layer: 3, presentation: p, actions: [:]))
        XCTAssertEqual(detached.configuration.layers[2].bindings[16], Binding(kind: .mouse, usage: 1))
        XCTAssertEqual(detached.presentation.resolved(config: detached.configuration, layer: 3, control: 16), custom)
        XCTAssertEqual(c.layers[1].bindings[14].usage, 2)
    }
    func testCodexNativeComponentsStillRejectMouse() {
        var c = BoardConfiguration()
        c.layers[0].bindings[13] = Binding(kind: .mouse, usage: 1)
        XCTAssertFalse(c.isValid)
    }
    func testAppSwitcherOnlyOnKnobHoldAndRoundTrips() throws {
        var c = BoardConfiguration()
        c.layers += [.blank(id: 2, name: "Source"), .blank(id: 3, name: "Target")]
        c.layers[1].bindings[20] = Binding(kind: .appSwitcher)
        c.layers[2].bindings[20] = Binding(kind: .inherit, source: 2)
        XCTAssertTrue(c.isValid)
        XCTAssertEqual(c.resolved(layer: 3, control: 20)?.kind, .appSwitcher)
        XCTAssertEqual(try JSONDecoder().decode(BoardConfiguration.self, from: JSONEncoder().encode(c)), c)
        let icon = ActionPresentation.standard(binding: Binding(kind: .appSwitcher), custom: KeyPresentation(), target: "")
        XCTAssertEqual(icon.name, "App Switcher")
        for control in 0..<25 where control != 20 {
            var bad = c; bad.layers[1].bindings[control] = Binding(kind: .appSwitcher)
            XCTAssertFalse(bad.isValid)
        }
        c.layers[0].bindings[20] = Binding(kind: .appSwitcher)
        XCTAssertFalse(c.isValid)
    }
    func testAppSwitcherRejectsPayloadFields() {
        XCTAssertTrue(Binding(kind: .appSwitcher).isValid)
        XCTAssertFalse(Binding(kind: .appSwitcher, usage: 1).isValid)
        XCTAssertFalse(Binding(kind: .appSwitcher, modifiers: 8).isValid)
        XCTAssertFalse(Binding(kind: .appSwitcher, source: 2).isValid)
        var b = Binding(kind: .appSwitcher); b.keys = [43]
        XCTAssertFalse(b.isValid)
    }

}
