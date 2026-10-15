# Artwork

- `app-icon.png`: the app icon, the angel and the devil on a split yellow and red ground.
  Square, opaque and without rounded corners: iOS applies the icon mask.
- `splash.png`: the launch screen's art, the angel above the clouds and the devil in the
  embers below.
- `logo.png`: the Little Voices logo, which drops in over the launch intro. On a transparent
  ground, or on white, which the export makes transparent.

`export.py` turns them into the images in `../ios/PipecatVoice/Assets.xcassets`: the
1024 × 1024 `AppIcon`, the `LaunchSplash` images, which keep the art whole at each screen's
width and extend its sky and embers so every iPhone and iPad screen is covered, and the
`Logo`, trimmed to its art at 520 pt wide.
The exports are checked in, so building the app needs no image tools. After changing the
artwork, run:

```bash
uv run --no-project --with pillow --with numpy python src/branding/export.py
```
