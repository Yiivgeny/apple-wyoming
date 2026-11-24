#!/usr/bin/env python3
"""Home Assistant acceptance helper. Never prints the access token."""

import argparse
import asyncio
import json
import os
from urllib.parse import urlparse
from urllib.request import Request, urlopen

import websockets


class HomeAssistantWS:
    def __init__(self, url: str, token: str):
        parsed = urlparse(url)
        scheme = "wss" if parsed.scheme == "https" else "ws"
        self.http_url = f"{parsed.scheme}://{parsed.netloc}"
        self.websocket_url = f"{scheme}://{parsed.netloc}/api/websocket"
        self.token = token
        self.ws = None
        self.message_id = 0

    async def __aenter__(self):
        self.ws = await websockets.connect(self.websocket_url, max_size=8 * 1024 * 1024)
        required = json.loads(await self.ws.recv())
        assert required["type"] == "auth_required", required
        await self.ws.send(json.dumps({"type": "auth", "access_token": self.token}))
        authenticated = json.loads(await self.ws.recv())
        assert authenticated["type"] == "auth_ok", authenticated
        return self

    async def __aexit__(self, *_):
        await self.ws.close()

    async def call(self, command_type: str, **payload):
        self.message_id += 1
        request = {"id": self.message_id, "type": command_type, **payload}
        await self.ws.send(json.dumps(request))
        while True:
            response = json.loads(await self.ws.recv())
            if response.get("id") != self.message_id:
                continue
            if not response.get("success"):
                raise RuntimeError(
                    f"{command_type}: {json.dumps(response.get('error'), ensure_ascii=False)}"
                )
            return response.get("result")

    async def post(self, path: str, payload: dict):
        def send():
            request = Request(
                f"{self.http_url}{path}",
                data=json.dumps(payload).encode(),
                method="POST",
                headers={
                    "Authorization": f"Bearer {self.token}",
                    "Content-Type": "application/json",
                },
            )
            with urlopen(request, timeout=30) as response:
                return json.load(response)

        return await asyncio.to_thread(send)


async def inspect(ha: HomeAssistantWS, satellite: str):
    entries = await ha.call("config_entries/get")
    wyoming = [entry for entry in entries if entry.get("domain") == "wyoming"]
    pipelines = await ha.call("assist_pipeline/pipeline/list")
    satellite_config = await ha.call(
        "assist_satellite/get_configuration", entity_id=satellite
    )
    print(json.dumps({
        "wyoming_entries": [{
            "entry_id": entry.get("entry_id"),
            "title": entry.get("title"),
            "state": entry.get("state"),
            "source": entry.get("source"),
        } for entry in wyoming],
        "pipelines": pipelines,
        "satellite": satellite_config,
    }, ensure_ascii=False, indent=2))


async def configure_wyoming(ha: HomeAssistantWS, host: str, port: int):
    entries = await ha.call("config_entries/get")
    for entry in entries:
        if entry.get("domain") == "wyoming" and (
            host in entry.get("title", "")
            or entry.get("title") == "Apple Speech STT"
            or entry.get("title") == "Apple Wyoming Voice"
        ):
            print(json.dumps({"existing": entry}, ensure_ascii=False, indent=2))
            return

    flow = await ha.post(
        "/api/config/config_entries/flow",
        {
            "handler": "wyoming",
            "show_advanced_options": False,
        },
    )
    if flow.get("type") != "form":
        print(json.dumps(flow, ensure_ascii=False, indent=2))
        return
    result = await ha.post(
        f"/api/config/config_entries/flow/{flow['flow_id']}",
        {"host": host, "port": port},
    )
    print(json.dumps(result, ensure_ascii=False, indent=2))


