#if DEBUG
import AVFoundation
import Foundation
import FoundationModels

/// Scripted conversations for DEBUG builds; docs/native-tts.md lists the scenarios and log lines.
///
/// `--preview-duo [scenario]` stands in for the microphone and the language model, so the rest of
/// the app plays the scenario as in a conversation. `--demo-question "…"` stands in for the
/// microphone alone and asks the live language model.
@MainActor
final class ConversationScript {
    let scenario: PreviewScenario
    let microphone: ScriptedMicrophone
    /// The characters' lines, or nil when the live language model writes them.
    let lines: ScriptedLines?
    private let demo: Bool

    private init(scenario: PreviewScenario, audio: VoiceAudioEngine, scripted: Bool, records: Bool) {
        self.scenario = scenario
        microphone = ScriptedMicrophone(audio: audio, records: records)
        lines = scripted ? ScriptedLines(scenario.lines) : nil
        demo = !scripted
    }

    /// `--preview-buffered`: each sentence is synthesized in full before it plays, so a busy machine
    /// cannot starve playback (for lip-sync recordings).
    static let buffersSpeech = ProcessInfo.processInfo.arguments.contains("--preview-buffered")

    /// `samples` once they have all arrived, as a stream again.
    static func buffered(_ samples: AsyncThrowingStream<[Float], Error>) async throws
        -> AsyncThrowingStream<[Float], Error> {
        var chunks: [[Float]] = []
        for try await chunk in samples { chunks.append(chunk) }
        return AsyncThrowingStream { continuation in
            chunks.forEach { continuation.yield($0) }
            continuation.finish()
        }
    }

    /// The run the launch arguments ask for, if any.
    static func launchRequested(audio: VoiceAudioEngine) -> ConversationScript? {
        let arguments = ProcessInfo.processInfo.arguments
        func value(after flag: String) -> String? {
            guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count,
                  !arguments[index + 1].hasPrefix("--") else { return nil }
            return arguments[index + 1]
        }
        if let question = value(after: "--demo-question") {
            let demo = PreviewScenario(name: "demo", summary: "the live model answers a question",
                                       steps: [.say(question), .floor], lines: [:])
            return ConversationScript(scenario: demo, audio: audio, scripted: false, records: true)
        }
        guard arguments.contains("--preview-duo") else { return nil }
        let name = value(after: "--preview-duo") ?? PreviewScenario.all[0].name
        guard let scenario = PreviewScenario.named(name) else {
            print("DUO_PREVIEW_FAILED: no scenario \(name); try \(PreviewScenario.all.map(\.name).joined(separator: ", "))")
            return nil
        }
        return ConversationScript(scenario: scenario, audio: audio, scripted: true,
                                  records: arguments.contains("--record-audio"))
    }

    func run(_ model: ConversationModel) async {
        let launched = ContinuousClock.now
        let monitor = PreviewMonitor(model: model)
        lines?.onIssue = { monitor.issue($0) }
        print("DUO_PREVIEW_SCENARIO: \(scenario.name): \(scenario.summary)")
        print(String(format: "DUO_PREVIEW_CLOCK: %.3f", Date().timeIntervalSince1970))
        monitor.start()
        await waitForMicrophone(model)
        // As a person would, the run waits for the launch intro, after which the microphone shows.
        try? await Task.sleep(until: launched + .seconds(StageIntro.length + 0.8), clock: .continuous)
        monitor.moment("idle")
        try? await Task.sleep(for: .seconds(1))
        // Holding to talk, the first press starts the conversation.
        if !scenario.holds { await tapMicrophone(model, monitor) }
        for step in scenario.steps { await perform(step, model, monitor) }
        monitor.moment("done")
        try? await Task.sleep(for: .seconds(2))
        microphone.stopRecording()
        monitor.stopping = true
        monitor.finish()
        model.logPythonModules()
        if demo {
            print("DEMO_DONE")
        } else {
            model.stop()
            print("DUO_PREVIEW_DONE: \(scenario.name), \(monitor.issues) issues")
        }
    }

