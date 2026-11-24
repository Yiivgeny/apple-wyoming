import AppleSpeech
import Foundation
import NIOCore
import OSLog
import WakeWord
import WyomingProtocol

public actor EventSink {
    private let writer: NIOAsyncChannelOutboundWriter<WyomingEvent>

    public init(writer: NIOAsyncChannelOutboundWriter<WyomingEvent>) {
        self.writer = writer
    }

    public func send(_ event: WyomingEvent) async throws {
        try await writer.write(event)
    }
}

public final class ConnectionSession: @unchecked Sendable {
    private struct StreamingTTSState {
        var voice: String?
        var text = ""
        var chunksSeen = false
        var totalCharacters = 0
        var announcedRate: Int?
        var pendingPCM = Data()
        var slotHeld = true
    }

    private struct PendingSTTState {
        var language: String
        var session: AppleSTTSession?
        var slotHeld = true
    }

    private struct PendingWakeState {
        var context: JSONValue?
        var session: WakeWordDetectionSession
        var audioStarted = false
        var detected = false
    }

    private let id = UUID().uuidString
    private let configuration: ServerConfiguration
    private let voices: VoiceRegistry
    private let tts: AppleTTSEngine
    private let ttsSlots: SlotLimiter
    private let sttSlots: SlotLimiter
    private let wakeWord: WakeWordEngine
    private let sink: EventSink
    private let logger = Logger(subsystem: "local.wyoming.apple-speech", category: "connection")
    private var streamingTTS: StreamingTTSState?
    private var pendingSTT: PendingSTTState?
    private var pendingWake: PendingWakeState?

    public init(
        configuration: ServerConfiguration,
        voices: VoiceRegistry,
        tts: AppleTTSEngine,
        ttsSlots: SlotLimiter,
        sttSlots: SlotLimiter,
        wakeWord: WakeWordEngine,
        sink: EventSink
    ) {
        self.configuration = configuration
        self.voices = voices
        self.tts = tts
        self.ttsSlots = ttsSlots
        self.sttSlots = sttSlots
        self.wakeWord = wakeWord
        self.sink = sink
    }

    public func run(_ inbound: NIOAsyncChannelInboundStream<WyomingEvent>) async {
        logger.info("session=\(self.id, privacy: .public) connected")
        do {
            for try await event in inbound {
                if EventLoggingPolicy.shouldSendToLogger(
                    eventType: event.type,
                    logAudioChunks: configuration.logAudioChunks
                ) {
                    logger.debug("session=\(self.id, privacy: .public) event=\(event.type, privacy: .public) payload_bytes=\(event.payload?.count ?? 0)")
                }
                do {
                    try await handle(event)
                } catch {
                    try await sink.send(mapError(error))
                    if event.type != WyomingEventType.describe && event.type != WyomingEventType.ping {
                        await resetActiveRequest()
                    }
                }
            }
        } catch {
            logger.error("session=\(self.id, privacy: .public) read_error=\(error.localizedDescription, privacy: .public)")
        }
        await resetActiveRequest()
        logger.info("session=\(self.id, privacy: .public) disconnected")
    }

    private func handle(_ event: WyomingEvent) async throws {
        switch event.type {
        case WyomingEventType.describe:
            let state = await STTAssets.state(language: configuration.language)
            try await sink.send(ServiceDescription.info(
                voices: voices.russianVoices(),
                stt: state,
                language: configuration.language
            ))
        case WyomingEventType.ping:
            try await sink.send(WyomingEvent(type: WyomingEventType.pong, data: event.data))
        case WyomingEventType.synthesize:
            try await handleSynthesize(event)
        case WyomingEventType.synthesizeStart:
            try await startStreamingTTS(event)
        case WyomingEventType.synthesizeChunk:
            try await appendStreamingTTS(event)
        case WyomingEventType.synthesizeStop:
            try await stopStreamingTTS()
        case WyomingEventType.transcribe:
            try await startTranscription(event)
        case WyomingEventType.detect:
            try startWakeDetection(event)
        case WyomingEventType.audioStart:
            try await startAudio(event)
        case WyomingEventType.audioChunk:
            try await acceptAudio(event)
        case WyomingEventType.audioStop:
            try await stopAudio()
        default:
            throw SessionError.invalidEvent("Unsupported event: \(event.type)")
        }
    }

