import AVFoundation
import SwiftUI

/// The conversation screen: the stage between a header (Settings, New conversation) and a dock
/// (input picker, microphone, End).
struct ConversationView: View {
    @Bindable var model: ConversationModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    /// Where the header ends and the footer starts, in window coordinates; the stage keeps its
    /// faces and captions between them.
    @State private var headerBottom: CGFloat = 0
    @State private var footerTop: CGFloat = .infinity
    /// The screen New conversation is wiping away.
    @State private var resetWipe: ResetWipeSnapshot?
    /// The launch intro is playing: the microphone fades in once it has.
    @State private var introPlaying = true
    /// The intro's logo shows.
    @State private var logoShown = false
    /// The first launch's welcome has been dismissed, on this launch or an earlier one.
    @State private var welcomeSeen = WelcomeCard.seen()
    @State private var showHistory = false

    private var connecting: Bool { model.loading || model.preparing }

    /// The header and dock, which a showreel leaves out.
    private var showsChrome: Bool {
        #if DEBUG
        !StageDebug.showreel
        #else
        true
        #endif
    }

    /// The welcome shows once the intro has played, until it is dismissed or a conversation starts.
    private var showsWelcome: Bool {
        #if DEBUG
        if stagePose != nil || StageDebug.showreel { return false }
        #endif
        return !welcomeSeen && !introPlaying && !model.active
    }

    /// The dock waits for the intro, then for the welcome.
    private var dockHidden: Bool { introPlaying || showsWelcome }

    init(model: ConversationModel) {
        self.model = model
    }

    #if DEBUG
    /// A settled stage pose drawn in place of the characters (`--stage-pose`).
    private var stagePose: StagePoseRequest?

    init(model: ConversationModel, stagePose: StagePoseRequest?) {
        self.model = model
        self.stagePose = stagePose
    }
    #endif

