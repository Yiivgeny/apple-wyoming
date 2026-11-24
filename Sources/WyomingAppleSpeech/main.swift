import AppleSpeech
import Darwin
import Foundation
import NIOCore
import WakeWord
import WyomingProtocol

struct WyomingAppleSpeechMain {
    static func main() async {
        do {
            try await dispatch(Array(CommandLine.arguments.dropFirst()))
        } catch {
            FileHandle.standardError.write(Data("error: \(error.localizedDescription)\n".utf8))
            Darwin.exit(1)
        }
    }

    private static func dispatch(_ arguments: [String]) async throws {
        let command = arguments.first ?? "help"
        let options = try CLIOptions(Array(arguments.dropFirst()))
        switch command {
        case "serve":
            var configuration = ServerConfiguration()
            configuration.host = options.string("host") ?? configuration.host
            configuration.port = try options.int("port") ?? configuration.port
            configuration.language = options.string("language") ?? configuration.language
            configuration.defaultVoice = options.string("voice")
            configuration.ttsSettings.rate = try options.float("rate")
            configuration.ttsSettings.pitch = try options.float("pitch")
            configuration.ttsSettings.volume = try options.float("volume")
            configuration.maxConnections = try options.int("max-connections") ?? configuration.maxConnections
            configuration.maxTTSSessions = try options.int("max-tts-sessions") ?? configuration.maxTTSSessions
            configuration.maxSTTSessions = try options.int("max-stt-sessions") ?? configuration.maxSTTSessions
            configuration.wakeThreshold = try options.float("wake-threshold") ?? configuration.wakeThreshold
            configuration.wakeTriggerLevel = try options.int("wake-trigger-level") ?? configuration.wakeTriggerLevel
            configuration.idleTimeoutSeconds = try options.int("idle-timeout") ?? configuration.idleTimeoutSeconds
            configuration.publishBonjour = !options.flags.contains("no-mdns")
            configuration.logAudioChunks = options.flags.contains("log-audio-chunks")
            try validate(configuration)
            try await WyomingServer(configuration: configuration).run()

        case "prepare":
            let language = options.string("language") ?? "ru-RU"
            print("Preparing local dictation assets for \(language)…")
            let state = try await STTAssets.prepare(language: language)
            print("\(state.language): \(state.status), installed=\(state.installed)")

        case "voices":
            let registry = VoiceRegistry(observeChanges: false)
            let voices = registry.russianVoices()
            let selected = try? registry.resolve(identifier: nil)
            if voices.isEmpty { print("No installed Russian Apple voices") }
            for voice in voices {
                let marker = voice.identifier == selected?.identifier ? "*" : " "
                print("\(marker) \(voice.identifier)\n    \(voice.name), \(voice.language), \(voice.quality)")
            }

        case "locales":
            let supported = await STTAssets.supportedLocales()
            let installed = Set(await STTAssets.installedLocales())
            for locale in supported {
                print("\(installed.contains(locale) ? "*" : " ") \(locale)")
            }

        case "doctor":
            try await doctor(language: options.string("language") ?? "ru-RU")

        case "help", "--help", "-h":
            print(usage)
        default:
            throw CLIError("Unknown command: \(command)\n\n\(usage)")
        }
    }

