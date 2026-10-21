"""Embedded entry point. Native audio never crosses the Python boundary."""


def run():
    import asyncio
    import json

    import _pipecat_native
    from loguru import logger
    from pipecat.workers.runner import WorkerRunner
    from pipecat_apple.bridge import AppleNativeBridge

    from .bot import create_bot

    logger.remove()
    # Warnings without tracebacks' variable values, which can hold what the user said.
    logger.add(
        lambda message: _pipecat_native.log(str(message)),
        level="WARNING",
        backtrace=False,
        diagnose=False,
    )

    async def main():
        bridge = AppleNativeBridge(lambda event: _pipecat_native.emit(json.dumps(event)))
        worker = create_bot(bridge, sentence_boundary_matcher=_pipecat_native.sentence_boundary)
        runner = WorkerRunner(handle_sigint=False, handle_sigterm=False)
        await runner.add_workers(worker)
        async with asyncio.TaskGroup() as tasks:
            tasks.create_task(runner.run())
            await bridge.ready.wait()
            while True:
                raw = _pipecat_native.poll()
                if raw is None:
                    await asyncio.sleep(0.015)
                    continue
                try:
                    await bridge.receive(json.loads(raw))
                except Exception:
                    logger.exception("Native event failed")
                    bridge.emit(
                        {
                            "type": "error",
                            "message": "Something went wrong. Tap the microphone to start again.",
                        }
                    )

    asyncio.run(main())
