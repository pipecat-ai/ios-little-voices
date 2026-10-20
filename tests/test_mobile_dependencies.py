import json
import subprocess
import sys
from email.parser import Parser
from pathlib import Path

import bundle_runtime
from packaging.requirements import Requirement
from packaging.utils import canonicalize_name
from pipecat_package import DIST_INFO, PIPECAT_DIR
from stage_python import DISTRIBUTIONS

ROOT = Path(__file__).resolve().parents[1]
# Pipecat's requirements the app leaves out: the patch imports them only where they are used.
DESKTOP = {
    "aiofiles",
    "aiohttp",
    "audioop-lts",
    "loudness",
    "num2words",
    "numba",
    "numpy",
    "onnxruntime",
    "openai",
    "pillow",
    "protobuf",
    "python-dotenv",
    "pyyaml",
    "resampy",
    "sentencex",
    "soundfile",
    "soxr",
}


def test_the_app_stages_every_pipecat_requirement_except_the_desktop_ones():
    metadata = Parser().parsestr((ROOT / PIPECAT_DIR / DIST_INFO / "METADATA").read_text())
    required = {
        canonicalize_name(requirement.name)
        for requirement in map(Requirement, metadata.get_all("Requires-Dist"))
        if not requirement.marker or requirement.marker.evaluate({"extra": ""})
    }
    staged = {canonicalize_name(name) for name in DISTRIBUTIONS}
    assert DESKTOP <= required
    assert required - DESKTOP <= staged
    assert not staged & DESKTOP


def test_real_pipeline_completes_a_turn_with_only_the_bundled_python():
    code = """
import importlib.abc, json, sys
UNBUNDLED = set(json.loads(sys.argv[1]))
PIPECAT = set(json.loads(sys.argv[2]))
class AsBundled(importlib.abc.MetaPathFinder):
    # As in the app: the desktop packages, the standard library it leaves out and the Pipecat
    # modules it does not bundle are missing.
    def find_spec(self, fullname, path=None, target=None):
        top = fullname.split('.')[0]
        if top in {'numpy','numba','onnxruntime','soxr','soundfile','PIL','loudness','aiohttp','aiofiles','openai','audioop','sentencex','num2words','yaml','dotenv','google','resampy'}:
            raise ModuleNotFoundError('Desktop module imported: ' + fullname)
        if top in UNBUNDLED or (top == 'pipecat' and fullname not in PIPECAT):
            raise ModuleNotFoundError('Module the app does not bundle imported: ' + fullname)
sys.meta_path.insert(0, AsBundled())
sys.path.insert(0, 'src/python')
sys.path.insert(0, 'src/python/pipecat_audience/runtime')
sys.path.insert(0, '.build/pipecat-ai')
from pipecat.workers.runner import WorkerRunner
from mobile_app.bot import create_bot
from pipecat_apple.bridge import AppleNativeBridge
import asyncio, re

async def check_native_turn():
    events = asyncio.Queue()
    seen = []
    def emit(event):
        seen.append(event)
        events.put_nowait(event)
    async def wait(predicate):
        async with asyncio.timeout(5):
            while True:
                event = await events.get()
                assert event.get('type') != 'error', event
                if predicate(event):
                    return event
    async def answer_audience(person):
        request = await wait(lambda e: e.get('operation') == 'audience')
        await bridge.receive({'type': 'result', 'request': request['request'],
                              'value': {'person': person, 'unclear': 0, 'group': 0}})
        await bridge.receive({'type': 'result', 'request': request['request'], 'done': True})
    def boundary(text):
        match = re.search(r'[.!?](?=\\s+\\S)', text)
        return match.end() if match else 0
    bridge = AppleNativeBridge(emit)
    worker = create_bot(bridge, sentence_boundary_matcher=boundary, max_lines=1)
    runner = WorkerRunner(handle_sigint=False, handle_sigterm=False)
    await runner.add_workers(worker)
    task = asyncio.create_task(runner.run())
    try:
        await asyncio.wait_for(bridge.ready.wait(), 5)
        await bridge.receive({'type': 'start', 'session': 'mobile-imports'})
        await bridge.receive({'type': 'vad', 'confidence': .95, 'volume': 1,
                              'time': .1, 'session': 'mobile-imports'})
        await bridge.receive({'type': 'transcription', 'text': 'Say',
                              'final': False, 'start': .1, 'end': .1,
                              'session': 'mobile-imports'})
        await wait(lambda e: e.get('message', {}).get('type') == 'user-started-speaking')
        for index in range(6):
            await bridge.receive({'type': 'vad', 'confidence': 0, 'volume': 1,
                                  'time': .2 + index * .1, 'session': 'mobile-imports'})
        endpoint = await wait(lambda e: e.get('operation') == 'finalize_asr')
        await bridge.receive({'type': 'transcription', 'text': 'Say hello',
                              'final': True, 'start': .1, 'end': .7,
                              'session': 'mobile-imports'})
        await bridge.receive({'type': 'result', 'request': endpoint['request'], 'done': True})
        await answer_audience([1.0, 0.0])  # the human's line is for the angel
        generate = await wait(lambda e: e.get('operation') == 'generate')
        assert generate['prompt'].startswith('[Human] Say hello\\n[Note: ')
        await bridge.receive({'type': 'result', 'request': generate['request'],
                              'delta': 'Hello there. Nice to meet you.'})
        await bridge.receive({'type': 'result', 'request': generate['request'], 'done': True})
        await answer_audience([1.0, 0.0])  # the angel's line is for the human
        for sentence in ['Hello there.', 'Nice to meet you.']:
            speak = await wait(lambda e: e.get('operation') == 'speak')
            assert speak['text'] == sentence
            assert (speak['speaker'], speak['voice']) == ('angel', 'Angel_F01'), speak
            await bridge.receive({'type': 'playback', 'request': speak['request'],
                                  'speaking': True, 'session': 'mobile-imports'})
            await bridge.receive({'type': 'playback', 'request': speak['request'],
                                  'speaking': False, 'session': 'mobile-imports'})
            await bridge.receive({'type': 'result', 'request': speak['request'], 'done': True})
        await wait(lambda e: e.get('state') == 'listening')
        assert bridge.context.messages == [
            {'role': 'user', 'content': 'Say hello'},
            {'role': 'assistant', 'content': 'Hello there. Nice to meet you.'},
        ], bridge.context.messages
        types = {event.get('message', {}).get('type') for event in seen}
        assert {'user-started-speaking', 'user-stopped-speaking',
                'bot-started-speaking', 'bot-stopped-speaking'} <= types, types
    finally:
        await bridge.receive({'type': 'stop', 'session': 'mobile-imports'})
        await runner.cancel()
        await asyncio.wait_for(task, 5)

asyncio.run(check_native_turn())
"""
    pipecat = ROOT / PIPECAT_DIR / "pipecat"
    kept = []
    for module in bundle_runtime.pipecat_modules(ROOT / "src/python", pipecat):
        parts = list(module.relative_to(pipecat.parent).with_suffix("").parts)
        kept.append(".".join(parts[:-1] if parts[-1] == "__init__" else parts))
    unbundled = bundle_runtime.UNUSED_STDLIB | bundle_runtime.UNUSED_EXTENSIONS
    result = subprocess.run(
        [sys.executable, "-c", code, json.dumps(sorted(unbundled)), json.dumps(sorted(kept))],
        cwd=ROOT,
        capture_output=True,
        text=True,
        timeout=20,
    )
    assert result.returncode == 0, result.stderr
