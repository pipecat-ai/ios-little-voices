import AppIntents
import SwiftUI

/// How to start a conversation by voice with Apple's Vocal Shortcuts.
struct WakeShortcutSetupView: View {
    /// "iPhone" or "iPad", as the steps name the device.
    private let device = UIDevice.current.localizedModel

    var body: some View {
        List {
            Section {
                Text("Say “Hey Little Voices” to open the app and start listening. Apple learns your phrase in Vocal Shortcuts.")
                ShortcutsLink().shortcutsLinkStyle(.automaticOutline)
            }
            Section("Set up once") {
                step("1", title: "Save a shortcut first",
                     detail: "Open All Shortcuts in the Shortcuts app and tap +. Add an action, search for Little Voices, and add Start conversation. Name the shortcut Talk to Little Voices and tap Done to save it. Tapping the existing App Shortcut tile runs the action.")
                step("2", title: "Select Talk to Little Voices",
                     detail: "Open Settings → Accessibility → Vocal Shortcuts. Tap Set Up or Add Action, then look for the saved Talk to Little Voices shortcut. Reopen the action list if it was already open when you saved it.")
                step("3", title: "Teach \(device) your phrase",
                     detail: "Enter Hey Little Voices and repeat it when \(device) asks.")
            }
            Section("Start talking") {
                Text("Say “Hey Little Voices”, then ask your question once the microphone stops spinning. Speak normally, and cut in whenever you like.")
                Text("Unlock \(device) if prompted. The first conversation may ask for microphone and speech permissions or need time to prepare its models.")
                    .foregroundStyle(.secondary)
            }
            Section("If the shortcut is missing") {
                Text("In Vocal Shortcuts, choose Siri Request and enter “Start a conversation with Little Voices”. Then train “Hey Little Voices” as the phrase that runs that request.")
            }
            Section {
                Text("Vocal Shortcuts processes the wake phrase on your device and controls its own microphone indicator. Turn it off in Accessibility settings when you no longer want it listening.")
                    .font(.footnote).foregroundStyle(.secondary)
                Link("Apple’s Vocal Shortcuts guide",
                     destination: URL(string: "https://support.apple.com/guide/iphone/use-vocal-shortcuts-iph7f242ea2c/ios")!)
            }
        }
        .navigationTitle("Hey Little Voices")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func step(_ number: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(number).font(.headline).foregroundStyle(VoicePalette.blue)
                .frame(width: 22).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(.headline)
                Text(detail).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 5)
        .accessibilityElement(children: .combine)
    }
}
