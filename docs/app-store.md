# App Store submission

## Done in the project

- **Archive:** `xcodebuild archive` (Release, `generic/platform=iOS`) bundles the Python
  runtime, Phonon with the characters' voices, and Audience, with a dSYM: about 174 MB, 134 MB
  to download. Every Python extension module is a signed framework
  (`scripts/bundle_runtime.py`). Release Swift is compiled whole-module and validated.
- **Info.plist:** version 1.0 (1); microphone and speech recognition purpose strings; always
  light; portrait on iPhone, every orientation on iPad; `ITSAppUsesNonExemptEncryption` NO (the
  only cryptography is Python's hashing and the system's). Not offered on Macs or Vision Pro.
- **Privacy manifest:** no tracking and no collected data; reasons for user defaults, system
  boot time, file timestamps and disk space. CPython links `statfs`, though the app never
  calls it, and App Store Connect refuses uploads that link an API without a reason.
- **Release builds** compile out every debug launch argument, and keep Pipecat's log
  messages private in the system log.
- **Acknowledgements:** Settings › Credits › Acknowledgements shows `THIRD_PARTY_NOTICES.md`,
  as the BSD, MIT and Apache licences of the bundled components require.

## For the account holder

- **Role:** creating the app, a distribution certificate and uploads needs the Admin role, or
  App Manager with access to Certificates, Identifiers & Profiles and to cloud-managed
  distribution certificates.
- **Signing:** choose your team for the PipecatVoice target (`scripts/generate_project.py`
  keeps it when it regenerates the project).
- **Bundle identifier:** `ai.pipecat.littlevoices` (`PRODUCT_BUNDLE_IDENTIFIER` in
  `scripts/generate_project.py`) must belong to your team.
- **Build number:** each upload needs a new one: raise `CURRENT_PROJECT_VERSION` in
  `scripts/generate_project.py` and regenerate, or pass `CURRENT_PROJECT_VERSION=<n>` to
  `xcodebuild archive`.
- **Before submitting:** install the build from TestFlight on an iPhone with Apple
  Intelligence and run the iPhone checklist in [validation.md](validation.md).
- **App Store Connect:**
  - the name Little Voices, a support URL, and a privacy policy URL
    ([privacy.md](privacy.md) is the text);
  - screenshots for 6.9-inch iPhone (1320 × 2868) and 13-inch iPad (2064 × 2752);
  - a description that says it needs Apple Intelligence and speaks English;
  - under Pricing and Availability, untick Mac and Apple Vision Pro, and choose countries
    where Apple Intelligence is available.
- **Licences:** Phonon 31m and Pipecat Audience are Apache-2.0. Confirm that Gradium's terms
  for the characters' voices allow distribution in an App Store app.

## App Store Connect answers

- **App Privacy:** Data Not Collected. Speech, conversations and your name stay on the device;
  the app makes no network requests.
- **Export compliance:** answered by `ITSAppUsesNonExemptEncryption`.
- **Age rating:** the lines are written on the device by Apple Intelligence, under its
  guardrails and prompts that rule out harmful, sexual and occult content. The devil's
  mischief is mild: cake, skipped workouts, sarcasm. There is no web access, no sharing between
  users and no chat with other people.

## App Review notes

> Little Voices runs entirely on the device: Apple's speech recognition and Apple
> Intelligence, with Gradium Phonon for the characters' voices. It needs a device that
> supports Apple Intelligence, with Apple Intelligence turned on and its model downloaded; on
> other devices, a banner says what is missing once the welcome card is dismissed. iOS may
> download its English speech recognition assets the first time. No account or network
> connection is needed.
>
> To try it: once the angel and the devil have introduced themselves, tap Let's go on the
> welcome card, press the microphone and allow microphone access. Then hold the microphone,
> ask a question aloud, such as "Should I go to the gym tonight?", and let go; the angel and
> the devil answer and debate. Hold it again at any time to cut in. Settings also offers a
> hands-free mode: tap the microphone once, and pause to finish each turn.
>
> Transcripts of conversations, but no audio, are kept on the device so they can be read
> again from the Conversations button. Settings can stop keeping them or delete them all.

Attach a screen recording of a full conversation, in case the reviewer's device lacks Apple
Intelligence.