    var body: some View {
        stage
        .safeAreaInset(edge: .top, spacing: 0) {
            header.onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).maxY } action: { headerBottom = $0 }
                .opacity(showsChrome ? 1 : 0)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            footer.onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).minY } action: { footerTop = $0 }
                .opacity(showsChrome ? 1 : 0)
        }
        .overlay {
            if let resetWipe {
                ResetWipeView(snapshot: resetWipe, reduceMotion: reduceMotion) {
                    if self.resetWipe?.id == resetWipe.id { self.resetWipe = nil }
                }
                .id(resetWipe.id)
                .ignoresSafeArea()
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
        }
        .overlay { IntroLogo(shown: logoShown) }
        .overlay {
            if showsWelcome {
                ZStack {
                    Color.black.opacity(0.18).ignoresSafeArea().accessibilityHidden(true)
                    WelcomeCard(palette: palette, holdsToTalk: model.microphoneHolds) { dismissWelcome() }
                }
                .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.92)))
            }
        }
        .animation(reduceMotion ? .easeInOut(duration: 0.25) : .spring(response: 0.45, dampingFraction: 0.8),
                   value: showsWelcome)
        // A conversation started another way, as by voice, has no need of it.
        .onChange(of: model.active) { _, active in if active { dismissWelcome() } }
        .tint(VoicePalette.blue)
        // No mute tick when ending a conversation clears the mute.
        .sensoryFeedback(.selection, trigger: model.muted) { _, _ in model.active }
        // New conversation's wipe taps in place of the conversation's end.
        .sensoryFeedback(.impact(flexibility: .soft), trigger: resetWipe?.id) { _, wipe in wipe != nil }
        // A conversation started by holding the microphone gets its tap as it starts listening.
        .sensoryFeedback(.impact(weight: .light), trigger: model.active) { _, active in
            resetWipe == nil && !(active && model.holdsToTalk)
        }
        .onChange(of: model.error) {
            if let error = model.errorMessage { AccessibilityNotification.Announcement("Error: \(error)").post() }
        }
        .sheet(isPresented: $model.showSettings) { SettingsView(model: model) }
        .sheet(isPresented: $showHistory) { HistoryView(archive: model.history, keeping: model.savesConversations, palette: palette) }
    }

    /// One VoiceOver container, read after the header and before the footer.
    @ViewBuilder
    private var stage: some View {
        Group {
            #if DEBUG
            DuoStageView(model: model, headerBottom: headerBottom, footerTop: footerTop, introPlaying: $introPlaying,
                         logoShown: $logoShown, pose: stagePose)
            #else
            DuoStageView(model: model, headerBottom: headerBottom, footerTop: footerTop, introPlaying: $introPlaying,
                         logoShown: $logoShown)
            #endif
        }
        .accessibilityElement(children: .contain)
        .accessibilitySortPriority(1)
        .onChange(of: introPlaying) { _, playing in if !playing { model.introEnded() } }
    }

    /// The stage's palette, which the chrome shares.
    private var palette: StagePalette {
        StagePalette(contrast: contrast, reduceTransparency: reduceTransparency)
    }

    /// Whether the dock shows its conversation controls: in a conversation, or inert under a
    /// `--stage-pose`.
    private var showsControls: Bool {
        #if DEBUG
        model.active || stagePose != nil
        #else
        model.active
        #endif
    }

    private var header: some View {
        let palette = palette
        return HStack(spacing: 0) {
            GlassCircleButton(title: "Settings", systemImage: "slider.horizontal.3",
                              tint: palette.colors.chromeGlass.angel, glyph: palette.colors.chromeGlyph.angel,
                              palette: palette, shadow: true) {
                model.showSettings = true
            }
            .disabled(model.active)
            Spacer(minLength: 16)
            GlassCircleButton(title: "New conversation", systemImage: "square.and.pencil",
                              tint: palette.colors.chromeGlass.angel, glyph: palette.colors.chromeGlyph.angel,
                              palette: palette, shadow: true) {
                newConversation()
            }
            .accessibilityHint("Clears the conversation and starts a fresh one.")
            .disabled(!model.hasConversation && !model.active)
        }
        .padding(.horizontal, 20).padding(.top, 8).padding(.bottom, 6)
        .accessibilityElement(children: .contain)
        .accessibilitySortPriority(2)
    }

    private func dismissWelcome() {
        guard !welcomeSeen else { return }
        welcomeSeen = true
        WelcomeCard.markSeen()
    }

    /// Clears the conversation at once and wipes the old screen away over the fresh stage.
    private func newConversation() {
        let snapshot = ResetWipeSnapshot.capture()
        model.clearConversation()
        resetWipe = snapshot
    }

    /// The dock, with the error banner above it while there is one, once the welcome is dismissed.
    private var footer: some View {
        VStack(spacing: 10) {
            if let error = model.errorMessage, !showsWelcome {
                errorBanner(error)
                    .transition(.asymmetric(insertion: reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity),
                                            removal: .opacity))
            }
            dock
                .opacity(dockHidden ? 0 : 1)
                .allowsHitTesting(!dockHidden)
                .accessibilityHidden(dockHidden)
                .animation(.easeInOut(duration: 0.5), value: dockHidden)
        }
        .frame(maxWidth: 520)
        .padding(.horizontal, 20).padding(.top, 8).padding(.bottom, 10)
        .frame(maxWidth: .infinity)
        .animation(reduceMotion ? nil : .smooth(duration: 0.3), value: showsControls)
        .animation(reduceMotion ? .linear(duration: 0.15) : .smooth(duration: 0.3), value: model.error)
        .accessibilityElement(children: .contain)
    }

    /// The microphone's 76 pt with a little glass around it.
    private static let dockHeight: CGFloat = 80

    /// The microphone, with Conversations beside it once there are any, and during a conversation
    /// a glass capsule with End too. The side buttons stay in the hierarchy, pinned to the dock's
    /// ends, so they slide out from behind the microphone as it widens and tuck back in as it
    /// narrows.
    private var dock: some View {
        let palette = palette, controls = showsControls
        let glyph = palette.colors.chromeGlyph.devil
        let history = controls || !model.history.conversations.isEmpty
        return ZStack {
            // Outside the capsule it floats on its own glass, as the header's buttons do.
            GlassCircleButton(title: "Conversations", systemImage: "bubble.left.and.text.bubble.right.fill",
                              tint: controls ? palette.colors.dockButton : palette.colors.chromeGlass.devil,
                              glyph: glyph, palette: palette, diameter: Self.sideButton, glyphSize: 18,
                              shadow: !controls) { showHistory = true }
                .accessibilityHint("Shows the conversations kept on this device.")
                .dockSideControl(shown: history)
                .frame(maxWidth: .infinity, alignment: .leading)
            GlassCircleButton(title: "End conversation", systemImage: "phone.down.fill",
                              tint: palette.colors.dockButton, glyph: glyph, palette: palette,
                              diameter: Self.sideButton, glyphSize: 18, action: model.stop)
                .dockSideControl(shown: controls)
                .frame(maxWidth: .infinity, alignment: .trailing)
            DockMicrophone(model: model, connecting: connecting, palette: palette)
        }
        .padding(.horizontal, controls ? 14 : 2)
        .frame(height: Self.dockHeight)
        .containerRelativeFrame(.horizontal) { width, _ in
            history ? min(width * 0.8, 380) : Self.dockHeight
        }
        .softGlass(Capsule(), tint: palette.colors.chromeGlass.devil, kind: .chrome, palette: palette, shown: controls)
    }

    private static let sideButton: CGFloat = 52

    /// Reads the input level in its own body, so level updates re-render only the button.
    private struct DockMicrophone: View {
        let model: ConversationModel
        let connecting: Bool
        let palette: StagePalette

        @Environment(\.accessibilityReduceMotion) private var reduceMotion

        var body: some View {
            MicrophoneControl(level: model.userLevel, muted: model.muted, connecting: connecting,
                              active: model.active, holds: model.microphoneHolds, held: model.talking,
                              hearing: model.hearing, palette: palette) {
                if model.active { model.toggleMute() } else { model.start(holdingToTalk: false) }
            } onHold: { pressed in
                if pressed { model.pressMicrophone() } else { model.releaseMicrophone() }
            }
            .overlay(alignment: .top) {
                if model.showsHoldHint {
                    HoldToTalkHint(palette: palette)
                        .fixedSize()
                        .offset(y: -54)
                        .transition(reduceMotion ? .opacity
                            : .opacity.combined(with: .scale(scale: 0.85, anchor: .bottom)))
                }
            }
            .animation(reduceMotion ? .linear(duration: 0.15) : .smooth(duration: 0.25), value: model.showsHoldHint)
        }
    }

    /// The microphone has been refused, so the error offers the app's page in Settings.
    private var microphoneDenied: Bool {
        model.error != model.availability && AVAudioApplication.shared.recordPermission == .denied
    }

    /// Its text stops growing at the captions' largest size, so it never crowds the stage.
    private func errorBanner(_ error: String) -> some View {
        let palette = palette, colors = palette.colors
        return HStack(spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "exclamationmark.circle.fill")
                    .foregroundStyle(palette.color(colors.bannerGlyph))
                Text(error)
                    .foregroundStyle(palette.color(colors.bannerText))
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                Spacer(minLength: 0)
            }
            .font(.subheadline.weight(.medium)).fontDesign(.rounded)
            .padding(.vertical, 12)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Error")
            .accessibilityValue(error)
            if microphoneDenied {
                Button("Open Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                }
                .font(.subheadline.weight(.semibold)).fontDesign(.rounded)
                .foregroundStyle(palette.color(colors.bannerText))
                .padding(.horizontal, 6)
                .frame(minHeight: 44)
            }
            Button { model.error = nil } label: {
                Image(systemName: "xmark")
                    .font(.footnote.weight(.bold))
                    .foregroundStyle(palette.color(colors.bannerText).opacity(0.7))
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Dismiss error")
        }
        .dynamicTypeSize(...DynamicTypeSize.accessibility2)
        .padding(.leading, 16).padding(.trailing, 4)
        .softGlass(RoundedRectangle(cornerRadius: 20, style: .continuous), tint: colors.bannerTint, kind: .caption,
                   palette: palette, shadowRadius: 18)
    }
}

