import XCTest
@testable import BoardCore

final class MediaActionTests: XCTestCase {
    func testSixActionsValidateAndRoundTrip() throws {
        XCTAssertEqual(MediaAction.allCases.map(\.rawValue), [233, 234, 226, 205, 182, 181])
        for action in MediaAction.allCases {
            let binding = Binding(kind: .media, usage: action.rawValue)
            XCTAssertTrue(binding.isValid)
            XCTAssertFalse(binding.kind.isHost)
            XCTAssertEqual(try JSONDecoder().decode(Binding.self, from: JSONEncoder().encode(binding)), binding)
            XCTAssertEqual(binding.description, action.title)
            let icon = ActionPresentation.standard(binding: binding, custom: KeyPresentation(), target: "")
            XCTAssertEqual(icon.name, action.title)
            XCTAssertEqual(icon.symbol, action.symbol)
        }
    }
    func testMalformedMediaRejectedWithoutRelaxingShortcuts() {
        for usage in [0, 4, 115, 180, 235, 256] { XCTAssertFalse(Binding(kind: .media, usage: usage).isValid) }
        var binding = Binding(kind: .media, usage: 205)
        binding.modifiers = 1; XCTAssertFalse(binding.isValid)
        binding.modifiers = 0; binding.source = 2; XCTAssertFalse(binding.isValid)
        binding.source = 0; binding.keys = [4]; XCTAssertFalse(binding.isValid)
        XCTAssertFalse(Binding(kind: .shortcut, usage: 233).isValid)
    }
    func testInheritanceAndDetachPreserveMediaAndAppearance() throws {
        var config = BoardConfiguration()
        config.layers += [.blank(id: 2, name: "Source"), .blank(id: 7, name: "Target")]
        for id in Control.stickIDs { config.layers[1].bindings[id] = Binding(kind: .media, usage: 205) }
        config = try XCTUnwrap(QuickSelection.inheriting(config, layer: 7, source: 2))
        XCTAssertTrue(config.isValid)
        XCTAssertEqual(config.resolved(layer: 7, control: 16)?.usage, 205)
        var presentation = PresentationCatalog()
        presentation.keys["2:16"] = KeyPresentation(name: "Music", symbol: "music.note")
        let detached = try XCTUnwrap(QuickSelection.detached(config, layer: 7, presentation: presentation, actions: [:]))
        XCTAssertEqual(detached.configuration.layers[2].bindings[16].kind, .media)
        let custom = detached.presentation.resolved(config: detached.configuration, layer: 7, control: 16)
        let icon = ActionPresentation.standard(binding: detached.configuration.layers[2].bindings[16], custom: custom, target: "")
        XCTAssertEqual(icon.name, "Music"); XCTAssertEqual(icon.symbol, "music.note")
        XCTAssertEqual(try JSONDecoder().decode(BoardConfiguration.self, from: JSONEncoder().encode(config)), config)
    }
}
