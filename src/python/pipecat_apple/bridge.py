"""In-process native requests, session fencing, and pipeline lifecycle."""

import asyncio
import uuid
from collections.abc import AsyncIterator, Callable
from typing import TYPE_CHECKING, Any, cast

from pipecat.frames.frames import (
    Frame,
    InterruptionFrame,
    LLMFullResponseEndFrame,
    LLMUpdateSettingsFrame,
)
from pipecat.processors.aggregators.llm_context import LLMContext, LLMContextMessage
from pipecat.processors.frame_processor import FrameDirection, FrameProcessor
from pipecat.services.settings import LLMSettings

from pipecat_apple.context import bounded_history
from pipecat_apple.frames import AppleControlFrame, AppleInputFrame

if TYPE_CHECKING:
    from pipecat.pipeline.worker import PipelineWorker
    from pipecat.processors.aggregators.llm_response_universal import LLMContextAggregatorPair

    from pipecat_apple.llm import AppleFoundationLLMService
    from pipecat_apple.phonon import PhononTTSService
    from pipecat_apple.transport import AppleTransport


class AppleNativeBridge:
    """Connect an embedded Pipecat worker to a native Apple audio host.

    The host and the worker exchange JSON-compatible events. Every event that
    belongs to a conversation carries its ``session``, and turn-scoped events
    their ``turn``, so late events from an ended session or turn are dropped.

    From the host (:meth:`receive`): ``start``, ``stop``, ``reset``, ``mute``,
    ``unmute`` and ``interrupt`` control the session; ``vad`` and
    ``transcription`` carry speech input, with ``talk`` in place of ``vad`` for
    a microphone held to talk (``talking`` as it is pressed, not as it is
    released); ``playback`` reports a speak request's audio starting and
    stopping; and ``result`` answers a request (``delta``, ``value``, ``done``
    or ``error``).

    To the host (``emit``): ``ready`` and ``error`` for the pipeline;
    ``user_turn`` when speech starts a turn; ``request`` and ``cancel_request``
    for native operations (``generate``, ``speak``, ``finalize_asr``, and any
    an application adds); ``cancel_turn`` for generation; ``prewarm`` hints;
    ``state`` (``listening``) when the floor returns to the user; and ``rtvi``
    messages.
    """

    def __init__(self, emit: Callable[[dict], None], *, timeout: float = 90) -> None:
        """Initialize the bridge.

        Args:
            emit: Deliver a JSON-compatible event to the native host.
            timeout: Maximum idle time for a native operation in seconds.
        """
        self.emit = emit
        self.timeout = timeout
        self.pending: dict[str, asyncio.Queue] = {}
        self.operations: dict[str, tuple[str, str | None]] = {}
        self.ready = asyncio.Event()
        self.worker: PipelineWorker | None = None
        self.transport: AppleTransport | None = None
        self.aggregators: LLMContextAggregatorPair | None = None
        self.context: LLMContext | None = None
        self.tts: PhononTTSService | None = None
        self.llm: AppleFoundationLLMService | None = None
        self._system_instruction_factory: Callable[[dict[str, Any]], str] | None = None
        self.session: str | None = None
        self.turn: str | None = None
        self.input_epoch = 0
        self._turn_sessions: dict[str, str | None] = {}
        self.active = False
        self.muted = False

    def bind(
        self,
        worker: "PipelineWorker",
        transport: "AppleTransport",
        context: LLMContext,
        aggregators: "LLMContextAggregatorPair",
        *,
        tts: "PhononTTSService | None" = None,
        llm: "AppleFoundationLLMService | None" = None,
        system_instruction_factory: Callable[[dict[str, Any]], str] | None = None,
    ) -> None:
        """Attach pipeline components and publish readiness and errors.

        Args:
            worker: Worker owning the native pipeline.
            transport: Native input and output transport.
            context: Shared conversation context.
            aggregators: Standard user and assistant context aggregators.
            tts: Optional Phonon service whose speech each new session cancels.
            llm: Optional Apple language model service.
            system_instruction_factory: Build replacement instructions from each
                native start event. Requires ``llm`` and preserves conversation history.
        """
        if system_instruction_factory is not None and llm is None:
            raise ValueError("Session instructions require an Apple LLM service")
        self.worker, self.transport = worker, transport
        self.context, self.aggregators = context, aggregators
        self.tts = tts
        self.llm = llm
        self._system_instruction_factory = system_instruction_factory

        @worker.event_handler("on_pipeline_started")
        async def started(worker, frame):
            self.ready.set()
            self.emit({"type": "ready"})

        @worker.event_handler("on_pipeline_error")
        async def failed(worker, frame):
            turn = frame.metadata.get("turn")
            session = frame.metadata.get("session")
            if session != self.session or (turn is not None and turn != self.turn):
                return
            self.emit(
                {
                    "type": "error",
                    "message": frame.error,
                    "turn": turn,
                    "session": session,
                    "operation": frame.metadata.get("operation"),
                    "recoverable": bool(frame.metadata.get("recoverable"))
                    and not frame.fatal
                    and (frame.processor is None or frame.processor.is_usable),
                }
            )

        async def tag_origin(processor: FrameProcessor, frame: Frame) -> None:
            turn = frame.metadata.setdefault("turn", self.turn)
            frame.metadata.setdefault("session", self._session_of(turn))

        def register_origin(processor: FrameProcessor) -> None:
            processor.add_event_handler("on_before_push_frame", tag_origin)
            for child in processor.processors:
                register_origin(child)

        register_origin(worker.pipeline)

        @aggregators.assistant().event_handler("on_after_process_frame")
        async def response_processed(processor, frame: Frame) -> None:
            # A response whose end says it `continues` is followed by another in the same
            # turn, so the floor is not the user's yet.
            continues = isinstance(frame, LLMFullResponseEndFrame) and frame.metadata.get(
                "continues"
            )
            if isinstance(frame, (LLMFullResponseEndFrame, InterruptionFrame)):
                self._trim_context(context)
                if (
                    self.llm is not None
                    and not continues
                    and frame.metadata.get("session") == self.session
                    and frame.metadata.get("turn") == self.turn
                ):
                    self.llm.prepare_context(context)
            if isinstance(frame, LLMFullResponseEndFrame):
                turn = frame.metadata.get("turn")
                if (
                    self.active
                    and not continues
                    and turn == self.turn
                    and frame.metadata.get("session") == self.session
                ):
                    self.emit(
                        {
                            "type": "state",
                            "state": "listening",
                            "turn": turn,
                            "session": self.session,
                        }
                    )

    @staticmethod
    def _trim_context(context: LLMContext) -> None:
        # Keep the shared context bounded as well as the native model request: complete
        # recent turns, including played interruptions, after any initial instructions.
        messages = [message for message in context.messages if isinstance(message, dict)]
        instructions = messages[:1] if messages and messages[0].get("role") == "system" else []
        trimmed = instructions + bounded_history(messages[len(instructions) :])
        context.set_messages(cast(list[LLMContextMessage], trimmed))

    def _session_of(self, turn: str | None) -> str | None:
        """The session a turn began in; the current session for no turn."""
        if turn is None:
            return self.session
        return self._turn_sessions.get(turn, self.session)

    def begin_turn(self) -> None:
        """Start a user turn, and tell the host, before its speech reaches the pipeline."""
        self.turn = uuid.uuid4().hex
        self._turn_sessions[self.turn] = self.session
        if len(self._turn_sessions) > 64:
            self._turn_sessions.pop(next(iter(self._turn_sessions)))
        self.emit({"type": "user_turn", "turn": self.turn, "session": self.session})

    async def stream(self, operation: str, turn: str | None, **payload: Any) -> AsyncIterator[dict]:
        """Run a native operation with bounded waiting, and cancel it if abandoned.

        Args:
            operation: The native operation's name.
            turn: The turn the operation belongs to, if any.
            **payload: The operation's arguments.

        Yields:
            Each result event the host sends before ``done``.

        Raises:
            TimeoutError: The host sent nothing for longer than the bridge's timeout.
            RuntimeError: The host reported an error.
        """
        request = uuid.uuid4().hex
        session = self._session_of(turn)
        queue = self.pending[request] = asyncio.Queue(maxsize=1024)
        self.operations[request] = (operation, turn)
        self.emit(
            {
                "type": "request",
                "operation": operation,
                "request": request,
                "turn": turn,
                "session": session,
                **payload,
            }
        )
        finished = False
        try:
            while True:
                try:
                    event = await asyncio.wait_for(queue.get(), timeout=self.timeout)
                except TimeoutError as exc:
                    raise TimeoutError(f"Native {operation} timed out. Please try again.") from exc
                if event.get("error"):
                    raise RuntimeError(event["error"])
                if event.get("done"):
                    finished = True
                    return
                yield event
        finally:
            self.pending.pop(request, None)
            self.operations.pop(request, None)
            if not finished:
                self.emit(
                    {
                        "type": "cancel_request",
                        "request": request,
                        "turn": turn,
                        "session": session,
                    }
                )

    async def receive(self, event: dict) -> None:
        """Route a native event into the worker without blocking on inference.

        Args:
            event: An event from the host.
        """
        kind = event.get("type")
        if kind == "result":
            request = event.get("request")
            if isinstance(request, str) and (queue := self.pending.get(request)):
                _, turn = self.operations[request]
                session = self._session_of(turn)
                if event.get("session", session) != session or event.get("turn", turn) != turn:
                    return
                queue.put_nowait(event)
            return
        worker, transport = self.worker, self.transport
        if worker is None or transport is None:
            raise RuntimeError("The Apple bridge is not attached to a pipeline")
        if kind == "start":
            await self._start(event)
        elif event.get("session") is not None and event["session"] != self.session:
            return
        if kind in {"start", "stop", "reset", "mute", "unmute", "interrupt"}:
            self.input_epoch += 1
        if kind == "playback":
            await transport.output().playback_changed(event)
            return
        if kind in {"vad", "talk", "transcription"} and (not self.active or self.muted):
            return
        if kind == "stop":
            self.active = False
        elif kind == "mute":
            self.muted = True
        elif kind == "unmute":
            self.muted = False
        frame_type = AppleInputFrame if kind == "transcription" else AppleControlFrame
        frame = frame_type(dict(event))
        frame.metadata.update(input_epoch=self.input_epoch, session=self.session, turn=self.turn)
        await worker.queue_frame(frame)

    async def _start(self, event: dict) -> None:
        """Begin a session: cancel the last one's speech, then apply its instructions."""
        session = event["session"]
        instruction = None
        if self._system_instruction_factory is not None:
            instruction = self._system_instruction_factory(dict(event))
            if not isinstance(instruction, str):
                raise TypeError("Session instructions must be a string")
        self.active = False
        if self.tts is not None:
            interrupted = InterruptionFrame()
            interrupted.metadata.update(turn=self.turn, session=self.session)
            await self._process_control(self.tts, interrupted)
        llm = self.llm
        if instruction is not None and llm is not None:
            # A settings control frame cannot overtake an old generation.
            # Interrupt it before awaiting the replacement session's settings.
            interrupted = InterruptionFrame()
            interrupted.metadata.update(turn=self.turn, session=self.session)
            await self._process_control(llm, interrupted)
        self.session = session
        self.turn = None
        self.muted = False
        if instruction is not None and llm is not None:
            settings = LLMUpdateSettingsFrame(
                delta=LLMSettings(system_instruction=instruction), service=llm
            )
            settings.metadata.update(turn=None, session=session)
            await self._process_control(llm, settings)
        self.active = True

    async def _process_control(self, processor: FrameProcessor, frame: Frame) -> None:
        """Wait for a queued control frame to finish before admitting native input."""
        completed = asyncio.Event()

        async def processed(
            processor: FrameProcessor, frame: Frame, direction: FrameDirection
        ) -> None:
            completed.set()

        await processor.queue_frame(frame, callback=processed)
        await asyncio.wait_for(completed.wait(), timeout=self.timeout)

    async def endpoint(self, turn: str | None, *, endpoint_id: str) -> None:
        """Order an identified endpoint after all native ASR transcript callbacks.

        Args:
            turn: Current conversation turn, or None before speech is confirmed.
            endpoint_id: Identity of the acoustic span being finalized, allowing
                the STT service to reject a completion queued before resumed speech.
        """
        input_epoch, session = self.input_epoch, self.session
        async for _ in self.stream("finalize_asr", turn):
            pass
        if (
            self.worker is not None
            and self.active
            and not self.muted
            and self.turn == turn
            and self.input_epoch == input_epoch
            and self.session == session
        ):
            frame = AppleInputFrame(
                {
                    "type": "endpoint",
                    "turn": turn,
                    "session": session,
                    "endpoint_id": endpoint_id,
                }
            )
            frame.metadata.update(input_epoch=input_epoch, session=session, turn=turn)
            await self.worker.queue_frame(frame)
