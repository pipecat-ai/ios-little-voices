"""The rules baseline: word matching plus the rules of evidence (harness/addressee/evidence.py). No model.

It is the floor every model is compared against, the scene demo's first engine, and the harness's instant fallback.
What the words pick out is guessed from the text:

1. Names: a person's label or alias used to call them: at the start, after a greeting or "hey", or set off by commas
   ("Tomas, another round", "Oi, barkeep!"). A name the line only talks about ("tell Wren", "talking to the mechanic")
   is not a call. Two or more calls are a set named on purpose ("Tomas, Wren, a word").
1b. Neighbours: "you, talking to the barkeep" points at whoever's card says they are with the barkeep.
2. Group words with no name: "everyone", "anyone", "someone", "all of you", "you guys", "you lot", "listen up". "You
   two" and "both of you" are the two people present when there are two, otherwise the group (rule 2).
3. Descriptions: content words of each visible feature value found in the line ("red hat" in "you in the red hat").
   The person or people with the most matching words are picked out. A word matches a longer one it starts
   ("fire" and "fireplace") when it has four letters or more.

Then `evidence.resolve` applies the rules of evidence with the history and the spatial facts. Known limits: no fuzzy
match for misheard names, and any shared content word counts as a description, even an incidental one.

Version 0.3 of the rules (rc2's) adds questions to the room (rule 2b): "Who knows where the mill key is?", "Anyone seen my
horse?", "Does anybody here sell rope?", "Can any of you...". "Anyone" and the like count when they are who the line
asks (first in a sentence, or right after the question's verb), not what it asks about ("Have you seen anyone?"); "who"
counts when it asks which of the listeners knows, has, saw or wants something ("Who's got a light?"), not "Who are
you?". A name that calls someone still wins. And a character may speak (rule 6): the matcher reads the line the same
way, with the player's card among the people. `guide="0.2"` reads lines exactly as version 0.2 did: rc1's inputs
(addressee-tt-0.5) are built with it, so they never change.
"""
from __future__ import annotations

import re

from contracts.schemas.addressee import AddresseeAnswer, AddresseeLabel, AddresseeRequest
from harness.addressee.evidence import Evidence, resolve

STOP = frozenset("""a an the of and or to in on at by with from for as is are was were be been it its this that these those
there here you your yours you're ya ye u i me my mine we us our he him his she her hers they them their one ones who what
which where when how why do does did not no yes so but if then than just very too some any all also over up down out
into onto off about around near next behind front back side left right old new big small little bit lot""".split())
GUIDE = "0.3"  # the guide the rules follow unless told otherwise; "0.2" for the inputs of models trained under it
# Words that, with no name in the line, address the whole group (guide 0.2; 0.3 moves "anyone" and the like to ROOM).
GROUP = re.compile(r"\b(everyone|everybody|anyone|anybody|someone|somebody|all of you|you all|y'?all|you lot|you people|"
                   r"you guys|guys|folks|lads|gents|listen up|listen to me|gather round|(morning|evening|afternoon|hello|hi|hey|night),? all)\b", re.I)
GROUP_03 = re.compile(r"\b(everyone|everybody|all of you|you all|y'?all|you lot|you people|you guys|guys|folks|lads|gents|"
                      r"listen up|listen to me|gather round|(morning|evening|afternoon|hello|hi|hey|night),? all)\b", re.I)
# Guide 0.3, rule 2b: a question or request to whoever can hear.
_ANY = r"(?:anyone|anybody|someone|somebody|any ?one)"
_INTRO = r"(?:(?:hey|oi|right|ok|okay|so|well|now|um|uh|er|listen|look|please|excuse me|sorry|quick question)[\s,!.]+)*"
ROOM = re.compile(
    r"(?:^|[.!?;:]\s*)" + _INTRO + _ANY + r"\b"                                         # "Anyone seen my horse?", "Somebody, help!"
    r"|\b(?:does|did|do|has|have|had|is|was|are|were|can|ca|could|will|wo|would|might|may|should|shall)(?:n['’]?t)?\s+" + _ANY + r"\b"
    r"|\bis there\s+" + _ANY + r"\b"
    r"|\b(?:any|which|whichever|either|one) of you\b|\bamong you\b"
    r"|\bwho\s*(?:here|among|else|knows|saw|heard|wants|fancies|needs|can|could|will|would|['’]ll|['’]d|has (?:got|seen|been)|"
    r"(?:['’]s|is|has) (?:got|seen|been|coming|going|heading|up for|ready|willing|interested|buying)|got)\b", re.I)