    private func perform(_ step: PreviewScenario.Step, _ model: ConversationModel,
                         _ monitor: PreviewMonitor) async {
        switch step {
        case .pause(let seconds):
            try? await Task.sleep(for: .seconds(seconds))
        case .say(let text):
            let muted = model.muted, unheld = model.holdsToTalk && !model.talking
            await microphone.say(text) { words in if words == 4 { monitor.moment("hearing") } }
            if muted {
                monitor.check("muted speech is unheard", model.userLine == nil)
            } else if unheld {
                try? await Task.sleep(for: .milliseconds(500))
                monitor.check("speech without the microphone held is unheard", model.userLine == nil)
            } else if !(await monitor.wait(seconds: 3) { model.userLine != nil }) {
                monitor.issue("the human's words never showed: \(text)")
            }
        case .tapMicrophone:
            await tapMicrophone(model, monitor)
        case .hold(let text):
            await hold(text, model, monitor)
        case .tap:
            monitor.moment("tap")
            model.pressMicrophone()
            try? await Task.sleep(for: .milliseconds(120))
            model.releaseMicrophone()
            monitor.check("a tap shows how to talk", model.showsHoldHint)
            // A turn would show the human's words, or reopen the exchange that ended.
            let heard = await monitor.wait(seconds: 1.5) { model.userLine != nil || !model.scriptedView.exchangeOver }
            monitor.check("a tap starts no turn", !heard)
        case .background(let seconds):
            monitor.moment("background")
            monitor.stopping = true
            model.enterBackground()
            monitor.check("the conversation ends", !model.active)
            lines?.expectFreshConversation()
            try? await Task.sleep(for: .seconds(seconds))
            monitor.moment("foreground")
            model.becomeActive()
        case .newConversation:
            monitor.moment("new conversation")
            monitor.stopping = true
            model.clearConversation()
            try? await Task.sleep(for: .milliseconds(150))
            let view = model.scriptedView
            monitor.check("audio stops", !view.playing)
            monitor.check("the conversation ends", !model.active && !model.hasConversation)
            monitor.check("the stage clears", model.floor == nil && model.captions.isEmpty
                && model.addressed.isEmpty && model.userLine == nil
                && DuoCharacter.allCases.allSatisfy { !model.isThinking($0) })
            monitor.check("mouths rest", model.mouths.values.allSatisfy { !$0.isAnimating })
            lines?.expectFreshConversation()
            for _ in 0..<15 {
                try? await Task.sleep(for: .milliseconds(100))
                if model.scriptedView.playing { monitor.issue("audio after New conversation"); break }
            }
        case .line(let number):
            let found = await monitor.wait(seconds: 60) { model.scriptedView.line == number }
            if !found { monitor.issue("line \(number) never played") }
        case .floor:
            let found = await monitor.wait(seconds: 120) { monitor.floorIsHumans }
            if !found { monitor.issue("the floor never came back to the human") }
        }
    }

    /// As the dock's microphone: start a conversation, or mute or unmute the one running.
    private func tapMicrophone(_ model: ConversationModel, _ monitor: PreviewMonitor) async {
        if model.active {
            let muting = !model.muted
            monitor.moment(muting ? "muted" : "unmuted")
            model.toggleMute()
            monitor.check(muting ? "the microphone mutes" : "the microphone unmutes", model.muted == muting)
        } else {
            await waitForMicrophone(model)
            monitor.moment("start")
            monitor.stopping = false
            model.start(holdingToTalk: false)
        }
        let ready = await monitor.wait(seconds: 20) { model.active && !model.preparing }
        if !ready { monitor.issue("the microphone never became ready (\(model.error ?? "no error"))") }
    }

