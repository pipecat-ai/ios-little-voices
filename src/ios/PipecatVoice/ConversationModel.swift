import AVFoundation
import Foundation
import Observation
import OSLog

/// An event from Python (see `AppleNativeBridge` in `src/python/pipecat_apple/bridge.py`).
private struct NativeEvent: Decodable {
    let type: String
    var operation: String?
    var request: String?
    var turn: String?
    var session: String?
    var state: String?
    var text: String?
    var prompt: String?
    var instructions: String?
    var history: [HistoryMessage]?
    var message: String?
    var recoverable: Bool?
    // A speak request's character, voice and line within its turn.
    var speaker: String?
    var voice: String?
    var line: Int?
    // An Audience request's inputs, rendered by the SpellSpeak runtime in Python.
    var cards: [String]?
    var utterance: String?
    var current: Int?
    var people: [[Float]]?
    var features: [Float]?
    /// Who a line is for (`addressed`): character ids, or the human's.
    var to: [String]?
}

/// An RTVI message from Python, in its session envelope.
private struct RTVIEnvelope: Decodable {
    let type: String
    let turn: String?
    let session: String?
    /// For a character's line: who says it, and which line of the turn it is.
    let speaker: String?
    let line: Int?
    let message: Message
    struct Message: Decodable {
        let type: String
        let data: Payload?
    }
    struct Payload: Decodable {
        let text: String?
        let final: Bool?
    }
}

/// The microphone: recognized words, speech confidence and level (`AppleSpeechRecognizer`, or a
/// DEBUG script).
@MainActor
protocol SpeechInput: AnyObject {
    /// Recognized words, whether they are final, and their start and end on the input's clock.
    var onTranscript: ((String, Bool, Double, Double) -> Void)? { get set }
    /// Speech confidence, its time on the input's clock, and the input's normalized volume.
    var onVAD: ((Double, Double, Double) -> Void)? { get set }
    var onLevel: ((Double) -> Void)? { get set }
    var onError: ((String) -> Void)? { get set }
    /// Hold to talk: recognize only while the microphone is held. Set before `start`.
    var holdsToTalk: Bool { get set }
    /// Load the recognizer's model ahead of `start`, without the microphone.
    func prepare() async
    /// Start listening on a fresh clock.
    func start() async throws
    func stop() async
    /// Hold to talk: start recognizing as the microphone is pressed, from a moment before unless
    /// `preRoll` is false, or finalize the speech and stop as it is released.
    func listen(_ on: Bool, preRoll: Bool) async throws
    /// Deliver every final result for the speech so far, then return.
    func finalize() async throws
    func logAudioMetrics(stage: String)
}

/// Writes Python's `generate` requests (`AppleLanguageModel`, or a DEBUG script).
@MainActor
protocol TextGenerator: AnyObject {
    /// Why the model cannot be used now, as the screen shows it; nil when it can.
    var unavailableReason: String? { get }
    func invalidate()
    func prepare(instructions: String, history: [HistoryMessage]) async
    func generate(prompt: String, instructions: String, history: [HistoryMessage],
                  onDelta: (String) -> Void) async throws
}

extension AppleSpeechRecognizer: SpeechInput {}

extension AppleLanguageModel: TextGenerator {
    var unavailableReason: String? { Self.unavailableReason }
}

