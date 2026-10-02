import Foundation
import XCTest
import BoardCore

final class RotatingLogTests: XCTestCase {
    func testRotationRetainsNewestFiveFilesAcrossWriters() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("app.log")
        for index in 0..<12 {
            // No in-memory size or generation state; reopening keeps the same bound.
            try RotatingLog.append(Data(String(repeating: String(index % 10), count: 8).utf8), to: url, limit: 8)
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path).count, 5)
        for index in 0..<5 {
            let file = index == 0 ? url : URL(fileURLWithPath: url.path + ".\(index)")
            XCTAssertEqual(try Data(contentsOf: file), Data(String(repeating: String((11 - index) % 10), count: 8).utf8))
        }
    }
    func testOversizedRecordCannotExceedLimitOrDestroyExistingLog() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        try RotatingLog.append(Data("kept".utf8), to: url, limit: 8)
        try RotatingLog.append(Data(repeating: 0, count: 9), to: url, limit: 8)
        XCTAssertEqual(try Data(contentsOf: url), Data("kept".utf8))
    }
    func testWriteFailureIsReportedToCaller() {
        let missingParent = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("app.log")
        XCTAssertThrowsError(try RotatingLog.append(Data("entry".utf8), to: missingParent, limit: 8))
    }
}