    /// The human holds the microphone, starting a conversation if there is none, says `text` and
    /// lets go.
    private func hold(_ text: String, _ model: ConversationModel, _ monitor: PreviewMonitor) async {
        if !model.active {
            await waitForMicrophone(model)
            monitor.moment("start")
            monitor.stopping = false
            model.start(holdingToTalk: true)
        }
        monitor.moment("press")
        model.pressMicrophone()
        guard await monitor.wait(seconds: 20, until: { model.hearing }) else {
            monitor.issue("the held microphone never listened (\(model.error ?? "no error"))")
            model.releaseMicrophone()
            return
        }
        let quiet = await monitor.wait(seconds: 0.3) { !model.scriptedView.playing && model.floor == nil }
        monitor.check("holding the microphone quiets the characters", quiet)
        await microphone.say(text) { words in if words == 4 { monitor.moment("hearing") } }
        model.releaseMicrophone()
        monitor.moment("release")
        if !(await monitor.wait(seconds: 3) { model.userLine != nil }) {
            monitor.issue("the human's words never showed: \(text)")
        }
        let ended = await monitor.wait(seconds: 3) { !model.hearing }
        monitor.check("letting go ends the turn", ended)
    }

    /// Until the microphone can be tapped: it spins while Python or the models load.
    private func waitForMicrophone(_ model: ConversationModel) async {
        while model.loading { try? await Task.sleep(for: .milliseconds(50)) }
    }
}

// MARK: - Scenarios

/// A scripted conversation: what the human does, and each character's lines in the order the
/// director asks for them.
struct PreviewScenario {
    enum Step {
        case pause(Double)
        /// The human says this, a word at a time, then falls quiet.
        case say(String)
        /// The dock's microphone: start a conversation, or mute or unmute it.
        case tapMicrophone
        /// Holding to talk: the human holds the microphone while saying this, then lets go.
        case hold(String)
        /// Holding to talk: a quick tap on the microphone, which says nothing.
        case tap
        /// The app goes to the background, as the conversation sees it, and returns after this
        /// many seconds.
        case background(Double)
        /// The New conversation button.
        case newConversation
        /// Until line `n` of the turn starts playing.
        case line(Int)
        /// Until the floor is the human's again and playback has ended.
        case floor
    }

    /// A line a character writes, or the language model's failure in its place. A line written
    /// while another plays is used up even when the human cuts in before anyone hears it.
    enum Line: CustomStringConvertible {
        case says(String)
        case fails(LanguageModelError)

        var description: String {
            switch self {
            case .says(let text): "\"\(text)\""
            case .fails(let error): "fails with \(NativeGenerationError.classify(error).code)"
            }
        }
    }

    let name: String
    let summary: String
    /// The conversation listens only while the microphone is held.
    var holds = false
    let steps: [Step]
    let lines: [DuoCharacter: [Line]]

    static func named(_ name: String) -> PreviewScenario? { all.first { $0.name == name } }

    /// The scenarios, the default first.
    static let all: [PreviewScenario] = [gym, bargeIn, newConversation, background, mute, longAndShort, markup,
                                         error, debate, hold]

    static let gym = PreviewScenario(
        name: "gym", summary: "a question for the angel, debated, with verdicts",
        steps: [.say("Angel, should I go to the gym tonight?"), .floor],
        lines: [
            .angel: [.says("Go to the gym tonight. You will feel wonderful."),
                     .says("Twenty minutes on the bike, then a hot shower and your favourite treat. You will "
                           + "sleep better, wake up proud, and the sofa will still be there tomorrow. Deal?")],
            .devil: [.says("Oh, please, Angel! The sofa is so much comfier."),
                     .says("Fine, go. But the sofa will miss you.")],
        ])

    static let bargeIn = PreviewScenario(
        name: "barge-in", summary: "the human cuts in while the devil speaks",
        steps: [.say("Should I skip the gym today?"), .line(1), .pause(1.5),
                .say("Wait, Devil, what about pizza tonight?"), .floor],
        lines: [
            .angel: [.says("Go to the gym today. You will feel wonderful afterwards."),
                     .says("Devil, the sofa can wait. Health comes first."),
                     .says("A walk first, then pizza. You will enjoy every slice even more.")],
            .devil: [.says("Oh, please, Angel! Skipping one day never hurt anyone. Stay in, put your feet up, "
                           + "and order something delicious."),
                     .says("Pizza tonight! Now you are talking. Extra cheese, no regrets.")],
        ])

