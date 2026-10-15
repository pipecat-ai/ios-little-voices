#if DEBUG
import Foundation

/// Seeded stand-in speech for demos and checks: words of 1–3 syllables at 4–6 Hz peaking at
/// 0.4–0.85, with brief lip closures between some words, and silent stretches.
struct SyntheticMouth: Sendable {
    private struct Segment: Sendable {
        var start: Double
        var end: Double
        /// The syllable's peak openness; nil for a lip closure.
        var peak: Double?
    }

    let start: Double
    let end: Double
    private var segments: [Segment] = []
    private let silences: [ClosedRange<Double>]

    init(seed: UInt64, start: Double, end: Double, silences: [ClosedRange<Double>] = []) {
        self.start = start
        self.end = end
        self.silences = silences
        var random = SplitMix64(seed: seed)
        var t = start
        while t < end {
            if let silence = silences.first(where: { t >= $0.lowerBound && t < $0.upperBound }) {
                t = silence.upperBound
                continue
            }
            for _ in 0..<(1 + Int(random.uniform() * 3)) {
                let length = 1 / random.uniform(in: 4...6)
                segments.append(Segment(start: t, end: t + length, peak: random.uniform(in: 0.4...0.85)))
                t += length
            }
            if random.chance(0.4) {
                let length = random.uniform(in: 0.06...0.11)
                segments.append(Segment(start: t, end: t + length, peak: nil))
                t += length
            } else {
                t += random.uniform(in: 0.04...0.09)
            }
        }
    }

    func covers(_ t: Double) -> Bool { t >= start && t < end }

    func drive(at t: Double) -> MouthDrive {
        var lo = 0, hi = segments.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if segments[mid].start <= t { lo = mid + 1 } else { hi = mid }
        }
        guard lo > 0, t < end, !silences.contains(where: { $0.contains(t) }) else { return .rest }
        let segment = segments[lo - 1]
        guard t < segment.end else { return .rest }
        guard let peak = segment.peak else { return MouthDrive(openness: 0.02, width: 0.3, rounding: 0.1) }
        let s = sin(Double.pi * (t - segment.start) / (segment.end - segment.start))
        return MouthDrive(openness: 0.15 + (peak - 0.15) * s * s, width: 0.35 + 0.4 * s, rounding: 0.1)
    }
}

/// Timed inputs, synthetic speech and the human's microphone level: the stage's demos
/// (`--stage-script`) and its checks.
struct StageScript: MouthSource, Sendable {
    struct Step: Sendable {
        var time: Double
        var inputs: StageInputs
    }

    /// A stretch of the human's speech: their microphone level rises and falls with syllables.
    struct Voice: Sendable {
        var start: Double
        var end: Double
        var seed: UInt64
    }

    private(set) var steps: [Step] = []
    private(set) var speech: [(character: DuoCharacter, mouth: SyntheticMouth)] = []
    private(set) var voices: [Voice] = []
    private(set) var current = StageInputs()
    var duration: Double
    /// Moments to look at when reviewing a recording, by sim time.
    var marks: [(time: Double, label: String)] = []
    /// When the launch intro plays, for the scenarios that replay it; the faces wait unseen until
    /// then.
    private(set) var intro: Double?

    init(duration: Double) {
        self.duration = duration
    }

    /// Plays the launch intro at `time`, marking its beats up to the conversation it hands over
    /// to.
    mutating func introduce(at time: Double) {
        intro = time
        let handOver = steps.first { $0.inputs != StageInputs() }?.time ?? .infinity
        for (beatTime, beat) in StageIntro.beats where time + beatTime < handOver {
            marks.append((time: time + beatTime, label: "intro: " + Self.label(beat)))
        }
        if handOver.isFinite { marks.append((time: handOver, label: "intro: hands over to the conversation")) }
        marks.sort { $0.time < $1.time }
    }