    private func handleSynthesize(_ event: WyomingEvent) async throws {
        let text = try plainText(from: event)
        if var state = streamingTTS {
            if state.chunksSeen { return }
            state.totalCharacters += text.count
            guard state.totalCharacters <= 4_096 else {
                throw AppleSpeechError.limitExceeded("text exceeds 4096 characters")
            }
            state.text.append(text)
            streamingTTS = state
            return
        }

        guard await ttsSlots.acquire() else { throw SessionError.busy("All TTS sessions are busy") }
        defer { Task { await ttsSlots.release() } }
        let voice = try requestedVoice(from: event)
        var output = StreamingTTSState(voice: voice)
        try await synthesize(text, into: &output)
        try await finishAudioOutput(&output)
    }

    private func startStreamingTTS(_ event: WyomingEvent) async throws {
        guard streamingTTS == nil else {
            throw SessionError.invalidEvent("synthesize-start received while TTS is active")
        }
        guard await ttsSlots.acquire() else { throw SessionError.busy("All TTS sessions are busy") }
        do {
            streamingTTS = StreamingTTSState(voice: try requestedVoice(from: event))
        } catch {
            await ttsSlots.release()
            throw error
        }
    }

    private func appendStreamingTTS(_ event: WyomingEvent) async throws {
        guard var state = streamingTTS else {
            throw SessionError.invalidEvent("synthesize-chunk received before synthesize-start")
        }
        let text = try plainText(from: event)
        state.chunksSeen = true
        state.totalCharacters += text.count
        guard state.totalCharacters <= 4_096 else {
            throw AppleSpeechError.limitExceeded("text exceeds 4096 characters")
        }
        state.text.append(text)
        let segments = StreamingTextSegmenter.takeSegments(from: &state.text)
        for segment in segments { try await synthesize(segment, into: &state) }
        streamingTTS = state
    }

    private func stopStreamingTTS() async throws {
        guard var state = streamingTTS else {
            throw SessionError.invalidEvent("synthesize-stop received before synthesize-start")
        }
        streamingTTS = nil
        defer {
            if state.slotHeld {
                state.slotHeld = false
                Task { await ttsSlots.release() }
            }
        }
        for segment in StreamingTextSegmenter.takeSegments(from: &state.text, force: true) {
            try await synthesize(segment, into: &state)
        }
        try await finishAudioOutput(&state)
        try await sink.send(WyomingEvent(type: WyomingEventType.synthesizeStopped))
    }

    private func synthesize(_ text: String, into state: inout StreamingTTSState) async throws {
        logger.debug(
            "session=\(self.id, privacy: .public) tts_text=\(text, privacy: .public)"
        )
        let stream = try await tts.stream(
            text: text,
            voiceIdentifier: state.voice ?? configuration.defaultVoice,
            settings: configuration.ttsSettings
        )
        for try await output in stream {
            switch output {
            case let .format(rate):
                if let announced = state.announcedRate, announced != rate {
                    throw AppleSpeechError.internalFailure("voice sample rate changed within one response")
                }
                if state.announcedRate == nil {
                    state.announcedRate = rate
                    try await sink.send(.audioStart(rate: rate))
                }
            case let .pcm(data):
                state.pendingPCM.append(data)
                while state.pendingPCM.count >= 4_096 {
                    let chunk = Data(state.pendingPCM.prefix(4_096))
                    state.pendingPCM.removeFirst(4_096)
                    try await sink.send(.audioChunk(chunk, rate: state.announcedRate))
                }
            }
        }
    }

    private func finishAudioOutput(_ state: inout StreamingTTSState) async throws {
        guard state.announcedRate != nil else {
            throw AppleSpeechError.internalFailure("TTS produced no audio")
        }
        if !state.pendingPCM.isEmpty {
            try await sink.send(.audioChunk(state.pendingPCM, rate: state.announcedRate))
            state.pendingPCM.removeAll(keepingCapacity: false)
        }
        try await sink.send(.audioStop)
    }

