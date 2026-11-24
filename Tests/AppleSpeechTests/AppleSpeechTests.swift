import Foundation
import XCTest
@testable import AppleSpeech

final class AppleSpeechTests: XCTestCase {
    func testEnhancedMilenaWinsWhenItAppears() {
        let compact = VoiceDescriptor(
            identifier: "compact.milena",
            name: "Milena",
            language: "ru-RU",
            quality: "default",
            qualityRank: 1
        )
        let enhanced = VoiceDescriptor(
            identifier: "enhanced.milena",
            name: "Milena",
            language: "ru-RU",
            quality: "enhanced",
            qualityRank: 2
        )
        XCTAssertEqual(
            VoiceRegistry.preferredDefault(in: [compact, enhanced])?.identifier,
            enhanced.identifier
        )
    }

    func testTTSProducesInMemoryInt16PCM() async throws {
        let voices = VoiceRegistry(observeChanges: false)
        let voice = try voices.resolve(identifier: nil)
        let stream = try await AppleTTSEngine(voices: voices).stream(
            text: "Testing local speech synthesis.",
            voiceIdentifier: voice.identifier
        )
        var rate: Int?
        var pcm = Data()
        for try await output in stream {
            switch output {
            case let .format(value): rate = value
            case let .pcm(data): pcm.append(data)
            }
        }
        XCTAssertNotNil(rate)
        XCTAssertFalse(pcm.isEmpty)
        XCTAssertEqual(pcm.count % MemoryLayout<Int16>.size, 0)
    }

    func testPrewarmedTTSPoolSupportsConcurrentReuse() async throws {
        let voices = VoiceRegistry(observeChanges: false)
        let voice = try voices.resolve(identifier: nil)
        let engine = AppleTTSEngine(voices: voices, poolSize: 2)
        try await engine.prewarm(voiceIdentifier: voice.identifier)

        async let first = Self.render(
            engine: engine,
            text: "First concurrent synthesis.",
            voice: voice.identifier
        )
        async let second = Self.render(
            engine: engine,
            text: "Second concurrent synthesis.",
            voice: voice.identifier
        )
        let concurrent = try await (first, second)
        let reused = try await Self.render(
            engine: engine,
            text: "Reusing the synthesizer.",
            voice: voice.identifier
        )

        XCTAssertGreaterThan(concurrent.0, 0)
        XCTAssertGreaterThan(concurrent.1, 0)
        XCTAssertGreaterThan(reused, 0)
    }

    func testRussianTTSSTTLoopback() async throws {
        let assets = await STTAssets.state(language: "ru-RU")
        guard assets.installed else {
            throw XCTSkip("ru-RU Dictation assets are not installed")
        }
        try await STTAssets.prewarm(language: "ru-RU")
        // Russian speech fixture: "Turn on the living room lights".
        let phrase = "Включи свет в гостиной"
        let voices = VoiceRegistry(observeChanges: false)
        let voice = try voices.resolve(identifier: nil)
        var rate: Int?
        var pcm = Data()
        for try await output in try await AppleTTSEngine(voices: voices).stream(
            text: phrase,
            voiceIdentifier: voice.identifier
        ) {
            switch output {
            case let .format(value): rate = value
            case let .pcm(data): pcm.append(data)
            }
        }
        let sampleRate = try XCTUnwrap(rate)
        let session = try await AppleSTTSession.start(
            language: "ru-RU",
            inputFormat: PCMInputFormat(sampleRate: sampleRate, channels: 1, sampleWidth: 2)
        ) { _ in }
        for offset in stride(from: 0, to: pcm.count, by: 4_096) {
            try await session.push(Data(pcm[offset..<min(offset + 4_096, pcm.count)]))
        }
        let transcript = try await session.finish()
        XCTAssertEqual(normalize(transcript), normalize(phrase))
    }

    private func normalize(_ text: String) -> String {
        text.lowercased()
            .components(separatedBy: CharacterSet.letters.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private static func render(
        engine: AppleTTSEngine,
        text: String,
        voice: String
    ) async throws -> Int {
        var byteCount = 0
        for try await output in try await engine.stream(
            text: text,
            voiceIdentifier: voice
        ) {
            if case let .pcm(data) = output { byteCount += data.count }
        }
        return byteCount
    }
}