/// The conversation: the session's lifecycle, the native work Python asks for (generating,
/// speaking, Audience readings, speech endpoints), and what the screen shows of each turn.
@MainActor @Observable
final class ConversationModel {
    private(set) var ready = false
    private(set) var active = false
    private(set) var muted = false
    /// How conversations take the human's turns, from Settings.
    private(set) var inputMode = InputMode.load()
    /// This conversation listens only while the microphone is held.
    private(set) var holdsToTalk = false
    /// The human holds the microphone in a hold-to-talk conversation.
    private(set) var talking = false
    /// A push to talk is being heard: from the press, once the microphone is ready, until a
    /// moment after the release.
    private(set) var hearing = false
    /// The microphone was tapped rather than held, so it shows how to talk.
    private(set) var showsHoldHint = false
    /// Setting up audio, speech and models: as a conversation starts, and after an audio route change.
    private(set) var preparing = false
    /// Loading the voices, Audience and speech recognition as the app opens or returns.
    private var warming = false
    /// Python or the models are loading, which a conversation waits for.
    var loading: Bool { !ready || warming }
    private(set) var userLevel = 0.0
    /// `userLevel` without observation, for the stage's per-frame sampling.
    var unobservedUserLevel: Double { _userLevel }
    var error: String?
    /// The banner's text: Release builds drop the trailing diagnostic code (`[LLM_DECLINED]`).
    var errorMessage: String? {
        #if DEBUG
        error
        #else
        error.map { $0.replacing(#/\s*[\[(][A-Z][A-Z0-9_]+[\])]\s*$/#, with: "") }
        #endif
    }
    var showSettings = false
    /// Why the language model cannot be used, for Settings; nil when it can.
    private(set) var availability: String?
    private(set) var userProfile = ProfileSettings.load()
    /// Something has been said since the conversation was last cleared.
    private(set) var hasConversation = false
    /// The character whose line is being heard: from its first audio until the next line starts,
    /// or until the exchange has ended and played out.
    private(set) var floor: DuoCharacter?
    /// Who the line being heard is for: the human's question until a character answers, then each
    /// character's line as it plays.
    private(set) var addressed: Set<DuoCharacter> = []
    /// The sentence the speaker is saying: shown as its audio starts, and gone once someone else
    /// speaks or they have been quiet for `captionHold`.
    private(set) var captions: [DuoCharacter: String] = [:]
    /// Lip-sync for each character's mouth, analyzed from their audio as it is scheduled.
    let mouths = Dictionary(uniqueKeysWithValues: DuoCharacter.allCases.map { ($0, LipsyncTimeline()) })
    /// Counts playback stopping early while a character holds the floor; the stage startles at each.
    private(set) var interruptions = 0

    var microphoneInputSession: AVAudioSession? { active ? audio.inputPickerSession : nil }
    var canChooseMicrophone: Bool { active && inputReady && !isRecoveringAudio && !preparing }

    /// The human's words this turn, as they are recognized, until a character answers.
    var userLine: UserTranscript? {
        guard currentTurn != nil, !exchangeOver, heardLine == nil, !userTranscript.text.isEmpty else {
            return nil
        }
        return userTranscript
    }

    /// A character is thinking while they write a line and someone else has the floor.
    func isThinking(_ character: DuoCharacter) -> Bool {
        floor != character && writing.values.contains(character)
    }

    /// A character's mouth `ahead` seconds past the current playback position: the stage asks for
    /// the pose when its frame will be presented.
    func mouthPose(for character: DuoCharacter, ahead: Double) -> LipsyncTimeline.Pose {
        mouths[character]?.pose(at: player.playbackTime.map { $0 + ahead }) ?? LipsyncTimeline.rest
    }

    private let runtime = PCPythonRuntime()
    private let audio: VoiceAudioEngine
    private let speech: SpeechInput
    private let synthesizer = PhononSynthesizer()
    private let player: PCMPlayer
    private let audience = AudienceRunner()
    private let languageModel: TextGenerator
    private let modelWork = NativeModelWorkCoordinator()
    private let logger = Logger(subsystem: "ai.pipecat.littlevoices", category: "Conversation")
    private var languageModelRequest: String?
    private var requests: [String: Task<Void, Never>] = [:]
    private var speechRequest: String?
    private var currentTurn: String?
    private var userTranscript = UserTranscript()
    /// The character whose audio is playing, while some is: its samples drive their mouth.
    private var speakingCharacter: DuoCharacter?
    private var playing = false
    private var sessionTask: Task<Void, Never>?
    private var captureTask: Task<Void, Never>?
    private var pressedAt: ContinuousClock.Instant?
    private var releaseTask: Task<Void, Never>?
    private var hintTask: Task<Void, Never>?
    private var stopTask: Task<Void, Never>?
    /// The voices, Audience and speech recognition loading, or loaded, for conversations to come.
    private var warmup: Task<Void, Error>?
    /// Freeing the voices and Audience in the background; the next load waits for it.
    private var cooldown: Task<Void, Never>?
    /// The launch intro still plays: the models wait for it, so loading them doesn't take its frames.
    private var awaitingIntro = true
    /// Between `becomeActive` and `enterBackground`.
    private var inFront = false
    private var sessionGeneration = UUID()
    private var captureGeneration = UUID()
    private var inputReady = false
    private var microphonePickerPresented = false
    private var isRecoveringAudio = false
    private var routeRestarting = false
    private var configuredAudioRoute = ""
    /// The number of the turn's line being heard. Lines play in order, so every line before it
    /// has been heard or never will be.
    private var heardLine: Int?
    /// The turn's lines being written that have not started playing, with their speakers.
    private var writing: [Int: DuoCharacter] = [:]
    /// Who each of the turn's lines not yet heard is for.
    private var lineAddressees: [Int: Set<DuoCharacter>] = [:]
    /// The turn's exchange has ended: the floor is the human's once its last line has played.
    private var exchangeOver = false
    /// Clears the captions once playback has been quiet for `captionHold`.
    private var captionExpiry: Task<Void, Never>?
    /// How long a caption stays after its sentence has played, so a speaker's next sentence
    /// replaces it rather than following a gap.
    private static let captionHold: Duration = .seconds(2)
    #if DEBUG
    /// A scripted run (`--preview-duo`, `--demo-question`), standing in for the microphone and,
    /// in a preview, the language model.
    private let script: ConversationScript?
    /// A launch check is timing models it loads itself, so the app loads none alongside.
    private var checking = false
    #endif

    init() {
        let audio = VoiceAudioEngine()
        self.audio = audio
        player = PCMPlayer(audio: audio)
        #if DEBUG
        script = ConversationScript.launchRequested(audio: audio)
        speech = script?.microphone ?? AppleSpeechRecognizer(audio: audio)
        let scriptedLines: TextGenerator? = script?.lines
        languageModel = scriptedLines ?? AppleLanguageModel()
        #else
        speech = AppleSpeechRecognizer(audio: audio)
        languageModel = AppleLanguageModel()
        #endif
        availability = languageModel.unavailableReason
        speech.onTranscript = { [weak self] text, final, start, end in
            guard let self, active, !muted, inputReady else { return }
            sendSession(["type": "transcription", "text": text, "final": final, "start": start, "end": end])
        }
        speech.onVAD = { [weak self] confidence, time, volume in
            guard let self, active, !muted, inputReady, !holdsToTalk else { return }
            sendSession(["type": "vad", "confidence": confidence, "time": time, "volume": volume])
        }
        speech.onLevel = { [weak self] value in
            guard let self, active, !muted, inputReady, !holdsToTalk || hearing else { return }
            userLevel = value
        }
        speech.onError = { [weak self] message in self?.fail(message) }
        player.onSpeakingChanged = { [weak self] speaking in
            guard let self else { return }
            playing = speaking
            guard let request = speechRequest else { return }
            sendSession(["type": "playback", "request": request, "speaking": speaking])
        }
        player.onScheduled = { [weak self] samples, start in
            guard let self, let speaker = speakingCharacter else { return }
            mouths[speaker]?.schedule(samples, at: start)
        }
        player.onPlaybackEnded = { [weak self] interrupted in
            guard let self else { return }
            for mouth in mouths.values {
                if interrupted { mouth.cancel() } else { mouth.finish() }
            }
            speakingCharacter = nil
            expireCaptions()
            if interrupted, floor != nil { interruptions &+= 1 }
            // Between sentences and lines the floor stays with the speaker.
            if interrupted || exchangeOver { floor = nil }
            if exchangeOver { addressed = [] }
        }
        // The runtime calls back on the main queue.
        runtime.start { [weak self] json in
            MainActor.assumeIsolated { self?.handle(json) }
        }
        #if DEBUG
        runLaunchDiagnostics()
        #endif
        // The system deactivates the session for interruptions such as calls. The
        // app's own deactivation when a conversation ends is not an interruption.
        NotificationCenter.default.addObserver(forName: AVAudioSession.didBecomeInactiveNotification,
            object: nil, queue: .main) { [weak self] notification in
                guard let context = notification.userInfo?[AVAudioSession.deactivationContextKey]
                        as? AVAudioSession.DeactivationContext,
                      context.source == .system else { return }
                MainActor.assumeIsolated {
                    guard let self, self.active else { return }
                    self.fail("The conversation ended when another app or a call took over the audio. Tap the "
                        + "microphone to start again.")
                }
            }
        NotificationCenter.default.addObserver(forName: AVAudioSession.routeChangeNotification,
            object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.audioRouteChanged()
                }
            }
    }

    func saveSettings(preferredName: String, inputMode: InputMode) throws {
        guard !active else { throw VoiceError(message: "End the conversation before changing settings.") }
        let profile = UserProfile(preferredName: preferredName)
        try ProfileSettings.save(profile)
        if profile != userProfile { invalidatePreparation() }
        userProfile = profile
        InputMode.save(inputMode)
        self.inputMode = inputMode
    }

    /// Whether the microphone is held to talk: in this conversation, or in the next one.
    var microphoneHolds: Bool { active ? holdsToTalk : inputMode == .hold }

    private func send(_ event: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: event),
              let json = String(data: data, encoding: .utf8) else { return }
        runtime.sendJSON(json)
    }

