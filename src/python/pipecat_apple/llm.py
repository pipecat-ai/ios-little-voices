"""Apple Foundation Models on the device, run by the native host."""

import asyncio
from collections.abc import Awaitable, Callable
from typing import Any, cast

from pipecat.adapters.base_llm_adapter import BaseLLMAdapter
from pipecat.adapters.schemas.tools_schema import ToolsSchema
from pipecat.frames.frames import (
    ErrorFrame,
    Frame,
    LLMConfigureOutputFrame,
    LLMContextFrame,
    LLMContextSummaryRequestFrame,
    LLMFullResponseEndFrame,
    LLMFullResponseStartFrame,
    LLMTextFrame,
    LLMUpdateSettingsFrame,
)
from pipecat.processors.aggregators.llm_context import (
    LLMContext,
    LLMContextMessage,
    LLMSpecificMessage,
)
from pipecat.processors.frame_processor import FrameDirection
from pipecat.services.llm_service import LLMService
from pipecat.services.settings import LLMSettings

from pipecat_apple.bridge import AppleNativeBridge
from pipecat_apple.context import MAX_TURN_CHARACTERS, bounded_history

MODEL = "apple-foundation-models"


class AppleLLMAdapter(BaseLLMAdapter[dict[str, Any]]):
    """Adapt Pipecat's text context to Apple Foundation Models on the native host.

    The native host runs no tools, so a context with tools is refused.
    """

    @property
    def id_for_llm_specific_messages(self) -> str:
        """Return the provider identifier used for native context messages."""
        return "apple"

    def get_llm_invocation_params(
        self, context: LLMContext, *, system_instruction: str | None = None, **kwargs: Any
    ) -> dict[str, Any]:
        """Build bounded text history and resolve the service's system instruction.

        Args:
            context: Pipecat conversation context.
            system_instruction: Composed instructions from service settings.
            **kwargs: Additional adapter arguments.

        Returns:
            Native prompt, history and instructions, without mutating the context.
        """
        messages, instructions = self._text_context(context, system_instruction)
        if not messages or messages[-1].get("role") != "user":
            raise ValueError("Apple Foundation Models requires a user message")
        prompt = messages[-1]["content"]
        if not prompt.strip() or len(prompt) > MAX_TURN_CHARACTERS:
            raise ValueError(
                f"Apple voice turns must contain between 1 and {MAX_TURN_CHARACTERS:,} "
                "text characters"
            )
        return {
            "prompt": prompt,
            "history": bounded_history(messages[:-1]),
            "instructions": instructions,
        }

    def get_preparation_params(
        self, context: LLMContext, *, system_instruction: str | None = None
    ) -> dict[str, Any]:
        """Prepare committed history before a future user prompt is available.

        Args:
            context: Authoritative Pipecat context after playback or interruption.
            system_instruction: Composed instructions from service settings.

        Returns:
            Bounded history and instructions for native session prewarming.
        """
        messages, instructions = self._text_context(context, system_instruction)
        return {"history": bounded_history(messages), "instructions": instructions}

    def _text_context(
        self, context: LLMContext, system_instruction: str | None
    ) -> tuple[list[dict[str, Any]], str]:
        self.from_standard_tools(context.tools)
        messages: list[dict[str, Any]] = []
        for message in self.get_messages(context):
            if isinstance(message, LLMSpecificMessage):
                raise ValueError("The native Apple host has no provider-specific messages")
            messages.append(cast(dict[str, Any], message))
        system_from_context = self._extract_initial_system(
            messages, system_instruction=system_instruction
        )
        instructions = self._resolve_system_instruction(
            system_from_context, system_instruction, discard_context_system=True
        )
        for message in messages:
            if message.get("role") not in {"user", "assistant"} or not isinstance(
                message.get("content"), str
            ):
                raise ValueError("The native Apple host supports only text messages")
        return messages, instructions or ""

    def to_provider_tools_format(self, tools_schema: ToolsSchema) -> list[Any]:
        """Refuse tools, which the native host does not run.

        Args:
            tools_schema: The context's tools.

        Returns:
            An empty list, for a schema without tools.

        Raises:
            NotImplementedError: The schema declares a tool.
        """
        if tools_schema.standard_tools or tools_schema.custom_tools:
            raise NotImplementedError("The native Apple host runs no tools")
        return []

    def get_messages_for_logging(self, context: LLMContext) -> list[LLMContextMessage]:
        """Return the context's messages for diagnostics, with large values truncated.

        Args:
            context: The context to log.

        Returns:
            The context's messages.
        """
        return self.get_messages(context, truncate_large_values=True)