    private static func doctor(language: String) async throws {
        var wire = ByteBufferAllocator().buffer(capacity: 64)
        try WyomingEncoder().encode(data: WyomingEvent(type: WyomingEventType.ping), out: &wire)
        guard wire.readableBytesView.contains(0x0A) else {
            throw CLIError("Wyoming framing self-test failed")
        }
        print("✓ Wyoming JSONL framing")

        let wakeWord = try WakeWordEngine()
        try await wakeWord.prewarm()
        print("✓ CoreML wake words: \(WakeWordEngine.modelNames.joined(separator: ", "))")

        let assets = await STTAssets.state(language: language)
        guard assets.installed else {
            print("✗ STT assets: \(assets.status)")
            print("  Recovery: wyoming-apple-speech prepare --language \(language)")
            throw AppleSpeechError.modelNotInstalled(language)
        }
        print("✓ Apple Dictation assets for \(language)")

        let voices = VoiceRegistry(observeChanges: false)
        let selected = try voices.resolve(identifier: nil)
        print("✓ TTS voice: \(selected.name) (\(selected.quality))")
        let engine = AppleTTSEngine(voices: voices)
        // Russian speech fixture: "Turn on the living room lights".
        let phrase = "Включи свет в гостиной"
        var rate: Int?
        var pcm = Data()
        for try await output in try await engine.stream(
            text: phrase,
            voiceIdentifier: selected.identifier
        ) {
            switch output {
            case let .format(sampleRate): rate = sampleRate
            case let .pcm(data): pcm.append(data)
            }
        }
        guard let rate, !pcm.isEmpty else { throw CLIError("TTS produced no PCM") }
        print("✓ In-memory TTS: \(pcm.count) bytes, mono S16LE, \(rate) Hz")

        let session = try await AppleSTTSession.start(
            language: language,
            inputFormat: PCMInputFormat(sampleRate: rate, channels: 1, sampleWidth: 2)
        ) { _ in }
        var offset = 0
        while offset < pcm.count {
            let end = min(offset + 4_096, pcm.count)
            try await session.push(Data(pcm[offset..<end]))
            offset = end
        }
        let transcript = try await session.finish()
        guard normalized(transcript).contains(normalized(phrase)) else {
            throw CLIError("Loopback mismatch: \(transcript)")
        }
        print("✓ Local TTS→STT loopback: \(transcript)")
        print("Doctor completed without using speakers, Python, network, or WAV files.")
    }

    private static func normalized(_ text: String) -> String {
        text.lowercased()
            .components(separatedBy: CharacterSet.letters.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private static func validate(_ configuration: ServerConfiguration) throws {
        guard (1...65_535).contains(configuration.port) else { throw CLIError("port must be 1...65535") }
        guard configuration.maxConnections > 0,
              configuration.maxTTSSessions > 0,
              configuration.maxSTTSessions > 0,
              configuration.wakeTriggerLevel > 0 else {
            throw CLIError("session limits must be positive")
        }
        guard (0...1).contains(configuration.wakeThreshold) else {
            throw CLIError("wake-threshold must be between 0 and 1")
        }
        if let rate = configuration.ttsSettings.rate, !(0...1).contains(rate) {
            throw CLIError("rate must be between 0 and 1")
        }
        if let pitch = configuration.ttsSettings.pitch, !(0.5...2).contains(pitch) {
            throw CLIError("pitch must be between 0.5 and 2")
        }
        if let volume = configuration.ttsSettings.volume, !(0...1).contains(volume) {
            throw CLIError("volume must be between 0 and 1")
        }
    }

    private static let usage = """
    Wyoming Apple Speech — local TTS and STT for macOS 26

    Commands:
      serve [--host 0.0.0.0] [--port 10700] [--language ru-RU]
            [--voice APPLE_IDENTIFIER] [--rate FLOAT] [--pitch FLOAT] [--volume FLOAT]
            [--max-connections 16] [--max-tts-sessions 2] [--max-stt-sessions 1]
            [--wake-threshold 0.5] [--wake-trigger-level 1]
            [--idle-timeout 120] [--no-mdns] [--log-audio-chunks]
      prepare [--language ru-RU]
      voices
      locales
      doctor [--language ru-RU]
    """
}

private struct CLIOptions {
    var values: [String: String] = [:]
    var flags: Set<String> = []

    init(_ arguments: [String]) throws {
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            guard argument.hasPrefix("--") else { throw CLIError("Unexpected argument: \(argument)") }
            let key = String(argument.dropFirst(2))
            if key == "no-mdns" || key == "log-audio-chunks" {
                flags.insert(key)
                index += 1
                continue
            }
            guard index + 1 < arguments.count, !arguments[index + 1].hasPrefix("--") else {
                throw CLIError("Missing value for --\(key)")
            }
            values[key] = arguments[index + 1]
            index += 2
        }
    }

    func string(_ key: String) -> String? { values[key] }

    func int(_ key: String) throws -> Int? {
        guard let raw = values[key] else { return nil }
        guard let value = Int(raw) else { throw CLIError("--\(key) must be an integer") }
        return value
    }

    func float(_ key: String) throws -> Float? {
        guard let raw = values[key] else { return nil }
        guard let value = Float(raw) else { throw CLIError("--\(key) must be a number") }
        return value
    }
}

private struct CLIError: Error, LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

await WyomingAppleSpeechMain.main()
