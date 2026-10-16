import SwiftUI

@main
struct PipecatVoiceApp: App {
    @State private var model = ConversationModel()
    @State private var launchRequests = ConversationLaunchRequests.shared
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            root
                .onChange(of: scenePhase, initial: true) { previous, phase in
                    if phase == .background, previous != phase { model.enterBackground() }
                    if phase == .active {
                        model.becomeActive()
                        startRequestedConversation()
                    }
                }
                .onChange(of: model.ready, initial: true) { _, _ in startRequestedConversation() }
                .onChange(of: launchRequests.pendingStart, initial: true) { _, _ in startRequestedConversation() }
        }
    }

    @ViewBuilder
    private var root: some View {
        #if DEBUG
        if let gallery = StageDebug.gallery {
            ExpressionGalleryView(request: gallery)
        } else if StageDebug.mouthSheet {
            MouthSheetView()
        } else if StageDebug.micSheet {
            MicrophoneSheetView()
        } else if let pose = StageDebug.stagePose {
            ConversationView(model: model, stagePose: pose)
        } else {
            ConversationView(model: model)
        }
        #else
        ConversationView(model: model)
        #endif
    }

    private func startRequestedConversation() {
        guard launchRequests.consume(whenReady: scenePhase == .active && model.ready) else { return }
        model.startFromShortcut()
    }
}
