# App Store submission

## Done in the project

- **Archive:** `xcodebuild archive` (Release, `generic/platform=iOS`) bundles the Python
  runtime, Phonon with the characters' voices, and Audience, with a dSYM. Every Python
  extension module is a signed framework (`scripts/bundle_runtime.py`).
- **Info.plist:** version 1.0 (1); microphone and speech recognition purpose strings; always
  light; portrait on iPhone, every orientation on iPad; `ITSAppUsesNonExemptEncryption` NO (the
  only cryptography is Python's hashing and the system's).
- **Privacy manifest:** no tracking and no collected data; reasons for user defaults, system
  boot time and file timestamps.
- **Release builds** compile out every debug launch argument.

## For the account holder

- **Signing:** choose your team for the PipecatVoice target (`scripts/generate_project.py`
  keeps it when it regenerates the project).
- **Bundle identifier:** `ai.pipecat.littlevoices` (`PRODUCT_BUNDLE_IDENTIFIER` in
  `scripts/generate_project.py`) must belong to your team.
- **App Store Connect:** the name Little Voices, a privacy policy URL ([privacy.md](privacy.md)
  is the text), a support URL, iPhone and iPad screenshots, and an age rating.
- **Licences:** Phonon 31m and Pipecat Audience are Apache-2.0. Confirm that Gradium's terms
  for the characters' voices allow distribution in an App Store app.

## App Store Connect answers

- **App Privacy:** Data Not Collected. Speech, conversations and your name stay on the device;
  the app makes no network requests.
- **Export compliance:** answered by `ITSAppUsesNonExemptEncryption`.

## App Review notes

> Little Voices runs entirely on the device: Apple's speech recognition and Apple
> Intelligence, with Gradium Phonon for the characters' voices. It needs a device that
> supports Apple Intelligence, with Apple Intelligence turned on and its model downloaded; on
> other devices it explains what is missing. iOS may download its English speech recognition
> assets the first time. No account or network connection is needed.
>
> To try it: once the angel and the devil have introduced themselves, tap Let's go on the
> welcome card, press the microphone and allow microphone access. Then hold the microphone,
> ask a question aloud, such as "Should I go to the gym tonight?", and let go; the angel and
> the devil answer and debate. Hold it again at any time to cut in. Settings also offers a
> hands-free mode: tap the microphone once, and pause to finish each turn.

## Known risk

CPython links `statfs` and `fstatfs`, though nothing calls them, so the privacy manifest
declares no disk-space reason. If App Store Connect reports ITMS-91053 for
`NSPrivacyAccessedAPICategoryDiskSpace`, add that category to
`src/ios/PipecatVoice/PrivacyInfo.xcprivacy` with the reason Apple accepts.