class AppleFoundationLLMService(LLMService[AppleLLMAdapter]):
    """Stream on-device Foundation Models output as standard LLM frames.

    Each user turn's context is answered by :meth:`respond`, which subclasses may
    override to speak several responses in one turn with :meth:`generate`.
    """

    adapter_class = AppleLLMAdapter
    Settings = LLMSettings

    def __init__(
        self,
        bridge: AppleNativeBridge,
        *,
        system_instruction: str | None = None,
        settings: LLMSettings | None = None,
        **kwargs: Any,
    ) -> None:
        """Initialize the service.

        Args:
            bridge: Native request bridge.
            system_instruction: System prompt for Apple's language model.
            settings: Settings overrides; system_instruction is runtime-updatable.
            **kwargs: Additional LLMService configuration.
        """
        defaults = LLMSettings(
            model=MODEL,
            system_instruction=system_instruction,
            temperature=None,
            max_tokens=None,
            top_p=None,
            top_k=None,
            frequency_penalty=None,
            presence_penalty=None,
            seed=None,
            filter_incomplete_user_turns=False,
            user_turn_completion_config=None,
        )
        if settings is not None:
            self._validate_native_settings(settings)
            defaults.apply_update(settings)
        super().__init__(settings=defaults, **kwargs)
        self.bridge = bridge

    @property
    def system_instruction(self) -> str | None:
        """The service's system instruction, composed from its settings."""
        instruction = self._settings.system_instruction
        return instruction if isinstance(instruction, str) else None

    @staticmethod
    def _validate_native_settings(settings: LLMSettings) -> None:
        unsupported = [
            key
            for key, value in settings.given_fields().items()
            if key != "system_instruction"
            and value is not None
            and not (key == "model" and value == MODEL)
            and not (key == "filter_incomplete_user_turns" and value is False)
        ]
        if unsupported:
            raise ValueError(
                f"Native Apple settings are not configurable: {', '.join(unsupported)}"
            )

    async def _update_settings(self, delta: LLMSettings) -> dict[str, Any]:
        self._validate_native_settings(delta)
        changed = await super()._update_settings(delta)
        if self.bridge.context is not None:
            self.prepare_context(self.bridge.context)
        return changed

    def prepare_context(self, context: LLMContext) -> None:
        """Hint that native inference will soon use the committed conversation.

        Args:
            context: Context after the assistant aggregator committed played text.
        """
        self.prewarm(context, self.system_instruction)

    def prewarm(self, context: LLMContext, system_instruction: str | None) -> None:
        """Ask the host to prepare a session for a context, unless it is generating.

        Preparation is only a hint: a context the adapter rejects is left for the
        actual invocation to report.

        Args:
            context: The history the next generation will continue.
            system_instruction: The instructions it will be generated with.
        """
        if not self.bridge.active or any(
            operation == "generate" for operation, _ in self.bridge.operations.values()
        ):
            return
        try:
            params = self.get_llm_adapter().get_preparation_params(
                context, system_instruction=system_instruction
            )
        except (ValueError, NotImplementedError):
            return
        self.bridge.emit(
            {"type": "prewarm", "session": self.bridge.session, "turn": self.bridge.turn, **params}
        )

    async def process_frame(self, frame: Frame, direction: FrameDirection) -> None:
        """Answer each current user turn's context; pass other frames on.

        Args:
            frame: Incoming Pipecat frame.
            direction: Direction of travel through the pipeline.
        """
        await super().process_frame(frame, direction)
        if isinstance(
            frame, (LLMUpdateSettingsFrame, LLMConfigureOutputFrame, LLMContextSummaryRequestFrame)
        ):
            return
        if not isinstance(frame, LLMContextFrame) or direction != FrameDirection.DOWNSTREAM:
            await self.push_frame(frame, direction)
            return
        turn = frame.metadata.get("turn", self.bridge.turn)
        if not self.bridge.active or turn is None or turn != self.bridge.turn:
            return
        await self.respond(frame.context, turn)

    async def respond(self, context: LLMContext, turn: str) -> None:
        """Answer a user turn's context with one response.

        Subclasses may override this to speak several responses for one turn.

        Args:
            context: The user turn's context.
            turn: The native turn the response belongs to.
        """
        await self.generate(context, turn)

    async def push_response_error(self, exc: Exception, turn: str) -> None:
        """Report a failed response to the host, as a recoverable error of its turn.

        Args:
            exc: The response's failure.
            turn: The native turn the response belonged to.
        """
        error = ErrorFrame(str(exc), exception=exc)
        error.metadata.update(turn=turn, operation="generate", recoverable=True)
        await self.push_error_frame(error)

    async def generate(
        self,
        context: LLMContext,
        turn: str,
        *,
        instructions: str | None = None,
        metadata: dict[str, Any] | None = None,
        finish: Callable[[str], Awaitable[dict[str, Any]]] | None = None,
        report_errors: bool = True,
    ) -> str | None:
        """Stream one native response as standard LLM frames.

        Args:
            context: Conversation context whose last message is the user prompt.
            turn: The native turn the response belongs to.
            instructions: Instructions for this response in place of the service's.
            metadata: Added to every frame of the response.
            finish: Called with the complete text before the end frame is pushed;
                returns more metadata for the end frame.
            report_errors: Push a recoverable ``ErrorFrame`` when the response fails,
                for the host to report. When False, the response is closed with an end
                frame that ``continues``, keeping the turn, and the failure is raised to the
                caller, which can report it with :meth:`push_response_error`; every call
                whose turn stays current then makes exactly one response.

        Returns:
            The response's text, or None when it failed and was reported or its turn
            was superseded.

        Raises:
            Exception: The response's failure, when ``report_errors`` is False.
        """
        if self.bridge.turn != turn or not self.bridge.active:
            return None
        tags = {**(metadata or {}), "turn": turn}
        system_instruction = self.system_instruction if instructions is None else instructions
        text = ""
        started = False
        try:
            params = self.get_llm_adapter().get_llm_invocation_params(
                context, system_instruction=system_instruction
            )
            start = LLMFullResponseStartFrame()
            start.metadata.update(tags)
            await self.push_frame(start)
            started = True
            async for event in self.bridge.stream("generate", turn, **params):
                if self.bridge.turn != turn or not self.bridge.active:
                    return None
                delta = str(event.get("delta", ""))
                text += delta
                chunk = LLMTextFrame(delta)
                chunk.metadata.update(tags)
                await self.push_frame(chunk)
            if self.bridge.turn != turn or not self.bridge.active:
                return None
            if not text.strip():
                raise RuntimeError("The language model returned an empty response. Try again.")
            end = LLMFullResponseEndFrame()
            end.metadata.update(tags)
            if finish is not None:
                end.metadata.update(await finish(text))
            await self.push_frame(end)
            return text
        except asyncio.CancelledError:
            raise
        except Exception as exc:
            if self.bridge.turn != turn or not self.bridge.active:
                return None
            if not report_errors:
                # Close the response, opening it first if need be, keeping the turn: the caller
                # decides what follows.
                if not started:
                    start = LLMFullResponseStartFrame()
                    start.metadata.update(tags)
                    await self.push_frame(start)
                end = LLMFullResponseEndFrame()
                end.metadata.update(tags, continues=True)
                await self.push_frame(end)
                raise
            await self.push_response_error(exc, turn)
            return None