private extension View {
    /// Hidden outside a conversation: shrunk behind the microphone, with no touches or VoiceOver focus.
    func dockSideControl(shown: Bool) -> some View {
        scaleEffect(shown ? 1 : 0.6)
            .opacity(shown ? 1 : 0)
            .allowsHitTesting(shown)
            .accessibilityHidden(!shown)
    }
}

private struct SettingsView: View {
    let model: ConversationModel
    @Environment(\.dismiss) private var dismiss
    @State private var preferredName: String
    @State private var inputMode: InputMode
    @State private var savesConversations: Bool
    @State private var confirmingDeleteAll = false
    /// The audio session, set up for choosing a microphone while Settings is open.
    @State private var microphoneSession: AVAudioSession?
    @State private var showContactPicker = false
    @State private var contactNotice: String?
    @State private var error: String?

    init(model: ConversationModel) {
        self.model = model
        _preferredName = State(initialValue: model.userProfile.preferredName)
        _inputMode = State(initialValue: model.inputMode)
        _savesConversations = State(initialValue: model.savesConversations)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Your name", text: $preferredName)
                        .textContentType(.givenName).textInputAutocapitalization(.words)
                        .autocorrectionDisabled()
                    Button("Choose my contact", systemImage: "person.crop.circle") {
                        contactNotice = nil
                        showContactPicker = true
                    }
                    if !preferredName.isEmpty {
                        Button("Clear name") { preferredName = ""; contactNotice = nil }
                    }
                    if let contactNotice { Text(contactNotice).foregroundStyle(.secondary) }
                } header: { Text("About you") } footer: {
                    Text("Choose your contact or enter the name you’d like the angel and the devil to use. Only this name is saved and added to their instructions when a conversation starts.")
                }
                .disabled(model.active)
                Section {
                    Picker("Microphone", selection: $inputMode) {
                        ForEach(InputMode.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                } header: { Text("Talking") } footer: {
                    Text(inputMode == .hold
                         ? "Hold the microphone while you talk, and let go when you’re done."
                         : "Tap the microphone once, then talk. The angel and the devil answer when you pause.")
                }
                .disabled(model.active)
                Section {
                    MicrophoneInputPicker(session: microphoneSession) { presented in
                        if !presented, let microphoneSession { MicrophonePreference.remember(from: microphoneSession) }
                    }
                } header: { Text("Microphone") } footer: {
                    Text("The microphone your conversations use, and its Mic Mode, such as Voice Isolation.")
                }
                Section {
                    Toggle("Keep conversations", isOn: $savesConversations)
                    Button("Delete All Conversations", role: .destructive) { confirmingDeleteAll = true }
                        .disabled(model.history.conversations.isEmpty)
                } header: { Text("History") } footer: {
                    Text("Transcripts of your conversations stay on this device, so you can read them again. They’re never backed up or shared, and no audio is kept.")
                }
                .confirmationDialog("Delete all conversations?", isPresented: $confirmingDeleteAll,
                                    titleVisibility: .visible) {
                    Button("Delete All Conversations", role: .destructive) { model.history.deleteAll() }
                } message: {
                    Text("Their transcripts are removed from this device.")
                }
                Section {
                    ForEach(DuoCharacter.allCases) { character in
                        LabeledContent("\(character.title)’s voice", value: Self.voiceName(character.voice))
                    }
                    LabeledContent("Language", value: "English (US)")
                } header: { Text("Voices") } footer: {
                    Text("Gradium Phonon generates speech audio on this device.")
                }
                Section {
                    NavigationLink("Set up a voice shortcut") { WakeShortcutSetupView() }
                } header: { Text("Hey Little Voices") } footer: {
                    Text("Use Apple’s Vocal Shortcuts to open Little Voices and start a conversation with your voice.")
                }
                Section {
                    LabeledContent("Speech recognition", value: "Apple Speech")
                    LabeledContent("Language model", value: "Apple Foundation Models")
                    LabeledContent("Speech synthesis", value: VoiceSettings.engineTitle)
                    if let availability = model.availability {
                        Label(availability, systemImage: "info.circle")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                } header: { Text("On this device") } footer: {
                    Text("Apple Intelligence must be enabled. Apple speech assets may download on first use.")
                }
                Section("Credits") {
                    credit("Pipecat", detail: "Conversation by Pipecat, Daily’s open-source framework for voice AI.",
                           url: "https://pipecat.ai")
                    credit("Gradium", detail: "Speech by Phonon, Gradium’s on-device text-to-speech model.",
                           url: "https://gradium.ai")
                    NavigationLink("Acknowledgements") { AcknowledgementsView() }
                }
                if let error { Section { Text(error).foregroundStyle(.red) } }
            }.navigationTitle("Settings").navigationBarTitleDisplayMode(.inline)
                .onAppear { microphoneSession = model.sessionForMicrophoneChoice() }
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { dismiss() }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Save") {
                            do {
                                try model.saveSettings(preferredName: preferredName, inputMode: inputMode,
                                                       savesConversations: savesConversations)
                                dismiss()
                            } catch { self.error = error.localizedDescription }
                        }.disabled(model.active)
                    }
                }
                .sheet(isPresented: $showContactPicker) {
                    ProfileContactPicker(onSelection: { name in
                        if name.isEmpty {
                            contactNotice = "That contact has no first name. Enter the name you’d like to use."
                        } else { preferredName = name; contactNotice = nil }
                        showContactPicker = false
                    }, onCancel: { showContactPicker = false })
                }
        }.tint(VoicePalette.blue)
    }

    /// A Phonon voice's name as people say it: Gradium's are language_region_Name, so
    /// `en_gb_Reuben` is Reuben; a custom voice such as `Angel_F01` is Angel F01.
    private static func voiceName(_ voice: String) -> String {
        let parts = voice.split(separator: "_")
        if parts.count == 3, parts[0].count == 2, parts[1].count == 2,
           parts[0].allSatisfy(\.isLowercase), parts[1].allSatisfy(\.isLowercase) {
            return String(parts[2])
        }
        return parts.joined(separator: " ")
    }

    private func credit(_ name: String, detail: String, url: String) -> some View {
        Link(destination: URL(string: url)!) {
            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                Text(detail).font(.footnote).foregroundStyle(.secondary)
            }
        }
    }
}

