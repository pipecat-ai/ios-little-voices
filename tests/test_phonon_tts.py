"""Phonon speech through the real embedded Pipecat pipeline."""

import pytest
from pipecat.services.settings import TTSSettings
from pipecat_apple.phonon import PhononTTSService
from support import assistant_messages, plain, reply, respond, session


def test_phonon_takes_its_voice_from_each_response_not_settings():
    service = PhononTTSService(None)
    assert service._settings.model == "gradium-phonon"
    for settings in (TTSSettings(model="another-model"), TTSSettings(voice="another-voice")):
        with pytest.raises(ValueError, match="comes from each response"):
            PhononTTSService(None, settings=settings)


async def test_speak_requests_carry_each_sentence():
    async with session() as (bridge, host):
        assert isinstance(bridge.tts, PhononTTSService)
        generation = await host.say(bridge, "Hello")
        speech = await reply(bridge, host, generation, "Hello there.")
        assert speech["text"] == "Hello there."
        await respond(bridge, speech, done=True)
        await host.wait(lambda event: event.get("state") == "listening")


async def test_new_session_cancels_old_playback_and_preserves_played_context():
    async with session() as (bridge, host):
        generation = await host.say(bridge, "Tell me something")
        first = await reply(bridge, host, generation, "Already played. Never completed.")
        marker = len(host.events)
        await host.play(bridge, first)
        second = await host.wait(lambda event: event.get("operation") == "speak", after=marker)
        await host.playback(bridge, second, speaking=True)
        old_turn = bridge.turn
        assert second["request"] in bridge.pending

        host.session = "next-session"
        marker = len(host.events)
        await bridge.receive({"type": "start", "session": host.session})
        assert second["request"] not in bridge.pending
        assert bridge.tts._context_turns == {}
        cancelled = await host.wait(
            lambda event: (
                event.get("type") == "cancel_request" and event.get("request") == second["request"]
            ),
            after=marker,
        )
        assert cancelled["turn"] == old_turn
        assert cancelled["session"] == "test"

        # The old acknowledgement cannot mark its interrupted sentence played.
        await respond(bridge, second, done=True)
        generation = await host.say(bridge, "Continue")
        assert plain(generation["history"]) == [
            {"role": "user", "content": "Tell me something"},
            {"role": "assistant", "content": "Already played.…"},
        ]
        speech = await reply(bridge, host, generation, "Phonon continues.")
        assert speech["session"] == "next-session"
        await respond(bridge, speech, done=True)
        await host.wait(
            lambda event: event.get("state") == "listening" and event.get("turn") == speech["turn"],
            after=marker,
        )
        assert assistant_messages(bridge) == [
            {"role": "assistant", "content": "Already played."},
            {"role": "assistant", "content": "Phonon continues."},
        ]
        assert not bridge.pending
        assert not bridge.operations
        assert not bridge.tts._context_turns
    assert not bridge.pending
    assert not bridge.operations


@pytest.mark.parametrize(
    "controls",
    [
        ("mute", "unmute"),
        ("interrupt", "mute", "unmute"),
        ("interrupt",),
        ("stop", "start"),
    ],
    ids=["microphone-resume", "audio-route-resume", "manual-interruption", "session-restart"],
)
async def test_native_resume_sequences_keep_phonon_speaking(controls):
    async with session() as (bridge, host):
        generation = await host.say(bridge, "Before the transition")
        speech = await reply(bridge, host, generation, "The first reply.")
        await host.play(bridge, speech)
        await host.wait(lambda event: event.get("state") == "listening")
        marker = len(host.events)

        for control in controls:
            if control == "start":
                host.session = "resumed-session"
            await bridge.receive({"type": control, "session": host.session})

        generation = await host.say(bridge, "After the transition")
        speech = await reply(bridge, host, generation, "Phonon still answers.")
        assert speech["text"] == "Phonon still answers."
        assert speech["session"] == host.session
        assert not any(event.get("type") == "error" for event in host.events[marker:])