PAIR = re.compile(r"\b(you two|both of you|you both|the pair of you|the two of you)\b", re.I)
# Simple, harmless lines (rule 5): greetings, small talk, simple questions, thanks, polite requests.
SIMPLE = re.compile(r"\b(hello|hi|hiya|hey there|hey|howdy|greetings|good (morning|afternoon|evening|day|night)|morning|evening|"
                    r"afternoon|well met|ahoy|yo|g'?day|what'?s up|who are you|what'?s your name|what is your name|who'?s this|"
                    r"what is this place|what'?s this place|where am i|where'?s|where is|what do you (do|sell|have|want|need)|how much|"
                    r"can you help|could you help|can i ask|excuse me|pardon|how are you|how'?s it going|how do you do|"
                    r"(nice|pleased|good) to meet|what'?s going on|what happened|any news|what'?s new|got a (minute|moment|sec)|"
                    r"do you know|have you seen|can i (buy|get|have)|i'?d like|thanks|thank you|cheers|much obliged|goodbye|bye|"
                    r"see you|farewell|take care|nice (weather|day|place)|(is|are) \w+ (around|here|about|in))\b", re.I)
# Words that give a line consequences (rule 4): insults, threats, accusations, orders to go away.
HOSTILE = re.compile(r"\b(idiot|moron|fool|stupid|dumb|useless|worthless|pathetic|scum|bastard|damn|shut up|get out|go away|"
                     r"piss|crap|ugly|loser|coward|liar|lied|lying|thief|stole|steal|kill|gut|hurt|smash|break your|fuck|shit|"
                     r"wanker|git|prat|twit|clown|filthy|disgusting|stink|lazy|move it|out of my way|hate|rat|pig|wretch)\b", re.I)


# Lines that open an exchange rather than carry one on (rule 5): greetings and introductions.
OPENER = re.compile(r"\b(hello|hi|hiya|hey there|hey|howdy|greetings|good (morning|afternoon|evening|day)|well met|ahoy|g'?day|"
                    r"who are you|who'?s this|what'?s your name|what is your name|(nice|pleased|good) to meet|excuse me|pardon me|"
                    r"sorry to bother|got a (minute|moment|sec)|have you got a (minute|moment))\b", re.I)


def room_words(text: str) -> bool:
    """Words that open the line to whoever can hear (guide 0.3, rule 2b)."""
    return bool(ROOM.search(text))


def is_opener(text: str) -> bool:
    """A line that opens an exchange (a greeting, "who are you?"), not one that carries the conversation on."""
    return bool(OPENER.search(text))


def is_simple(text: str) -> bool:
    """A simple, harmless line (rule 5): simple words or a short question, and nothing hostile."""
    if HOSTILE.search(text):
        return False
    short_question = text.rstrip().endswith("?") and len(_words(text)) <= 8
    return bool(SIMPLE.search(text)) or short_question
WORD = re.compile(r"[a-z0-9']+")


def _words(text: str) -> list[str]:
    return [w.strip("'") for w in WORD.findall(text.lower()) if w.strip("'")]


def _content(text: str) -> set[str]:
    return {w for w in _words(text) if w not in STOP and len(w) > 1}


def _match(a: str, b: str) -> bool:
    if a == b:
        return True
    short, long_ = sorted((a, b), key=len)
    return len(short) >= 4 and long_.startswith(short)


def _name_hit(name: str, line_words: list[str]) -> bool:
    parts = _words(name)
    if parts and parts[0] == "the" and len(parts) > 1:
        parts = parts[1:]
    n = len(parts)
    return n > 0 and any(line_words[i:i + n] == parts for i in range(len(line_words) - n + 1))


# Words that may come before a name that calls someone ("Hey, Tomas", "Excuse me Tomas", "Good morning, Tomas").
LEAD = frozenset("""hey oi hi hello excuse me sorry right ok okay well listen look yo ah um uh so and now please thanks thank you
dear good morning evening afternoon night sir madam ma'am miss mister oh""".split())
# Phrases that point at someone by who they are with ("you, talking to the mechanic").
NEIGHBOUR = re.compile(r"\b(talking to|talking with|chatting with|chatting to|speaking to|speaking with|sitting with|standing with|"
                       r"next to|beside|with)\s+(the\s+)?$", re.I)


def name_use(name: str, text: str, guide: str = GUIDE) -> str | None:
    """How the line uses a name: "call" when it calls that person (at the start, after a greeting or "hey", or set
    off by commas or at the end after a comma), "mention" when it only talks about them ("tell Wren", "talking to the
    mechanic"), None when the name is absent (rule 3). Under guide 0.3 a name with 's ("Hale's the one you want",
    "Wren's horse") is a mention."""
    parts = _words(name)
    if parts and parts[0] == "the" and len(parts) > 1:
        parts = parts[1:]
    if not parts:
        return None
    pattern = re.compile(r"\b" + r"\W+".join(re.escape(x) for x in parts) + r"\b", re.I)
    use = None
    for m in pattern.finditer(text):
        before, after = text[:m.start()], text[m.end():]
        b = before.rstrip()
        b = re.sub(r"\bthe$", "", b, flags=re.I).rstrip() if re.search(r"\bthe$", b, re.I) else b
        clause = re.split(r"[,.!?;:]", b)[-1]  # only the words since the last comma or full stop count as a lead-in
        lead = all(w in LEAD for w in _words(clause))
        opens = (not b) or b[-1] in ",!.?:;" or lead
        closes = (not after.strip()) or after.lstrip()[:1] in ",!.?:;"
        if NEIGHBOUR.search(before):
            use = use or "mention"
        elif guide != "0.2" and re.match(r"['’]s\b", after):
            use = use or "mention"
        elif opens and (closes or lead or not b):
            return "call"
        else:
            use = "mention"
    return use


