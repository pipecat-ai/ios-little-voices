"""Helpers shared by the tests: a native host for the bot's pipeline, and Swift builds."""

import asyncio
import platform
import re
import shutil
import subprocess
import sys
from collections.abc import Sequence
from contextlib import asynccontextmanager
from pathlib import Path

import pytest
from mobile_app.bot import create_bot
from pipecat.workers.runner import WorkerRunner
from pipecat_apple.bridge import AppleNativeBridge
from pipecat_apple.stt import AppleSpeechSTTService

ROOT = Path(__file__).resolve().parents[1]
SOURCES = ROOT / "src/ios/PipecatVoice"
CHECKS = ROOT / "tests/native"

needs_swift = pytest.mark.skipif(
    sys.platform != "darwin"
    or not shutil.which("swiftc")
    or int(platform.mac_ver()[0].split(".")[0] or "0") < 27,
    reason="macOS 27 and its Swift SDK required",
)


def build_swift(output: Path, sources: Sequence[Path], *flags: str) -> Path:
    """Compile Swift `sources` into the executable `output`, for macOS 27 on this Mac."""
    result = subprocess.run(
        [
            "xcrun",
            "swiftc",
            "-swift-version",
            "5",
            "-parse-as-library",
            "-target",
            f"{platform.machine()}-apple-macos27.0",
            "-module-cache-path",
            str(output.parent / "ModuleCache"),
            *flags,
            *map(str, sources),
            "-o",
            str(output),
        ],
        capture_output=True,
        text=True,
        timeout=600,
    )
    if result.returncode:
        pytest.fail(f"swiftc failed:\n{result.stderr}")
    return output


def audience_answer(event):
    """Stand in for the native Audience model: a line naming a character is for them; otherwise
    the human's lines are for the angel and the characters' lines for the human."""
    ids = [
        "angel" if card.startswith("Angel") else "devil" if card.startswith("Devil") else "player"
        for card in event["cards"]
    ]
    line = event["utterance"][: event["current"]]
    named = [pid for pid in ids if pid != "player" and pid.capitalize() in line]
    chosen = named or (["player"] if "player" in ids else ["angel"])
    return {"person": [1.0 if pid in chosen else 0.0 for pid in ids], "unclear": 0.0, "group": 0.0}


def human(request):
    """The human's words in a generation request's prompt."""
    return "\n".join(
        line.removeprefix("[Human] ")
        for line in request["prompt"].splitlines()
        if line.startswith("[Human] ")
    )


def plain(messages):
    """A character's history as plain turns: the human's words without their name tag."""
    return [
        {**message, "content": message["content"].removeprefix("[Human] ")}
        if message["role"] == "user"
        else message
        for message in messages
    ]