    private func sendSession(_ event: [String: Any]) {
        send(event.merging(["session": sessionGeneration.uuidString]) { _, session in session })
    }

    // MARK: - The session

    /// The app is in front: check the language model again, and load the voices, Audience and
    /// speech recognition once the launch intro has played, so the microphone needn't wait for
    /// them.
    func becomeActive() {
        inFront = true
        refreshAvailability()
        if !awaitingIntro { warmUp() }
    }

    /// The launch intro has played, or a conversation took it over.
    func introEnded() {
        guard awaitingIntro else { return }
        awaitingIntro = false
        if inFront { warmUp() }
    }

    private func warmUp() {
        #if DEBUG
        if checking { return }
        #endif
        loadModels()
    }

    /// The app has gone to the background: the conversation ends, and the voices and Audience are
    /// freed until it returns.
    func enterBackground() {
        inFront = false
        stop()
        #if DEBUG
        if checking { return }
        #endif
        let warmup = self.warmup
        self.warmup = nil
        warming = false
        cooldown = Task {
            _ = await warmup?.result
            await synthesizer.unload()
            await audience.unload()
        }
    }

    /// Check again whether the language model can be used.
    private func refreshAvailability() {
        availability = languageModel.unavailableReason
    }

    /// The voices, Audience and speech recognition, loading or loaded. Only Phonon failing fails
    /// the load, which the next conversation tries again.
    @discardableResult
    private func loadModels() -> Task<Void, Error> {
        if let warmup { return warmup }
        warming = true
        let cooldown = cooldown
        let task = Task {
            await cooldown?.value
            async let voices: Void = synthesizer.prepare(voices: VoiceSettings.voices)
            async let audienceReady: Void = audience.prepare()
            await speech.prepare()
            do { try await audienceReady }
            catch {
                // Without the model, Python reads who each line is for with SpellSpeak's rules baseline.
                logger.error("SpellSpeak Audience failed to load: \(error.localizedDescription, privacy: .public)")
            }
            do { try await voices }
            catch {
                logger.error("Phonon failed to load: \(error.localizedDescription, privacy: .public)")
                throw error
            }
        }
        warmup = task
        Task {
            let result = await task.result
            guard warmup == task else { return }
            warming = false
            if case .failure = result { warmup = nil }
        }
        return task
    }

