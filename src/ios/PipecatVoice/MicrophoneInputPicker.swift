import AVFoundation
import AVKit
import SwiftUI

/// The microphone conversations use, chosen in Settings: its port's UID, used whenever it is
/// connected.
enum MicrophonePreference {
    private static let key = "preferred-input"

    static var uid: String? { UserDefaults.standard.string(forKey: key) }

    /// Remembers the input `session` prefers or records from.
    static func remember(from session: AVAudioSession) {
        guard let input = session.preferredInput ?? session.currentRoute.inputs.first else { return }
        UserDefaults.standard.set(input.uid, forKey: key)
    }
}

/// Settings' row for Apple's input menu, which owns route and Mic Mode selection: Voice Isolation
/// is the user's choice, and the app only reports the mode in use. It shows the microphone and
/// its mode, and tells `onPresentationChanged` as the menu opens and closes.
struct MicrophoneInputPicker: UIViewRepresentable {
    let session: AVAudioSession?
    let onPresentationChanged: (Bool) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> UIButton {
        let button = UIButton(type: .system)
        button.configuration = .plain()
        button.contentHorizontalAlignment = .leading
        button.accessibilityHint = "Shows the microphones you can use and their Mic Modes, such as Voice Isolation."
        button.addTarget(context.coordinator, action: #selector(Coordinator.present), for: .touchUpInside)
        context.coordinator.attach(button)
        return button
    }

    func updateUIView(_ button: UIButton, context: Context) {
        context.coordinator.update(session: session, onPresentationChanged: onPresentationChanged)
    }

    /// The proposed width, at least 44 pt tall.
    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UIButton, context: Context) -> CGSize? {
        let width = proposal.width.flatMap { $0.isFinite ? $0 : nil } ?? uiView.intrinsicContentSize.width
        let size = uiView.systemLayoutSizeFitting(
            CGSize(width: width, height: UIView.layoutFittingCompressedSize.height),
            withHorizontalFittingPriority: .required, verticalFittingPriority: .fittingSizeLevel)
        return CGSize(width: width, height: max(44, size.height))
    }

    static func dismantleUIView(_ button: UIButton, coordinator: Coordinator) {
        coordinator.detach()
    }

    @MainActor
    final class Coordinator: NSObject, @preconcurrency AVInputPickerInteraction.Delegate {
        private weak var button: UIButton?
        private var session: AVAudioSession?
        private var interaction: AVInputPickerInteraction?
        private var observers: [NSObjectProtocol] = []
        private var observesMicrophoneMode = false
        private var presenting = false
        private var onPresentationChanged: (Bool) -> Void = { _ in }

        func attach(_ button: UIButton) {
            self.button = button
            for name in [AVAudioSession.routeChangeNotification, UIApplication.didBecomeActiveNotification] {
                observers.append(NotificationCenter.default.addObserver(forName: name, object: nil,
                    queue: .main) { [weak self] _ in
                        MainActor.assumeIsolated { self?.refresh() }
                    })
            }
            // A class property, which key-path KVO cannot observe; class-object KVO is the
            // documented API.
            observesMicrophoneMode = true
            (AVCaptureDevice.self as AnyObject).addObserver(self, forKeyPath: "activeMicrophoneMode",
                                                           options: [.initial, .new], context: nil)
        }

        func update(session: AVAudioSession?, onPresentationChanged: @escaping (Bool) -> Void) {
            self.onPresentationChanged = onPresentationChanged
            if self.session !== session {
                interaction?.dismiss()
                if let interaction { button?.removeInteraction(interaction) }
                if presenting { presenting = false; self.onPresentationChanged(false) }
                self.session = session
                interaction = session.map { AVInputPickerInteraction(audioSession: $0) }
                if let interaction {
                    interaction.delegate = self
                    button?.addInteraction(interaction)
                }
            }
            refresh()
        }

        @objc func present() {
            guard session != nil, !presenting, button?.window != nil else { return }
            interaction?.present()
        }

        func inputPickerInteractionWillBeginPresenting(_ inputPickerInteraction: AVInputPickerInteraction) {
            guard interaction === inputPickerInteraction else { return }
            presenting = true
            onPresentationChanged(true)
        }

        func inputPickerInteractionDidEndDismissing(_ inputPickerInteraction: AVInputPickerInteraction) {
            guard interaction === inputPickerInteraction else { return }
            presenting = false
            refresh()
            onPresentationChanged(false)
        }

        override nonisolated func observeValue(forKeyPath keyPath: String?, of object: Any?,
                                               change: [NSKeyValueChangeKey: Any]?,
                                               context: UnsafeMutableRawPointer?) {
            guard keyPath == "activeMicrophoneMode" else {
                super.observeValue(forKeyPath: keyPath, of: object, change: change, context: context)
                return
            }
            Task { @MainActor [weak self] in self?.refresh() }
        }

        private func refresh() {
            guard let button else { return }
            let input = session.flatMap { $0.preferredInput ?? $0.currentRoute.inputs.first ?? $0.availableInputs?.first }
            let mode: String
            switch AVCaptureDevice.activeMicrophoneMode {
            case .standard: mode = "Standard"
            case .wideSpectrum: mode = "Wide Spectrum"
            case .voiceIsolation: mode = "Voice Isolation"
            @unknown default: mode = "System Mic Mode"
            }
            let name = input?.portName ?? "Microphone"
            var configuration = button.configuration ?? .plain()
            configuration.image = UIImage(systemName: deviceSymbol(for: input?.portType ?? .builtInMic))
            configuration.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(textStyle: .body)
            configuration.imagePadding = 12
            configuration.title = name
            configuration.attributedSubtitle = AttributedString(NSAttributedString(
                string: mode, attributes: [.foregroundColor: UIColor.secondaryLabel,
                                           .font: UIFont.preferredFont(forTextStyle: .footnote)]))
            configuration.titleAlignment = .leading
            configuration.baseForegroundColor = .label
            configuration.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: 0, bottom: 6, trailing: 0)
            button.configuration = configuration
            button.isEnabled = session != nil
            button.accessibilityLabel = "Microphone"
            button.accessibilityValue = "\(name), \(mode)"
            button.invalidateIntrinsicContentSize()
        }

        private func deviceSymbol(for port: AVAudioSession.Port) -> String {
            switch port {
            case .bluetoothHFP, .headsetMic: return "headphones"
            case .usbAudio, .lineIn: return "cable.connector"
            case .carAudio: return "car"
            default: return UIDevice.current.userInterfaceIdiom == .pad ? "ipad" : "iphone"
            }
        }

        func detach() {
            interaction?.dismiss()
            if let interaction { button?.removeInteraction(interaction) }
            interaction = nil
            if presenting { presenting = false; onPresentationChanged(false) }
            for observer in observers { NotificationCenter.default.removeObserver(observer) }
            observers.removeAll()
            if observesMicrophoneMode {
                (AVCaptureDevice.self as AnyObject).removeObserver(self, forKeyPath: "activeMicrophoneMode")
                observesMicrophoneMode = false
            }
            button = nil
        }
    }
}