    private func startTranscription(_ event: WyomingEvent) async throws {
        guard pendingSTT == nil, pendingWake == nil else {
            throw SessionError.invalidEvent("transcribe received while STT is active")
        }
        let language = event.string("language") ?? configuration.language
        guard normalizedLanguage(language) == normalizedLanguage(configuration.language) else {
            throw AppleSpeechError.unsupportedLanguage(language)
        }
        guard await sttSlots.acquire() else { throw SessionError.busy("All STT sessions are busy") }
        pendingSTT = PendingSTTState(language: language)
    }

    private func startAudio(_ event: WyomingEvent) async throws {
        if pendingWake != nil {
            try startWakeAudio(event)
            return
        }
        guard var state = pendingSTT, state.session == nil else {
            throw SessionError.invalidEvent("audio-start received without a pending transcribe")
        }
        let format = PCMInputFormat(
            sampleRate: event.int("rate") ?? 0,
            channels: event.int("channels") ?? 0,
            sampleWidth: event.int("width") ?? 0
        )
        let session = try await AppleSTTSession.start(
            language: state.language,
            inputFormat: format
        ) { [sink] phrase in
            try? await sink.send(WyomingEvent(
                type: WyomingEventType.transcriptChunk,
                data: ["text": .string(phrase)]
            ))
        }
        state.session = session
        pendingSTT = state
        try await sink.send(WyomingEvent(type: WyomingEventType.transcriptStart))
    }

    private func acceptAudio(_ event: WyomingEvent) async throws {
        guard let payload = event.payload, !payload.isEmpty else {
            throw AppleSpeechError.invalidAudioFormat("audio-chunk has no PCM payload")
        }
        if var wake = pendingWake {
            guard wake.audioStarted else {
                throw SessionError.invalidEvent("audio-chunk received before audio-start")
            }
            guard !wake.detected else { return }
            if let detection = try await wake.session.accept(payload) {
                wake.detected = true
                pendingWake = wake
                logger.info(
                    "session=\(self.id, privacy: .public) wake=\(detection.name, privacy: .public) confidence=\(detection.confidence) timestamp_ms=\(detection.timestampMilliseconds)"
                )
                try await sink.send(.detection(
                    name: detection.name,
                    timestampMilliseconds: detection.timestampMilliseconds,
                    context: wake.context
                ))
            }
            return
        }
        guard let session = pendingSTT?.session else {
            throw SessionError.invalidEvent("audio-chunk received before audio-start")
        }
        try await session.push(payload)
    }

    private func stopAudio() async throws {
        if let wake = pendingWake {
            guard wake.audioStarted else {
                throw SessionError.invalidEvent("audio-stop received before audio-start")
            }
            pendingWake = nil
            if !wake.detected {
                try await sink.send(.notDetected(context: wake.context))
            }
            return
        }
        guard var state = pendingSTT, let session = state.session else {
            throw SessionError.invalidEvent("audio-stop received before audio-start")
        }
        pendingSTT = nil
        defer {
            if state.slotHeld {
                state.slotHeld = false
                Task { await sttSlots.release() }
            }
        }
        let text = try await session.finish()
        logger.debug(
            "session=\(self.id, privacy: .public) stt_transcript=\(text, privacy: .public)"
        )
        try await sink.send(WyomingEvent(
            type: WyomingEventType.transcript,
            data: ["text": .string(text)]
        ))
        try await sink.send(WyomingEvent(type: WyomingEventType.transcriptStop))
    }

    private func startWakeDetection(_ event: WyomingEvent) throws {
        guard pendingWake == nil, pendingSTT == nil else {
            throw SessionError.invalidEvent("detect received while audio processing is active")
        }
        let requestedNames: Set<String>?
        if let namesValue = event.data["names"], namesValue != .null {
            guard case let .array(values) = namesValue,
                  values.allSatisfy({ $0.stringValue != nil }) else {
                throw SessionError.invalidEvent("detect names must be an array of strings or null")
            }
            let names = Set(values.compactMap(\.stringValue))
            if names.isEmpty {
                requestedNames = nil
            } else {
                let supportedNames = Set(WakeWordEngine.modelNames)
                let selectedNames = names.intersection(supportedNames)
                guard !selectedNames.isEmpty else {
                    throw SessionError.invalidEvent(
                        "Requested wake word is not available; supported models: "
                            + WakeWordEngine.modelNames.joined(separator: ", ")
                    )
                }
                requestedNames = selectedNames
            }
        } else {
            requestedNames = nil
        }
        let context: JSONValue?
        switch event.data["context"] {
        case nil, .some(.null): context = nil
        case let .some(.object(value)): context = .object(value)
        default: throw SessionError.invalidEvent("detect context must be an object or null")
        }
        pendingWake = PendingWakeState(
            context: context,
            session: try WakeWordDetectionSession(
                engine: wakeWord,
                modelNames: requestedNames,
                threshold: configuration.wakeThreshold,
                triggerLevel: configuration.wakeTriggerLevel
            )
        )
    }

