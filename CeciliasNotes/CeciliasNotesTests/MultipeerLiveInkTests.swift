import CryptoKit
import XCTest
@testable import CeciliasNotes

/// Transport-level coverage for the `"live-ink"` message (protocol
/// v2.4): payload framing round-trips, HMAC rejects tampering, and
/// the binary body layout survives odd sizes. The ephemeral overlay
/// semantics (never persisted, superseded by the durable drawing)
/// live in the canvas coordinator and need two devices — these tests
/// pin the wire format so both ends keep agreeing on it.
final class MultipeerLiveInkTests: XCTestCase {

    private let key = SymmetricKey(size: .bits256)

    /// Mirror of both receive lanes' envelope parsing:
    /// `[4B BE header len][header JSON][32B HMAC][body]`.
    private func unpack(_ payload: Data) -> (header: [String: Any], hmac: Data, body: Data)? {
        guard payload.count > 4 + 32 else { return nil }
        let headerLen = Int(UInt32(bigEndian: payload.prefix(4).withUnsafeBytes { $0.load(as: UInt32.self) }))
        guard payload.count >= 4 + headerLen + 32 else { return nil }
        let headerData = payload.subdata(in: 4..<(4 + headerLen))
        let hmac = payload.subdata(in: (4 + headerLen)..<(4 + headerLen + 32))
        let body = payload.subdata(in: (4 + headerLen + 32)..<payload.count)
        guard let header = (try? JSONSerialization.jsonObject(with: headerData)) as? [String: Any]
        else { return nil }
        return (header, hmac, body)
    }

    private func verify(_ payload: Data, key: SymmetricKey) -> Bool {
        guard let unpacked = unpack(payload) else { return false }
        let headerLen = Int(UInt32(bigEndian: payload.prefix(4).withUnsafeBytes { $0.load(as: UInt32.self) }))
        let headerData = payload.subdata(in: 4..<(4 + headerLen))
        let computed = Data(HMAC<SHA256>.authenticationCode(for: headerData + unpacked.body, using: key))
        return computed == unpacked.hmac
    }

    func test_roundTrip_preservesAllFields() throws {
        let notebookId = UUID()
        let pageId = UUID()
        let drawing = Data((0..<1024).map { UInt8($0 % 251) })
        let payload = try XCTUnwrap(MultipeerLiveInk.buildPayload(
            notebookId: notebookId, pageId: pageId,
            seq: 42, drawingData: drawing, key: key
        ))

        let unpacked = try XCTUnwrap(unpack(payload))
        XCTAssertEqual(unpacked.header["type"] as? String, "live-ink")
        XCTAssertNotNil(unpacked.header["nonce"] as? String)
        XCTAssertNotNil(unpacked.header["timestamp"] as? Int)
        XCTAssertTrue(verify(payload, key: key), "HMAC must verify with the signing key")

        let parsed = try XCTUnwrap(MultipeerLiveInk.parseBody(unpacked.body))
        XCTAssertEqual(parsed.notebookId, notebookId)
        XCTAssertEqual(parsed.pageId, pageId)
        XCTAssertEqual(parsed.seq, 42)
        XCTAssertEqual(parsed.drawingData, drawing)
    }

    func test_tamperedBody_failsHMAC() throws {
        let payload = try XCTUnwrap(MultipeerLiveInk.buildPayload(
            notebookId: UUID(), pageId: UUID(),
            seq: 1, drawingData: Data([1, 2, 3]), key: key
        ))
        var tampered = payload
        tampered[tampered.count - 1] ^= 0xFF
        XCTAssertFalse(verify(tampered, key: key),
                       "Flipping a body byte must break the HMAC")
    }

    func test_wrongKey_failsHMAC() throws {
        let payload = try XCTUnwrap(MultipeerLiveInk.buildPayload(
            notebookId: UUID(), pageId: UUID(),
            seq: 1, drawingData: Data([1, 2, 3]), key: key
        ))
        XCTAssertFalse(verify(payload, key: SymmetricKey(size: .bits256)),
                       "A different pairing key must not verify")
    }

    func test_parseBody_rejectsTruncated() {
        XCTAssertNil(MultipeerLiveInk.parseBody(Data()))
        XCTAssertNil(MultipeerLiveInk.parseBody(Data(repeating: 0, count: 39)),
                     "Body shorter than the 40-byte fixed prelude is malformed")
    }

    func test_parseBody_emptyDrawingIsValid() throws {
        // A page cleared to zero strokes still streams (the receiver
        // clears its overlay) — 40 bytes exactly, no drawing payload.
        let payload = try XCTUnwrap(MultipeerLiveInk.buildPayload(
            notebookId: UUID(), pageId: UUID(),
            seq: 7, drawingData: Data(), key: key
        ))
        let unpacked = try XCTUnwrap(unpack(payload))
        let parsed = try XCTUnwrap(MultipeerLiveInk.parseBody(unpacked.body))
        XCTAssertEqual(parsed.seq, 7)
        XCTAssertTrue(parsed.drawingData.isEmpty)
    }

    func test_seq_bigEndianOrdering() throws {
        // Guard the byte order — a LE/BE mismatch between devices
        // would silently drop every "newer" snapshot on one side.
        let payload = try XCTUnwrap(MultipeerLiveInk.buildPayload(
            notebookId: UUID(), pageId: UUID(),
            seq: 0x0102_0304_0506_0708, drawingData: Data(), key: key
        ))
        let unpacked = try XCTUnwrap(unpack(payload))
        let parsed = try XCTUnwrap(MultipeerLiveInk.parseBody(unpacked.body))
        XCTAssertEqual(parsed.seq, 0x0102_0304_0506_0708)
        XCTAssertEqual([UInt8](unpacked.body[32..<40]),
                       [1, 2, 3, 4, 5, 6, 7, 8])
    }
}
