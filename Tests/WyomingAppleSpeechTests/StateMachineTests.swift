import XCTest
import AppleSpeech
import WyomingProtocol
@testable import WyomingAppleSpeech

final class StateMachineTests: XCTestCase {
    func testPunctuationFlushesStreamingText() {
        var text = "First phrase. Second"
        XCTAssertEqual(StreamingTextSegmenter.takeSegments(from: &text), ["First phrase."])
        XCTAssertEqual(text, "Second")
    }

    func testLongTextFlushesAtLastSpaceBeforeThreshold() {
        var text = String(repeating: "a", count: 200) + " " + String(repeating: "b", count: 80)
        let result = StreamingTextSegmenter.takeSegments(from: &text)
        XCTAssertEqual(result, [String(repeating: "a", count: 200)])
        XCTAssertEqual(text, String(repeating: "b", count: 80))
    }

    func testForceFlushesRemainder() {
        var text = "  remainder without punctuation  "
        XCTAssertEqual(StreamingTextSegmenter.takeSegments(from: &text, force: true), ["remainder without punctuation"])
        XCTAssertTrue(text.isEmpty)
    }

    func testLimiterReportsBusyAndRecovers() async {
        let limiter = SlotLimiter(limit: 1)
        let first = await limiter.acquire()
        let second = await limiter.acquire()
        XCTAssertTrue(first)
        XCTAssertFalse(second)
        await limiter.release()
        let third = await limiter.acquire()
        XCTAssertTrue(third)
    }

    func testAudioChunksBypassLoggerUnlessExplicitlyEnabled() {
        XCTAssertFalse(EventLoggingPolicy.shouldSendToLogger(
            eventType: WyomingEventType.audioChunk,
            logAudioChunks: false
        ))
        XCTAssertTrue(EventLoggingPolicy.shouldSendToLogger(
            eventType: WyomingEventType.audioChunk,
            logAudioChunks: true
        ))
        XCTAssertTrue(EventLoggingPolicy.shouldSendToLogger(
            eventType: WyomingEventType.audioStart,
            logAudioChunks: false
        ))
    }

    func testServiceDescriptionPublishesAllWakeModels() throws {
        let info = ServiceDescription.info(
            voices: [],
            stt: STTAssetState(
                language: "ru-RU",
                supported: true,
                installed: true,
                status: "installed"
            ),
            language: "ru-RU"
        )
        guard let wakeValue = info.data["wake"],
              case let .array(programs) = wakeValue,
              let firstProgram = programs.first,
              case let .object(program) = firstProgram,
              let modelsValue = program["models"],
              case let .array(models) = modelsValue else {
            return XCTFail("Missing wake program/model in info")
        }
        let modelObjects = models.compactMap { value -> [String: JSONValue]? in
            guard case let .object(model) = value else { return nil }
            return model
        }
        XCTAssertEqual(
            modelObjects.compactMap { $0["name"]?.stringValue },
            ["okay_nabu", "hey_jarvis"]
        )
        XCTAssertEqual(
            modelObjects.compactMap { $0["phrase"]?.stringValue },
            ["Okay Nabu", "Hey Jarvis"]
        )
        XCTAssertTrue(modelObjects.allSatisfy { $0["installed"] == .bool(true) })
    }

    func testServiceDescriptionUsesStableProgramNamesAndReadableVoiceDescriptions() throws {
        let info = ServiceDescription.info(
            voices: [
                VoiceDescriptor(
                    identifier: "enhanced",
                    name: "Katya (Enhanced)",
                    language: "ru-RU",
                    quality: "enhanced",
                    qualityRank: 2
                ),
                VoiceDescriptor(
                    identifier: "default",
                    name: "Katya",
                    language: "ru-RU",
                    quality: "default",
                    qualityRank: 1
                ),
            ],
            stt: STTAssetState(
                language: "ru-RU",
                supported: true,
                installed: true,
                status: "installed"
            ),
            language: "ru-RU"
        )

        XCTAssertEqual(programName(in: info, domain: "asr"), "Apple Speech STT")
        XCTAssertEqual(programName(in: info, domain: "tts"), "Apple Speech TTS")
        XCTAssertEqual(programName(in: info, domain: "wake"), "Apple Wyoming Wake Word")
        XCTAssertEqual(
            voiceDescriptions(in: info),
            ["Katya (Enhanced)", "Katya"]
        )
    }

    private func programName(in info: WyomingEvent, domain: String) -> String? {
        guard case let .array(programs)? = info.data[domain],
              case let .object(program)? = programs.first else {
            return nil
        }
        return program["name"]?.stringValue
    }

    private func voiceDescriptions(in info: WyomingEvent) -> [String] {
        guard case let .array(programs)? = info.data["tts"],
              case let .object(program)? = programs.first,
              case let .array(voices)? = program["voices"] else {
            return []
        }
        return voices.compactMap { value in
            guard case let .object(voice) = value else { return nil }
            return voice["description"]?.stringValue
        }
    }
}
