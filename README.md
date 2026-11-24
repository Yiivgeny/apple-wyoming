# Wyoming Apple Speech

A native, local Wyoming service for Home Assistant on Apple Silicon with macOS 26:

- TTS: `AVSpeechSynthesizer.write` streams PCM without speaker playback;
- STT: `SpeechAnalyzer` + `DictationTranscriber` use the local `ru-RU` model;
- wake word: `okay_nabu` and `hey_jarvis` use openWakeWord ONNX models and the
  CoreML Execution Provider;
- one TCP endpoint for TTS, STT, and wake word, defaulting to `0.0.0.0:10700`;
- Bonjour `_wyoming._tcp.local.` discovery for Home Assistant;
- no Python, Docker, intermediate WAV files, or cloud requests in the service's
  audio processing path.

Requirements: Apple Silicon, macOS 26, and Swift 6.2+. Intel and macOS 15 are not supported.

## Quick start

Check available resources and prepare the local speech model:

```shell
swift run wyoming-apple-speech voices
swift run wyoming-apple-speech locales
swift run wyoming-apple-speech prepare --language ru-RU
swift run wyoming-apple-speech doctor
```

Run the service manually:

```shell
swift run -c release wyoming-apple-speech serve \
  --host 0.0.0.0 --port 10700 --language ru-RU
```

Install the release binary and a user LaunchAgent:

```shell
./scripts/install.sh
```

Uninstall the service:

```shell
./scripts/uninstall.sh
```

The installer copies the binary to
`~/Library/Application Support/Wyoming Apple Speech/bin`, prepares the STT assets,
and registers `local.wyoming.apple-speech` in the current user's GUI session.

## Home Assistant

First, make sure `doctor` completes successfully. Home Assistant normally discovers
this service through Bonjour as **Apple Wyoming Voice**. If mDNS does not cross your
VLANs, add the Wyoming integration manually using the Mac's IP address and port
`10700`.

One integration entry exposes three capabilities:

- ASR: `Apple Speech STT`, with the `ru-RU` model;
- TTS: `Apple Speech TTS`, with all installed Russian Apple voices;
- wake word: `Apple Wyoming Wake Word`, with `okay_nabu` (**Okay Nabu**) and
  `hey_jarvis` (**Hey Jarvis**).

The program names are stable. Home Assistant exposes them as
`stt.apple_speech_stt`, `tts.apple_speech_tts`, and
`wake_word.apple_wyoming_wake_word`. The selected wake-word model is stored in the
pipeline separately from the entity (`okay_nabu` or `hey_jarvis`).

Wyoming voice IDs are the full Apple voice identifiers. The default is the highest
available quality of Milena. Voice-list changes are picked up without restarting
the service.

## CLI

```text
serve [--host HOST] [--port PORT] [--language ru-RU]
      [--voice APPLE_IDENTIFIER] [--rate FLOAT] [--pitch FLOAT] [--volume FLOAT]
      [--max-connections 16] [--max-tts-sessions 2] [--max-stt-sessions 1]
      [--wake-threshold 0.5] [--wake-trigger-level 1]
      [--idle-timeout 120] [--no-mdns] [--log-audio-chunks]
prepare [--language ru-RU]
voices
locales
doctor [--language ru-RU]
```

`rate`, `pitch`, and `volume` are not overridden by default; the service uses the
system defaults from `AVSpeechUtterance`. Accepted CLI ranges are `0...1` for rate,
`0.5...2` for pitch, and `0...1` for volume.

## Latency optimization

The service prewarms the speech engines at startup:

- `SpeechAnalyzer` uses `userInitiated` priority and requests that the local model
  remain in memory for the process lifetime (`modelRetention: processLifetime`);
- each TTS slot creates and prewarms its own `AVSpeechSynthesizer`; synthesizers
  return to the pool and are reused for subsequent requests and streaming segments;
- the openWakeWord mel, embedding, and classifier models run through ONNX Runtime
  during prewarming. The CoreML Execution Provider handles supported operations,
  with ONNX Runtime CPU kernels handling unsupported operations.

The TTS pool size matches `--max-tts-sessions` and defaults to two. Keeping these
resources ready increases resident memory use and avoids cold model loading during
the first user request.

## Protocol and limits

- Wyoming JSONL framing with `data_length`, `payload_length`, and TCP fragmentation
  support;