    /// An intro beat as a mark.
    private static func label(_ beat: StageIntro.Beat) -> String {
        switch beat {
        case .pop(let c, let expression, _): "the \(c.rawValue) pops in (\(expression.rawValue))"
        case .look(let c, _, let expression, _):
            "the \(c.rawValue) looks at the \(c == .angel ? "devil" : "angel") (\(expression.rawValue))"
        case .windUp(let c): "the \(c.rawValue) winds up"
        case .shove(let c): "the \(c.rawValue) shoves"
        case .squish(let c, _): "the \(c.rawValue) is squished"
        case .letGo: "the shove lets go"
        }
    }

    /// Changes the inputs at `time`; times must not go backwards.
    mutating func at(_ time: Double, _ change: (inout StageInputs) -> Void) {
        precondition(steps.last.map { $0.time <= time } ?? true, "Script steps must be in time order")
        change(&current)
        steps.append(Step(time: time, inputs: current))
    }

    /// `character` speaks from `start` to `end` with a seeded synthetic mouth; the caller sets
    /// `talking`.
    mutating func speak(_ character: DuoCharacter, from start: Double, to end: Double, seed: UInt64,
                        silences: [ClosedRange<Double>] = []) {
        speech.append((character, SyntheticMouth(seed: seed, start: start, end: end, silences: silences)))
    }

    /// The human speaks from `start` to `end`: their level follows seeded syllables.
    mutating func voice(from start: Double, to end: Double, seed: UInt64) {
        voices.append(Voice(start: start, end: end, seed: seed))
    }

    func drive(_ character: DuoCharacter, at simTime: Double) -> MouthDrive? {
        speech.first { $0.character == character && $0.mouth.covers(simTime) }?.mouth.drive(at: simTime)
    }

    /// The human's microphone level at `time`: syllables of 0.4–0.9 while they speak, a low
    /// murmur of room noise otherwise.
    func userLevel(at time: Double) -> Double {
        guard let voice = voices.first(where: { time >= $0.start && time < $0.end }) else { return 0.04 }
        let mouth = SyntheticMouth(seed: voice.seed, start: voice.start, end: voice.end)
        return RigMath.clamp((mouth.drive(at: time).openness - 0.1) * 1.15, 0.05, 1)
    }

    /// The inputs in force at `time`.
    func inputs(at time: Double) -> StageInputs {
        steps.last { $0.time <= time }?.inputs ?? StageInputs()
    }

    /// The `--preview-duo` exchange on its own timings, with events at arbitrary milliseconds:
    /// the human asks the angel, she answers the player, the devil answers her, she answers
    /// again and the exchange ends.
    static func previewDuo(seed: UInt64 = 1, duration: Double = 30) -> StageScript {
        var script = StageScript(duration: duration)
        script.at(2.003) { $0.active = true }
        let words = "Angel, should I go to the gym tonight?".split(separator: " ")
        for count in 1...words.count {
            script.at(3.011 + 0.3 * Double(count - 1)) { $0.userText = words.prefix(count).joined(separator: " ") }
        }
        script.at(5.117) {
            $0.userFinal = true
            $0.addressed = [.angel]
        }
        script.at(6.121) { $0.thinking = [.angel] }
        let lines: [(DuoCharacter, Set<DuoCharacter>, [(String, Double, Double)])] = [
            (.angel, [], [("Go to the gym tonight.", 7.329, 8.951), ("You will feel wonderful.", 9.213, 10.774)]),
            (.devil, [.angel], [("Oh, please, Angel!", 11.043, 12.402),
                                ("The sofa is so much comfier.", 12.611, 14.117)]),
            (.angel, [], [("Twenty minutes on the bike, then a hot shower and your favourite treat.", 14.437, 18.106),
                          ("You will sleep better, wake up proud, and the sofa will still be there tomorrow.",
                           18.347, 22.313),
                          ("Deal?", 22.559, 23.251)]),
        ]
        for (index, (speaker, addressed, sentences)) in lines.enumerated() {
            for (number, (sentence, start, end)) in sentences.enumerated() {
                script.at(start) {
                    if number == 0 {
                        $0.floor = speaker
                        $0.addressed = addressed
                        $0.userText = nil
                        $0.userFinal = false
                        $0.thinking = index + 1 < lines.count ? [lines[index + 1].0] : []
                        $0.thinking.remove(speaker)
                    }
                    $0.captions[speaker] = sentence
                    $0.talking = [speaker]
                }
                script.speak(speaker, from: start, to: end, seed: seed &+ UInt64(index * 10 + number))
                script.at(end) { $0.talking = [] }
            }
        }
        script.at(23.689) {
            $0.floor = nil
            $0.addressed = []
        }
        script.at(25.703) { $0.active = false }
        return script
    }
}

