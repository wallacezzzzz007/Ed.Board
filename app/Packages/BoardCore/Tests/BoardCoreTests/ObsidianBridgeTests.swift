import XCTest
@testable import BoardCore

final class ObsidianBridgeTests: XCTestCase {
    private var nextSequence = 0
    private let code = String(repeating: "a", count: 64)
    private let token = String(repeating: "b", count: 64)
    private let client = String(repeating: "c", count: 32)
    private func request(_ path: String, auth: String, body: [String: Any] = [:]) -> BridgeHTTPRequest {
        BridgeHTTPRequest(path: path, authorization: auth, body: try! JSONSerialization.data(withJSONObject: body))
    }
    private func wire(_ path: String = "/v2/view", auth: String? = nil, body: String = "{}", headers: String = "") -> Data {
        Data("POST \(path) HTTP/1.1\r\nHost: 127.0.0.1:27124\r\nAuthorization: Bearer \(auth ?? token)\r\nContent-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\n\(headers)\r\n\(body)".utf8)
    }
    private func paired() -> ObsidianBridgeSession {
        var bridge = ObsidianBridgeSession(); bridge.activate(credential: token); bridge.setForeground(true, now: 0); return bridge
    }
    private func view(_ value: String = "markdown", client: String? = nil, focus: Int = 1, sequence: Int? = nil) -> BridgeHTTPRequest {
        nextSequence += 1
        return request("/v2/view", auth: token, body: ["client": client ?? self.client, "view": value, "focus": focus, "sequence": sequence ?? nextSequence])
    }
    func testHTTPFragmentationAndBounds() {
        let data = wire(body: "{\"view\":\"markdown\"}")
        for count in 0..<data.count {
            guard case .incomplete = BridgeHTTPRequest.parse(data.prefix(count)) else { return XCTFail("Incomplete frame accepted") }
        }
        guard case .request(let parsed) = BridgeHTTPRequest.parse(data) else { return XCTFail("Valid frame rejected") }
        XCTAssertEqual(parsed.path, "/v2/view"); XCTAssertEqual(parsed.authorization, token)
        for invalid in [data + Data("x".utf8), Data(repeating: 65, count: 4097), wire(body: String(repeating: "a", count: 513)), wire(auth: "bad")] {
            guard case .invalid = BridgeHTTPRequest.parse(invalid) else { return XCTFail("Invalid frame accepted") }
        }
    }
    func testHTTPRejectsBrowserRequestsAndAmbiguousHeaders() {
        for headers in ["Origin: http://example.test\r\n", "Transfer-Encoding: chunked\r\n", "Expect: 100-continue\r\n", "Content-Length: 2\r\n", "host: other\r\n", " folded: yes\r\n"] {
            guard case .invalid = BridgeHTTPRequest.parse(wire(headers: headers)) else { return XCTFail("Unsafe header accepted") }
        }
        for text in [String(decoding: wire(), as: UTF8.self).replacingOccurrences(of: "127.0.0.1:27124", with: "example.test:27124"),
                     String(decoding: wire(), as: UTF8.self).replacingOccurrences(of: "POST", with: "GET"),
                     String(decoding: wire(), as: UTF8.self).replacingOccurrences(of: "/v2/view", with: "/arbitrary")] {
            guard case .invalid = BridgeHTTPRequest.parse(Data(text.utf8)) else { return XCTFail("Invalid destination accepted") }
        }
    }
    func testPairingIsExplicitOneTimeExpiringAndPersistedBeforeSuccess() {
        var bridge = ObsidianBridgeSession(); var writes = 0
        let pair = request("/v1/pair", auth: code)
        func handle(_ now: Double, persist: Bool = true) -> BridgeHTTPReply {
            bridge.handle(pair, now: now, issueToken: { self.token }, persistToken: { _ in writes += 1; return persist })
        }
        XCTAssertEqual(handle(0).status, 503); XCTAssertEqual(writes, 0)
        bridge.activate(credential: nil)
        XCTAssertEqual(handle(0).status, 401)
        bridge.beginPairing(code: code, now: 10)
        XCTAssertEqual(handle(130).status, 401); XCTAssertEqual(writes, 0)
        bridge.beginPairing(code: code, now: 131)
        XCTAssertEqual(handle(132, persist: false).status, 503); XCTAssertNil(bridge.credential)
        let reply = handle(133)
        XCTAssertEqual(reply.status, 200); XCTAssertEqual(bridge.credential, token); XCTAssertNil(bridge.pairingCode)
        XCTAssertEqual(handle(134).status, 401)
        XCTAssertEqual((try? JSONSerialization.jsonObject(with: reply.body) as? [String: String])?["token"], token)
    }
    func testOnlyAuthenticatedMinimalViewPayloadsAreAccepted() {
        var bridge = paired()
        func handle(_ request: BridgeHTTPRequest) -> Int {
            bridge.handle(request, now: 1, issueToken: { "" }, persistToken: { _ in XCTFail("Unexpected persistence"); return false }).status
        }
        XCTAssertEqual(handle(request("/v2/view", auth: code, body: ["client": client, "view": "markdown"])), 401)
        for payload in [["client": client, "view": "unknown"], ["client": "bad", "view": "markdown"], ["client": client, "view": "markdown", "path": "synthetic"]] {
            XCTAssertEqual(handle(request("/v2/view", auth: token, body: payload)), 400)
        }
        for kind in ["markdown", "excalidraw", "other"] { XCTAssertEqual(handle(view(kind)), 200) }
        XCTAssertEqual(bridge.view, .other)
    }
    func testForegroundMappingsExpiryAndMissingLayersFallback() {
        var bridge = paired(); var settings = ObsidianPluginSettings(); settings.enabled = true
        var mapping = ObsidianLayerMapping(); mapping.defaultLayer = 2; mapping.excalidrawLayer = 7
        settings.devices["synthetic"] = mapping
        _ = bridge.handle(view(), now: 100, issueToken: { "" }, persistToken: { _ in false })
        func match(_ now: Double, bundle: String = "md.obsidian", available: Set<Int> = [1,2,7]) -> Int? {
            bridge.matchingLayer(settings: settings, serial: "synthetic", bundleID: bundle, available: available, now: now)
        }
        XCTAssertEqual(match(101), 2); XCTAssertNil(match(101, bundle: "example.other")); XCTAssertNil(match(116)); XCTAssertNil(match(99))
        _ = bridge.handle(view("excalidraw"), now: 110, issueToken: { "" }, persistToken: { _ in false })
        XCTAssertEqual(match(111), 7); XCTAssertNil(match(111, available: [1,2]))
        mapping.excalidrawLayer = 0; settings.devices["synthetic"] = mapping; XCTAssertEqual(match(111), 2)
        settings.enabled = false; XCTAssertNil(match(111))
        bridge.expire(now: 126); XCTAssertNil(bridge.view)
    }
    func testClearOnlyAffectsCurrentClientAndDisableRejectsCommunication() {
        var bridge = paired()
        _ = bridge.handle(view(), now: 100, issueToken: { "" }, persistToken: { _ in false })
        let unrelated = request("/v2/clear", auth: token, body: ["client": String(repeating: "d", count: 32), "focus": 1, "sequence": 99])
        _ = bridge.handle(unrelated, now: 101, issueToken: { "" }, persistToken: { _ in false }); XCTAssertNotNil(bridge.view)
        _ = bridge.handle(request("/v2/clear", auth: token, body: ["client": client, "focus": 1, "sequence": 99]), now: 102, issueToken: { "" }, persistToken: { _ in false })
        XCTAssertNil(bridge.view)
        bridge.beginPairing(code: code, now: 103); bridge.stop()
        XCTAssertFalse(bridge.enabled); XCTAssertNil(bridge.pairingCode); XCTAssertNil(bridge.credential)
        XCTAssertEqual(bridge.handle(view(), now: 104, issueToken: { "" }, persistToken: { _ in false }).status, 503)
    }
    func testSettingsRoundTripAndInvalidValues() throws {
        var settings = ObsidianPluginSettings(); XCTAssertFalse(settings.enabled); XCTAssertTrue(settings.isValid)
        settings.enabled = true; settings.credential = token
        var mapping = ObsidianLayerMapping(); mapping.defaultLayer = 2; settings.devices["synthetic"] = mapping
        XCTAssertEqual(try JSONDecoder().decode(ObsidianPluginSettings.self, from: JSONEncoder().encode(settings)), settings)
        settings.credential = "bad"; XCTAssertFalse(settings.isValid)
        settings.credential = nil; mapping.defaultLayer = 256; settings.devices["synthetic"] = mapping; XCTAssertFalse(settings.isValid)
    }
    func testMultiVaultOldPacketsAndUnloadsCannotOverrideNewOwner() {
        var bridge = paired(); let other = String(repeating: "d", count: 32)
        func handle(_ request: BridgeHTTPRequest, _ now: Double) -> Int {
            bridge.handle(request, now: now, issueToken: { "" }, persistToken: { _ in false }).status
        }
        XCTAssertEqual(handle(view(focus: 100000, sequence: 1), 100), 200)
        XCTAssertEqual(handle(view("excalidraw", client: other, focus: 101000, sequence: 1), 101), 200)
        XCTAssertEqual(handle(view(focus: 100000, sequence: 99), 102), 409)
        XCTAssertEqual(bridge.view, .excalidraw)
        XCTAssertEqual(handle(request("/v2/clear", auth: token, body: ["client": client, "focus": 100000, "sequence": 100]), 102), 200)
        XCTAssertEqual(bridge.view, .excalidraw)
        XCTAssertEqual(handle(request("/v2/clear", auth: token, body: ["client": other, "focus": 101000, "sequence": 3]), 103), 200)
        XCTAssertNil(bridge.view)
        XCTAssertEqual(handle(view(focus: 100000, sequence: 101), 104), 409)
        XCTAssertEqual(handle(view("excalidraw", client: other, focus: 101000, sequence: 2), 104), 409)
        XCTAssertEqual(handle(view(client: other, focus: 104000, sequence: 4), 104), 200)
        XCTAssertEqual(bridge.view, .markdown)
    }
    func testForegroundTransitionDiscardsOldStateAndBackgroundReports() {
        var bridge = paired()
        func handle(_ request: BridgeHTTPRequest, _ now: Double) -> Int {
            bridge.handle(request, now: now, issueToken: { "" }, persistToken: { _ in false }).status
        }
        XCTAssertEqual(handle(view(focus: 100000, sequence: 1), 100), 200)
        bridge.setForeground(false, now: 101)
        XCTAssertNil(bridge.view)
        XCTAssertEqual(handle(view(focus: 100000, sequence: 2), 102), 409)
        bridge.setForeground(true, now: 103)
        XCTAssertEqual(handle(view(focus: 100000, sequence: 3), 103), 409)
        XCTAssertEqual(handle(view("excalidraw", focus: 103000, sequence: 4), 103), 200)
    }
    func testTiedFocusAndExpiredLeaseKeepOrderingFence() {
        var bridge = paired(); let other = String(repeating: "d", count: 32)
        func handle(_ request: BridgeHTTPRequest, _ now: Double) -> Int {
            bridge.handle(request, now: now, issueToken: { "" }, persistToken: { _ in false }).status
        }
        XCTAssertEqual(handle(view(focus: 100000, sequence: 1), 100), 200)
        XCTAssertEqual(handle(view("excalidraw", client: other, focus: 100000, sequence: 1), 100), 409)
        XCTAssertEqual(handle(view("excalidraw", client: other, focus: 100001, sequence: 2), 100.001), 200)
        bridge.expire(now: 116); XCTAssertNil(bridge.view)
        XCTAssertEqual(handle(view(focus: 100000, sequence: 100), 116), 409)
        XCTAssertEqual(handle(view("excalidraw", client: other, focus: 100001, sequence: 3), 116), 200)
        XCTAssertEqual(handle(view("markdown", client: other, focus: 100001, sequence: 2), 117), 409)
        XCTAssertEqual(bridge.view, .excalidraw)
    }
    func testInvalidFocusAndSequenceMetadataRejected() {
        var bridge = paired()
        for (focus, sequence) in [(true as Any, 1 as Any), (0, 1), (1.5, 1), (1, true), (1, 0), (1, 1.5), (1, 2147483648), (103001, 1)] {
            let value = request("/v2/view", auth: token, body: ["client": client, "view": "markdown", "focus": focus, "sequence": sequence])
            XCTAssertEqual(bridge.handle(value, now: 100, issueToken: { "" }, persistToken: { _ in false }).status, 400)
        }
    }

}
