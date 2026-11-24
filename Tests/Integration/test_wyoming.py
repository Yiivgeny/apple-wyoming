#!/usr/bin/env python3
"""Black-box compatibility check using the official Wyoming Python client."""

import argparse
import asyncio
from pathlib import Path
import wave

from wyoming.asr import Transcribe, Transcript
from wyoming.audio import AudioChunk, AudioStart, AudioStop
from wyoming.client import AsyncTcpClient
from wyoming.info import Describe, Info
from wyoming.tts import (
    Synthesize,
    SynthesizeChunk,
    SynthesizeStart,
    SynthesizeStop,
    SynthesizeStopped,
)
from wyoming.wake import Detect, Detection, NotDetected


FIXTURE_PATH = (
    Path(__file__).parents[1]
    / "WakeWordTests"
    / "Fixtures"
    / "okay_nabu_positive.wav"
)

# Russian speech fixtures for the ru-RU STT model: "Turn on the living room lights".
SPEECH_PREFIX = "Включи свет "
SPEECH_SUFFIX = "в гостиной"
SPEECH_TEXT = SPEECH_PREFIX + SPEECH_SUFFIX


async def read_audio(client: AsyncTcpClient, streaming: bool = False):
    rate = None
    pcm = bytearray()
    saw_stopped = False
    while True:
        event = await asyncio.wait_for(client.read_event(), timeout=30)
        assert event is not None
        if AudioStart.is_type(event.type):
            start = AudioStart.from_event(event)
            assert start.width == 2
            assert start.channels == 1
            rate = start.rate
        elif AudioChunk.is_type(event.type):
            pcm.extend(AudioChunk.from_event(event).audio)
        elif AudioStop.is_type(event.type):
            if not streaming:
                break
        elif SynthesizeStopped.is_type(event.type):
            saw_stopped = True
            break
        elif event.type == "error":
            raise AssertionError(event.data)

    assert rate is not None
    assert pcm
    if streaming:
        assert saw_stopped
    return rate, bytes(pcm)


async def transcribe(client: AsyncTcpClient, rate: int, pcm: bytes):
    await client.write_event(Transcribe(language="ru-RU").event())
    await client.write_event(AudioStart(rate=rate, width=2, channels=1).event())
    for offset in range(0, len(pcm), 4096):
        await client.write_event(
            AudioChunk(
                rate=rate,
                width=2,
                channels=1,
                audio=pcm[offset : offset + 4096],
            ).event()
        )
    await client.write_event(AudioStop().event())

    transcript = None
    event_types = []
    while True:
        event = await asyncio.wait_for(client.read_event(), timeout=30)
        assert event is not None
        event_types.append(event.type)
        if Transcript.is_type(event.type):
            transcript = Transcript.from_event(event).text
        elif event.type == "transcript-stop":
            break
        elif event.type == "error":
            raise AssertionError(event.data)

    assert event_types[0] == "transcript-start"
    assert "transcript-chunk" in event_types
    assert transcript
    assert SPEECH_PREFIX.strip().lower() in transcript.lower()
    return transcript


async def detect_wake_word(client: AsyncTcpClient):
    context = {"test": "apple-wyoming"}
    with wave.open(str(FIXTURE_PATH), "rb") as fixture:
        assert fixture.getframerate() == 16000
        assert fixture.getsampwidth() == 2
        assert fixture.getnchannels() == 1
        pcm = fixture.readframes(fixture.getnframes())

    await client.write_event(
        Detect(names=["okay_nabu", "hey_jarvis"], context=context).event()
    )
    await client.write_event(AudioStart(rate=16000, width=2, channels=1).event())
    for offset in range(0, len(pcm), 2048):
        await client.write_event(
            AudioChunk(
                rate=16000,
                width=2,
                channels=1,
                audio=pcm[offset : offset + 2048],
            ).event()
        )
    await client.write_event(AudioStop().event())
    event = await asyncio.wait_for(client.read_event(), timeout=30)
    assert event is not None and Detection.is_type(event.type), event
    detection = Detection.from_event(event)
    assert detection.name == "okay_nabu"
    assert detection.context == context

    await client.write_event(Detect(names=["hey_jarvis"], context=context).event())
    await client.write_event(AudioStart(rate=16000, width=2, channels=1).event())
    silence = bytes(16000 * 2 * 2)
    for offset in range(0, len(silence), 2048):
        await client.write_event(
            AudioChunk(
                rate=16000,
                width=2,
                channels=1,
                audio=silence[offset : offset + 2048],
            ).event()
        )
    await client.write_event(AudioStop().event())
    event = await asyncio.wait_for(client.read_event(), timeout=30)
    assert event is not None and NotDetected.is_type(event.type), event
    assert NotDetected.from_event(event).context == context


async def run(host: str, port: int):
    async with AsyncTcpClient(host, port) as client:
        await client.write_event(Describe().event())
        event = await asyncio.wait_for(client.read_event(), timeout=5)
        assert event is not None and Info.is_type(event.type)
        info = Info.from_event(event)
        assert info.asr and info.asr[0].installed
        assert info.tts and info.tts[0].installed
        assert info.wake and info.wake[0].installed
        assert [model.name for model in info.wake[0].models] == [
            "okay_nabu",
            "hey_jarvis",
        ]
        assert info.asr[0].supports_transcript_streaming
        assert info.tts[0].supports_synthesize_streaming

        await detect_wake_word(client)

        await client.write_event(Synthesize(text=SPEECH_TEXT).event())
        rate, pcm = await read_audio(client)
        transcript = await transcribe(client, rate, pcm)

        await client.write_event(SynthesizeStart().event())
        await client.write_event(SynthesizeChunk(text=SPEECH_PREFIX).event())
        await client.write_event(SynthesizeChunk(text=SPEECH_SUFFIX + ".").event())
        # Home Assistant may include this compatibility event after streaming chunks.
        await client.write_event(Synthesize(text=SPEECH_TEXT + ".").event())
        await client.write_event(SynthesizeStop().event())
        stream_rate, stream_pcm = await read_audio(client, streaming=True)
        stream_transcript = await transcribe(client, stream_rate, stream_pcm)

        print(
            f"ok describe/wake, standard TTS/STT={transcript!r}, "
            f"streaming TTS/STT={stream_transcript!r}"
        )


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=10700)
    args = parser.parse_args()
    asyncio.run(run(args.host, args.port))


if __name__ == "__main__":
    main()
