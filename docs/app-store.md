# App Store submission

What the project already does for an App Store build, what only the account holder can do,
and the answers App Store Connect asks for.

## In the project

- **Archive:** `xcodebuild archive` (Release, `generic/platform=iOS`) bundles the Python
  runtime, the Phonon checkpoint with the characters' voices, and Audience. The archive
  carries a dSYM.
- **Native code:** every Python extension module is a framework in `Frameworks/`, signed
  with the build's identity by `scripts/bundle_runtime.py`; no loose `.so` or `.dylib` ships.
- **Info.plist:** version 1.0 (build 1), the microphone and speech recognition purpose
  strings, always light, portrait on iPhone and every orientation on iPad, and
  `ITSAppUsesNonExemptEncryption` set to NO: the app's only cryptography is Python's hashing
  modules and the system's own.
- **Privacy manifest:** no tracking and no collected data, with reasons for user defaults,
  system boot time and file timestamps (see [architecture](architecture.md)).
- **Release builds** compile out every debug launch argument and scripted run.
- **Icon and launch screen:** a single 1024-pt opaque icon, and the splash art on its
  colour.

## For the account holder

- **Signing:** choose your team for the PipecatVoice target. `scripts/generate_project.py`
  keeps it when it regenerates the project.
- **Bundle identifier:** `ai.pipecat.littlevoices` (`PRODUCT_BUNDLE_IDENTIFIER` in
  `scripts/generate_project.py`) must belong to your team.
- **App Store Connect record:**
  - the name Little Voices;
  - a privacy policy URL ([privacy.md](privacy.md) is a draft);
  - a support URL;
  - iPhone and iPad screenshots;
  - an age rating.
- **Licences:** the app redistributes Gradium Phonon's checkpoint, the characters' voices
  made for it, and SpellSpeak Audience. Confirm that their terms allow distribution in an App
  Store app (see `THIRD_PARTY_NOTICES.md`).

## App Store Connect answers

- **App Privacy:** Data Not Collected. Speech, the conversation and the name you give stay on
  the device; the app makes no network requests.
- **Export compliance:** answered by `ITSAppUsesNonExemptEncryption` (no non-exempt
  encryption).

## App Review notes

> Little Voices runs entirely on the device: Apple's speech recognition and Apple
> Intelligence, with Gradium Phonon for the characters' voices. It needs a device that
> supports Apple Intelligence, with Apple Intelligence turned on and its model downloaded; on
> other devices it explains what is missing. iOS may download its English speech recognition
> assets the first time. No account or network connection is needed.
>
> To try it: once the angel and the devil have introduced themselves, tap Let's go on the
> welcome card, press the microphone and allow microphone access. Then hold the microphone, ask a question aloud, such as
> "Should I go to the gym tonight?", and let go; the angel and the devil answer and debate.
> Hold it again at any time to cut in. End finishes, and New conversation starts afresh.
> Settings also offers a hands-free mode: tap the microphone once, and pause to finish each
> turn.

## Known risk

CPython links the disk-space functions `statfs` and `fstatfs`, though nothing in the app
calls them, so the privacy manifest declares no disk-space reason. If App Store Connect
reports ITMS-91053 for `NSPrivacyAccessedAPICategoryDiskSpace` on upload, add that category
to `src/ios/PipecatVoice/PrivacyInfo.xcprivacy` with the reason Apple accepts for it.
