import Foundation
import XCTest
@testable import WakeWord

final class WakeWordEngineTests: XCTestCase {
    func testStreamingSessionWaitsForCompleteWindow() async throws {
        let recorder = ScoreRecorder(scores: ["okay_nabu": 0.1])
        let session = try WakeWordDetectionSession(
            threshold: 0.5,
            triggerLevel: 1
        ) { samples in
            await recorder.evaluate(samples)
        }

        let almostTwoSeconds = pcmData(
            Array(repeating: 0, count: WakeWordDetectionSession.windowSamples - 1)
        )
        let earlyDetection = try await session.accept(almostTwoSeconds)
        let callsBeforeWindow = await recorder.callCount()
        XCTAssertNil(earlyDetection)
        XCTAssertEqual(callsBeforeWindow, 0)

        let fullWindowDetection = try await session.accept(pcmData([0]))
        let callsAfterWindow = await recorder.callCount()
        let lastSampleCount = await recorder.lastSampleCount()
        XCTAssertNil(fullWindowDetection)
        XCTAssertEqual(callsAfterWindow, 1)
        XCTAssertEqual(lastSampleCount, WakeWordDetectionSession.windowSamples)
    }

    func testTriggerLevelRequiresMultipleScoresAboveThreshold() async throws {
        let recorder = ScoreRecorder(scores: ["okay_nabu": 0.9])
        let session = try WakeWordDetectionSession(
            threshold: 0.5,
            triggerLevel: 2
        ) { samples in
            await recorder.evaluate(samples)
        }

        let firstScore = try await session.accept(pcmData(
            Array(repeating: 0, count: WakeWordDetectionSession.windowSamples)
        ))
        XCTAssertNil(firstScore)
        let detection = try await session.accept(pcmData(
            Array(repeating: 0, count: WakeWordDetectionSession.hopSamples)
        ))
        XCTAssertEqual(detection?.name, "okay_nabu")
        XCTAssertEqual(detection?.confidence, 0.9)
        XCTAssertEqual(detection?.timestampMilliseconds, 2_080)
        let hasDetected = await session.hasDetected()
        XCTAssertTrue(hasDetected)
    }

    func testRequestedModelFiltersHigherScoreFromAnotherModel() async throws {
        let recorder = ScoreRecorder(scores: [
            "okay_nabu": 0.99,
            "hey_jarvis": 0.8,
        ])
        let session = try WakeWordDetectionSession(
            threshold: 0.5,
            triggerLevel: 1,
            modelNames: ["hey_jarvis"]
        ) { samples in
            await recorder.evaluate(samples)
        }

        let detection = try await session.accept(pcmData(
            Array(repeating: 0, count: WakeWordDetectionSession.windowSamples)
        ))

        XCTAssertEqual(detection?.name, "hey_jarvis")
        XCTAssertEqual(detection?.confidence, 0.8)
    }

    func testHighestConfidenceWinsWhenMultipleModelsTrigger() async throws {
        let recorder = ScoreRecorder(scores: [
            "okay_nabu": 0.7,
            "hey_jarvis": 0.9,
        ])
        let session = try WakeWordDetectionSession(
            threshold: 0.5,
            triggerLevel: 1
        ) { samples in
            await recorder.evaluate(samples)
        }

        let detection = try await session.accept(pcmData(
            Array(repeating: 0, count: WakeWordDetectionSession.windowSamples)
        ))

        XCTAssertEqual(detection?.name, "hey_jarvis")
        XCTAssertEqual(detection?.confidence, 0.9)
    }

    func testTriggerLevelIsTrackedPerModel() async throws {
        let recorder = ScoreSequenceRecorder(scores: [
            ["okay_nabu": 0.9, "hey_jarvis": 0.1],
            ["okay_nabu": 0.1, "hey_jarvis": 0.9],
            ["okay_nabu": 0.1, "hey_jarvis": 0.9],
        ])
        let session = try WakeWordDetectionSession(
            threshold: 0.5,
            triggerLevel: 2
        ) { samples in
            await recorder.evaluate(samples)
        }

        let firstScore = try await session.accept(pcmData(
            Array(repeating: 0, count: WakeWordDetectionSession.windowSamples)
        ))
        let secondScore = try await session.accept(pcmData(
            Array(repeating: 0, count: WakeWordDetectionSession.hopSamples)
        ))
        let detection = try await session.accept(pcmData(
            Array(repeating: 0, count: WakeWordDetectionSession.hopSamples)
        ))

        XCTAssertNil(firstScore)
        XCTAssertNil(secondScore)
        XCTAssertEqual(detection?.name, "hey_jarvis")
        XCTAssertEqual(detection?.timestampMilliseconds, 2_160)
    }