    private func startWakeAudio(_ event: WyomingEvent) throws {
        guard var wake = pendingWake, !wake.audioStarted else {
            throw SessionError.invalidEvent("audio-start received without a pending detect")
        }
        let rate = event.int("rate") ?? 0
        let channels = event.int("channels") ?? 0
        let width = event.int("width") ?? 0
        guard rate == WakeWordEngine.sampleRate, channels == 1, width == 2 else {
            throw WakeWordError.invalidAudio(
                "wake-word models require 16000 Hz mono signed Int16 little-endian PCM"
            )
        }
        wake.audioStarted = true
        pendingWake = wake
    }

    private func plainText(from event: WyomingEvent) throws -> String {
        guard let text = event.string("text") else {
            throw SessionError.invalidEvent("\(event.type) is missing text")
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.range(of: "<[^>]+>", options: .regularExpression) == nil else {
            throw SessionError.invalidEvent("SSML is not supported; send plain text")
        }
        return text
    }

    private func requestedVoice(from event: WyomingEvent) throws -> String? {
        guard let value = event.data["voice"] else { return configuration.defaultVoice }
        guard case let .object(voice) = value else {
            throw SessionError.invalidEvent("voice must be an object")
        }
        if let speaker = voice["speaker"]?.stringValue, !speaker.isEmpty {
            throw SessionError.invalidEvent("speaker selection is not supported")
        }
        if let language = voice["language"]?.stringValue,
           !language.isEmpty,
           normalizedLanguage(language) != normalizedLanguage(configuration.language) {
            throw AppleSpeechError.unsupportedLanguage(language)
        }
        let identifier = voice["name"]?.stringValue
        if let identifier, !identifier.isEmpty { _ = try voices.resolve(identifier: identifier) }
        return identifier ?? configuration.defaultVoice
    }

    private func resetActiveRequest() async {
        if var state = streamingTTS, state.slotHeld {
            state.slotHeld = false
            streamingTTS = nil
            await ttsSlots.release()
        }
        if var state = pendingSTT, state.slotHeld {
            state.slotHeld = false
            pendingSTT = nil
            await state.session?.cancel()
            await sttSlots.release()
        }
        pendingWake = nil
    }

    private func normalizedLanguage(_ language: String) -> String {
        language.replacingOccurrences(of: "_", with: "-").lowercased()
    }

    private func mapError(_ error: Error) -> WyomingEvent {
        switch error {
        case let SessionError.invalidEvent(message):
            .error(.invalidEvent, message: message)
        case let SessionError.busy(message):
            .error(.busy, message: message)
        case let AppleSpeechError.invalidAudioFormat(message):
            .error(.invalidAudioFormat, message: message)
        case let AppleSpeechError.unsupportedLanguage(language):
            .error(.unsupportedLanguage, message: "Unsupported language: \(language)")
        case let AppleSpeechError.unknownVoice(voice):
            .error(.unknownVoice, message: "Unknown voice: \(voice)")
        case let AppleSpeechError.modelNotInstalled(language):
            .error(.modelNotInstalled, message: "Run: wyoming-apple-speech prepare --language \(language)")
        case let AppleSpeechError.limitExceeded(message):
            .error(.limitExceeded, message: message)
        case let WakeWordError.invalidAudio(message):
            .error(.invalidAudioFormat, message: message)
        case let WakeWordError.invalidConfiguration(message):
            .error(.invalidEvent, message: message)
        default:
            .error(.internalError, message: error.localizedDescription)
        }
    }
}

private enum SessionError: Error {
    case invalidEvent(String)
    case busy(String)
}
