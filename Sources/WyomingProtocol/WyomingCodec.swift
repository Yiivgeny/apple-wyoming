import Foundation
import NIOCore
import NIOFoundationCompat

public struct WyomingFrameLimits: Sendable, Equatable {
    public var headerBytes: Int
    public var dataBytes: Int
    public var payloadBytes: Int

    public init(
        headerBytes: Int = 64 * 1024,
        dataBytes: Int = 1024 * 1024,
        payloadBytes: Int = 4 * 1024 * 1024
    ) {
        self.headerBytes = headerBytes
        self.dataBytes = dataBytes
        self.payloadBytes = payloadBytes
    }

    public static let `default` = WyomingFrameLimits()
}

public enum WyomingCodecError: Error, LocalizedError, Equatable {
    case headerTooLarge(Int)
    case dataTooLarge(Int)
    case payloadTooLarge(Int)
    case malformedHeader(String)
    case malformedData(String)
    case invalidLength(String)

    public var errorDescription: String? {
        switch self {
        case let .headerTooLarge(size): "Wyoming header exceeds limit (\(size) bytes)"
        case let .dataTooLarge(size): "Wyoming data exceeds limit (\(size) bytes)"
        case let .payloadTooLarge(size): "Wyoming payload exceeds limit (\(size) bytes)"
        case let .malformedHeader(reason): "Malformed Wyoming header: \(reason)"
        case let .malformedData(reason): "Malformed Wyoming data: \(reason)"
        case let .invalidLength(name): "Invalid Wyoming \(name)"
        }
    }
}

private struct WireHeader: Codable {
    let type: String
    let version: String?
    let dataLength: Int?
    let payloadLength: Int?

    enum CodingKeys: String, CodingKey {
        case type
        case version
        case dataLength = "data_length"
        case payloadLength = "payload_length"
    }
}

public struct WyomingDecoder: ByteToMessageDecoder {
    public typealias InboundOut = WyomingEvent

    private enum State {
        case header
        case body(type: String, dataLength: Int, payloadLength: Int)
    }

    private var state: State = .header
    private let limits: WyomingFrameLimits
    private let decoder = JSONDecoder()

    public init(limits: WyomingFrameLimits = .default) {
        self.limits = limits
    }

    public mutating func decode(
        context: ChannelHandlerContext,
        buffer: inout ByteBuffer
    ) throws -> DecodingState {
        switch state {
        case .header:
            let view = buffer.readableBytesView
            guard let newlineIndex = view.firstIndex(of: 0x0A) else {
                if buffer.readableBytes > limits.headerBytes {
                    throw WyomingCodecError.headerTooLarge(buffer.readableBytes)
                }
                return .needMoreData
            }

            let headerLength = view.distance(from: view.startIndex, to: newlineIndex)
            guard headerLength <= limits.headerBytes else {
                throw WyomingCodecError.headerTooLarge(headerLength)
            }
            guard var headerString = buffer.readString(length: headerLength) else {
                return .needMoreData
            }
            buffer.moveReaderIndex(forwardBy: 1)
            if headerString.last == "\r" { headerString.removeLast() }

            let header: WireHeader
            do {
                header = try decoder.decode(WireHeader.self, from: Data(headerString.utf8))
            } catch {
                throw WyomingCodecError.malformedHeader(error.localizedDescription)
            }
            guard !header.type.isEmpty else {
                throw WyomingCodecError.malformedHeader("missing event type")
            }

            let dataLength = header.dataLength ?? 0
            let payloadLength = header.payloadLength ?? 0
            guard dataLength >= 0 else { throw WyomingCodecError.invalidLength("data_length") }
            guard payloadLength >= 0 else { throw WyomingCodecError.invalidLength("payload_length") }
            guard dataLength <= limits.dataBytes else {
                throw WyomingCodecError.dataTooLarge(dataLength)
            }
            guard payloadLength <= limits.payloadBytes else {
                throw WyomingCodecError.payloadTooLarge(payloadLength)
            }

            state = .body(
                type: header.type,
                dataLength: dataLength,
                payloadLength: payloadLength
            )
            return try decode(context: context, buffer: &buffer)

        case let .body(type, dataLength, payloadLength):
            let totalLength = dataLength + payloadLength
            guard buffer.readableBytes >= totalLength else { return .needMoreData }

            let eventData: [String: JSONValue]
            if dataLength == 0 {
                eventData = [:]
            } else {
                guard let bytes = buffer.readData(length: dataLength) else {
                    return .needMoreData
                }
                do {
                    eventData = try decoder.decode([String: JSONValue].self, from: bytes)
                } catch {
                    throw WyomingCodecError.malformedData(error.localizedDescription)
                }
            }

            let payload = payloadLength > 0 ? buffer.readData(length: payloadLength) : nil
            state = .header
            context.fireChannelRead(wrapInboundOut(WyomingEvent(
                type: type,
                data: eventData,
                payload: payload
            )))
            return .continue
        }
    }

    public mutating func decodeLast(
        context: ChannelHandlerContext,
        buffer: inout ByteBuffer,
        seenEOF: Bool
    ) throws -> DecodingState {
        let result = try decode(context: context, buffer: &buffer)
        if seenEOF, buffer.readableBytes > 0 {
            throw WyomingCodecError.malformedHeader("connection ended inside a frame")
        }
        return result
    }
}

public struct WyomingEncoder: MessageToByteEncoder {
    public typealias OutboundIn = WyomingEvent

    private let encoder: JSONEncoder

    public init() {
        encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    }

    public func encode(data event: WyomingEvent, out: inout ByteBuffer) throws {
        let encodedData = event.data.isEmpty ? nil : try encoder.encode(event.data)
        let payload = event.payload.flatMap { $0.isEmpty ? nil : $0 }
        let header = WireHeader(
            type: event.type,
            version: "1.0",
            dataLength: encodedData?.count,
            payloadLength: payload?.count
        )
        out.writeData(try encoder.encode(header))
        out.writeInteger(UInt8(ascii: "\n"))
        if let encodedData { out.writeData(encodedData) }
        if let payload { out.writeData(payload) }
    }
}