def _neighbour_of(c, req: AddresseeRequest, text: str) -> bool:
    """The line points at `c` by who they are with: "talking to the barkeep" and c's card says they are talking to
    Tomas, whose alias is the barkeep."""
    withs = [f.value for f in c.features if f.key.lower() == "with" and f.visible]
    if not withs:
        return False
    for other in req.present:
        if other.id == c.id:
            continue
        if any(any(_name_hit(nm, _words(w)) for nm in other.names) for w in withs):
            for nm in other.names:
                parts = _words(nm)
                if parts and parts[0] == "the" and len(parts) > 1:
                    parts = parts[1:]
                m = re.search(r"\b" + r"\W+".join(re.escape(x) for x in parts) + r"\b", text, re.I) if parts else None
                if m and NEIGHBOUR.search(text[:m.start()]):
                    return True
    return False


def words_evidence(req: AddresseeRequest, guide: str = GUIDE) -> Evidence:
    """What the words pick out. `guide="0.2"` reads the line as guide 0.2 did (no questions to the room)."""
    line = _words(req.text)
    benign = is_simple(req.text)
    follows = benign and not is_opener(req.text)
    named = [c.id for c in req.present if any(name_use(n, req.text, guide) == "call" for n in c.names)]
    if named:
        return Evidence(words=frozenset(named), words_set=len(named) > 1, benign=benign, follows=follows)
    neighbours = [c.id for c in req.present if _neighbour_of(c, req, req.text)]
    if len(neighbours) == 1:
        return Evidence(words=frozenset(neighbours), benign=benign, follows=follows)
    if PAIR.search(req.text):
        if len(req.present) == 2:
            return Evidence(words=frozenset(req.ids), words_set=True, benign=benign, follows=follows)
        return Evidence(words_group=True, benign=benign, follows=follows)
    if (GROUP if guide == "0.2" else GROUP_03).search(req.text):  # rule 2 before rule 2b: "Everyone, has anyone...?" is a group line
        return Evidence(words_group=True, benign=benign, follows=follows)
    if guide != "0.2" and room_words(req.text):
        return Evidence(words_room=True, benign=benign, follows=follows)
    line_content = {w for w in line if w not in STOP}
    scores = {}
    for c in req.present:
        best = 0
        for f in c.features:
            if not f.visible:
                continue
            best = max(best, sum(1 for w in _content(f.value) if any(_match(w, lw) for lw in line_content)))
        scores[c.id] = best
    top = max(scores.values())
    if top == 0:
        return Evidence(benign=benign, follows=follows)
    return Evidence(words=frozenset(i for i, s in scores.items() if s == top), benign=benign, follows=follows)


def rules_label(req: AddresseeRequest, guide: str = GUIDE) -> AddresseeLabel:
    return resolve(req, words_evidence(req, guide))


def answer_from_label(req: AddresseeRequest, label: AddresseeLabel) -> AddresseeAnswer:
    """A label as an answer: certainty for a clear line, an even split among the candidates for a vague one."""
    return AddresseeAnswer(addressed=label.targets(req.ids), unclear=1.0 if label.vague else 0.0,
                           to_group=1.0 if label.group else 0.0)


def rules_answer(req: AddresseeRequest, guide: str = GUIDE) -> AddresseeAnswer:
    return answer_from_label(req, rules_label(req, guide))


def match_signals(req: AddresseeRequest, guide: str = GUIDE) -> tuple[list[tuple[float, ...]], tuple[float, float, float, float]]:
    """The word matcher's raw signals, for the model to weigh: per person (name or alias used to call
    them, only mentioned, best feature match as a share of three words, has the top feature match, pointed at by who
    they are with), and for the line (group words, pair words, a simple harmless line, an opener). Group words follow
    `guide`: under 0.2 they include "anyone" and the like, under 0.3 those are room words (`room_words`)."""
    line = _words(req.text)
    line_content = {w for w in line if w not in STOP}
    names, mentions, desc = [], [], []
    for c in req.present:
        uses = {name_use(n, req.text, guide) for n in c.names}
        names.append(1.0 if "call" in uses else 0.0)
        mentions.append(1.0 if "mention" in uses and "call" not in uses else 0.0)
        best = 0
        for f in c.features:
            if f.visible:
                best = max(best, sum(1 for w in _content(f.value) if any(_match(w, lw) for lw in line_content)))
        desc.append(best)
    top = max(desc) if desc else 0
    per = [(n, m, min(d, 3) / 3.0, 1.0 if d == top and d > 0 else 0.0, 1.0 if _neighbour_of(c, req, req.text) else 0.0)
           for n, m, d, c in zip(names, mentions, desc, req.present)]
    group = GROUP if guide == "0.2" else GROUP_03
    return per, (1.0 if group.search(req.text) else 0.0, 1.0 if PAIR.search(req.text) else 0.0, 1.0 if is_simple(req.text) else 0.0,
                 1.0 if is_opener(req.text) else 0.0)
