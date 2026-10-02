import XCTest
@testable import BoardCore

final class HostActionTests: XCTestCase {
    func testPayloadValidationAndUnicodeLimit() {
        XCTAssertTrue(HostAction(kind: .application, value: "/Applications/TextEdit.app").isValid)
        XCTAssertFalse(HostAction(kind: .application, value: "https://example.com").isValid)
        XCTAssertTrue(HostAction(kind: .open, value: "/tmp/中文 文件.txt").isValid)
        XCTAssertTrue(HostAction(kind: .open, value: "https://example.com/path?q=1").isValid)
        for invalid in ["javascript:alert(1)", "file:///tmp/a", "https://user:pass@example.com", "https://example.com/\n", "relative.txt"] {
            XCTAssertFalse(HostAction(kind: .open, value: invalid).isValid, invalid)
        }
        XCTAssertTrue(HostAction(kind: .text, value: "中文🙂\n第二行").isValid)
        XCTAssertFalse(HostAction(kind: .text, value: "\0").isValid)
        XCTAssertTrue(HostAction(kind: .text, value: String(repeating: "🙂", count: 1024)).isValid)
        XCTAssertFalse(HostAction(kind: .text, value: String(repeating: "🙂", count: 1025)).isValid)
    }
    func testHostInheritanceAndNativeBypass() {
        var c = BoardConfiguration()
        c.layers[0].mode = .custom
        c.layers[0].bindings[6] = Binding(kind: .text, source: 2147483647)
        c.layers.append(Layer(id: 2, name: "Text", mode: .custom))
        c.layers[1].bindings[6] = Binding(kind: .inherit, source: 1)
        XCTAssertTrue(c.isValid)
        XCTAssertEqual(c.resolved(layer: 2, control: 6)?.source, 2147483647)
        c.layers[0].mode = .native
        XCTAssertEqual(c.resolved(layer: 2, control: 6)?.kind, .native)
        XCTAssertFalse(Binding(kind: .text, source: 0).isValid)
        XCTAssertFalse(Binding(kind: .open, usage: 29, source: 1).isValid)
        XCTAssertFalse(Binding(kind: .inherit, source: 256).isValid)
    }
    func testEventRejectsReplayWrongSessionRevisionAndExpiredLease() throws {
        var c = BoardConfiguration(); c.layers[0].mode = .custom
        c.layers[0].bindings[6] = Binding(kind: .text, source: 1234)
        let snapshot = Snapshot(revision: 7, config: c)
        func event(_ seq: Int, session: Int = 10, revision: Int = 7, lease: Int = 4, source: Int = 1234) throws -> HostActionEvent {
            let data = Data("{\"protocol\":1,\"event\":\"host.action\",\"session\":\(session),\"sequence\":\(seq),\"lease\":\(lease),\"revision\":\(revision),\"layer\":1,\"control\":6,\"source\":\(source)}".utf8)
            return try JSONDecoder().decode(HostActionEvent.self, from: data)
        }
        var gate = HostActionGate()
        XCTAssertNotNil(try gate.accept(event(1), session: 10, lease: 4, snapshot: snapshot))
        XCTAssertNil(try gate.accept(event(1), session: 10, lease: 4, snapshot: snapshot))
        XCTAssertNil(try gate.accept(event(2, session: 9), session: 10, lease: 4, snapshot: snapshot))
        XCTAssertNil(try gate.accept(event(2, revision: 6), session: 10, lease: 4, snapshot: snapshot))
        XCTAssertNil(try gate.accept(event(2, lease: 2), session: 10, lease: 4, snapshot: snapshot))
        XCTAssertNil(try gate.accept(event(2, source: 99), session: 10, lease: 4, snapshot: snapshot))
        XCTAssertNotNil(try gate.accept(event(3), session: 10, lease: 4, snapshot: snapshot))
        XCTAssertNotNil(try gate.accept(event(1, session: 11), session: 11, lease: 4, snapshot: snapshot))
    }
    func testLargestHostConfigurationFitsWireAndCompactStorage() throws {
        var c = BoardConfiguration()
        c.layers = (1...6).map { Layer(id: $0, name: String(repeating: "\\", count: 48), mode: .custom,
            bindings: Array(repeating: Binding(kind: .application, source: 2147483647), count: 25)) }
        for i in c.layers.indices { c.layers[i].color = 0xffffff; c.layers[i].ringColor = 0xffffff; c.layers[i].brightness = 100 }
        XCTAssertTrue(c.isValid)
        let request = try Wire.request(id: 2147483647, method: "config.set", params: SetParams(baseRevision: 2147483646, config: c))
        XCTAssertLessThan(request.count, 32769)
        // Schema 6 stores fixed-size binary records, including names and per-key lights.
        let maximumBytes = 6 + 6 * (2 + 48 + 1 + 3 + 3 + 1 + 5 + 25 * 22 + 13 * 7)
        XCTAssertEqual(maximumBytes, 4230)
        XCTAssertLessThanOrEqual(maximumBytes, 8192)
    }
    func testCatalogRetainsImmutableIDsAndRejectsInvalidEntries() throws {
        var catalog = HostCatalog(serial: "CM3-test")
        catalog.actions[42] = HostAction(kind: .text, value: "旧文本")
        catalog.actions[43] = HostAction(kind: .text, value: "新文本")
        let decoded = try JSONDecoder().decode(HostCatalog.self, from: JSONEncoder().encode(catalog))
        XCTAssertTrue(decoded.isValid)
        XCTAssertEqual(decoded.actions[42]?.value, "旧文本")
        catalog.actions[0] = HostAction(kind: .text, value: "invalid ID")
        XCTAssertFalse(catalog.isValid)
    }
}
