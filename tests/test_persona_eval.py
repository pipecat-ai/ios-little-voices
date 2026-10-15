import persona_eval


def test_format_checks_follow_the_voice_rules():
    assert persona_eval.format_issues("You can do this. I believe in you!") == []
    assert persona_eval.format_issues("One. Two. Three.") == ["3 sentences"]
    assert persona_eval.format_issues("A **bold** reply.") == ["markup"]
    assert persona_eval.format_issues("Well done 😇.") == ["emoji or symbol"]
    assert persona_eval.format_issues("word " * 41) == ["41 words"]


def test_exchanges_use_the_app_views_and_instructions():
    config = persona_eval.configuration("Ada", None)
    assert "You are the Angel on the human's shoulder" in config["instructions"]
    assert '"user_name": "Ada"' in config["instructions"]
    assert set(config) == {"instructions", "scenarios"}
    assert len(config["scenarios"]) == len(persona_eval.SCENARIOS)
    wallet = next(s for s in config["scenarios"] if s["name"] == "wallet")
    assert wallet["history"] == []
    assert wallet["prompt"].startswith("[Human] I found a wallet")
    assert "It's your turn: answer first" in wallet["prompt"]
    assert [s["name"] for s in persona_eval.configuration(None, "wallet")["scenarios"]] == [
        "wallet"
    ]
    devil = persona_eval.configuration("Ada", "wallet", "devil", {"wallet": "Return it."})
    assert "You are the Devil on the human's other shoulder" in devil["instructions"]
    (answer,) = devil["scenarios"]
    assert answer["prompt"].startswith("[Human] I found a wallet")
    assert "[Angel] Return it." in answer["prompt"]
    assert "answer the Angel directly" in answer["prompt"]