    /// Start a conversation that listens throughout, or, `holdingToTalk`, only while the
    /// microphone is held.
    func start(holdingToTalk: Bool) {
        guard ready, !active else { return }
        error = nil
        refreshAvailability()
        if let availability { error = availability; return }
        let userName = userProfile.preferredName
        invalidatePreparation()
        active = true
        muted = false
        holdsToTalk = holdingToTalk
        speech.holdsToTalk = holdingToTalk
        userLevel = 0
        inputReady = false
        preparing = true
        let generation = UUID()
        sessionGeneration = generation
        let previousStop = stopTask
        sessionTask = Task {
            await previousStop?.value
            do {
                try Task.checkCancellation()
                guard active, sessionGeneration == generation else { return }
                try audio.configureSession()
                do { try await loadModels().value }
                catch {
                    throw VoiceError(message: "The angel’s and the devil’s voices couldn’t load. Close other apps "
                        + "and try again; if it keeps happening, reinstall Little Voices.")
                }
                try Task.checkCancellation()
                guard active, sessionGeneration == generation else { return }
                sendSession(["type": "start", "user_name": userName])
                try await speech.start()
                try Task.checkCancellation()
                guard active, sessionGeneration == generation else { return }
                inputReady = true
                configuredAudioRoute = audioRouteSignature
                preparing = false
                // The microphone pressed to start the conversation is still held.
                if talking { beginTalking() }
            } catch is CancellationError { }
            catch { if sessionGeneration == generation { fail(error.localizedDescription) } }
        }
    }

    /// App Intents enter through the same permission and audio setup as the microphone button. A
    /// conversation started by voice is hands-free.
    func startFromShortcut() {
        showSettings = false
        if active {
            if muted, !preparing { toggleMute() }
            return
        }
        start(holdingToTalk: false)
    }

    // MARK: - Hold to talk

    /// Held for less than this, the microphone was tapped.
    private static let shortestHold: Duration = .milliseconds(300)
    /// Listening goes on this long after the release, for a last word still being said.
    private static let releaseTail: Duration = .milliseconds(350)

    /// The microphone is pressed: in a hold-to-talk conversation, or to start one, the human
    /// talks until it is released. Pressing cuts the characters off.
    func pressMicrophone() {
        if !active {
            guard inputMode == .hold else { return }
            start(holdingToTalk: true)
            guard active else { return }
        }
        guard holdsToTalk, !talking else { return }
        talking = true
        pressedAt = .now
        hintTask?.cancel()
        showsHoldHint = false
        if hearing {
            // Pressed again within the release's tail: the same words go on.
            releaseTask?.cancel()
            releaseTask = nil
        } else if inputReady, !isRecoveringAudio {
            beginTalking()
        }
    }

    /// The microphone is let go: a moment later the human's turn ends, or, if it was only
    /// tapped, it shows how to talk.
    func releaseMicrophone() {
        guard talking else { return }
        talking = false
        if let pressedAt, pressedAt.duration(to: .now) < Self.shortestHold { showHoldHint() }
        pressedAt = nil
        guard hearing else { return }
        let generation = sessionGeneration
        releaseTask = Task {
            try? await Task.sleep(for: Self.releaseTail)
            guard !Task.isCancelled, active, sessionGeneration == generation, hearing, !talking else { return }
            endTalking()
        }
    }

    private func beginTalking() {
        // A press while the characters speak or write cuts them off, without the pre-roll that
        // would carry their voice.
        let audible = playing || floor != nil
        if audible || !writing.isEmpty { interruptReply() }
        hearing = true
        sendSession(["type": "talk", "talking": true])
        listen(true, preRoll: !audible)
    }

    private func endTalking() {
        releaseTask = nil
        hearing = false
        userLevel = 0
        sendSession(["type": "talk", "talking": false])
        listen(false, preRoll: false)
    }

    private func listen(_ on: Bool, preRoll: Bool) {
        let generation = captureGeneration
        Task {
            do { try await speech.listen(on, preRoll: preRoll) }
            catch is CancellationError { }
            catch { if active, captureGeneration == generation { fail(error.localizedDescription) } }
        }
    }

    /// Forget the push to talk in progress, if any.
    private func releaseHold() {
        talking = false
        hearing = false
        pressedAt = nil
        releaseTask?.cancel()
        releaseTask = nil
    }

    private func showHoldHint() {
        showsHoldHint = true
        hintTask?.cancel()
        hintTask = Task {
            try? await Task.sleep(for: .seconds(2))
            if !Task.isCancelled { showsHoldHint = false }
        }
    }

