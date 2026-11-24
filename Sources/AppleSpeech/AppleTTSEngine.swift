@preconcurrency import AVFoundation
import Foundation

public final class AppleTTSEngine: @unchecked Sendable {
    private let voices: VoiceRegistry
    private let pool: TTSSynthesizerPool
    private let poolSize: Int

    public init(voices: VoiceRegistry, poolSize: Int = 2) {
        self.voices = voices
        self.poolSize = max(1, poolSize)
        pool = TTSSynthesizerPool(size: max(1, poolSize))
    }

    public func stream(
        text: String,
        voiceIdentifier: String? = nil,
        settings: TTSSettings = TTSSettings()
    ) async throws -> AsyncThrowingStream<TTSOutput, Error> {
        let session = await makeSession()
        let source: AsyncThrowingStream<TTSOutput, Error>
        do {
            source = try session.stream(
                text: text,
                voiceIdentifier: voiceIdentifier,
                settings: settings
            )
        } catch {
            await session.close()
            throw error
        }

        return AsyncThrowingStream { continuation in
            let forwardingTask = Task {
                do {
                    for try await output in source {
                        continuation.yield(output)
                    }
                    await session.close()
                    continuation.finish()
                } catch {
                    await session.close()
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { @Sendable termination in
                if case .cancelled = termination { forwardingTask.cancel() }
            }
        }
    }

    public func prewarm(
        voiceIdentifier: String? = nil,
        settings: TTSSettings = TTSSettings()
    ) async throws {
        var sessions: [AppleTTSSession] = []
        for _ in 0..<poolSize {
            sessions.append(await makeSession())
        }

        do {
            for session in sessions {
                let stream = try session.stream(
                    text: ".",
                    voiceIdentifier: voiceIdentifier,
                    settings: settings
                )
                for try await _ in stream {}
            }
        } catch {
            for session in sessions { await session.close() }
            throw error
        }
        for session in sessions { await session.close() }
    }

    private func makeSession() async -> AppleTTSSession {
        AppleTTSSession(
            resource: await pool.acquire(),
            pool: pool,
            voices: voices
        )
    }
}

private final class AppleTTSSession: @unchecked Sendable {
    private let lock = NSLock()
    private let pool: TTSSynthesizerPool
    private let voices: VoiceRegistry
    private var resource: TTSSynthesizerResource?
    private var active = false

    init(
        resource: TTSSynthesizerResource,
        pool: TTSSynthesizerPool,
        voices: VoiceRegistry
    ) {
        self.resource = resource
        self.pool = pool
        self.voices = voices
    }

    func stream(
        text: String,
        voiceIdentifier: String?,
        settings: TTSSettings
    ) throws -> AsyncThrowingStream<TTSOutput, Error> {
        guard !text.isEmpty else {
            throw AppleSpeechError.limitExceeded("text is empty")
        }
        guard text.count <= 4_096 else {
            throw AppleSpeechError.limitExceeded("text exceeds 4096 characters")
        }
        let descriptor = try voices.resolve(identifier: voiceIdentifier)
        guard let voice = AVSpeechSynthesisVoice(identifier: descriptor.identifier) else {
            throw AppleSpeechError.unknownVoice(descriptor.identifier)
        }

        let synthesizer = try lock.withLock { () throws -> AVSpeechSynthesizer in
            guard let resource else {
                throw AppleSpeechError.internalFailure("TTS session is closed")
            }
            guard !active else {
                throw AppleSpeechError.internalFailure("TTS session is already active")
            }
            active = true
            return resource.synthesizer
        }

        return AsyncThrowingStream { continuation in
            let lifetime = TTSLifetime()
            lifetime.start(
                text: text,
                voice: voice,
                settings: settings,
                synthesizer: synthesizer,
                onFinished: { [weak self] in self?.segmentFinished() },
                continuation: continuation
            )
            continuation.onTermination = { @Sendable _ in
                lifetime.cancel()
            }
        }
    }

    func close() async {
        let resource = lock.withLock { () -> TTSSynthesizerResource? in
            let value = self.resource
            self.resource = nil
            active = false
            return value
        }
        guard let resource else { return }
        resource.synthesizer.stopSpeaking(at: .immediate)
        await pool.release(resource)
    }

    private func segmentFinished() {
        lock.withLock { active = false }
    }
}

private final class TTSSynthesizerResource: @unchecked Sendable {
    let synthesizer = AVSpeechSynthesizer()
}

private actor TTSSynthesizerPool {
    private var available: [TTSSynthesizerResource]
    private var waiters: [CheckedContinuation<TTSSynthesizerResource, Never>] = []

    init(size: Int) {
        available = (0..<size).map { _ in TTSSynthesizerResource() }
    }

    func acquire() async -> TTSSynthesizerResource {
        if let resource = available.popLast() { return resource }
        return await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func release(_ resource: TTSSynthesizerResource) {
        if waiters.isEmpty {
            available.append(resource)
        } else {
            waiters.removeFirst().resume(returning: resource)
        }
    }
}

private final class TTSLifetime: @unchecked Sendable {
    private let lock = NSLock()
    private var finished = false
    private var announcedRate: Int?
    private var synthesizer: AVSpeechSynthesizer?
    private var onFinished: (@Sendable () -> Void)?

    func start(
        text: String,
        voice: AVSpeechSynthesisVoice,
        settings: TTSSettings,
        synthesizer: AVSpeechSynthesizer,
        onFinished: @escaping @Sendable () -> Void,
        continuation: AsyncThrowingStream<TTSOutput, Error>.Continuation
    ) {
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = voice
        if let rate = settings.rate { utterance.rate = rate }
        if let pitch = settings.pitch { utterance.pitchMultiplier = pitch }
        if let volume = settings.volume { utterance.volume = volume }

        lock.withLock {
            self.synthesizer = synthesizer
            self.onFinished = onFinished
        }
        synthesizer.write(utterance) { [weak self] rawBuffer in
            guard let self else { return }
            guard let pcm = rawBuffer as? AVAudioPCMBuffer else {
                self.fail(
                    AppleSpeechError.internalFailure("TTS returned a non-PCM buffer"),
                    continuation: continuation
                )
                return
            }
            guard pcm.frameLength > 0 else {
                self.complete(continuation: continuation)
                return
            }
            do {
                let normalized = try PCMNormalizer.normalize(pcm)
                let shouldAnnounce = self.lock.withLock { () -> Bool in
                    guard self.announcedRate == nil else { return false }
                    self.announcedRate = normalized.sampleRate
                    return true
                }
                if shouldAnnounce {
                    continuation.yield(.format(sampleRate: normalized.sampleRate))
                }
                if !normalized.data.isEmpty { continuation.yield(.pcm(normalized.data)) }
            } catch {
                self.fail(error, continuation: continuation)
            }
        }
    }

    func cancel() {
        let result = lock.withLock { () -> (AVSpeechSynthesizer?, (@Sendable () -> Void)?) in
            guard !finished else { return (nil, nil) }
            finished = true
            let synthesizer = self.synthesizer
            let completion = onFinished
            self.synthesizer = nil
            onFinished = nil
            return (synthesizer, completion)
        }
        result.0?.stopSpeaking(at: .immediate)
        result.1?()
    }

    private func complete(
        continuation: AsyncThrowingStream<TTSOutput, Error>.Continuation
    ) {
        let completion = lock.withLock { () -> (@Sendable () -> Void)? in
            guard !finished else { return nil }
            finished = true
            synthesizer = nil
            let value = onFinished
            onFinished = nil
            return value
        }
        guard let completion else { return }
        completion()
        continuation.finish()
    }

    private func fail(
        _ error: Error,
        continuation: AsyncThrowingStream<TTSOutput, Error>.Continuation
    ) {
        let result = lock.withLock { () -> (AVSpeechSynthesizer?, (@Sendable () -> Void)?) in
            guard !finished else { return (nil, nil) }
            finished = true
            let synthesizer = self.synthesizer
            let completion = onFinished
            self.synthesizer = nil
            onFinished = nil
            return (synthesizer, completion)
        }
        result.0?.stopSpeaking(at: .immediate)
        result.1?()
        continuation.finish(throwing: error)
    }
}

private enum PCMNormalizer {
    static func normalize(_ input: AVAudioPCMBuffer) throws -> (sampleRate: Int, data: Data) {
        let sampleRate = Int(input.format.sampleRate.rounded())
        if input.format.commonFormat == .pcmFormatInt16,
           input.format.channelCount == 1,
           let channels = input.int16ChannelData {
            return (
                sampleRate,
                Data(bytes: channels[0], count: Int(input.frameLength) * MemoryLayout<Int16>.size)
            )
        }

        guard let outputFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: input.format.sampleRate,
            channels: 1,
            interleaved: false
        ), let converter = AVAudioConverter(from: input.format, to: outputFormat) else {
            throw AppleSpeechError.internalFailure("Cannot create TTS PCM converter")
        }
        guard let output = AVAudioPCMBuffer(
            pcmFormat: outputFormat,
            frameCapacity: max(input.frameLength + 32, 64)
        ) else {
            throw AppleSpeechError.internalFailure("Cannot allocate TTS PCM buffer")
        }

        let inputBox = ConverterInputBox(input)
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, inputStatus in
            guard let input = inputBox.take() else {
                inputStatus.pointee = .endOfStream
                return nil
            }
            inputStatus.pointee = .haveData
            return input
        }
        guard status != .error, conversionError == nil, let channels = output.int16ChannelData else {
            throw AppleSpeechError.internalFailure(
                conversionError?.localizedDescription ?? "TTS PCM conversion failed"
            )
        }
        return (
            sampleRate,
            Data(bytes: channels[0], count: Int(output.frameLength) * MemoryLayout<Int16>.size)
        )
    }
}

private final class ConverterInputBox: @unchecked Sendable {
    private let lock = NSLock()
    private var input: AVAudioPCMBuffer?

    init(_ input: AVAudioPCMBuffer) {
        self.input = input
    }

    func take() -> AVAudioPCMBuffer? {
        lock.withLock {
            defer { input = nil }
            return input
        }
    }
}

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
