import Foundation
import XCTest
import BoardCore

final class FirmwareHistoryTests: XCTestCase {
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
    private func attempt(_ root: URL, draftHandled: Bool = true, backup: Bool = false) throws -> URL {
        let url = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: ["serial": "device", "stage": "failed", "draftHandled": draftHandled])
        try data.write(to: url.appendingPathComponent("record.json"))
        try Data("draft".utf8).write(to: url.appendingPathComponent("app-draft.json"))
        try Data("log".utf8).write(to: url.appendingPathComponent("update.log"))
        if backup { try Data([1]).write(to: url.appendingPathComponent("device-nvs.bin")) }
        return url
    }
    func testKeepsThreeHistoricalAttemptsPlusCurrent() throws {
        let root = try directory()
        for _ in 0..<6 { _ = try attempt(root) }
        let current = try attempt(root)
        try FirmwareHistory.prune(root: root, current: current)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path).count, 4)
        XCTAssertTrue(FileManager.default.fileExists(atPath: current.path))
    }
    func testProtectsDraftAndRecoveryEvenOutsideRetention() throws {
        let root = try directory()
        let draft = try attempt(root, draftHandled: false)
        let backup = try attempt(root, backup: true)
        let removable = try attempt(root)
        try FirmwareHistory.prune(root: root, current: nil, keep: 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: draft.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: backup.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: removable.path))
    }
    func testPreservesUnknownFilesLegacyAndSymlinkTargets() throws {
        let root = try directory()
        let unknown = try attempt(root)
        try Data([1]).write(to: unknown.appendingPathComponent("unexpected.bin"))
        let legacy = try attempt(root)
        try FileManager.default.removeItem(at: legacy.appendingPathComponent("record.json"))
        let outside = try directory()
        let link = root.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        let nested = try attempt(root)
        try FileManager.default.removeItem(at: nested.appendingPathComponent("update.log"))
        try FileManager.default.createSymbolicLink(at: nested.appendingPathComponent("update.log"), withDestinationURL: outside)
        try FirmwareHistory.prune(root: root, current: nil, keep: 0)
        for url in [unknown, legacy, outside, link, nested] {
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        }
    }
}
