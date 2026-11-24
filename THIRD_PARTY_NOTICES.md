# Third-party notices

## okay_nabu wake-word classifier

`Sources/WakeWord/Resources/okay_nabu.onnx` is a mechanically converted form
of `pyopen_wakeword/models/okay_nabu.tflite` from
[`rhasspy/pyopen-wakeword`](https://github.com/rhasspy/pyopen-wakeword), commit
`6bc5c5f5c9c71e46a723b6c9277b1d50f2ba13fd`.

- Upstream TFLite SHA-256:
  `2982cecde4ee81cc7a2573d2602a7d54f0669425c94a7b64af77e0ff92b03a18`
- Bundled ONNX SHA-256:
  `26b81f8cec2ba844c36262de0f05c88f3559f127a4b6d65ee5ab778c67e5e492`
- Upstream repository license: Apache License 2.0.
- The conversion is reproducible with `scripts/convert-okay-nabu.py` and does
  not change the learned weights.

The wake-word runtime uses
[`livekit/livekit-wakeword`](https://github.com/livekit/livekit-wakeword),
licensed under the Apache License 2.0, and its ONNX Runtime dependency.

`Tests/WakeWordTests/Fixtures/okay_nabu_positive.wav` comes from the same
`rhasspy/pyopen-wakeword` commit (`tests/okay_nabu/1.wav`) and has SHA-256
`c19747e603b00db74eb53ee2a65ae0489dd9feb574a9e98683fc3be8740b6c66`.

## hey_jarvis wake-word classifier

`Sources/WakeWord/Resources/hey_jarvis.onnx` is the `hey_jarvis_v0.1.onnx`
classifier published with
[`dscripka/openWakeWord` v0.5.1](https://github.com/dscripka/openWakeWord/releases/tag/v0.5.1).
Only its input and output tensor names were changed to the names required by
the Swift runtime; learned weights and graph operations are unchanged.

- Upstream ONNX SHA-256:
  `94a13cfe60075b132f6a472e7e462e8123ee70861bc3fb58434a73712ee0d2cb`
- Prepared ONNX SHA-256:
  `a081216ab2a339998bfca7d834c952721803fc7669434d19e80e68c80e81f819`
- Model license: Creative Commons Attribution-NonCommercial-ShareAlike 4.0
  International (CC BY-NC-SA 4.0).
- Preparation is reproducible with `scripts/prepare-hey-jarvis.py`.