    func toggleMute() {
        guard active, !preparing, !holdsToTalk else { return }
        muted.toggle()
        userLevel = 0
        userTranscript.partial = ""
        inputReady = false
        let isMuted = muted
        let generation = sessionGeneration
        let captureGeneration = UUID()
        self.captureGeneration = captureGeneration
        // Python mutes at once but unmutes only once the input clock has restarted, so queued
        // capture can't reset timestamps of audio Pipecat has accepted.
        if isMuted { sendSession(["type": "mute"]) }
        let previous = captureTask
        captureTask = Task {
            await previous?.value
            guard active, sessionGeneration == generation,
                  self.captureGeneration == captureGeneration else { return }
            do {
                try Task.checkCancellation()
                // Muted audio is never recognized. Unmuting starts a fresh input, whose new
                // generation rejects any recognition or classifier callbacks from before.
                if isMuted { await speech.stop() } else { try await speech.start() }
                try Task.checkCancellation()
                guard active, sessionGeneration == generation,
                      self.captureGeneration == captureGeneration else { return }
                if !isMuted {
                    sendSession(["type": "unmute"])
                    inputReady = true
                    configuredAudioRoute = audioRouteSignature
                }
            }
            catch is CancellationError { }
            catch { if sessionGeneration == generation { fail(error.localizedDescription) } }
        }
    }

    func stop() {
        ConversationLaunchRequests.shared.cancel()
        if ready { sendSession(["type": "stop"]) }
        active = false
        muted = false
        releaseHold()
        inputReady = false
        preparing = false
        microphonePickerPresented = false
        isRecoveringAudio = false
        routeRestarting = false
        configuredAudioRoute = ""
        captureGeneration = UUID()
        sessionGeneration = UUID()
        sessionTask?.cancel()
        let previousPreparation = sessionTask
        sessionTask = nil
        captureTask?.cancel()
        let previousCapture = captureTask
        captureTask = nil
        cancelRequests()
        forgetTurn()
        let previousStop = stopTask
        stopTask = Task {
            await previousStop?.value
            await previousCapture?.value
            await speech.stop()
            audio.stop()
            await previousPreparation?.value
        }
    }

    func clearConversation() {
        stop()
        hasConversation = false
        error = nil
        send(["type": "reset"])
    }

    private func fail(_ message: String) {
        #if DEBUG
        print("CONVERSATION_FAILED: \(message)")
        #endif
        stop()
        error = message
    }

    /// Cancel the reply in progress and keep listening.
    private func interruptReply() {
        guard active else { return }
        cancelRequests()
        sendSession(["type": "interrupt"])
        forgetTurn()
    }

    /// Forget the turn's words, speakers and lines.
    private func forgetTurn() {
        currentTurn = nil
        resetStage()
        userTranscript = UserTranscript()
        userLevel = 0
    }

    // MARK: - Audio routes

    private var audioRouteSignature: String {
        let session = AVAudioSession.sharedInstance()
        let ports = (session.currentRoute.inputs + session.currentRoute.outputs).map(\.uid)
        return (ports + [session.mode.rawValue, String(session.sampleRate)]).joined(separator: "|")
    }

    func microphonePickerPresentationChanged(_ presented: Bool) {
        #if DEBUG
        print("AUDIO_ROUTE: picker \(presented ? "presented" : "dismissed"), recovering=\(isRecoveringAudio)")
        #endif
        microphonePickerPresented = presented
        if !presented { finishAudioRouteChange() }
    }

    private func audioRouteChanged() {
        #if DEBUG
        print("AUDIO_ROUTE: changed, active=\(active) preparing=\(preparing) recovering=\(isRecoveringAudio) "
            + "picker=\(microphonePickerPresented) from=\(configuredAudioRoute) to=\(audioRouteSignature)")
        #endif
        guard active, !preparing, !isRecoveringAudio,
              configuredAudioRoute != audioRouteSignature || audio.routeChangeError() != nil else { return }
        // Keep the Pipecat conversation, but cancel the current utterance/reply
        // before rebuilding converters for the selected microphone's format.
        interruptReply()
        releaseHold()
        inputReady = false
        isRecoveringAudio = true
        routeRestarting = false
        preparing = true
        sendSession(["type": "mute"])
        audio.suspendForRouteChange()
        let generation = sessionGeneration
        let captureGeneration = UUID()
        self.captureGeneration = captureGeneration
        let previous = captureTask
        previous?.cancel()
        captureTask = Task {
            await previous?.value
            guard active, sessionGeneration == generation,
                  self.captureGeneration == captureGeneration else { return }
            await speech.stop()
        }
        // Keep the recording session alive while Apple's menu is open. Changing
        // its category mid-selection can replace the user's chosen microphone.
        if !microphonePickerPresented { finishAudioRouteChange() }
    }

    private func finishAudioRouteChange() {
        guard active, isRecoveringAudio, !microphonePickerPresented, !routeRestarting else { return }
        routeRestarting = true
        let selectedInput = microphoneInputSession?.currentRoute.inputs.first
        let generation = sessionGeneration
        let captureGeneration = self.captureGeneration
        let previous = captureTask
        captureTask = Task {
            await previous?.value
            guard active, sessionGeneration == generation,
                  self.captureGeneration == captureGeneration else { return }
            do {
                try Task.checkCancellation()
                try audio.configureSession(preservingInput: selectedInput)
                if !muted { try await speech.start() }
                try Task.checkCancellation()
                guard active, sessionGeneration == generation,
                      self.captureGeneration == captureGeneration else { return }
                if let message = audio.routeChangeError() { throw VoiceError(message: message) }
                configuredAudioRoute = audioRouteSignature
                #if DEBUG
                print("AUDIO_ROUTE: recovered on \(audioRouteSignature)")
                #endif
                if !muted {
                    // The fresh ASR clock must exist before Python admits input.
                    sendSession(["type": "unmute"])
                    inputReady = true
                }
                isRecoveringAudio = false
                routeRestarting = false
                preparing = false
                // The microphone was pressed while the route changed.
                if talking { beginTalking() }
            } catch is CancellationError {
                #if DEBUG
                print("AUDIO_ROUTE: recovery cancelled")
                #endif
            }
            catch { if sessionGeneration == generation { fail(error.localizedDescription) } }
        }
    }