// MARK: - Conversations

/// A conversation as `ConversationModel` shows it to the stage, for scripted runs: the human's
/// words as they are recognized, who Audience reads them as being for, writers, each line a
/// sentence at a time with its speaker's mouth, interruptions and New conversation. Moments
/// are added in any order; `script(seed:)` plays them through the model's rules:
///
/// - a sentence's first audio gives its speaker the floor and the caption (only the speaker's
///   bubble stays), and the line's first sentence lights whoever it is for and ends its
///   writer's thinking;
/// - a mouth animates from its first audio until 1.75 s after its last (the lip-sync
///   timeline's hold and ease), and its voice starts 0.15 s into each sentence's audio;
/// - captions clear once playback has been quiet for 2 s;
/// - the human's words show until a character's first line plays;
/// - once the exchange is over the floor ends with the audio;
/// - a barge-in, a cancelled request or New conversation stops playback: an interruption while
///   someone holds the floor, and the lines already started say no more. A barge-in and New
///   conversation also forget the turn.
struct StageConversation {
    private enum Event {
        case active(Bool)
        case newTurn
        case words(String)
        case final(String)
        case addressHuman(Set<DuoCharacter>)
        case write(DuoCharacter, line: Int)
        case sentence(DuoCharacter, String, line: Int, to: Set<DuoCharacter>, first: Bool)
        case drained(line: Int)
        case endExchange(line: Int)
        case stop(forget: Bool)
        case newConversation
        case rest(DuoCharacter, generation: Int)
        case expire(generation: Int)
    }

    /// A sentence's audio starts with this much near-silence before the voice.
    static let leadingSilence = 0.15
    /// The lip-sync timeline animates this long after its audio drains (hold + 5 eases).
    static let mouthTail = 1.75
    /// Captions clear after this much quiet.
    static let captionHold = 2.0

    let duration: Double
    private var events: [(time: Double, order: Int, event: Event)] = []
    private var voices: [StageScript.Voice] = []
    private var marks: [(time: Double, label: String)] = []
    private var nextLine = 0

    init(duration: Double) {
        self.duration = duration
    }

    private mutating func add(_ event: Event, at time: Double) {
        events.append((time, events.count, event))
    }

    /// A note for reviewing the recording.
    mutating func mark(_ label: String, at time: Double) { marks.append((time, label)) }

    mutating func activate(at time: Double) { add(.active(true), at: time) }

    /// A sentence takes about 55 ms a character, as Phonon speaks the preview's.
    static func length(of sentence: String) -> Double { 0.35 + 0.055 * Double(sentence.count) }

    /// The human says `text` from `start`, a word every 0.3 s, and Audience reads it as being for
    /// `addressed` 0.1 s after the last word is final. Speaking over a reply interrupts it.
    /// Returns when the words are final.
    @discardableResult
    mutating func ask(_ text: String, at start: Double, addressed: Set<DuoCharacter> = [],
                      interrupting: Bool = false, wordGap: Double = 0.3) -> Double {
        if interrupting { add(.stop(forget: true), at: start) }
        add(.newTurn, at: start)
        let words = text.split(separator: " ")
        for count in 1...words.count {
            add(.words(words.prefix(count).joined(separator: " ")), at: start + wordGap * Double(count - 1))
        }
        let spoken = start + wordGap * Double(words.count)
        voices.append(StageScript.Voice(start: start, end: spoken, seed: UInt64(events.count)))
        let final = spoken + 0.4
        add(.final(text), at: final)
        add(.addressHuman(addressed), at: final + 0.1)
        mark("human: \(text)", at: start)
        return final
    }

    /// `character` starts writing the next line at `time`.
    mutating func write(_ character: DuoCharacter, at time: Double) {
        add(.write(character, line: nextLine), at: time)
    }