    static let newConversation = PreviewScenario(
        name: "new-conversation", summary: "New conversation mid-line, then a fresh conversation",
        steps: [.say("Should I skip the gym today?"), .line(1), .pause(1.0), .newConversation, .pause(2),
                .tapMicrophone, .say("Hello! Who are you two?"), .floor],
        lines: [
            .angel: [.says("Go to the gym today. You will feel wonderful afterwards."),
                     .says("Devil, a lie-in never made anyone stronger."),
                     .says("Hello! I am the angel on your shoulder.")],
            .devil: [.says("Oh, please, Angel! Stay in and have a lie-in. The gym will still be there tomorrow."),
                     .says("And I am the fun one.")],
        ])

    static let background = PreviewScenario(
        name: "background", summary: "the app goes to the background between questions, then returns",
        steps: [.say("Should I call my mum tonight?"), .floor, .background(1.5), .tapMicrophone,
                .say("Should I bring her flowers?"), .floor],
        lines: [
            .angel: [.says("Call her tonight. She would love to hear your voice."),
                     .says("Devil, five minutes on the phone means the world to her."),
                     .says("Bring her flowers. Tulips, maybe. She will smile all week.")],
            .devil: [.says("Text her instead, Angel. Calls take forever."),
                     .says("Fine, call her. But keep it short."),
                     .says("Flowers wilt. Bring her cake, and save me a slice.")],
        ])

    static let mute = PreviewScenario(
        name: "mute", summary: "muting and unmuting mid-line, with speech while muted",
        steps: [.say("Tell me something nice about the weekend."), .line(0), .pause(1.0), .tapMicrophone,
                .pause(0.4), .say("Nobody should hear these muted words."), .pause(0.6), .tapMicrophone, .floor],
        lines: [
            .angel: [.says("The weekend is a fresh start. Sleep in a little, call someone you love, and take a "
                           + "slow walk in the sunshine. You deserve the rest.")],
            .devil: [.says("Or stay in your pyjamas all day with a stack of pancakes. That is a real weekend.")],
        ])

    static let longAndShort = PreviewScenario(
        name: "long-and-short", summary: "one-word greetings, then a six-sentence line and a quip",
        steps: [.say("Hi!"), .floor, .pause(1), .say("How do I get fit?"), .floor],
        lines: [
            .angel: [.says("Hi!"),
                     .says("Start small and be kind to yourself. Walk for twenty minutes every day this week. "
                           + "Next week, add a few push-ups and some stretching. Drink plenty of water, and go "
                           + "to bed a little earlier. Celebrate every small win, because each one counts. You "
                           + "will be amazed at how far you get in a month.")],
            .devil: [.says("Yo."), .says("Nah.")],
        ])

    static let markup = PreviewScenario(
        name: "markup", summary: "emoji, Markdown and odd punctuation, a markup-only line and an emoji-only line",
        steps: [.say("Should I eat the last slice of cake?"), .floor],
        lines: [
            .angel: [.says("**Share it!** 🍰 Half for you… half for a friend?!"),
                     .says("\"Moderation,\" Devil: one slice (just one) & a glass of water — then 10 push-ups!"),
                     .says("😇")],
            .devil: [.says("Pfft — *seriously*, Angel? 😈 Eat it. #treatyourself"),
                     .says("* * *"),
                     .says("> Cake. Is. Life. <")],
        ])

    static let error = PreviewScenario(
        name: "error",
        summary: "a declined opening the other character takes, an exchange neither can begin, then a later line "
            + "that fails while another plays",
        steps: [.say("Should I skip the gym today?"), .floor, .pause(2),
                .say("Should I keep a wallet I found on the bus?"), .floor, .pause(2),
                .say("Okay. Should I go for a walk instead?"), .floor],
        lines: [
            .angel: [.fails(declined),
                     .says("A short walk will lift your mood far more than cocoa."),
                     .fails(declined),
                     .says("Yes! A walk in the fresh air is a lovely idea. Go on, you will feel so much better.")],
            .devil: [.says("Skip it! Stay cosy and have a hot chocolate instead."),
                     .fails(declined),
                     .fails(.timeout(.init(debugDescription: "Scripted timeout")))],
        ])

