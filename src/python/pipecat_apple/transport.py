"""Native Apple transport and RTVI delivery for embedded voice applications."""

from typing import Any

import pipecat.processors.frameworks.rtvi.models as RTVI
from pipecat.frames.frames import (
    AggregatedTextFrame,
    BotStartedSpeakingFrame,
    BotStoppedSpeakingFrame,
    CancelFrame,
    EndFrame,
    Frame,
    InterruptionFrame,
    LLMMessagesUpdateFrame,
    LLMTextFrame,
    TTSTextFrame,
)
from pipecat.observers.base_observer import FramePushed
from pipecat.processors.frame_processor import FrameDirection, FrameProcessor
from pipecat.processors.frameworks.rtvi import RTVIObserver
from pipecat.transports.base_input import BaseInputTransport
from pipecat.transports.base_output import BaseOutputTransport
from pipecat.transports.base_transport import BaseTransport, TransportParams
from pydantic import BaseModel

from pipecat_apple.bridge import AppleNativeBridge
from pipecat_apple.frames import AppleInputFrame


class AppleOutputTransport(BaseOutputTransport):
    """Represent native playback without moving PCM through Python."""

    def __init__(self, bridge: AppleNativeBridge, params: TransportParams, **kwargs: Any) -> None:
        """Initialize output.

        Args:
            bridge: Native event bridge.
            params: Transport parameters.
            **kwargs: Additional output transport configuration.
        """
        super().__init__(params, **kwargs)
        self.bridge = bridge
        self._speaking_request: str | None = None
        self._speaking_turn: str | None = None

    async def playback_changed(self, event: dict) -> None:
        """Turn the host's playback starting and draining into bot speaking frames.

        Args:
            event: A ``playback`` event naming its speak request and whether audio is playing.
        """
        request = event.get("request")
        operation = self.bridge.operations.get(request) if isinstance(request, str) else None
        if event.get("speaking"):
            if not operation or operation[0] != "speak" or operation[1] != self.bridge.turn:
                return
            if self._speaking_request == request:
                return
            self._speaking_request, self._speaking_turn = request, operation[1]
            await self._speech_frame(BotStartedSpeakingFrame)
        elif request == self._speaking_request:
            await self._stop_speaking()

    async def _speech_frame(
        self, cls: type[BotStartedSpeakingFrame | BotStoppedSpeakingFrame]
    ) -> None:
        downstream, upstream = cls(), cls()
        downstream.broadcast_sibling_id = upstream.id
        upstream.broadcast_sibling_id = downstream.id
        downstream.metadata["turn"] = upstream.metadata["turn"] = self._speaking_turn
        await self.push_frame(downstream)
        await self.push_frame(upstream, FrameDirection.UPSTREAM)

    async def _stop_speaking(self) -> None:
        if self._speaking_request is not None:
            await self._speech_frame(BotStoppedSpeakingFrame)
            self._speaking_request = self._speaking_turn = None

    async def process_frame(self, frame: Frame, direction: FrameDirection) -> None:
        """Forward native output and cancel its speech state on interruption.

        Args:
            frame: Incoming pipeline frame.
            direction: Direction of travel through the pipeline.
        """
        # Native audio has its own playback clock. BaseOutputTransport's PCM
        # MediaSender is deliberately not started for this transport.
        await FrameProcessor.process_frame(self, frame, direction)
        if isinstance(frame, (InterruptionFrame, EndFrame, CancelFrame)):
            await self._stop_speaking()
        elif isinstance(frame, AppleInputFrame) and frame.event.get("type") == "reset_context":
            await self.push_frame(LLMMessagesUpdateFrame(messages=[]))
            return
        await self.push_frame(frame, direction)