class Host:
    """Native host with explicit ASR finalization and audio playback acknowledgments.

    Audience requests are answered at once by `audience` (None leaves them to the test).
    """

    def __init__(self):
        self.events = []
        self.changed = asyncio.Event()
        self.time = 0.0
        self.session = "test"
        self.bridge = None
        self.audience = audience_answer

    def emit(self, event):
        self.events.append(event)
        self.changed.set()
        if (
            event.get("operation") == "audience"
            and self.audience is not None
            and self.bridge is not None
        ):
            answer = self.audience(event)
            asyncio.get_running_loop().create_task(self._answer(event, answer))

    async def _answer(self, event, answer):
        await respond(self.bridge, event, value=answer)
        await respond(self.bridge, event, done=True)

    async def wait(self, predicate, *, after=0, timeout=5):
        try:
            async with asyncio.timeout(timeout):
                while True:
                    match = next((event for event in self.events[after:] if predicate(event)), None)
                    if match:
                        return match
                    self.changed.clear()
                    await self.changed.wait()
        except TimeoutError:
            pytest.fail(f"Expected native event was not emitted. Events: {self.events[after:]}")

    async def vad(self, bridge, confidence, *, session=None):
        self.time = round(self.time + 0.1, 4)
        await bridge.receive(
            {
                "type": "vad",
                "confidence": confidence,
                "time": self.time,
                "volume": 1.0,
                "session": session or self.session,
            }
        )

    async def begin_speech(self, bridge, *, text="Hello"):
        marker = len(self.events)
        await self.vad(bridge, 0.95)
        await self.transcribe(bridge, text, start=self.time, final=False)
        await self.wait(lambda event: rtvi_type(event) == "user-started-speaking", after=marker)
        return marker, self.time

    async def end_speech(self, bridge, text, *, start, after=0):
        for _ in range(6):
            await self.vad(bridge, 0.05)
        endpoint = await self.wait(
            lambda event: event.get("operation") == "finalize_asr", after=after
        )
        if text:
            await self.transcribe(bridge, text, start=start, final=True)
        endpoint_marker = len(self.events)
        await respond(bridge, endpoint, done=True)
        await self.wait(
            lambda event: rtvi_type(event) == "user-stopped-speaking", after=endpoint_marker
        )
        return endpoint

    async def transcribe(self, bridge, text, *, start, final, session=None):
        await bridge.receive(
            {
                "type": "transcription",
                "text": text,
                "final": final,
                "start": start,
                "end": self.time,
                "session": session or self.session,
            }
        )

    async def say(self, bridge, text):
        marker, start = await self.begin_speech(bridge, text=text)
        await self.end_speech(bridge, text, start=start, after=marker)
        return await self.wait(
            lambda event: event.get("type") == "request" and event.get("operation") == "generate",
            after=marker,
        )

    async def play(self, bridge, speech):
        """Play a speak request through: playback starts, drains, then the request completes."""
        await self.playback(bridge, speech, speaking=True)
        await self.playback(bridge, speech, speaking=False)
        await respond(bridge, speech, done=True)

    async def playback(self, bridge, request, *, speaking):
        await bridge.receive(
            {
                "type": "playback",
                "request": request["request"],
                "speaking": speaking,
                "session": self.session,
            }
        )


def rtvi_type(event):
    return event.get("message", {}).get("type") if event.get("type") == "rtvi" else None


@asynccontextmanager
async def session(*, user_name=None, lines=1):
    host = Host()

    # The native tokenizer is verified separately; this host models its boundary API.
    def boundary(text):
        match = re.search(r"[.!?](?=\s+\S)", text)
        return match.end() if match else 0

    bridge = AppleNativeBridge(host.emit)
    host.bridge = bridge
    worker = create_bot(bridge, sentence_boundary_matcher=boundary, max_lines=lines)
    runner = WorkerRunner(handle_sigint=False, handle_sigterm=False)
    await runner.add_workers(worker)
    task = asyncio.create_task(runner.run())
    try:
        await asyncio.wait_for(bridge.ready.wait(), 5)
        profile = {"user_name": user_name} if user_name is not None else {}
        await bridge.receive({"type": "start", "session": host.session, **profile})
        yield bridge, host
    finally:
        await bridge.receive({"type": "stop", "session": host.session})
        await runner.cancel()
        await asyncio.wait_for(task, 5)


async def respond(bridge, request, **fields):
    await bridge.receive({"type": "result", "request": request["request"], **fields})


async def reply(bridge, host, request, text):
    marker = len(host.events)
    await respond(bridge, request, delta=text)
    await respond(bridge, request, done=True)
    return await host.wait(lambda event: event.get("operation") == "speak", after=marker)


def speech_service(bridge):
    """The session pipeline's speech recognition service."""

    def processors(parent):
        yield parent
        for child in parent.processors:
            yield from processors(child)

    return next(
        processor
        for processor in processors(bridge.worker.pipeline)
        if isinstance(processor, AppleSpeechSTTService)
    )


def assistant_messages(bridge):
    return [message for message in bridge.context.messages if message["role"] == "assistant"]