    // MARK: - Python's events

    private func invalidatePreparation() {
        modelWork.cancel()
        languageModel.invalidate()
    }

    private func cancelRequests(preservePreparation: Bool = false) {
        if !preservePreparation { invalidatePreparation() }
        for task in requests.values { task.cancel() }
        requests.removeAll()
        languageModelRequest = nil
        player.stop()
        speechRequest = nil
    }

    private func handle(_ json: String) {
        guard let data = json.data(using: .utf8) else { return }
        if let event = try? JSONDecoder().decode(RTVIEnvelope.self, from: data), event.type == "rtvi" {
            handleRTVI(event)
            return
        }
        guard let event = try? JSONDecoder().decode(NativeEvent.self, from: data) else {
            fail("The Python bridge returned an invalid event.")
            return
        }
        if event.type != "request", let session = event.session,
           session != sessionGeneration.uuidString { return }
        switch event.type {
        case "ready":
            ready = true
            #if DEBUG
            print("PIPECAT_PYTHON_READY")
            #endif
        case "user_turn":
            guard active, !muted, inputReady, !isRecoveringAudio,
                  event.session == sessionGeneration.uuidString,
                  let turn = event.turn else { return }
            // A session prepared after a fully played reply serves the next question; a
            // generation in progress is cancelled.
            cancelRequests(preservePreparation: requests.isEmpty)
            currentTurn = turn
            resetStage()
            userTranscript = UserTranscript()
            error = nil
        case "error":
            guard event.turn == nil || event.turn == currentTurn else { return }
            if active, event.recoverable == true, event.operation == "generate" {
                interruptReply()
                error = event.message ?? "That reply failed. Please try another question."
            } else { fail(event.message ?? "Something went wrong. Tap the microphone to start again.") }
        case "cancel_request":
            if let id = event.request {
                if languageModelRequest == id { invalidatePreparation() }
                requests.removeValue(forKey: id)?.cancel()
                if speechRequest == id { player.stop(); speechRequest = nil }
            }
        case "cancel_turn":
            if let turn = event.turn, turn == currentTurn { cancelRequests() }
        case "state":
            guard active, event.session == sessionGeneration.uuidString,
                  event.turn == currentTurn, event.state == "listening" else { return }
            endExchange()
        case "addressed":
            guard active, event.session == sessionGeneration.uuidString,
                  event.turn != nil, event.turn == currentTurn else { return }
            address(line: event.line, to: event.to ?? [])
        case "dropped":
            guard active, event.session == sessionGeneration.uuidString,
                  event.turn != nil, event.turn == currentTurn, let line = event.line else { return }
            // Nobody will say that line, so its writer stops typing.
            writing[line] = nil
            lineAddressees[line] = nil
        case "prewarm":
            guard active, event.session == sessionGeneration.uuidString,
                  event.turn == currentTurn else { return }
            modelWork.prepare { [self] in
                await languageModel.prepare(instructions: event.instructions ?? "", history: event.history ?? [])
            }
        case "request":
            let validTurn = event.operation == "finalize_asr" || (event.turn != nil && event.turn == currentTurn)
            let validInput = event.operation != "finalize_asr" || (inputReady && !isRecoveringAudio && !muted)
            guard active, validTurn, validInput, event.session == sessionGeneration.uuidString else {
                if let id = event.request { send(["type": "result", "request": id, "error": "Turn was cancelled"]) }
                return
            }
            perform(event)
        default: fail("Unknown Python event: \(event.type)")
        }
    }

    private func handleRTVI(_ event: RTVIEnvelope) {
        guard active, event.session == sessionGeneration.uuidString, event.turn == currentTurn else { return }
        switch event.message.type {
        case "bot-llm-started":
            startWriting(line: event.line, speaker: event.speaker.flatMap(DuoCharacter.init(rawValue:)))
        case "user-transcription":
            guard !muted, inputReady else { return }
            let text = event.message.data?.text ?? ""
            if event.message.data?.final == true { userTranscript.commit(text) } else { userTranscript.partial = text }
            if !text.isEmpty { hasConversation = true }
        default: break
        }
    }

    // MARK: - The stage

    /// Nobody has the floor, is being talked to or is writing: a new turn, an interruption or the end.
    private func resetStage() {
        floor = nil
        addressed = []
        captions.removeAll()
        captionExpiry?.cancel()
        heardLine = nil
        writing.removeAll()
        lineAddressees.removeAll()
        exchangeOver = false
    }

    /// Whether line `line` of the turn is still to be heard.
    private func isAhead(_ line: Int) -> Bool {
        heardLine.map { line > $0 } ?? true
    }