class AppleTransport(BaseTransport):
    """An in-process native host with standard Pipecat input/output processors."""

    def __init__(self, bridge: AppleNativeBridge, **kwargs: Any) -> None:
        """Initialize the transport.

        Args:
            bridge: Native host bridge.
            **kwargs: Additional BaseTransport configuration.
        """
        super().__init__(**kwargs)
        params = TransportParams(audio_out_sample_rate=24000, audio_in_sample_rate=16000)
        self._input = BaseInputTransport(params, name="AppleInputTransport")
        self._output = AppleOutputTransport(bridge, params)

    def input(self) -> BaseInputTransport:
        """Return the pipeline's native input processor."""
        return self._input

    def output(self) -> AppleOutputTransport:
        """Return the pipeline's native playback output processor."""
        return self._output


def _line_tags(frame: Frame) -> dict[str, Any]:
    """A bot line's speaker and line identity, when a response carries them."""
    return {key: frame.metadata[key] for key in ("speaker", "line") if key in frame.metadata}


class AppleRTVIObserver(RTVIObserver):
    """Deliver standard RTVI messages over the in-process Apple bridge.

    The bridge carries the messages, so the pipeline needs no RTVIProcessor.
    Add the observer with ``PipelineWorker.add_observer()`` and pass
    ``enable_rtvi=False``: the worker reports an RTVIObserver in its
    ``observers`` without an RTVIProcessor in the pipeline as an error.
    """

    def __init__(self, bridge: AppleNativeBridge, **kwargs: Any) -> None:
        """Initialize native RTVI delivery.

        Args:
            bridge: Native event bridge.
            **kwargs: RTVIObserver parameters.
        """
        super().__init__(**kwargs)
        self.bridge = bridge
        self._event_turn: str | None = None
        self._event_session: str | None = None
        self._event_line: dict[str, Any] = {}

    async def on_push_frame(self, data: FramePushed) -> None:
        """Note each frame's turn, session and line, so its messages carry them.

        Args:
            data: The pushed frame and its push details.
        """
        self._event_turn = data.frame.metadata.get("turn")
        self._event_session = data.frame.metadata.get("session")
        self._event_line = _line_tags(data.frame)
        if (
            isinstance(data.frame, InterruptionFrame)
            and data.direction == FrameDirection.DOWNSTREAM
            and data.first_push
        ):
            self._queued_aggregated_text_frames.clear()
        await super().on_push_frame(data)

    async def _handle_llm_text_frame(self, frame: LLMTextFrame) -> None:
        # Sends bot-llm-text without RTVI's deprecated bot-transcription, a sentence-by-sentence
        # copy of it whose sentence matching would load sentencex, which the app doesn't bundle.
        await self.send_rtvi_message(
            RTVI.BotLLMTextMessage(data=RTVI.TextMessageData(text=frame.text))
        )

    async def _handle_aggregated_llm_text(self, frame: AggregatedTextFrame) -> None:
        if isinstance(frame, TTSTextFrame):
            # Native text acknowledgement follows playback drain, after the
            # matching BotStoppedSpeakingFrame may already have been observed.
            await self._send_aggregated_llm_text(frame)
        else:
            await super()._handle_aggregated_llm_text(frame)

    async def _send_aggregated_llm_text(self, frame: AggregatedTextFrame) -> None:
        origin = self._event_turn, self._event_session, self._event_line
        self._event_turn = frame.metadata.get("turn")
        self._event_session = frame.metadata.get("session")
        self._event_line = _line_tags(frame)
        try:
            await super()._send_aggregated_llm_text(frame)
        finally:
            self._event_turn, self._event_session, self._event_line = origin

    async def send_rtvi_message(self, model: BaseModel, exclude_none: bool = True) -> None:
        """Send an unchanged RTVI message to the host inside a native session envelope.

        Args:
            model: The RTVI message.
            exclude_none: Whether to leave out fields that are None.
        """
        self.bridge.emit(
            {
                "type": "rtvi",
                "turn": self._event_turn,
                "session": self._event_session,
                **self._event_line,
                "message": model.model_dump(exclude_none=exclude_none),
            }
        )