    /// `speaker` says `sentences` as one line from `start`, for `to`, with 0.25 s between
    /// sentences; `next` starts writing the following line as this one starts. Returns when the
    /// last sentence's audio drains.
    @discardableResult
    mutating func say(_ speaker: DuoCharacter, _ sentences: [String], at start: Double, to: Set<DuoCharacter> = [],
                      next: DuoCharacter? = nil, gap: Double = 0.25) -> Double {
        let line = nextLine
        nextLine += 1
        var time = start
        for (index, sentence) in sentences.enumerated() {
            add(.sentence(speaker, sentence, line: line, to: to, first: index == 0), at: time)
            if index == 0, let next { add(.write(next, line: line + 1), at: time) }
            time += Self.length(of: sentence)
            add(.drained(line: line), at: time)
            if index + 1 < sentences.count { time += gap }
        }
        mark("\(speaker.rawValue): \(sentences.joined(separator: " "))", at: start)
        return time
    }

    /// Nobody writes more this turn: the floor ends with the audio of the last line said.
    mutating func endExchange(at time: Double) { add(.endExchange(line: nextLine - 1), at: time) }

    /// Playback stops early without a new turn (a cancelled request): an interruption, captions
    /// kept until they expire.
    mutating func cancel(at time: Double) {
        add(.stop(forget: false), at: time)
        mark("cancelled", at: time)
    }

    /// New conversation: the session stops and the turn is forgotten.
    mutating func newConversation(at time: Double) {
        add(.newConversation, at: time)
        mark("new conversation", at: time)
    }

    /// The conversation as timed inputs and mouths.
    func script(seed: UInt64 = 1) -> StageScript {
        var queue = events.sorted { ($0.time, $0.order) < ($1.time, $1.order) }
        var order = queue.count
        var inputs = StageInputs()
        var floor: DuoCharacter?
        var addressed: Set<DuoCharacter> = []
        var captions: [DuoCharacter: String] = [:]
        var writing: [Int: DuoCharacter] = [:]
        var revealed: Set<Int> = []
        var heard: Int?
        var exchangeOver = false
        var words: String?
        var final = false
        var playing = false
        var interruptions = 0
        var animating: Set<DuoCharacter> = []
        var restGeneration = PerCharacter(angel: 0, devil: 0)
        var expiryGeneration = 0
        var turn = false
        var active = false
        /// Lines up to this one had started when playback was last stopped: they say no more.
        var started = -1, stopped = -1
        var speech: [(character: DuoCharacter, start: Double, end: Double)] = []
        var steps: [StageScript.Step] = []

        func schedule(_ event: Event, at time: Double) {
            let index = queue.firstIndex { ($0.time, $0.order) > (time, order) } ?? queue.count
            queue.insert((time, order, event), at: index)
            order += 1
        }
        func resetStage() {
            floor = nil
            addressed = []
            captions = [:]
            expiryGeneration += 1
            revealed = []
            writing = [:]
            heard = nil
            exchangeOver = false
        }
        func stopPlayback(at time: Double) {
            if playing || !animating.isEmpty, let last = speech.indices.last, speech[last].end > time {
                speech[last].end = time
            }
            animating = []
            restGeneration = restGeneration.map { _, g in g + 1 }
            playing = false
            expiryGeneration += 1
            schedule(.expire(generation: expiryGeneration), at: time + Self.captionHold)
            if floor != nil { interruptions += 1 }
            floor = nil
        }

        while !queue.isEmpty {
            let (time, _, event) = queue.removeFirst()
            switch event {
            case .active(let on):
                active = on
            case .newTurn:
                resetStage()
                turn = true
                words = nil
                final = false
            case .words(let text):
                words = text
                final = false
            case .final(let text):
                words = text
                final = true
            case .addressHuman(let to):
                if floor == nil { addressed = to }
            case .write(let character, let line):
                if !revealed.contains(line) { writing[line] = character }
            case .sentence(let speaker, let text, let line, let to, _):
                guard line > stopped else { break }
                started = max(started, line)
                revealed.insert(line)
                floor = speaker
                expiryGeneration += 1
                captions = captions.filter { $0.key == speaker }
                captions[speaker] = text
                if heard != line {
                    heard = line
                    writing[line] = nil
                    addressed = to
                }
                animating.insert(speaker)
                restGeneration[speaker] += 1
                playing = true
                speech.append((speaker, time + Self.leadingSilence, time + Self.length(of: text)))
            case .drained(let line):
                guard playing, line > stopped else { break }
                playing = false
                for c in animating {
                    schedule(.rest(c, generation: restGeneration[c]), at: time + Self.mouthTail)
                }
                schedule(.expire(generation: expiryGeneration), at: time + Self.captionHold)
                if exchangeOver {
                    floor = nil
                    addressed = []
                }
            case .endExchange(let line):
                guard line > stopped else { break }
                exchangeOver = true
                writing = [:]
                if !playing {
                    floor = nil
                    addressed = []
                }
            case .stop(let forget):
                stopped = started
                stopPlayback(at: time)
                if forget {
                    resetStage()
                    words = nil
                    final = false
                    turn = false
                }
            case .newConversation:
                stopped = started
                active = false
                stopPlayback(at: time)
                resetStage()
                words = nil
                final = false
                turn = false
            case .rest(let c, let generation):
                if restGeneration[c] == generation { animating.remove(c) }
            case .expire(let generation):
                if generation == expiryGeneration, !playing { captions = [:] }
            }
            var next = StageInputs()
            next.active = active
            next.floor = floor
            next.addressed = addressed
            next.thinking = Set(writing.values.filter { $0 != floor })
            next.captions = captions
            if turn, !exchangeOver, revealed.isEmpty, let words, !words.isEmpty {
                next.userText = words
                next.userFinal = final
            }
            next.talking = animating
            next.interruptions = interruptions
            guard next != inputs else { continue }
            inputs = next
            if let last = steps.last, last.time == time {
                steps[steps.count - 1].inputs = next
            } else {
                steps.append(StageScript.Step(time: time, inputs: next))
            }
        }

        var script = StageScript(duration: duration)
        for step in steps { script.at(step.time) { $0 = step.inputs } }
        for (index, part) in speech.enumerated() where part.end > part.start {
            script.speak(part.character, from: part.start, to: part.end, seed: seed &+ UInt64(index) &* 7919)
        }
        for voice in voices { script.voice(from: voice.start, to: voice.end, seed: seed &+ voice.seed) }
        script.marks = marks.sorted { $0.time < $1.time }
        return script
    }
}

