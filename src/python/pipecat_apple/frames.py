"""Events from the native host; PCM stays in the host audio engine."""

from dataclasses import dataclass, field

from pipecat.frames.frames import DataFrame, SystemFrame


@dataclass
class AppleInputFrame(DataFrame):
    """An ordered native transcript, endpoint acknowledgment, or context reset.

    Recognized speech can itself trigger a bot interruption. Keep that speech
    and its finalization acknowledgment ordered while STT checks their session
    and input epoch, rather than dropping them with cancelled bot output. The STT
    service also sends a ``reset_context`` event downstream when the host clears
    the conversation.

    Parameters:
        event: Native event payload.
    """

    interruptible: bool = field(default=False, init=False)

    event: dict


@dataclass
class AppleControlFrame(SystemFrame):
    """Native activity or lifecycle input that may interrupt a reply.

    Parameters:
        event: Native event payload.
    """

    event: dict


@dataclass
class TTSAudioPlayedFrame(DataFrame):
    """The host has played a sentence's speech.

    Parameters:
        context_id: The sentence's audio context.
    """

    context_id: str
