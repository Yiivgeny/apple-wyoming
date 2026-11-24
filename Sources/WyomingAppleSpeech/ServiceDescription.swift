import AppleSpeech
import Foundation
import WakeWord
import WyomingProtocol

public enum ServiceDescription {
    public static func info(
        voices: [VoiceDescriptor],
        stt: STTAssetState,
        language: String
    ) -> WyomingEvent {
        let voiceValues = voices.map { voice in
            JSONValue.object([
                "name": .string(voice.identifier),
                "description": .string(voiceDescription(voice)),
                "languages": .array([.string(voice.language)]),
                "installed": .bool(true),
                "attribution": appleAttribution,
            ])
        }
        let asrModel: JSONValue = .object([
            "name": .string(language),
            "description": .string("Apple on-device Dictation model for \(language)"),
            "languages": .array([.string(language)]),
            "installed": .bool(stt.installed),
            "attribution": appleAttribution,
        ])
        let asrProgram: JSONValue = .object([
            "name": .string("Apple Speech STT"),
            "description": .string("Local SpeechAnalyzer + DictationTranscriber"),
            "version": .string("macOS 26"),
            "installed": .bool(stt.installed),
            "supports_transcript_streaming": .bool(true),
            "models": .array([asrModel]),
            "attribution": appleAttribution,
        ])
        let ttsProgram: JSONValue = .object([
            "name": .string("Apple Speech TTS"),
            "description": .string("Local AVSpeechSynthesizer PCM streaming"),
            "version": .string("macOS 26"),
            "installed": .bool(!voices.isEmpty),
            "supports_synthesize_streaming": .bool(true),
            "voices": .array(voiceValues),
            "attribution": appleAttribution,
        ])
        let wakeAttribution: JSONValue = .object([
            "name": .string("openWakeWord"),
            "url": .string("https://github.com/dscripka/openWakeWord"),
        ])
        let wakeModels = WakeWordEngine.descriptors.map { wake in
            JSONValue.object([
                "name": .string(wake.name),
                "description": .string(wake.phrase),
                "version": .string(wake.version),
                "languages": .array([.string(wake.language)]),
                "phrase": .string(wake.phrase),
                "installed": .bool(true),
                "attribution": wakeAttribution,
            ])
        }
        let wakeProgram: JSONValue = .object([
            "name": .string("Apple Wyoming Wake Word"),
            "description": .string("Local openWakeWord inference through CoreML"),
            "version": .string("LiveKit WakeWord"),
            "installed": .bool(true),
            "models": .array(wakeModels),
            "attribution": wakeAttribution,
        ])
        return WyomingEvent(type: WyomingEventType.info, data: [
            "asr": .array([asrProgram]),
            "tts": .array([ttsProgram]),
            "wake": .array([wakeProgram]),
        ])
    }

    private static let appleAttribution: JSONValue = .object([
        "name": .string("Apple"),
        "url": .string("https://www.apple.com/"),
    ])

    private static func voiceDescription(_ voice: VoiceDescriptor) -> String {
        guard voice.quality.caseInsensitiveCompare("default") != .orderedSame else {
            return voice.name
        }

        if voice.name.range(of: voice.quality, options: .caseInsensitive) != nil {
            return voice.name
        }

        return "\(voice.name) (\(voice.quality.capitalized))"
    }
}