    /// A sentence of a character's line starts playing: caption it, and give them the floor. The line's
    /// first sentence also lights whoever it is for.
    private func reveal(line: Int?, speaker: DuoCharacter?, sentence: String?) {
        guard let line else { return }
        if let speaker {
            floor = speaker
            captionExpiry?.cancel()
            // Only the speaker's bubble shows: anyone else has finished talking.
            captions = captions.filter { $0.key == speaker }
            if let sentence, !sentence.isEmpty { captions[speaker] = sentence }
        }
        // Each of a line's sentences starts like this; only the first starts the line.
        guard isAhead(line) else { return }
        heardLine = line
        addressed = lineAddressees[line] ?? []
        // An earlier line not heard by now, such as one with nothing to say aloud, never will be.
        writing = writing.filter { isAhead($0.key) }
        lineAddressees = lineAddressees.filter { isAhead($0.key) }
    }

    /// Playback has stopped: the captions go once it has stayed quiet for `captionHold`, unless
    /// another sentence starts first.
    private func expireCaptions() {
        captionExpiry?.cancel()
        captionExpiry = Task { [weak self] in
            try? await Task.sleep(for: Self.captionHold)
            guard !Task.isCancelled, let self, !playing else { return }
            captions.removeAll()
        }
    }

    /// A character has started writing a line of the turn.
    private func startWriting(line: Int?, speaker: DuoCharacter?) {
        guard let line, let speaker, isAhead(line) else { return }
        writing[line] = speaker
    }

    /// Audience's reading of who a line is for: the human's (`line` nil), lit at once, or a
    /// character's, lit while it is heard.
    private func address(line: Int?, to ids: [String]) {
        let to = Set(ids.compactMap(DuoCharacter.init(rawValue:)))
        guard let line else {
            if floor == nil { addressed = to }
            return
        }
        if heardLine == line { addressed = to } else if isAhead(line) { lineAddressees[line] = to }
    }

    /// Nobody writes more this turn. Once the last line has played, the floor is the human's.
    private func endExchange() {
        exchangeOver = true
        writing.removeAll()
        lineAddressees.removeAll()
        if !playing {
            floor = nil
            addressed = []
        }
    }

    // MARK: - Native work

    /// Whether a request from session `generation` for `turn` still belongs to the live conversation.
    private func isCurrent(_ generation: UUID, turn: String?) -> Bool {
        active && sessionGeneration == generation && turn != nil && currentTurn == turn
    }

    private func perform(_ event: NativeEvent) {
        guard let id = event.request, let operation = event.operation else { return }
        let turn = event.turn
        let generation = sessionGeneration
        let inputGeneration = captureGeneration
        // Speech endpoints belong to the microphone input rather than to a turn.
        func stillCurrent() -> Bool {
            guard operation == "finalize_asr" else { return isCurrent(generation, turn: turn) }
            return active && sessionGeneration == generation && inputReady && !isRecoveringAudio && !muted
                && captureGeneration == inputGeneration
        }
        let work: @MainActor () async -> Void = { [self] in
            do {
                try Task.checkCancellation()
                guard stillCurrent() else { throw CancellationError() }
                switch operation {
                case "generate": try await generate(event, request: id, generation: generation)
                case "speak": try await speak(event, request: id, generation: generation)
                case "audience": try await readAudience(event, request: id)
                case "finalize_asr": try await finalizeSpeech()
                default: throw VoiceError(message: "Unknown native operation.")
                }
                try Task.checkCancellation()
                guard stillCurrent() else { throw CancellationError() }
                send(["type": "result", "request": id, "done": true])
            } catch is CancellationError {
            } catch {
                if stillCurrent() { send(["type": "result", "request": id, "error": error.localizedDescription]) }
            }
        }
        let completed: @MainActor () -> Void = { [self] in
            requests.removeValue(forKey: id)
            if speechRequest == id { speechRequest = nil }
            if languageModelRequest == id { languageModelRequest = nil }
        }
        if operation == "generate" {
            requests[id] = modelWork.generate(work, onCompletion: completed)
        } else {
            requests[id] = Task { defer { completed() }; await work() }
        }
    }

    private func generate(_ event: NativeEvent, request: String, generation: UUID) async throws {
        let turn = event.turn
        languageModelRequest = request
        speech.logAudioMetrics(stage: "generation_start")
        try await languageModel.generate(prompt: event.prompt ?? "", instructions: event.instructions ?? "",
                                         history: event.history ?? []) { delta in
            guard isCurrent(generation, turn: turn), !Task.isCancelled else { return }
            send(["type": "result", "request": request, "delta": delta])
        }
    }