    private static let declined = LanguageModelError.guardrailViolation(.init(debugDescription: "Scripted decline"))

    static let hold = PreviewScenario(
        name: "hold", summary: "holding the microphone to talk: a question, a press that cuts the devil off, a "
            + "tap, words said without holding it, and a last question",
        holds: true,
        steps: [.hold("Should I skip the gym today?"), .line(1), .pause(1.5),
                .hold("Wait, Devil, what about pizza tonight?"), .floor, .pause(1), .tap, .pause(1),
                .say("Nobody should hear these words."), .pause(1), .hold("Thanks, you two!"), .floor],
        lines: [
            .angel: [.says("Go to the gym today. You will feel wonderful afterwards."),
                     .says("Devil, the sofa can wait. Health comes first."),
                     .says("A walk first, then pizza. You will enjoy every slice even more."),
                     .says("You are very welcome. Look after yourself.")],
            .devil: [.says("Oh, please, Angel! Skipping one day never hurt anyone. Stay in, put your feet up, "
                           + "and order something delicious."),
                     .says("Pizza tonight! Now you are talking. Extra cheese, no regrets."),
                     .says("Any time. Save me a slice.")],
        ])

    static let debate = PreviewScenario(
        name: "debate", summary: "the characters argue with each other up to the six-line limit",
        steps: [.say("Is it okay to lie to my boss?"), .floor],
        lines: [
            .angel: [.says("Devil, honesty builds trust. Why would you ever tell someone to lie?"),
                     .says("Devil, little fibs grow into big ones. Can't you see that?"),
                     .says("Tell your boss the truth, kindly and calmly.")],
            .devil: [.says("Angel, admit it. You have told a white lie or two yourself, haven't you?"),
                     .says("Angel, a tiny fib keeps the peace. Why are you always so serious?"),
                     .says("Fine. Keep it honest, but keep it short.")],
        ])
}

// MARK: - The stand-ins

/// Stands in for the microphone: the engine runs for playback only, quiet speech confidence
/// arrives every 0.1 s as SoundAnalysis would send it, and the human's words arrive as speech
/// recognition would report them, through the same callbacks.
@MainActor
final class ScriptedMicrophone: SpeechInput {
    var onTranscript: ((String, Bool, Double, Double) -> Void)?
    var onVAD: ((Double, Double, Double) -> Void)?
    var onLevel: ((Double) -> Void)?
    var onError: ((String) -> Void)?
    var holdsToTalk = false

    private let audio: VoiceAudioEngine
    private let records: Bool
    /// Holding to talk, the microphone is held.
    private var listening = false
    private var recording = false
    private var quiet: Task<Void, Never>?
    private var clock = ContinuousClock.now
    private var speaking = false
    /// The words said since the last endpoint, given as final when Python finalizes the turn.
    private var final: (text: String, start: Double, end: Double)?

    init(audio: VoiceAudioEngine, records: Bool) {
        self.audio = audio
        self.records = records
    }

    private var time: Double {
        let elapsed = clock.duration(to: .now).components
        return Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
    }

    func prepare() async {}