    func testRejectsUnknownRequestedModel() {
        XCTAssertThrowsError(try WakeWordDetectionSession(
            threshold: 0.5,
            triggerLevel: 1,
            modelNames: ["unknown"]
        ) { _ in
            [:]
        }) { error in
            guard case let WakeWordError.invalidConfiguration(reason) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertTrue(reason.contains("unknown"))
        }
    }

    func testBundledOkayNabuModelDetectsUpstreamPositiveFixture() async throws {
        XCTAssertEqual(WakeWordEngine.modelNames, ["okay_nabu", "hey_jarvis"])
        let engine = try WakeWordEngine()
        try await engine.prewarm()
        let session = try WakeWordDetectionSession(
            engine: engine,
            modelNames: ["okay_nabu"]
        )
        let waveURL = try XCTUnwrap(
            Bundle.module.url(
                forResource: "okay_nabu_positive",
                withExtension: "wav",
                subdirectory: "Fixtures"
            )
        )
        let pcm = try wavePCMData(at: waveURL)

        var detection: WakeWordDetection?
        for offset in stride(from: 0, to: pcm.count, by: 2_048) {
            detection = try await session.accept(
                pcm.subdata(in: offset..<min(offset + 2_048, pcm.count))
            ) ?? detection
        }

        XCTAssertEqual(detection?.name, "okay_nabu")
        XCTAssertGreaterThan(detection?.confidence ?? 0, 0.5)
    }

    func testRejectsOddS16LEPayload() async throws {
        let recorder = ScoreRecorder(scores: ["okay_nabu": 0])
        let session = try WakeWordDetectionSession(
            threshold: 0.5,
            triggerLevel: 1
        ) { samples in
            await recorder.evaluate(samples)
        }

        do {
            _ = try await session.accept(Data([0]))
            XCTFail("Expected invalid audio error")
        } catch let error as WakeWordError {
            guard case .invalidAudio = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    private func pcmData(_ samples: [Int16]) -> Data {
        var data = Data(capacity: samples.count * 2)
        for sample in samples {
            let value = UInt16(bitPattern: sample)
            data.append(UInt8(truncatingIfNeeded: value))
            data.append(UInt8(truncatingIfNeeded: value >> 8))
        }
        return data
    }

    private func wavePCMData(at url: URL) throws -> Data {
        let wave = try Data(contentsOf: url)
        guard wave.count >= 44,
              String(decoding: wave[0..<4], as: UTF8.self) == "RIFF",
              String(decoding: wave[8..<12], as: UTF8.self) == "WAVE" else {
            throw WakeWordError.invalidAudio("test fixture is not a RIFF/WAVE file")
        }

        var offset = 12
        while offset + 8 <= wave.count {
            let name = String(decoding: wave[offset..<(offset + 4)], as: UTF8.self)
            let size = Int(wave[offset + 4])
                | (Int(wave[offset + 5]) << 8)
                | (Int(wave[offset + 6]) << 16)
                | (Int(wave[offset + 7]) << 24)
            let start = offset + 8
            let end = start + size
            guard end <= wave.count else {
                throw WakeWordError.invalidAudio("truncated WAVE chunk")
            }
            if name == "data" { return wave.subdata(in: start..<end) }
            offset = end + (size % 2)
        }
        throw WakeWordError.invalidAudio("WAVE file has no data chunk")
    }
}

private actor ScoreRecorder {
    private let scores: [String: Float]
    private var calls = 0
    private var sampleCount = 0

    init(scores: [String: Float]) { self.scores = scores }

    func evaluate(_ samples: [Int16]) -> [String: Float] {
        calls += 1
        sampleCount = samples.count
        return scores
    }

    func callCount() -> Int { calls }
    func lastSampleCount() -> Int { sampleCount }
}

private actor ScoreSequenceRecorder {
    private let scores: [[String: Float]]
    private var index = 0

    init(scores: [[String: Float]]) { self.scores = scores }

    func evaluate(_: [Int16]) -> [String: Float] {
        let current = scores[min(index, scores.count - 1)]
        index += 1
        return current
    }
}
