@preconcurrency import AVFoundation
import Foundation
import Speech

public enum STTAssets {
    public static func state(language: String) async -> STTAssetState {
        let locale = Locale(identifier: language)
        guard let supported = await DictationTranscriber.supportedLocale(equivalentTo: locale) else {
            return STTAssetState(
                language: language,
                supported: false,
                installed: false,
                status: "unsupported"
            )
        }
        let transcriber = DictationTranscriber(locale: supported, preset: .progressiveShortDictation)
        let status = await AssetInventory.status(forModules: [transcriber])
        let installed = await isInstalled(locale: supported) || status == .installed
        return STTAssetState(
            language: language,
            supported: status != .unsupported,
            installed: installed,
            status: installed ? "installed" : String(describing: status)
        )
    }

    @discardableResult
    public static func prepare(language: String) async throws -> STTAssetState {
        let locale = Locale(identifier: language)
        guard let supported = await DictationTranscriber.supportedLocale(equivalentTo: locale) else {
            throw AppleSpeechError.unsupportedLanguage(language)
        }
        _ = try await AssetInventory.reserve(locale: supported)
        let transcriber = DictationTranscriber(locale: supported, preset: .progressiveShortDictation)
        let status = await AssetInventory.status(forModules: [transcriber])
        if !(await isInstalled(locale: supported)) && status != .installed {
            guard let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) else {
                throw AppleSpeechError.internalFailure("No asset installation request was created")
            }
            try await request.downloadAndInstall()
        }
        return await state(language: language)
    }

    public static func prewarm(language: String) async throws {
        let locale = Locale(identifier: language)
        guard let supported = await DictationTranscriber.supportedLocale(equivalentTo: locale) else {
            throw AppleSpeechError.unsupportedLanguage(language)
        }
        let transcriber = makeRealtimeTranscriber(locale: supported)
        let status = await AssetInventory.status(forModules: [transcriber])
        let localeInstalled = await isInstalled(locale: supported)
        guard status == .installed || localeInstalled else {
            throw AppleSpeechError.modelNotInstalled(language)
        }
        guard let analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(
            compatibleWith: [transcriber]
        ) else {
            throw AppleSpeechError.internalFailure("No compatible analyzer audio format")
        }

        let analyzer = makeRetainedAnalyzer(transcriber: transcriber)
        try await analyzer.prepareToAnalyze(in: analyzerFormat)
        await analyzer.cancelAndFinishNow()
    }

    public static func supportedLocales() async -> [String] {
        await DictationTranscriber.supportedLocales
            .map(\.identifier)
            .sorted()
    }

    public static func installedLocales() async -> [String] {
        await DictationTranscriber.installedLocales
            .map(\.identifier)
            .sorted()
    }

    public static func isInstalled(language: String) async -> Bool {
        let requested = normalizeLocaleIdentifier(language)
        return await DictationTranscriber.installedLocales.contains {
            normalizeLocaleIdentifier($0.identifier) == requested
        }
    }

    private static func isInstalled(locale: Locale) async -> Bool {
        await isInstalled(language: locale.identifier)
    }

    private static func normalizeLocaleIdentifier(_ identifier: String) -> String {
        identifier.replacingOccurrences(of: "_", with: "-").lowercased()
    }
}

private func makeRealtimeTranscriber(locale: Locale) -> DictationTranscriber {
    DictationTranscriber(
        locale: locale,
        contentHints: [.shortForm],
        transcriptionOptions: [.punctuation],
        reportingOptions: [.volatileResults, .frequentFinalization],
        attributeOptions: []
    )
}

private func makeRetainedAnalyzer(transcriber: DictationTranscriber) -> SpeechAnalyzer {
    SpeechAnalyzer(
        modules: [transcriber],
        options: SpeechAnalyzer.Options(
            priority: .userInitiated,
            modelRetention: .processLifetime
        )
    )
}