    func start() async throws {
        if records, !recording {
            try record()
            recording = true
        }
        try audio.start()
        clock = .now
        final = nil
        quiet?.cancel()
        quiet = Task { [weak self] in
            while !Task.isCancelled, let self {
                if !speaking {
                    onVAD?(0.03, time, 0.1)
                    onLevel?(Double.random(in: 0...0.04))
                }
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }

    func stop() async {
        quiet?.cancel()
        quiet = nil
        speaking = false
        listening = false
        onLevel?(0)
    }

    func listen(_ on: Bool, preRoll: Bool) async throws {
        listening = on
        if !on { try await finalize() }
    }

    func finalize() async throws {
        guard let words = final else { return }
        final = nil
        onTranscript?(words.text, true, words.start, words.end)
    }

    func logAudioMetrics(stage: String) {}

    /// The human says `text`: confident speech and a growing transcript a word at a time, then quiet.
    /// Holding to talk, words are recognized only once the microphone listens, from the first word
    /// on as the pre-roll would catch it.
    func say(_ text: String, onWord: (Int) -> Void) async {
        speaking = true
        var heard = false
        let words = text.split(separator: " ")
        let start = time
        for count in 1...max(1, words.count) {
            for _ in 0..<3 {
                onVAD?(0.95, time, 0.6)
                onLevel?(Double.random(in: 0.45...0.85))
                try? await Task.sleep(for: .milliseconds(100))
            }
            if !holdsToTalk || listening {
                heard = true
                onTranscript?(words.prefix(count).joined(separator: " "), false, start, time)
            }
            onWord(count)
        }
        if heard { final = (text, start, time) }
        speaking = false
        onLevel?(0)
    }

    /// Record everything the app plays (`DEMO_AUDIO`: the wall-clock time of its first sample, the
    /// output latency, and the file).
    private func record() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("demo-audio.caf")
        try? FileManager.default.removeItem(at: url)
        let latency = AVAudioSession.sharedInstance().outputLatency
        try audio.recordOutput(to: url) { started in
            print(String(format: "DEMO_AUDIO: %.6f %.6f %@", started.timeIntervalSince1970, latency, url.path))
        }
    }

    func stopRecording() {
        guard recording else { return }
        audio.stopRecordingOutput()
        recording = false
    }
}

/// Stands in for the language model: each character's next scripted line, streamed in small
/// pieces, or the model's failure. The speaker is read from the instructions' opening.
@MainActor
final class ScriptedLines: TextGenerator {
    private var remaining: [DuoCharacter: [PreviewScenario.Line]]
    /// The next line must start a conversation, with nothing said before it.
    private var fresh = false
    /// Reports a line written from a view that should not be.
    var onIssue: ((String) -> Void)?

    init(_ lines: [DuoCharacter: [PreviewScenario.Line]]) { remaining = lines }

    var unavailableReason: String? { nil }
    func invalidate() {}
    func prepare(instructions: String, history: [HistoryMessage]) async {}

    func expectFreshConversation() { fresh = true }

    func generate(prompt: String, instructions: String, history: [HistoryMessage],
                  onDelta: (String) -> Void) async throws {
        let speaker: DuoCharacter = instructions.hasPrefix("You are the Devil") ? .devil : .angel
        let line: PreviewScenario.Line
        if let next = remaining[speaker]?.first {
            remaining[speaker]?.removeFirst()
            line = next
        } else {
            line = .says(speaker == .angel ? "You can do this. I believe in you." : "Fine. But treat yourself after.")
        }
        let note = prompt.range(of: "[Note: ", options: .backwards).map { String(prompt[$0.upperBound...].prefix(40)) }
        print("DUO_PREVIEW_MODEL: \(speaker.rawValue) after \(history.count) messages (\(note ?? "no note")…): \(line)")
        if fresh {
            fresh = false
            if !history.isEmpty || prompt.components(separatedBy: "[Human]").count > 2 {
                onIssue?("a new conversation's first line sees the old one")
            }
        }
        try await Task.sleep(for: .milliseconds(450))
        switch line {
        case .fails(let error):
            throw NativeGenerationError.classify(error).atStage("stream_response")
        case .says(let text):
            var rest = Substring(text)
            while !rest.isEmpty {
                let piece = rest.prefix(5)
                rest = rest.dropFirst(piece.count)
                onDelta(String(piece))
                try await Task.sleep(for: .milliseconds(35))
            }
        }
    }
}

// MARK: - The monitor

/// Samples the conversation every 20 ms as the stage reads it, prints each change and moment, and
/// reports what the screen should never show.
@MainActor
private final class PreviewMonitor {
    private struct Screen: Equatable {
        var active = false, muted = false, preparing = false, playing = false
        /// Holding to talk, and whether the human holds the microphone and is heard.
        var holds = false, held = false, hearing = false
        /// The microphone spins before a conversation: Python or the models are loading.
        var loading = false
        var floor: DuoCharacter?
        var addressed: Set<DuoCharacter> = []
        var captions: [DuoCharacter: String] = [:]
        var thinking: Set<DuoCharacter> = []
        var pill: String?
        var talking: Set<DuoCharacter> = []
        var error: String?
        var interruptions = 0
        var line: Int?
        var writing: [Int] = []
        var exchangeOver = false
    }

