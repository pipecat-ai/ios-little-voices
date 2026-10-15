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

    private var connecting: Bool { model.loading || model.preparing }

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
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            footer.onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).minY } action: { footerTop = $0 }
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
        .tint(VoicePalette.blue)
        // No mute tick when ending a conversation clears the mute.
        .sensoryFeedback(.selection, trigger: model.muted) { _, _ in model.active }
        // New conversation's wipe taps in place of the conversation's end.
        .sensoryFeedback(.impact(flexibility: .soft), trigger: resetWipe?.id) { _, wipe in wipe != nil }
        .sensoryFeedback(.impact(weight: .light), trigger: model.active) { _, _ in resetWipe == nil }
        .onChange(of: model.error) {
            if let error = model.errorMessage { AccessibilityNotification.Announcement("Error: \(error)").post() }
        }
        .sheet(isPresented: $model.showSettings) { SettingsView(model: model) }
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

    /// Clears the conversation at once and wipes the old screen away over the fresh stage.
    private func newConversation() {
        let snapshot = ResetWipeSnapshot.capture()
        model.clearConversation()
        resetWipe = snapshot
    }

    /// The dock, with the error banner above it while there is one.
    private var footer: some View {
        VStack(spacing: 10) {
            if let error = model.errorMessage {
                errorBanner(error)
                    .transition(.asymmetric(insertion: reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity),
                                            removal: .opacity))
            }
            dock
                .opacity(introPlaying ? 0 : 1)
                .allowsHitTesting(!introPlaying)
                .accessibilityHidden(introPlaying)
                .animation(.easeInOut(duration: 0.5), value: introPlaying)
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

    /// The microphone alone, or during a conversation a glass capsule with the input picker and
    /// End beside it. The side buttons stay in the hierarchy, pinned to the capsule's ends, so they
    /// slide out from behind the microphone as it widens and tuck back in as it narrows.
    private var dock: some View {
        let palette = palette, controls = showsControls
        let glyph = palette.colors.chromeGlyph.devil
        return ZStack {
            MicrophoneInputPicker(session: model.microphoneInputSession,
                                  isEnabled: model.canChooseMicrophone,
                                  onPresentationChanged: model.microphonePickerPresentationChanged,
                                  glyphColor: UIColor(red: glyph.r, green: glyph.g, blue: glyph.b, alpha: glyph.a))
                .frame(width: Self.sideButton, height: Self.sideButton)
                .softGlass(Circle(), tint: palette.colors.dockButton, kind: .chrome, palette: palette)
                .dockSideControl(shown: controls)
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
            controls ? min(width * 0.8, 380) : Self.dockHeight
        }
        .softGlass(Capsule(), tint: palette.colors.chromeGlass.devil, kind: .chrome, palette: palette, shown: controls)
    }

    private static let sideButton: CGFloat = 52

    /// Reads the input level in its own body, so level updates re-render only the button.
    private struct DockMicrophone: View {
        let model: ConversationModel
        let connecting: Bool
        let palette: StagePalette

        var body: some View {
            MicrophoneControl(level: model.userLevel, muted: model.muted, connecting: connecting,
                              active: model.active, palette: palette) {
                if model.active { model.toggleMute() } else { model.start() }
            }
        }
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
    @State private var showContactPicker = false
    @State private var contactNotice: String?
    @State private var error: String?

    init(model: ConversationModel) {
        self.model = model
        _preferredName = State(initialValue: model.userProfile.preferredName)
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
                    Text("Conversations stay in memory and clear when the app closes. Apple Intelligence must be enabled. Apple speech assets may download on first use.")
                }
                Section("Credits") {
                    credit("Pipecat", detail: "Conversation by Pipecat, Daily’s open-source framework for voice AI.",
                           url: "https://pipecat.ai")
                    credit("Gradium", detail: "Speech by Phonon, Gradium’s on-device text-to-speech model.",
                           url: "https://gradium.ai")
                }
                if let error { Section { Text(error).foregroundStyle(.red) } }
            }.navigationTitle("Settings").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { dismiss() }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Save") {
                            do {
                                try model.saveProfile(preferredName: preferredName)
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

