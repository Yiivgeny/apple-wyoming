import Foundation
import LiveKitWakeWord

public struct WakeWordDescriptor: Sendable, Equatable {
    public let name: String
    public let phrase: String
    public let language: String
    public let version: String

    public init(name: String, phrase: String, language: String, version: String) {
        self.name = name
        self.phrase = phrase
        self.language = language
        self.version = version
    }
}

public struct WakeWordDetection: Sendable, Equatable {
    public let name: String
    public let confidence: Float
    public let timestampMilliseconds: Int

    public init(name: String, confidence: Float, timestampMilliseconds: Int) {
        self.name = name
        self.confidence = confidence
        self.timestampMilliseconds = timestampMilliseconds
    }
}

public enum WakeWordError: Error, LocalizedError, Sendable, Equatable {
    case invalidConfiguration(String)
    case invalidAudio(String)
    case modelResourceMissing(String)
    case inferenceFailure(String)

    public var errorDescription: String? {
        switch self {
        case let .invalidConfiguration(reason): "Invalid wake word configuration: \(reason)"
        case let .invalidAudio(reason): "Invalid wake word audio: \(reason)"
        case let .modelResourceMissing(name): "Wake word model resource is missing: \(name)"
        case let .inferenceFailure(reason): "Wake word inference failed: \(reason)"
        }
    }
}

/// Process-wide openWakeWord feature pipeline and classifier.
///
/// LiveKitWakeWord documents that calls on one model must not overlap. Keeping
/// the model inside an actor both reuses the CoreML/ORT sessions and serializes
/// inference across Wyoming connections.
public actor WakeWordEngine {
    public static let descriptors = [
        WakeWordDescriptor(
            name: "okay_nabu",
            phrase: "Okay Nabu",
            language: "en",
            version: "v0.1"
        ),
        WakeWordDescriptor(
            name: "hey_jarvis",
            phrase: "Hey Jarvis",
            language: "en",
            version: "v0.1"
        ),
    ]
    public static let modelNames = descriptors.map(\.name)
    public static let sampleRate = 16_000

    private let model: WakeWordModel

    public init(executionProvider: ExecutionProvider = .coreML) throws {
        let modelURLs = try Self.descriptors.map { descriptor in
            guard let modelURL = Bundle.module.url(
                forResource: descriptor.name,
                withExtension: "onnx"
            ) else {
                throw WakeWordError.modelResourceMissing("\(descriptor.name).onnx")
            }
            return modelURL
        }

        do {
            model = try WakeWordModel(
                models: modelURLs,
                sampleRate: UInt32(Self.sampleRate),
                executionProvider: executionProvider
            )
        } catch {
            throw WakeWordError.inferenceFailure(error.localizedDescription)
        }
    }

    /// Forces CoreML/ORT graph creation before the first Wyoming request.
    public func prewarm() throws {
        let modelScores = try scores(
            Array(repeating: 0, count: WakeWordDetectionSession.windowSamples)
        )
        let missingNames = Self.modelNames.filter { modelScores[$0] == nil }
        guard missingNames.isEmpty else {
            throw WakeWordError.inferenceFailure(
                "classifier scores missing for: \(missingNames.joined(separator: ", "))"
            )
        }
    }

    fileprivate func scores(_ samples: [Int16]) throws -> [String: Float] {
        do {
            return try model.predict(samples)
        } catch {
            throw WakeWordError.inferenceFailure(error.localizedDescription)
        }
    }
}