async def create_pipeline(ha: HomeAssistantWS):
    pipelines = await ha.call("assist_pipeline/pipeline/list")
    for pipeline in pipelines.get("pipelines", []):
        if pipeline.get("name") == "Apple Speech Test":
            print(json.dumps({"existing": pipeline}, ensure_ascii=False, indent=2))
            return

    states = await ha.call("get_states")

    def engine_id(domain: str, friendly_name: str) -> str:
        matches = [
            state["entity_id"]
            for state in states
            if state["entity_id"].startswith(f"{domain}.")
            and state.get("attributes", {}).get("friendly_name") == friendly_name
        ]
        if not matches:
            raise RuntimeError(f"Home Assistant entity not found: {friendly_name}")
        return matches[0]

    stt_engine = engine_id("stt", "Apple Speech STT")
    tts_engine = engine_id("tts", "Apple Speech TTS")
    wake_word_entity = engine_id("wake_word", "Apple Wyoming Wake Word")

    result = await ha.call(
        "assist_pipeline/pipeline/create",
        conversation_engine="conversation.google_gemini_flash_latest",
        conversation_language="*",
        language="ru",
        name="Apple Speech Test",
        stt_engine=stt_engine,
        stt_language="ru-RU",
        tts_engine=tts_engine,
        tts_language="ru-RU",
        tts_voice="com.apple.voice.compact.ru-RU.Milena",
        wake_word_entity=wake_word_entity,
        wake_word_id="okay_nabu",
        prefer_local_intents=False,
    )
    print(json.dumps({"created": result}, ensure_ascii=False, indent=2))


async def delete_pipeline(ha: HomeAssistantWS, pipeline_id: str):
    result = await ha.call(
        "assist_pipeline/pipeline/delete", pipeline_id=pipeline_id
    )
    print(json.dumps({"deleted": pipeline_id, "result": result}, ensure_ascii=False))


async def debug_pipeline(ha: HomeAssistantWS, pipeline_id: str):
    runs = await ha.call(
        "assist_pipeline/pipeline_debug/list", pipeline_id=pipeline_id
    )
    pipeline_runs = runs.get("pipeline_runs", [])
    if not pipeline_runs:
        print(json.dumps({"pipeline_runs": []}))
        return
    latest = pipeline_runs[-1]
    debug = await ha.call(
        "assist_pipeline/pipeline_debug/get",
        pipeline_id=pipeline_id,
        pipeline_run_id=latest["pipeline_run_id"],
    )
    print(json.dumps({"run": latest, "debug": debug}, ensure_ascii=False, indent=2))


async def main_async(args):
    token = os.environ.get("HA_TOKEN_MAIN")
    if not token:
        raise SystemExit("HA_TOKEN_MAIN is not set")
    async with HomeAssistantWS(args.url, token) as ha:
        if args.command == "inspect":
            await inspect(ha, args.satellite)
        elif args.command == "configure-wyoming":
            await configure_wyoming(ha, args.wyoming_host, args.wyoming_port)
        elif args.command == "create-pipeline":
            await create_pipeline(ha)
        elif args.command == "delete-pipeline":
            if not args.pipeline_id:
                raise SystemExit("--pipeline-id is required")
            await delete_pipeline(ha, args.pipeline_id)
        elif args.command == "debug-pipeline":
            if not args.pipeline_id:
                raise SystemExit("--pipeline-id is required")
            await debug_pipeline(ha, args.pipeline_id)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "command",
        choices=(
            "inspect",
            "configure-wyoming",
            "create-pipeline",
            "delete-pipeline",
            "debug-pipeline",
        ),
    )
    parser.add_argument("--url", default="http://localhost:8123")
    parser.add_argument(
        "--satellite",
        default="assist_satellite.waveshare_voice_satellite_assist_satellite",
    )
    parser.add_argument("--wyoming-host", default="127.0.0.1")
    parser.add_argument("--wyoming-port", type=int, default=10700)
    parser.add_argument("--pipeline-id")
    args = parser.parse_args()
    asyncio.run(main_async(args))


if __name__ == "__main__":
    main()
