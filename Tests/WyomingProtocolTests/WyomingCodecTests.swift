import Foundation
import NIOCore
import NIOEmbedded
import XCTest
@testable import WyomingProtocol

final class WyomingCodecTests: XCTestCase {
    func testUnicodeRoundTrip() throws {
        let event = WyomingEvent(
            type: WyomingEventType.synthesize,
            data: ["text": .string("Hello, world 👋")],
            payload: Data([0, 1, 2, 255])
        )
        XCTAssertEqual(try roundTrip(event), event)
    }

    func testCombinedFrames() throws {
        var combined = ByteBufferAllocator().buffer(capacity: 256)
        try WyomingEncoder().encode(data: WyomingEvent(type: "one"), out: &combined)
        try WyomingEncoder().encode(
            data: WyomingEvent(type: "two", data: ["value": .int(2)]),
            out: &combined
        )
        let channel = EmbeddedChannel(handler: ByteToMessageHandler(WyomingDecoder()))
        _ = try channel.writeInbound(combined)
        let first: WyomingEvent? = try channel.readInbound()
        let second: WyomingEvent? = try channel.readInbound()
        XCTAssertEqual(first?.type, "one")
        XCTAssertEqual(second, WyomingEvent(type: "two", data: ["value": .int(2)]))
        XCTAssertNoThrow(try channel.finish())
    }

    func testEveryByteMayArriveSeparately() throws {
        let expected = WyomingEvent(
            type: WyomingEventType.audioChunk,
            data: ["note": .string("fragment 👋")],
            payload: Data((0..<251).map(UInt8.init))
        )
        var encoded = ByteBufferAllocator().buffer(capacity: 512)
        try WyomingEncoder().encode(data: expected, out: &encoded)
        let bytes = encoded.readBytes(length: encoded.readableBytes)!
        let channel = EmbeddedChannel(handler: ByteToMessageHandler(WyomingDecoder()))
        for byte in bytes {
            var fragment = channel.allocator.buffer(capacity: 1)
            fragment.writeInteger(byte)
            _ = try channel.writeInbound(fragment)
        }
        let actual: WyomingEvent? = try channel.readInbound()
        XCTAssertEqual(actual, expected)
        XCTAssertNoThrow(try channel.finish())
    }

    func testExactDataAndPayloadLimits() throws {
        let limits = WyomingFrameLimits(headerBytes: 1024, dataBytes: 32, payloadBytes: 64)
        let dataText = String(repeating: "a", count: 21)
        let data = try JSONEncoder().encode(["x": JSONValue.string(dataText)])
        XCTAssertEqual(data.count, 29)
        let event = WyomingEvent(
            type: "boundary",
            data: ["x": .string(dataText)],
            payload: Data(repeating: 7, count: 64)
        )
        XCTAssertEqual(try roundTrip(event, limits: limits), event)
    }

    func testRejectsOversizedHeaderWithoutNewline() throws {
        let channel = EmbeddedChannel(
            handler: ByteToMessageHandler(WyomingDecoder(
                limits: WyomingFrameLimits(headerBytes: 8, dataBytes: 32, payloadBytes: 32)
            ))
        )
        var input = channel.allocator.buffer(capacity: 9)
        input.writeString("123456789")
        XCTAssertThrowsError(try channel.writeInbound(input)) { error in
            XCTAssertEqual(error as? WyomingCodecError, .headerTooLarge(9))
        }
    }

    func testRejectsNegativeAndOversizedLengths() throws {
        try assertMalformed("{\"type\":\"x\",\"data_length\":-1}\n") { error in
            XCTAssertEqual(error as? WyomingCodecError, .invalidLength("data_length"))
        }
        try assertMalformed("{\"type\":\"x\",\"payload_length\":65}\n", payloadLimit: 64) { error in
            XCTAssertEqual(error as? WyomingCodecError, .payloadTooLarge(65))
        }
    }

    func testRejectsMalformedDataJSON() throws {
        let channel = EmbeddedChannel(handler: ByteToMessageHandler(WyomingDecoder()))
        var input = channel.allocator.buffer(capacity: 80)
        input.writeString("{\"type\":\"x\",\"data_length\":4}\nnope")
        XCTAssertThrowsError(try channel.writeInbound(input)) { error in
            guard case .malformedData = error as? WyomingCodecError else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    private func roundTrip(
        _ event: WyomingEvent,
        limits: WyomingFrameLimits = .default
    ) throws -> WyomingEvent? {
        let encoder = EmbeddedChannel(handler: MessageToByteHandler(WyomingEncoder()))
        _ = try encoder.writeOutbound(event)
        let bytes: ByteBuffer = try XCTUnwrap(encoder.readOutbound())
        XCTAssertNoThrow(try encoder.finish())

        let decoder = EmbeddedChannel(handler: ByteToMessageHandler(WyomingDecoder(limits: limits)))
        _ = try decoder.writeInbound(bytes)
        let decoded: WyomingEvent? = try decoder.readInbound()
        XCTAssertNoThrow(try decoder.finish())
        return decoded
    }

    private func assertMalformed(
        _ inputString: String,
        payloadLimit: Int = 64,
        verify: (Error) -> Void
    ) throws {
        let channel = EmbeddedChannel(
            handler: ByteToMessageHandler(WyomingDecoder(
                limits: WyomingFrameLimits(headerBytes: 1024, dataBytes: 64, payloadBytes: payloadLimit)
            ))
        )
        var input = channel.allocator.buffer(capacity: inputString.utf8.count)
        input.writeString(inputString)
        XCTAssertThrowsError(try channel.writeInbound(input)) { error in verify(error) }
    }
}