    /// Speak a sentence in its character's voice, through to the end of its playback.
    private func speak(_ event: NativeEvent, request: String, generation: UUID) async throws {
        let turn = event.turn
        speechRequest = request
        speech.logAudioMetrics(stage: "synthesis_start")
        let character = event.speaker.flatMap(DuoCharacter.init(rawValue:))
        let synthesis = try await synthesizer.synthesize(event.text ?? "", voice: event.voice)
        // The speaker's mouth shapes the sentence's words as they are heard.
        if let character { mouths[character]?.expect(text: event.text) }
        var scheduled = 0
        do {
            try await withTaskCancellationHandler {
                var stream = synthesis.samples
                #if DEBUG
                if ConversationScript.buffersSpeech { stream = try await ConversationScript.buffered(stream) }
                #endif
                for try await samples in stream where !samples.isEmpty {
                    try Task.checkCancellation()
                    guard isCurrent(generation, turn: turn), speechRequest == request else {
                        throw CancellationError()
                    }
                    if scheduled == 0 {
                        speech.logAudioMetrics(stage: "synthesis_first_pcm")
                        reveal(line: event.line, speaker: character, sentence: event.text)
                    }
                    #if DEBUG
                    if scheduled > 0, !playing {
                        print(String(format: "PLAYBACK_UNDERRUN: %@ line %d after %.2f s of audio",
                                     character?.rawValue ?? "-", event.line ?? -1,
                                     Double(scheduled) / PCMPlayer.format.sampleRate))
                    }
                    #endif
                    // Every chunk drives its speaker's mouth: a player that ran dry between
                    // chunks has ended the mouth's utterance, and the next chunk starts another.
                    if let character, character != speakingCharacter {
                        if let previous = speakingCharacter { mouths[previous]?.finish() }
                        speakingCharacter = character
                    }
                    try player.enqueue(samples)
                    scheduled += samples.count
                }
                try await player.finish()
            } onCancel: { synthesis.cancel() }
            await synthesis.waitForCompletion()
        } catch {
            synthesis.cancel()
            await synthesis.waitForCompletion()
            if error is CancellationError { throw error }
            logger.error("Speech failed: \(error.localizedDescription, privacy: .public)")
            throw VoiceError(message: "The angel and the devil lost their voices. Tap the microphone to start again.")
        }
    }

    /// Ask Audience who a line is for, on inputs Python rendered.
    private func readAudience(_ event: NativeEvent, request: String) async throws {
        let answer = try await audience.answer(
            cards: event.cards ?? [], line: event.utterance ?? "", current: event.current ?? 0,
            people: event.people ?? [], features: event.features ?? [])
        try Task.checkCancellation()
        send(["type": "result", "request": request,
              "value": ["person": answer.person, "unclear": answer.unclear, "group": answer.group]])
    }

    /// Finish recognizing the speech so far, for Python's end of the human's turn.
    private func finalizeSpeech() async throws {
        guard !muted else { throw CancellationError() }
        try await speech.finalize()
    }
}

#if DEBUG
/// Developer checks, previews and demos, chosen by launch argument (see docs/native-tts.md).
extension ConversationModel {
    fileprivate func runLaunchDiagnostics() {
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("--verify-voice-settings") {
            print("PHONON_SETTINGS: voices=\(VoiceSettings.voices.joined(separator: ","))")
        }
        let checks: [(flag: String, run: @MainActor () async -> Void)] = [
            ("--verify-phonon", { await TTSDiagnostics.verifySynthesis() }),
            ("--verify-phonon-playback", { await TTSDiagnostics.run() }),
            ("--benchmark-phonon", { await TTSDiagnostics.benchmark() }),
            ("--verify-audience", { [weak self] in await self?.verifyAudience() }),
        ]
        for check in checks where arguments.contains(check.flag) {
            checking = true
            Task { await check.run() }
        }
        if let script { Task { await script.run(self) } }
    }

    /// What a scripted run checks besides the screen: whether audio is playing, which line of the
    /// turn is being heard, the lines being written, and whether the turn's exchange is over.
    var scriptedView: (playing: Bool, line: Int?, writing: [Int], exchangeOver: Bool) {
        (playing, heardLine, writing.keys.sorted(), exchangeOver)
    }

    /// Log every Python module imported so far (`PYTHON_MODULES`), which shows what the bundled
    /// standard library and packages must keep.
    func logPythonModules() {
        print("PYTHON_MODULES: \(runtime.importedModuleNames().joined(separator: " "))")
    }

    /// Run the bundled Audience model on inputs the SpellSpeak reference runtime rendered, and
    /// compare with its answer on ONNX Runtime (tests/fixtures/audience/answers.json).
    private func verifyAudience() async {
        let started = ProcessInfo.processInfo.systemUptime
        do {
            try await audience.prepare()
            let loaded = ProcessInfo.processInfo.systemUptime - started
            let answer = try await audience.answer(
                cards: AudienceSample.cards, line: AudienceSample.line, current: AudienceSample.current,
                people: AudienceSample.people, features: AudienceSample.features)
            let values = answer.person + [answer.unclear, answer.group]
            let expected = AudienceSample.person + [AudienceSample.unclear, AudienceSample.group]
            let worst = zip(values, expected).map { abs($0 - $1) }.max() ?? .infinity
            let timed = ProcessInfo.processInfo.systemUptime
            for _ in 0..<10 {
                _ = try await audience.answer(
                    cards: AudienceSample.cards, line: AudienceSample.line, current: AudienceSample.current,
                    people: AudienceSample.people, features: AudienceSample.features)
            }
            let perLine = (ProcessInfo.processInfo.systemUptime - timed) * 100
            print(String(format: "AUDIENCE_%@: angel %.3f devil %.3f unclear %.3f group %.3f; largest difference %.1e; loaded in %.2f s, %.1f ms per line",
                         worst < 1e-4 ? "VERIFIED" : "MISMATCH", answer.person[0], answer.person[1], answer.unclear,
                         answer.group, worst, loaded, perLine))
        } catch {
            print("AUDIENCE_FAILED: \(error.localizedDescription)")
        }
    }
}
#endif