    private weak var model: ConversationModel?
    private let began = ContinuousClock.now
    private var screen = Screen()
    private var sampler: Task<Void, Never>?
    private var openness: [DuoCharacter: [Double]] = [:]
    /// Since when each suspect condition has held, and those already reported.
    private var since: [String: ContinuousClock.Instant] = [:]
    private var reported: Set<String> = []
    private(set) var issues = 0
    /// The script is ending the conversation itself (New conversation, or the end of the run).
    var stopping = false

    init(model: ConversationModel) { self.model = model }

    private var seconds: Double {
        let elapsed = began.duration(to: .now).components
        return Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
    }

    /// Nobody holds the floor, nothing plays, and the turn's exchange is over or was cancelled.
    var floorIsHumans: Bool {
        guard let model else { return false }
        let view = model.scriptedView
        return model.floor == nil && !view.playing && (view.exchangeOver || view.line == nil && view.writing.isEmpty)
            && model.userLine == nil
    }

    func start() {
        sampler = Task { [weak self] in
            while !Task.isCancelled, let self {
                sample()
                try? await Task.sleep(for: .milliseconds(20))
            }
        }
    }

    func moment(_ name: String) {
        print(String(format: "DUO_PREVIEW_STATE: %@ (t=%.2f)", name, seconds))
    }

    func issue(_ text: String) {
        issues += 1
        print(String(format: "DUO_PREVIEW_ISSUE: t=%.2f %@", seconds, text))
    }

    func check(_ text: String, _ passed: Bool) {
        print("DUO_PREVIEW_CHECK: \(text): \(passed ? "yes" : "NO")")
        if !passed { issue(text) }
    }

    func wait(seconds limit: Double, until condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .seconds(limit))
        while !condition() {
            guard ContinuousClock.now < deadline else { return false }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return true
    }

    func finish() {
        sampler?.cancel()
        guard let model else { return }
        for character in DuoCharacter.allCases {
            let poses = openness[character] ?? []
            print(String(format: "DUO_PREVIEW_PLAYED: %@ %d poses, openness %.2f to %.2f",
                         character.title, poses.count, poses.min() ?? 0, poses.max() ?? 0))
        }
        print("DUO_PREVIEW_RESTING: \(model.mouths.values.allSatisfy { !$0.isAnimating })")
    }

    private func sample() {
        guard let model else { return }
        let view = model.scriptedView
        var now = Screen()
        now.active = model.active
        now.muted = model.muted
        now.holds = model.holdsToTalk
        now.held = model.talking
        now.hearing = model.hearing
        now.preparing = model.preparing
        now.loading = model.loading
        now.playing = view.playing
        now.floor = model.floor
        now.addressed = model.addressed
        now.captions = model.captions
        now.thinking = Set(DuoCharacter.allCases.filter(model.isThinking))
        now.pill = model.userLine?.text
        now.talking = Set(DuoCharacter.allCases.filter { model.mouths[$0]?.isAnimating == true })
        now.error = model.error
        now.interruptions = model.interruptions
        now.line = view.line
        now.writing = view.writing
        now.exchangeOver = view.exchangeOver
        for character in now.talking {
            openness[character, default: []].append(model.mouthPose(for: character, ahead: 0).openness)
        }
        let before = screen
        screen = now
        if now != before {
            noteMoments(from: before, to: now)
            print(String(format: "DUO_PREVIEW_TRACE: t=%.2f %@", seconds, describe(now)))
        }
        watch(now)
    }

