import AppleSpeech
import Foundation
import WyomingProtocol

public struct ServerConfiguration: Sendable, Equatable {
    public var host = "0.0.0.0"
    public var port = 10_700
    public var language = "ru-RU"
    public var defaultVoice: String?
    public var ttsSettings = TTSSettings()
    public var maxConnections = 16
    public var maxTTSSessions = 2
    public var maxSTTSessions = 1
    public var wakeThreshold: Float = 0.5
    public var wakeTriggerLevel = 1
    public var idleTimeoutSeconds = 120
    public var publishBonjour = true
    public var logAudioChunks = false

    public init() {}
}

enum EventLoggingPolicy {
    static func shouldSendToLogger(eventType: String, logAudioChunks: Bool) -> Bool {
        eventType != WyomingEventType.audioChunk || logAudioChunks
    }
}

public actor SlotLimiter {
    private let limit: Int
    private var active = 0

    public init(limit: Int) {
        self.limit = max(1, limit)
    }

    public func acquire() -> Bool {
        guard active < limit else { return false }
        active += 1
        return true
    }

    public func release() {
        active = max(0, active - 1)
    }
}

public enum StreamingTextSegmenter {
    private static let punctuation = CharacterSet(charactersIn: ".?!;:\n")

    public static func takeSegments(from text: inout String, force: Bool = false) -> [String] {
        var segments: [String] = []
        while !text.isEmpty {
            if let boundary = punctuationBoundary(in: text) {
                appendPrefix(through: boundary, from: &text, into: &segments)
                continue
            }
            if text.count > 240, let boundary = whitespaceBoundary(in: text) {
                appendPrefix(through: boundary, from: &text, into: &segments)
                continue
            }
            break
        }
        if force {
            let remainder = text.trimmingCharacters(in: .whitespacesAndNewlines)
            text.removeAll(keepingCapacity: true)
            if !remainder.isEmpty { segments.append(remainder) }
        }
        return segments
    }

    private static func punctuationBoundary(in text: String) -> String.Index? {
        text.indices.first { index in
            let scalar = text[index].unicodeScalars.first!
            return punctuation.contains(scalar)
        }
    }

    private static func whitespaceBoundary(in text: String) -> String.Index? {
        let threshold = text.index(text.startIndex, offsetBy: 240)
        return text.indices.last { index in
            index <= threshold && text[index].isWhitespace
        }
    }

    private static func appendPrefix(
        through boundary: String.Index,
        from text: inout String,
        into segments: inout [String]
    ) {
        let end = text.index(after: boundary)
        let segment = text[..<end].trimmingCharacters(in: .whitespacesAndNewlines)
        text.removeSubrange(..<end)
        while text.first?.isWhitespace == true { text.removeFirst() }
        if !segment.isEmpty { segments.append(segment) }
    }
}
