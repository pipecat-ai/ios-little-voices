# Artwork

- `app-icon.png`: the angel and the devil on a split yellow and red ground; square and opaque
  (iOS applies the mask).
- `splash.png`: the launch art, the angel above the clouds and the devil in the embers.
- `logo.png`: the Little Voices logo, which drops in over the launch intro.
- `avatars.png`: both faces, which name the characters in a saved conversation.
- `welcome.png`: the two peeking over the top of the first launch's welcome card.

`export.py` turns them into the `AppIcon`, `LaunchSplash`, `Logo`, `AngelAvatar`, `DevilAvatar`
and `WelcomeCharacters` images in `../ios/PipecatVoice/Assets.xcassets`. The exports are checked
in, so building needs no image tools. After changing the artwork, run:

```bash
uv run --no-project --with pillow --with numpy python src/branding/export.py
```