    private func noteMoments(from before: Screen, to now: Screen) {
        if now.pill != nil, now.addressed != before.addressed, !now.addressed.isEmpty, now.floor == nil {
            moment("asked")
        }
        if now.line == nil, before.thinking.isEmpty, !now.thinking.isEmpty { moment("thinking") }
        if let line = now.line, line != before.line { moment("line \(line)") }
        if now.interruptions > before.interruptions { moment("interrupted") }
        if let error = now.error, error != before.error { moment("error: \(error)") }
        if before.active, !now.active, !stopping { issue("the conversation stopped: \(now.error ?? "no error")") }
        if floorIsHumans, before.floor != nil || before.playing || !before.writing.isEmpty, now.active {
            moment("floor back")
        }
    }

    /// Conditions the screen may pass through but never hold.
    private func watch(_ now: Screen) {
        func hold(_ name: String, _ condition: Bool, for limit: Double, _ text: @autoclosure () -> String) {
            guard condition else {
                since[name] = nil
                reported.remove(name)
                return
            }
            let start = since[name] ?? .now
            since[name] = start
            if start.duration(to: .now) > .seconds(limit), !reported.contains(name) {
                reported.insert(name)
                issue(text())
            }
        }
        let speaker = now.floor
        hold("mouths", !now.talking.isEmpty && !now.playing, for: 2.5,
             "a mouth still moves 2.5 s after the audio ended: \(now.talking.map(\.rawValue).sorted())")
        hold("silent mouth", now.playing && speaker != nil && now.talking.contains { $0 != speaker }, for: 2.5,
             "the silent character's mouth moves while \(speaker?.rawValue ?? "-") speaks")
        hold("still mouth", now.playing && speaker.map { !now.talking.contains($0) } ?? false, for: 0.5,
             "\(speaker?.rawValue ?? "-") speaks with a still mouth")
        hold("no floor", now.playing && now.floor == nil, for: 0.3, "audio plays with nobody on the floor")
        hold("captions", !now.captions.isEmpty && !now.playing, for: 3.0,
             "captions stay 3 s after the audio ended: \(now.captions.values.sorted())")
        hold("stale dots", now.line.map { line in now.writing.contains { $0 < line } } ?? false, for: 0.3,
             "typing dots for a line that was never spoken (writing \(now.writing), hearing \(now.line ?? -1))")
        hold("dots after", now.exchangeOver && !now.thinking.isEmpty, for: 0.3,
             "typing dots after the exchange ended")
        hold("pill", now.pill != nil && now.playing, for: 0.3, "the human's words show while a character speaks")
        hold("preparing", now.preparing, for: 10, "the microphone spins for 10 s")
    }

    private func describe(_ screen: Screen) -> String {
        var parts: [String] = []
        let microphone = screen.muted ? "mic=muted" : !screen.holds ? "mic=on"
            : screen.hearing ? (screen.held ? "mic=held" : "mic=released") : screen.held ? "mic=pressed" : "mic=hold"
        parts.append(screen.active ? (screen.preparing ? "starting" : microphone) : screen.loading ? "loading" : "idle")
        if screen.playing { parts.append("playing") }
        if let floor = screen.floor { parts.append("floor=\(floor.rawValue)") }
        if !screen.addressed.isEmpty { parts.append("addressed=\(screen.addressed.map(\.rawValue).sorted().joined(separator: ","))") }
        if let line = screen.line { parts.append("line=\(line)") }
        if !screen.writing.isEmpty { parts.append("writing=\(screen.writing.map(String.init).joined(separator: ","))") }
        if !screen.thinking.isEmpty { parts.append("dots=\(screen.thinking.map(\.rawValue).sorted().joined(separator: ","))") }
        if !screen.talking.isEmpty { parts.append("mouths=\(screen.talking.map(\.rawValue).sorted().joined(separator: ","))") }
        for character in DuoCharacter.allCases {
            if let caption = screen.captions[character] { parts.append("\(character.rawValue)=\"\(caption)\"") }
        }
        if let pill = screen.pill { parts.append("human=\"\(pill)\"") }
        if screen.exchangeOver { parts.append("over") }
        if screen.interruptions > 0 { parts.append("interruptions=\(screen.interruptions)") }
        if let error = screen.error { parts.append("error=\"\(error)\"") }
        return parts.joined(separator: " ")
    }
}
#endif
