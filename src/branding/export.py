"""Export the app icon and launch images from the artwork in this folder.

The icon is `app-icon.png` at 1024 px, opaque and square: iOS applies its mask. The launch
image keeps `splash.png` whole at each screen's width and extends its sky and embers above
and below (and, on iPad, its colours to either side), so no screen crops a wing or a tail.
iPhone images cover 440 x 956 pt, the largest iPhone, at 2x and 3x; the iPad image covers
1376 x 1376 pt, an iPad Pro 13-inch in either orientation, at 2x. iOS centres the launch
image without scaling it.

    uv run --no-project --with pillow --with numpy python src/branding/export.py
"""

from pathlib import Path

import numpy as np
from PIL import Image, ImageFilter

HERE = Path(__file__).resolve().parent
ASSETS = HERE.parent / "ios/PipecatVoice/Assets.xcassets"


def save(image: Image.Image, path: Path, profile: bytes | None) -> None:
    image.convert("RGB").save(path, icc_profile=profile, optimize=True)


def extend(art: Image.Image, size: tuple[int, int], box: tuple[int, int, int, int]) -> Image.Image:
    """`art` scaled into `box` (x, y, width, height) on a canvas of `size`, the rest filled
    with its edge colours, softened, and the art eased into that fill at its edges."""
    width, height = size
    x0, y0, w, h = box
    a = np.asarray(art.resize((w, h), Image.LANCZOS), np.float32)
    canvas = np.zeros((height, width, 3), np.float32)
    canvas[y0 : y0 + h, x0 : x0 + w] = a
    band = 24
    # Above and below: each column's edge colour, carried out to the canvas edge.
    canvas[:y0, x0 : x0 + w] = a[:band].mean(axis=0)
    canvas[y0 + h :, x0 : x0 + w] = a[-band:].mean(axis=0)
    if x0 > 0:
        # Either side: each edge's colour down the canvas, smoothed into a soft vertical
        # gradient, since carrying the clouds sideways would leave bands.
        sigma = height / 14
        offsets = np.arange(-3 * int(sigma), 3 * int(sigma) + 1)
        kernel = np.exp(-0.5 * (offsets / sigma) ** 2)
        kernel /= kernel.sum()
        edges = (
            (slice(x0, x0 + band), slice(0, x0)),
            (slice(x0 + w - band, x0 + w), slice(x0 + w, width)),
        )
        for source, target in edges:
            profile = canvas[:, source].mean(axis=1)
            padded = np.pad(profile, ((len(offsets) // 2, len(offsets) // 2), (0, 0)), mode="edge")
            smooth = np.stack(
                [np.convolve(padded[:, c], kernel, mode="valid") for c in range(3)], axis=1
            )
            canvas[:, target] = smooth[:, None, :]
    filled = Image.fromarray(canvas.clip(0, 255).astype(np.uint8))
    soft = np.asarray(filled.filter(ImageFilter.GaussianBlur(max(width, height) / 40)), np.float32)
    # The art stays sharp inside a smoothstep ramp from each extended edge.
    ys, xs = np.mgrid[0:height, 0:width]
    ramp = np.ones((height, width), np.float32)
    if y0 > 0:
        ramp = np.minimum(ramp, np.minimum(ys - y0, y0 + h - 1 - ys) / max(8, h // 12))
    if x0 > 0:
        ramp = np.minimum(ramp, np.minimum(xs - x0, x0 + w - 1 - xs) / max(8, w // 6))
    ramp = np.clip(ramp, 0, 1)
    mask = (ramp * ramp * (3 - 2 * ramp))[..., None]
    return Image.fromarray((soft * (1 - mask) + canvas * mask).clip(0, 255).astype(np.uint8))


def main() -> None:
    icon = Image.open(HERE / "app-icon.png")
    save(
        icon.convert("RGB").resize((1024, 1024), Image.LANCZOS),
        ASSETS / "AppIcon.appiconset/AppIcon.png",
        icon.info.get("icc_profile"),
    )
    splash = Image.open(HERE / "splash.png")
    profile = splash.info.get("icc_profile")
    art = splash.convert("RGB")
    launch = ASSETS / "LaunchSplash.imageset"
    for scale in (2, 3):
        width, height = 440 * scale, 956 * scale
        h = round(art.height * width / art.width)
        image = extend(art, (width, height), (0, (height - h) // 2, width, h))
        save(image, launch / f"LaunchSplash-iPhone@{scale}x.png", profile)
    side, h = 1376 * 2, 1032 * 2  # fits the shorter side of a landscape iPad Pro 13-inch
    w = round(art.width * h / art.height)
    image = extend(art, (side, side), ((side - w) // 2, (side - h) // 2, w, h))
    save(image, launch / "LaunchSplash-iPad@2x.png", profile)


if __name__ == "__main__":
    main()