public actor AppleSTTSession {
    public typealias FinalPhraseHandler = @Sendable (String) async -> Void

    private let inputFormat: PCMInputFormat
    private let sourceFormat: AVAudioFormat
    private let analyzerFormat: AVAudioFormat
    private let converter: AVAudioConverter?
    private let analyzer: SpeechAnalyzer
    private let continuation: AsyncStream<AnalyzerInput>.Continuation
    private let analysisTask: Task<Void, Error>
    private let resultsTask: Task<[String], Error>
    private var byteCarry = Data()
    private var inputFrames: Int64 = 0
    private var finished = false

    private init(
        inputFormat: PCMInputFormat,
        sourceFormat: AVAudioFormat,
        analyzerFormat: AVAudioFormat,
        converter: AVAudioConverter?,
        analyzer: SpeechAnalyzer,
        continuation: AsyncStream<AnalyzerInput>.Continuation,
        analysisTask: Task<Void, Error>,
        resultsTask: Task<[String], Error>
    ) {
        self.inputFormat = inputFormat
        self.sourceFormat = sourceFormat
        self.analyzerFormat = analyzerFormat
        self.converter = converter
        self.analyzer = analyzer
        self.continuation = continuation
        self.analysisTask = analysisTask
        self.resultsTask = resultsTask
    }

    public static func start(
        language: String,
        inputFormat: PCMInputFormat,
        onFinalPhrase: @escaping FinalPhraseHandler
    ) async throws -> AppleSTTSession {
        try inputFormat.validate()
        guard language.replacingOccurrences(of: "_", with: "-").lowercased() == "ru-ru" else {
            throw AppleSpeechError.unsupportedLanguage(language)
        }
        let locale = Locale(identifier: language)
        guard let supported = await DictationTranscriber.supportedLocale(equivalentTo: locale) else {
            throw AppleSpeechError.unsupportedLanguage(language)
        }
        let transcriber = makeRealtimeTranscriber(locale: supported)
        let status = await AssetInventory.status(forModules: [transcriber])
        let localeInstalled = await STTAssets.isInstalled(language: language)
        guard status == .installed || localeInstalled else {
            throw AppleSpeechError.modelNotInstalled(language)
        }
        guard let analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(
            compatibleWith: [transcriber]
        ) else {
            throw AppleSpeechError.internalFailure("No compatible analyzer audio format")
        }
        guard let sourceFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: Double(inputFormat.sampleRate),
            channels: AVAudioChannelCount(inputFormat.channels),
            interleaved: true
        ) else {
            throw AppleSpeechError.invalidAudioFormat("Cannot construct the source PCM format")
        }
        let needsConversion = sourceFormat.sampleRate != analyzerFormat.sampleRate
            || sourceFormat.channelCount != analyzerFormat.channelCount
            || sourceFormat.commonFormat != analyzerFormat.commonFormat
            || sourceFormat.isInterleaved != analyzerFormat.isInterleaved
        let converter = needsConversion ? AVAudioConverter(from: sourceFormat, to: analyzerFormat) : nil
        if needsConversion, converter == nil {
            throw AppleSpeechError.invalidAudioFormat("Cannot convert input PCM to analyzer format")
        }

        let analyzer = makeRetainedAnalyzer(transcriber: transcriber)
        try await analyzer.prepareToAnalyze(in: analyzerFormat)
        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        let analysisTask = Task<Void, Error> {
            try await analyzer.start(inputSequence: stream)
        }
        let resultsTask = Task<[String], Error> {
            var phrases: [String] = []
            for try await result in transcriber.results {
                guard result.isFinal else { continue }
                let text = String(result.text.characters)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { continue }
                phrases.append(text)
                await onFinalPhrase(text)
            }
            return phrases
        }

        return AppleSTTSession(
            inputFormat: inputFormat,
            sourceFormat: sourceFormat,
            analyzerFormat: analyzerFormat,
            converter: converter,
            analyzer: analyzer,
            continuation: continuation,
            analysisTask: analysisTask,
            resultsTask: resultsTask
        )
    }

    public func push(_ data: Data) throws {
        guard !finished else { return }
        byteCarry.append(data)
        let bytesPerFrame = inputFormat.channels * inputFormat.sampleWidth
        let completeBytes = byteCarry.count - (byteCarry.count % bytesPerFrame)
        guard completeBytes > 0 else { return }

        let frameCount = completeBytes / bytesPerFrame
        inputFrames += Int64(frameCount)
        if Double(inputFrames) / Double(inputFormat.sampleRate) > 60.0 {
            throw AppleSpeechError.limitExceeded("audio session exceeds 60 seconds")
        }
        let chunk = byteCarry.prefix(completeBytes)
        byteCarry.removeFirst(completeBytes)

        guard let input = AVAudioPCMBuffer(
            pcmFormat: sourceFormat,
            frameCapacity: AVAudioFrameCount(frameCount)
        ) else {
            throw AppleSpeechError.internalFailure("Cannot allocate STT input buffer")
        }
        input.frameLength = AVAudioFrameCount(frameCount)
        var audioBuffer = UnsafeMutableAudioBufferListPointer(input.mutableAudioBufferList).first!
        chunk.withUnsafeBytes { bytes in
            if let base = bytes.baseAddress, let target = audioBuffer.mData {
                target.copyMemory(from: base, byteCount: completeBytes)
            }
        }
        audioBuffer.mDataByteSize = UInt32(completeBytes)

        if let converter {
            let ratio = analyzerFormat.sampleRate / sourceFormat.sampleRate
            let capacity = AVAudioFrameCount(max(64, Int(ceil(Double(frameCount) * ratio)) + 64))
            guard let output = AVAudioPCMBuffer(pcmFormat: analyzerFormat, frameCapacity: capacity) else {
                throw AppleSpeechError.internalFailure("Cannot allocate analyzer buffer")
            }
            let inputBox = STTConverterInputBox(input)
            var conversionError: NSError?
            let status = converter.convert(to: output, error: &conversionError) { _, inputStatus in
                guard let input = inputBox.take() else {
                    inputStatus.pointee = .noDataNow
                    return nil
                }
                inputStatus.pointee = .haveData
                return input
            }
            guard status != .error, conversionError == nil else {
                throw AppleSpeechError.invalidAudioFormat(
                    conversionError?.localizedDescription ?? "PCM conversion failed"
                )
            }
            if output.frameLength > 0 { continuation.yield(AnalyzerInput(buffer: output)) }
        } else {
            continuation.yield(AnalyzerInput(buffer: input))
        }
    }

    public func finish() async throws -> String {
        guard !finished else { return "" }
        finished = true
        guard byteCarry.isEmpty else {
            await analyzer.cancelAndFinishNow()
            continuation.finish()
            throw AppleSpeechError.invalidAudioFormat("audio payload ends inside a PCM frame")
        }
        continuation.finish()
        try await analyzer.finalizeAndFinishThroughEndOfInput()
        try await analysisTask.value
        let phrases = try await resultsTask.value
        return phrases.joined(separator: " ")
    }

    public func cancel() async {
        guard !finished else { return }
        finished = true
        continuation.finish()
        await analyzer.cancelAndFinishNow()
        analysisTask.cancel()
        resultsTask.cancel()
    }
}

private final class STTConverterInputBox: @unchecked Sendable {
    private let lock = NSLock()
    private var input: AVAudioPCMBuffer?

    init(_ input: AVAudioPCMBuffer) {
        self.input = input
    }

    func take() -> AVAudioPCMBuffer? {
        lock.lock()
        defer {
            input = nil
            lock.unlock()
        }
        return input
    }
}
