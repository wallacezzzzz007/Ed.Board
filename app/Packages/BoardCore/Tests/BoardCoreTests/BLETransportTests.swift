import XCTest
@testable import BoardCore

final class BLETransportTests: XCTestCase {
    func testLegacyPreferenceDecodesWithoutBluetooth() throws {
        let old = Data(#"{"serial":"CM3-test","automatic":true}"#.utf8)
        let value = try JSONDecoder().decode(ConnectionPreference.self, from: old)
        XCTAssertNil(value.bluetooth)
        XCTAssertTrue(value.automatic)
    }
    func testBluetoothPreferenceRoundTrip() throws {
        let value = ConnectionPreference(serial: "CM3-test", automatic: true, bluetooth: true)
        XCTAssertEqual(try JSONDecoder().decode(ConnectionPreference.self, from: JSONEncoder().encode(value)), value)
    }
    func testFragmentedUnicodeFrameRoundTripAtMinimumMTU() {
        let data = Data(("@edboard " + String(repeating: "中文🌟", count: 800) + "\n").utf8)
        var queue = BLEWriteBuffer(), framer = LineFramer()
        XCTAssertTrue(queue.enqueue(data))
        var lines = [String]()
        while !queue.isEmpty {
            guard let chunk = queue.next(maximum: 20) else { return XCTFail("missing chunk") }
            XCTAssertLessThanOrEqual(chunk.count, 20)
            XCTAssertNil(queue.next(maximum: 20)) // Wait for ATT acknowledgement.
            lines += framer.feed(chunk); queue.acknowledge()
        }
        XCTAssertEqual(lines, [String(decoding: data.dropLast(), as: UTF8.self)])
        XCTAssertEqual(framer.droppedLines, 0)
    }
    func testNextRequestBeforeFinalAckPreservesOrderingAndBounds() {
        var queue = BLEWriteBuffer()
        XCTAssertTrue(queue.enqueue(Data([1, 2])))
        XCTAssertEqual(queue.next(maximum: 128), Data([1, 2]))
        XCTAssertTrue(queue.enqueue(Data([3, 4])))
        XCTAssertFalse(queue.enqueue(Data([5])))
        XCTAssertNil(queue.next(maximum: 128))
        queue.acknowledge()
        XCTAssertEqual(queue.next(maximum: 128), Data([3, 4]))
        queue.acknowledge(); XCTAssertTrue(queue.isEmpty)
        XCTAssertFalse(queue.enqueue(Data(repeating: 0, count: 12290)))
    }
    func testExplicitRejectionRetriesOnlyUnacceptedChunk() {
        var queue = BLEWriteBuffer()
        XCTAssertTrue(queue.enqueue(Data([1, 2, 3, 4, 5])))
        XCTAssertEqual(queue.next(maximum: 2), Data([1, 2]))
        queue.acknowledge()
        XCTAssertEqual(queue.next(maximum: 2), Data([3, 4]))
        XCTAssertTrue(queue.rejectUnacceptedChunk())
        XCTAssertFalse(queue.rejectUnacceptedChunk())
        XCTAssertTrue(queue.enqueue(Data([6, 7])))
        XCTAssertEqual(queue.next(maximum: 2), Data([3, 4]))
        XCTAssertNil(queue.next(maximum: 2))
        queue.acknowledge()
        XCTAssertEqual(queue.next(maximum: 2), Data([5]))
        queue.acknowledge()
        XCTAssertEqual(queue.next(maximum: 2), Data([6, 7]))
        queue.acknowledge()
        XCTAssertTrue(queue.isEmpty)
    }
    func testResourceRetriesAreShortAndBounded() {
        XCTAssertEqual((0..<5).compactMap { BLEWriteBuffer.resourceRetryDelay(attempt: $0) }, [0.05, 0.1, 0.2, 0.4, 0.8])
        XCTAssertNil(BLEWriteBuffer.resourceRetryDelay(attempt: 5))
        XCTAssertNil(BLEWriteBuffer.resourceRetryDelay(attempt: -1))
    }

}