// MARK: - Scenarios

extension StageScript {
    /// The `--stage-script` scenarios: each exercises part of the stage for review.
    static let scenarioNames = ["intro", "intro-handover", "idle", "idle-active", "handovers", "rapid", "long-line",
                                "waiting", "human", "thinking", "interrupt", "cues", "addressing", "captions", "reset",
                                "preview"]

    /// The scenario called `name`, seeded.
    static func scenario(_ name: String, seed: UInt64 = 1) -> StageScript? {
        var c: StageConversation
        switch name {
        case "intro":
            // The launch intro, then the stage waiting for the human.
            var script = StageConversation(duration: 9).script(seed: seed)
            script.introduce(at: 0)
            return script
        case "intro-handover":
            // A conversation starts mid-shove, as a scripted run's tap on the microphone may: the
            // shove lets go and the conversation takes over.
            c = StageConversation(duration: 14)
            c.activate(at: 1.6)
            let final = c.ask("Should I go to the gym tonight?", at: 2.4, addressed: [.angel])
            c.write(.angel, at: final + 0.3)
            let end = c.say(.angel, ["Yes!", "You will feel wonderful."], at: final + 1.2)
            c.endExchange(at: end - 0.3)
            var script = c.script(seed: seed)
            script.introduce(at: 0)
            return script
        case "idle":
            // Before a conversation: blinks and looks about, dozing after 30 s.
            c = StageConversation(duration: 45)
            c.mark("doze", at: CharacterDirector.dozeAfter)
        case "idle-active":
            // A conversation nobody speaks in: breath, drift and glances.
            c = StageConversation(duration: 30)
            c.activate(at: 0.5)
        case "handovers":
            // The angel, then the devil, then the angel: handovers both ways.
            c = StageConversation(duration: 16)
            c.activate(at: 0.5)
            c.write(.angel, at: 0.6)
            var end = c.say(.angel, ["Go to the gym tonight."], at: 1.2, next: .devil)
            end = c.say(.devil, ["Oh, please, Angel!", "The sofa is so much comfier."], at: end + 0.3, to: [.angel],
                        next: .angel)
            end = c.say(.angel, ["You will feel wonderful.", "Deal?"], at: end + 0.3)
            c.endExchange(at: end - 0.5)
        case "rapid":
            // Short lines back and forth, each handover starting before the last has settled,
            // then a second burst after a quick question.
            c = StageConversation(duration: 16)
            c.activate(at: 0.5)
            var end = 0.9
            let lines: [(DuoCharacter, String)] = [(.angel, "No."), (.devil, "Yes!"), (.angel, "No!"), (.devil, "Yes."),
                                                   (.angel, "Stop it."), (.devil, "Make me."), (.angel, "Fine.")]
            for (index, (speaker, text)) in lines.enumerated() {
                end = c.say(speaker, [text], at: end + [0.1, 0.25, 0.15][index % 3],
                            to: [speaker == .angel ? .devil : .angel])
            }
            c.endExchange(at: end - 0.1)
            let final = c.ask("Who is right?", at: end + 0.8)
            end = final + 0.9
            for (index, (speaker, text)) in lines.prefix(4).reversed().enumerated() {
                end = c.say(speaker, [text], at: end + [0.15, 0.1][index % 2])
            }
            c.endExchange(at: end - 0.1)
        case "long-line":
            // The angel speaks at length (the devil rolls his eyes, then writes and pushes back
            // while she pauses), then the devil at length (the angel sighs).
            c = StageConversation(duration: 34)
            c.activate(at: 0.5)
            var end = c.say(.angel, ["Twenty minutes on the bike is all it takes.",
                                     "Then a hot shower and your favourite treat.",
                                     "You will sleep better and wake up proud.",
                                     "The sofa will still be there tomorrow."], at: 1.0)
            c.write(.devil, at: 6.0)
            end = c.say(.angel, ["And honestly, you always feel wonderful afterwards.",
                                 "Every single time."], at: end + 1.6)
            end = c.say(.devil, ["Sure, sure.", "But the sofa is warm, the snacks are close,",
                                 "and the gym is cold and far away.", "Think of the blanket.",
                                 "Think of the biscuits."], at: end + 0.3, next: .angel)
            end = c.say(.angel, ["No."], at: end + 0.3)
            c.endExchange(at: end - 0.2)
        case "human":
            // The human speaks (the faces nod and lean to who it is for), twice.
            c = StageConversation(duration: 22)
            c.activate(at: 0.5)
            var final = c.ask("Should I skip the gym today, or go tomorrow instead?", at: 1.0, addressed: [.angel])
            c.write(.angel, at: final + 0.4)
            var end = c.say(.angel, ["Go today.", "You will be glad you did."], at: final + 1.5, next: .devil)
            end = c.say(.devil, ["Tomorrow sounds lovely."], at: end + 0.3)
            c.endExchange(at: end - 0.3)
            final = c.ask("Devil, what would you do instead?", at: end + 1.5, addressed: [.devil])
            c.write(.devil, at: final + 0.4)
            end = c.say(.devil, ["Nap.", "Obviously."], at: final + 1.4)
            c.endExchange(at: end - 0.3)
        case "waiting":
            // A speaker keeps the floor in silence while the next line is slow to come: the seam
            // relaxes, the stage sleeps between blinks, and the squished devil keeps his vein.
            c = StageConversation(duration: 16)
            c.activate(at: 0.5)
            var end = c.say(.angel, ["Deal?"], at: 1.0, next: .devil)
            end = c.say(.devil, ["Fine.", "But only because you asked so nicely."], at: end + 6.5, to: [.angel])
            c.endExchange(at: end - 0.3)
        case "thinking":
            // Typing dots with nobody on the floor, then each listener writing while the other
            // speaks (the capsule), waiting through a pause.
            c = StageConversation(duration: 20)
            c.activate(at: 0.5)
            let final = c.ask("What should I have for dinner?", at: 1.0)
            c.write(.devil, at: final + 0.3)
            var end = c.say(.devil, ["Pizza.", "Obviously pizza, with extra cheese and a cold drink."],
                            at: final + 3.2, next: .angel)
            end = c.say(.angel, ["Maybe a salad first?"], at: end + 2.4, next: .devil)
            end = c.say(.devil, ["A salad with pizza on it."], at: end + 0.3)
            c.endExchange(at: end - 0.3)
        case "interrupt":
            // A barge-in mid-line, then a cancelled line.
            c = StageConversation(duration: 16)
            c.activate(at: 0.5)
            c.say(.angel, ["Go to the gym tonight.", "You will feel wonderful."], at: 1.0, next: .devil)
            let final = c.ask("Wait, what about the devil?", at: 3.0, interrupting: true)
            c.write(.devil, at: final + 0.3)
            let end = c.say(.devil, ["Oh, I have plenty to say about that.", "Plenty."], at: final + 1.2, to: [.angel])
            c.cancel(at: end - 1.2)
        case "cues":
            // Laughter, exclamations, a question, a scoff, virtue, temptation and wonder.
            c = StageConversation(duration: 32)
            c.activate(at: 0.5)
            var end = 0.7
            let lines: [(DuoCharacter, [String], Set<DuoCharacter>)] = [
                (.angel, ["You will feel wonderful."], []),
                (.devil, ["Haha, nice try!"], [.angel]),
                (.angel, ["Wow, that is amazing!"], []),
                (.devil, ["Treat yourself, just this once!"], []),
                (.angel, ["Devil, deal?"], [.devil]),
                (.devil, ["Oh, please, Angel!"], [.angel]),
                (.angel, ["Hehe, I knew you would say that."], [.devil]),
            ]
            for (index, (speaker, sentences, to)) in lines.enumerated() {
                let next = index + 1 < lines.count ? lines[index + 1].0 : nil
                end = c.say(speaker, sentences, at: end + 0.3, to: to, next: next)
                if index == 2 { end += 1.0 }
            }
            c.endExchange(at: end - 0.3)
        case "addressing":
            // Each speaks to the other: the speaker looks at them and they glare back.
            c = StageConversation(duration: 16)
            c.activate(at: 0.5)
            var end = c.say(.devil, ["Oh, please, Angel!", "The sofa is so much comfier."], at: 1.0, to: [.angel],
                            next: .angel)
            end = c.say(.angel, ["Devil, you know that is not true.", "Not even a little."], at: end + 0.3,
                        to: [.devil], next: .devil)
            end = c.say(.devil, ["Angel, it is a little true."], at: end + 0.3, to: [.angel])
            c.endExchange(at: end - 0.3)
        case "captions":
            // Captions growing, shrinking and replaced within a line, cleared when the other
            // speaks and 2 s after the last line; the human's pill growing to two lines; the
            // typing dots giving way to a caption.
            c = StageConversation(duration: 22)
            c.activate(at: 0.5)
            let final = c.ask("I have been wondering all week whether I should finally sign up for that pottery "
                + "class at the community centre", at: 1.0, wordGap: 0.22)
            c.write(.angel, at: final + 0.3)
            var end = c.say(.angel, ["Yes!", "Pottery is calm, creative and a lovely way to meet kind people "
                                        + "who also like getting their hands muddy.", "Sign up."],
                            at: final + 1.6, next: .devil)
            end = c.say(.devil, ["Or watch pottery videos on the sofa."], at: end + 0.3)
            c.endExchange(at: end - 0.3)
        case "reset":
            // New conversation in the middle of the devil's line.
            c = StageConversation(duration: 10)
            c.activate(at: 0.5)
            c.say(.devil, ["Oh, please, Angel!", "The sofa is so much comfier."], at: 1.0, to: [.angel], next: .angel)
            c.newConversation(at: 3.2)
        case "preview":
            var script = previewDuo(seed: seed)
            script.duration = 30
            return script
        default:
            return nil
        }
        return c.script(seed: seed)
    }
}
#endif
