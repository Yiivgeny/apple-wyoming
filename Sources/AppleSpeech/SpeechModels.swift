import Foundation

public enum AppleSpeechError: Error, LocalizedError, Sendable, Equatable {
    case unsupportedLanguage(String)
    case unknownVoice(String)
    case modelNotInstalled(String)
    case invalidAudioFormat(String)
    case limitExceeded(String)
    case internalFailure(String)

    public var errorDescription: String? {
        switch self {
        case let .unsupportedLanguage(language): "Unsupported language: \(language)"
        case let .unknownVoice(identifier): "Unknown Apple voice: \(identifier)"
        case let .modelNotInstalled(language): "Speech model is not installed for \(language)"
        case let .invalidAudioFormat(reason): "Invalid audio format: \(reason)"
        case let .limitExceeded(reason): "Speech limit exceeded: \(reason)"
        case let .internalFailure(reason): "Apple Speech failure: \(reason)"
        }
    }
}

public struct VoiceDescriptor: Sendable, Equatable {
    public let identifier: String
    public let name: String
    public let language: String
    public let quality: String
    public let qualityRank: Int

    public init(
        identifier: String,
        name: String,
        language: String,
        quality: String,
        qualityRank: Int
    ) {
        self.identifier = identifier
        self.name = name
        self.language = language
        self.quality = quality
        self.qualityRank = qualityRank
    }
}

public struct TTSSettings: Sendable, Equatable {
    public var rate: Float?
    public var pitch: Float?
    public var volume: Float?

    public init(rate: Float? = nil, pitch: Float? = nil, volume: Float? = nil) {
        self.rate = rate
        self.pitch = pitch
        self.volume = volume
    }
}

public enum TTSOutput: Sendable, Equatable {
    case format(sampleRate: Int)
    case pcm(Data)
}

public struct PCMInputFormat: Sendable, Equatable {
    public let sampleRate: Int
    public let channels: Int
    public let sampleWidth: Int

    public init(sampleRate: Int, channels: Int, sampleWidth: Int) {
        self.sampleRate = sampleRate
        self.channels = channels
        self.sampleWidth = sampleWidth
    }

    public func validate() throws {
        guard (8_000...48_000).contains(sampleRate) else {
            throw AppleSpeechError.invalidAudioFormat("sample rate must be 8000...48000 Hz")
        }
        guard (1...2).contains(channels) else {
            throw AppleSpeechError.invalidAudioFormat("only mono or stereo is supported")
        }
        guard sampleWidth == 2 else {
            throw AppleSpeechError.invalidAudioFormat("only signed Int16 little-endian PCM is supported")
        }
    }
}

public struct STTAssetState: Sendable, Equatable {
    public let language: String
    public let supported: Bool
    public let installed: Bool
    public let status: String

    public init(language: String, supported: Bool, installed: Bool, status: String) {
        self.language = language
        self.supported = supported
        self.installed = installed
        self.status = status
    }
}
