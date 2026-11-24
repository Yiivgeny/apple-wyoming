@preconcurrency import AVFoundation
import Foundation

public final class VoiceRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var cachedVoices: [VoiceDescriptor] = []
    private var observer: NSObjectProtocol?

    public init(observeChanges: Bool = true) {
        refresh()
        if observeChanges {
            observer = NotificationCenter.default.addObserver(
                forName: AVSpeechSynthesizer.availableVoicesDidChangeNotification,
                object: nil,
                queue: nil
            ) { [weak self] _ in
                self?.refresh()
            }
        }
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    public func refresh() {
        let voices = AVSpeechSynthesisVoice.speechVoices()
            .filter { Locale(identifier: $0.language).language.languageCode?.identifier == "ru" }
            .map(Self.describe)
            .sorted {
                if $0.qualityRank != $1.qualityRank { return $0.qualityRank > $1.qualityRank }
                return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
        lock.withLock { cachedVoices = voices }
    }

    public func russianVoices() -> [VoiceDescriptor] {
        lock.withLock { cachedVoices }
    }

    public func resolve(identifier: String?) throws -> VoiceDescriptor {
        let voices = russianVoices()
        if let identifier, !identifier.isEmpty {
            guard let voice = voices.first(where: { $0.identifier == identifier }) else {
                throw AppleSpeechError.unknownVoice(identifier)
            }
            return voice
        }
        guard let best = Self.preferredDefault(in: voices) else {
            throw AppleSpeechError.unknownVoice("No installed Russian voice")
        }
        return best
    }

    public static func preferredDefault(in voices: [VoiceDescriptor]) -> VoiceDescriptor? {
        let milena = voices
            .filter {
                $0.name.localizedCaseInsensitiveContains("milena")
                    || $0.identifier.localizedCaseInsensitiveContains("milena")
            }
            .max(by: { $0.qualityRank < $1.qualityRank })
        return milena ?? voices.max(by: { $0.qualityRank < $1.qualityRank })
    }

    private static func describe(_ voice: AVSpeechSynthesisVoice) -> VoiceDescriptor {
        let quality: String
        switch voice.quality {
        case .premium: quality = "premium"
        case .enhanced: quality = "enhanced"
        default: quality = "default"
        }
        return VoiceDescriptor(
            identifier: voice.identifier,
            name: voice.name,
            language: voice.language,
            quality: quality,
            qualityRank: voice.quality.rawValue
        )
    }
}

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
