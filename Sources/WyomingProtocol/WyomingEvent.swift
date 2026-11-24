import Foundation

public struct WyomingEvent: Sendable, Equatable {
    public var type: String
    public var data: [String: JSONValue]
    public var payload: Data?

    public init(
        type: String,
        data: [String: JSONValue] = [:],
        payload: Data? = nil
    ) {
        self.type = type
        self.data = data
        self.payload = payload
    }

    public subscript(key: String) -> JSONValue? {
        get { data[key] }
        set { data[key] = newValue }
    }

    public func string(_ key: String) -> String? { data[key]?.stringValue }
    public func int(_ key: String) -> Int? { data[key]?.intValue }
    public func bool(_ key: String) -> Bool? { data[key]?.boolValue }
}

public enum WyomingEventType {
    public static let describe = "describe"
    public static let info = "info"
    public static let ping = "ping"
    public static let pong = "pong"
    public static let error = "error"

    public static let synthesize = "synthesize"
    public static let synthesizeStart = "synthesize-start"
    public static let synthesizeChunk = "synthesize-chunk"
    public static let synthesizeStop = "synthesize-stop"
    public static let synthesizeStopped = "synthesize-stopped"

    public static let transcribe = "transcribe"
    public static let transcript = "transcript"
    public static let transcriptStart = "transcript-start"
    public static let transcriptChunk = "transcript-chunk"
    public static let transcriptStop = "transcript-stop"

    public static let detect = "detect"
    public static let detection = "detection"
    public static let notDetected = "not-detected"

    public static let audioStart = "audio-start"
    public static let audioChunk = "audio-chunk"
    public static let audioStop = "audio-stop"
}

public enum WyomingErrorCode: String, Sendable {
    case invalidEvent = "invalid-event"
    case invalidAudioFormat = "invalid-audio-format"
    case unsupportedLanguage = "unsupported-language"
    case unknownVoice = "unknown-voice"
    case modelNotInstalled = "model-not-installed"
    case busy
    case limitExceeded = "limit-exceeded"
    case internalError = "internal-error"
}

public extension WyomingEvent {
    static func error(_ code: WyomingErrorCode, message: String) -> WyomingEvent {
        WyomingEvent(type: WyomingEventType.error, data: [
            "code": .string(code.rawValue),
            "text": .string(message),
        ])
    }

    static func audioStart(rate: Int, width: Int = 2, channels: Int = 1) -> WyomingEvent {
        WyomingEvent(type: WyomingEventType.audioStart, data: [
            "rate": .int(rate),
            "width": .int(width),
            "channels": .int(channels),
        ])
    }

    static func audioChunk(
        _ pcm: Data,
        rate: Int? = nil,
        width: Int = 2,
        channels: Int = 1
    ) -> WyomingEvent {
        var data: [String: JSONValue] = [:]
        if let rate {
            data = [
                "rate": .int(rate),
                "width": .int(width),
                "channels": .int(channels),
            ]
        }
        return WyomingEvent(type: WyomingEventType.audioChunk, data: data, payload: pcm)
    }

    static var audioStop: WyomingEvent { WyomingEvent(type: WyomingEventType.audioStop) }

    static func detection(
        name: String,
        timestampMilliseconds: Int,
        context: JSONValue? = nil
    ) -> WyomingEvent {
        var data: [String: JSONValue] = [
            "name": .string(name),
            "timestamp": .int(timestampMilliseconds),
            "speaker": .null,
        ]
        if let context { data["context"] = context }
        return WyomingEvent(type: WyomingEventType.detection, data: data)
    }

    static func notDetected(context: JSONValue? = nil) -> WyomingEvent {
        var data: [String: JSONValue] = [:]
        if let context { data["context"] = context }
        return WyomingEvent(type: WyomingEventType.notDetected, data: data)
    }
}