/// Streaming request state over a shared ``WakeWordEngine``.
///
/// Wyoming normally sends 16 kHz mono S16LE in small chunks. The detector
/// evaluates the trailing two-second window every 80 ms, matching the cadence
/// used by openWakeWord, and reports at most one detection per request.
public actor WakeWordDetectionSession {
    public static let windowSamples = WakeWordEngine.sampleRate * 2
    public static let hopSamples = WakeWordEngine.sampleRate * 80 / 1_000

    private let threshold: Float
    private let triggerLevel: Int
    private let modelNames: [String]
    private let scorer: @Sendable ([Int16]) async throws -> [String: Float]
    private var window: [Int16] = []
    private var samplesUntilPrediction = hopSamples
    private var totalSamples = 0
    private var triggersSeen: [String: Int] = [:]
    private var detected = false

    public init(
        engine: WakeWordEngine,
        modelNames: Set<String>? = nil,
        threshold: Float = 0.5,
        triggerLevel: Int = 1
    ) throws {
        let selectedNames = try Self.validate(
            modelNames: modelNames,
            threshold: threshold,
            triggerLevel: triggerLevel
        )
        self.threshold = threshold
        self.triggerLevel = triggerLevel
        self.modelNames = selectedNames
        scorer = { samples in try await engine.scores(samples) }
        window.reserveCapacity(Self.windowSamples)
    }

    init(
        threshold: Float,
        triggerLevel: Int,
        modelNames: Set<String>? = nil,
        scorer: @escaping @Sendable ([Int16]) async throws -> [String: Float]
    ) throws {
        let selectedNames = try Self.validate(
            modelNames: modelNames,
            threshold: threshold,
            triggerLevel: triggerLevel
        )
        self.threshold = threshold
        self.triggerLevel = triggerLevel
        self.modelNames = selectedNames
        self.scorer = scorer
        window.reserveCapacity(Self.windowSamples)
    }

    private static func validate(
        modelNames: Set<String>?,
        threshold: Float,
        triggerLevel: Int
    ) throws -> [String] {
        guard (0...1).contains(threshold) else {
            throw WakeWordError.invalidConfiguration("threshold must be between 0 and 1")
        }
        guard triggerLevel > 0 else {
            throw WakeWordError.invalidConfiguration("trigger level must be positive")
        }
        guard let modelNames, !modelNames.isEmpty else {
            return WakeWordEngine.modelNames
        }
        let availableNames = Set(WakeWordEngine.modelNames)
        let unknownNames = modelNames.subtracting(availableNames)
        guard unknownNames.isEmpty else {
            throw WakeWordError.invalidConfiguration(
                "unsupported wake word model(s): \(unknownNames.sorted().joined(separator: ", "))"
            )
        }
        return WakeWordEngine.modelNames.filter(modelNames.contains)
    }

    public func accept(_ pcm: Data) async throws -> WakeWordDetection? {
        guard !pcm.isEmpty else { throw WakeWordError.invalidAudio("audio chunk is empty") }
        guard pcm.count.isMultiple(of: MemoryLayout<Int16>.size) else {
            throw WakeWordError.invalidAudio("S16LE payload has an odd byte count")
        }

        let samples = Self.decodeS16LE(pcm)
        var offset = 0
        while offset < samples.count {
            let count = min(samplesUntilPrediction, samples.count - offset)
            window.append(contentsOf: samples[offset..<(offset + count)])
            if window.count > Self.windowSamples {
                window.removeFirst(window.count - Self.windowSamples)
            }
            totalSamples += count
            samplesUntilPrediction -= count
            offset += count

            guard samplesUntilPrediction == 0 else { continue }
            samplesUntilPrediction = Self.hopSamples
            guard !detected, window.count == Self.windowSamples else { continue }

            let scores = try await scorer(window)
            var winner: (name: String, confidence: Float)?
            for name in modelNames {
                guard let confidence = scores[name], confidence > threshold else { continue }
                triggersSeen[name, default: 0] += 1
                guard triggersSeen[name, default: 0] >= triggerLevel else { continue }
                if let currentWinner = winner, currentWinner.confidence >= confidence {
                    continue
                }
                winner = (name, confidence)
            }
            guard let winner else { continue }

            detected = true
            return WakeWordDetection(
                name: winner.name,
                confidence: winner.confidence,
                timestampMilliseconds: totalSamples * 1_000 / WakeWordEngine.sampleRate
            )
        }
        return nil
    }

    public func hasDetected() -> Bool { detected }

    private static func decodeS16LE(_ data: Data) -> [Int16] {
        data.withUnsafeBytes { rawBytes in
            let bytes = rawBytes.bindMemory(to: UInt8.self)
            var samples = [Int16]()
            samples.reserveCapacity(bytes.count / 2)
            for index in stride(from: 0, to: bytes.count, by: 2) {
                let value = UInt16(bytes[index]) | (UInt16(bytes[index + 1]) << 8)
                samples.append(Int16(bitPattern: value))
            }
            return samples
        }
    }
}
