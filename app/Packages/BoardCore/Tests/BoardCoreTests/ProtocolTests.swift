import XCTest
import BoardCore

final class ProtocolTests: XCTestCase {
    struct InvalidCase: Decodable {
        let name: String; let config: BoardConfiguration?
        enum CodingKeys: String, CodingKey { case name, config }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            name = try c.decode(String.self, forKey: .name)
            config = try? c.decode(BoardConfiguration.self, forKey: .config)
        }
    }
    struct Fixtures: Decodable { let validConfig: BoardConfiguration; let maximumConfig: BoardConfiguration; let invalidConfigs: [InvalidCase] }
    func fixtures() throws -> Fixtures {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<6 { root.deleteLastPathComponent() }
        return try JSONDecoder().decode(Fixtures.self, from: Data(contentsOf: root.appendingPathComponent("protocol/fixtures/management-v6.json")))
    }
    func testPublicErrorConstructionAndDecoding() throws {
        let remote = try JSONDecoder().decode(RPCError.self, from: Data(#"{"code":"invalid_snapshot"}"#.utf8))
        XCTAssertEqual(RPCError(code: "invalid_snapshot").code, remote.code)
    }
    func testSharedFirmwareFixtures() throws {
        let f = try fixtures()
        XCTAssertTrue(f.validConfig.isValid)
        XCTAssertTrue(f.maximumConfig.isValid)
        for invalid in f.invalidConfigs { XCTAssertFalse(invalid.config?.isValid ?? false, invalid.name) }
    }
    func testLiveInheritanceDoesNotSwitchLayerOrCopyColors() throws {
        var config = try fixtures().validConfig
        config.layers[1].color = 0x00ff00
        XCTAssertEqual(config.resolved(layer: 2, control: 6)?.modifiers, 8)
        config.layers[0].bindings[6].modifiers = 10
        XCTAssertEqual(config.resolved(layer: 2, control: 6)?.modifiers, 10)
        XCTAssertEqual(config.startupLayerID, 1)
        XCTAssertEqual(config.layers[1].color, 0x00ff00)
    }
    func testModePreservesCustomPlanAndChangesInheritedAction() throws {
        var config = try fixtures().validConfig
        let plan = config.layers[0].bindings
        config.layers[0].mode = .native
        XCTAssertEqual(config.resolved(layer: 2, control: 6)?.kind, .native)
        config.layers[0].mode = .custom
        XCTAssertEqual(config.layers[0].bindings, plan)
        XCTAssertEqual(config.resolved(layer: 2, control: 6)?.kind, .shortcut)
    }
    func testDeletionProtectsReferencesAndSortPreservesIdentity() throws {
        var config = try fixtures().maximumConfig
        XCTAssertFalse(config.canDelete(1)); XCTAssertFalse(config.canDelete(2))
        config.deleteLayer(2); XCTAssertEqual(config.layers.count, 6)
        let original = config.resolved(layer: 6, control: 6)
        config.moveLayer(1, offset: 1)
        XCTAssertEqual(config.startupLayerID, 2)
        XCTAssertEqual(config.resolved(layer: 6, control: 6), original)
        XCTAssertTrue(config.canDelete(6)); config.deleteLayer(6)
        XCTAssertEqual(config.layers.count, 5); XCTAssertTrue(config.isValid)
    }
    func testNamesUseUTF8Limit() {
        var config = BoardConfiguration()
        config.layers[0].name = String(repeating: "层", count: 16)
        XCTAssertTrue(config.isValid)
        config.layers[0].name += "层"
        XCTAssertFalse(config.isValid)
    }
    func testSixLayerChainAndRuntimeIsNotPersisted() throws {
        var config = try fixtures().maximumConfig
        config.layers[0].bindings[12] = Binding(kind: .shortcut, usage: 82)
        XCTAssertEqual(config.resolved(layer: 6, control: 12)?.usage, 82)
        XCTAssertNil(config.resolved(layer: 6, control: 25))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(config)) as? [String: Any])
        XCTAssertNil(json["manualLayer"]); XCTAssertNil(json["defaultLayer"])
        let runtime = try JSONDecoder().decode(RuntimeState.self, from: Data(#"{"manualLayer":6,"activeLayer":6}"#.utf8))
        XCTAssertTrue(runtime.isValid(for: config))
        config.deleteLayer(6); XCTAssertFalse(runtime.isValid(for: config))
    }
    func testMaximumSnapshotRoundTripAndFrameCapacity() throws {
        var config = try fixtures().maximumConfig
        for i in config.layers.indices {
            config.layers[i].name = String(repeating: "\\", count: 48)
            config.layers[i].bindings = Array(repeating: Binding(kind: .shortcut, usage: 115, modifiers: 15), count: 25)
            if config.layers[i].id == 1 { for control in 13..<25 { config.layers[i].bindings[control] = Binding() } }
            config.layers[i].color = 0xffffff; config.layers[i].ringColor = 0xffffff; config.layers[i].brightness = 100
        }
        let encoded = try JSONEncoder().encode(config)
        XCTAssertLessThan(encoded.count + 256, 12288)
        XCTAssertEqual(try JSONDecoder().decode(BoardConfiguration.self, from: encoded), config)
        let data = try Wire.request(id: 23, method: "config.set", params: SetParams(baseRevision: 17, config: config))
        XCTAssertLessThan(data.count, 4096)
        XCTAssertLessThan(data.count, 32769)
        var framer = LineFramer(); var lines = [String]()
        for start in stride(from: 0, to: data.count, by: 7) { lines += framer.feed(data.subdata(in: start..<min(start + 7, data.count))) }
        XCTAssertEqual(lines.count, 1)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(Wire.payload(lines[0]))) as? [String: Any])
        XCTAssertEqual((object["params"] as? [String: Any])?["baseRevision"] as? Int, 17)
        XCTAssertEqual(object["protocol"] as? Int, 1)
    }
    func testFragmentedManagementAndDiagnostics() throws {
        var framer = LineFramer()
        XCTAssertEqual(framer.feed(Data("edboard test\r\n@edbo".utf8)), ["edboard test"])
        let lines = framer.feed(Data("ard {\"protocol\":1,\"id\":7,\"result\":{}}\n".utf8))
        let data = try XCTUnwrap(Wire.payload(try XCTUnwrap(lines.first)))
        XCTAssertEqual(try JSONDecoder().decode(Header.self, from: data).id, 7)
    }
    func testOversizedLineRecoversAtNextNewline() {
        var framer = LineFramer()
        XCTAssertTrue(framer.feed(Data(repeating: 65, count: 33000)).isEmpty)
        XCTAssertEqual(framer.feed(Data("\nnext\n".utf8)), ["next"])
        XCTAssertEqual(framer.droppedLines, 1)
    }
}