- maximum header size: 64 KiB; data: 1 MiB; payload: 4 MiB;
- idle timeout: 120 seconds;
- TTS accepts up to 4096 plain-text characters; SSML and speaker selection are
  rejected;
- STT accepts mono or stereo signed Int16 little-endian PCM at 8-48 kHz, with a
  maximum duration of 60 seconds;
- streaming TTS splits text at `.?!;:` or newlines, or at a space when buffered
  text exceeds 240 characters;
- streaming STT emits finalized phrase chunks and a required final `transcript`;
- wake word accepts Wyoming `detect -> audio-start/chunk/stop` and responds with
  `detection` or `not-detected`; input must be 16 kHz mono S16LE;
- `detect.names` selects the active models. A null or empty list enables all
  models; `detection.name` identifies the winning model;
- detection uses a two-second sliding window, an 80 ms hop, a default threshold of
  `0.5`, and a default trigger level of one;
- stable error codes: `invalid-event`, `invalid-audio-format`,
  `unsupported-language`, `unknown-voice`, `model-not-installed`, `busy`,
  `limit-exceeded`, and `internal-error`.

If STT assets are missing, TTS remains available and `info` advertises ASR with
`installed=false`.

## Security and privacy

The service has no TLS or authentication and is intended for a trusted LAN. Do not
expose port `10700` to the internet. PCM audio is never logged. Text is omitted at
the info level; debug logging includes actual `tts_text` and final
`stt_transcript` values. Unified Logging also records session IDs, event types,
durations, PCM sizes, and errors. Frequent `audio-chunk` events bypass `Logger` by
default; use `--log-audio-chunks` to temporarily enable them at the debug level.

View regular logs:

```shell
/usr/bin/log stream --style compact --level info \
  --predicate 'subsystem == "local.wyoming.apple-speech"'
```

View all phases, including actual `tts_text` and `stt_transcript` values:

```shell
/usr/bin/log stream --style compact --level debug \
  --predicate 'subsystem == "local.wyoming.apple-speech"'
```

## Tests

Run the Swift unit, state, and engine tests:

```shell
swift test
```

Run black-box tests with the official Wyoming Python clients, versions 1.7.2 and
1.10.0. Python is used only for testing:

```shell
swift run wyoming-apple-speech serve --host 127.0.0.1 --no-mdns
./scripts/test-integration.sh
```

The Home Assistant acceptance helper is available at
`Tests/Integration/ha_acceptance.py`. It never prints the access token. It discovers
the current Apple STT/TTS entity IDs, creates a temporary Assist pipeline, reads
pipeline debug data, and removes the test configuration:

```shell
export HA_TOKEN_MAIN='...'
uv run --with websockets python Tests/Integration/ha_acceptance.py inspect
uv run --with websockets python Tests/Integration/ha_acceptance.py create-pipeline
uv run --with websockets python Tests/Integration/ha_acceptance.py \
  debug-pipeline --pipeline-id PIPELINE_ID
uv run --with websockets python Tests/Integration/ha_acceptance.py \
  delete-pipeline --pipeline-id PIPELINE_ID
```

`doctor` checks framing, loads both wake-word models through CoreML, and performs
a local, in-memory TTS-to-STT loopback using a Russian command meaning "Turn on the
living room lights", without speaker playback or files. Russian speech literals
in `doctor` and the STT loopback tests are intentional `ru-RU` test data.

## Project structure

- `Sources/WyomingProtocol`: events and the NIO codec;
- `Sources/AppleSpeech`: voice registry, PCM TTS, assets, and streaming STT;
- `Sources/WakeWord`: openWakeWord ONNX pipeline, CoreML inference, and the
  streaming window;
- `Sources/WyomingAppleSpeech`: state machines, TCP server, Bonjour, and CLI;
- `scripts`: installation, removal, and integration tests.

## Wake-word models and licenses

`okay_nabu.onnx` is mechanically converted from the weights in
`rhasspy/pyopen-wakeword`'s `okay_nabu.tflite`. The conversion is reproducible with
`scripts/convert-okay-nabu.py`. Python is needed only to regenerate the artifact
and is not used by the running service.

`hey_jarvis.onnx` is prepared from the official `dscripka/openWakeWord` v0.5.1 model
using `scripts/prepare-hey-jarvis.py`. The model is distributed under
CC BY-NC-SA 4.0 and is restricted to noncommercial use. Source SHA-256 hashes,
versions, and third-party notices are recorded in `THIRD_PARTY_NOTICES.md`.
