"""Export the app icon and launch images from the artwork in this folder.

The icon is `app-icon.png` at 1024 px, opaque and square: iOS applies its mask. The launch
image keeps `splash.png` whole at each screen's width and extends its sky and embers above
and below (and, on iPad, its colours to either side), so no screen crops a wing or a tail.
iPhone images cover 440 x 956 pt, the largest iPhone, at 2x and 3x; the iPad image covers
1376 x 1376 pt, an iPad Pro 13-inch in either orientation, at 2x. iOS centres the launch
image without scaling it. The logo, which the launch intro shows, is `logo.png` trimmed to
its art, on a transparent ground, at 520 pt wide, 2x and 3x. The avatars, which name the angel
and the devil in a saved conversation, are the faces in `avatars.png`, each in a circle of its
ground with a gutter around it, at 34 pt, 2x and 3x. The characters who peek over the first
launch's welcome are `welcome.png` trimmed to its art, at 300 pt wide, 2x and 3x.

    uv run --no-project --with pillow --with numpy python src/branding/export.py
"""

from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw, ImageFilter, ImageOps

HERE = Path(__file__).resolve().parent
ASSETS = HERE.parent / "ios/PipecatVoice/Assets.xcassets"

# The faces in `avatars.png`: the angel's on the left half, the devil's on the right.
AVATARS = ("AngelAvatar", "DevilAvatar")
# How far the faces reach across their circles' radius: the rest is gutter, so no cheek
# touches the edge.
AVATAR_FILL = 0.82
AVATAR_POINTS = 34
WELCOME_POINTS = 300


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


def transparent(art: Image.Image) -> Image.Image:
    """`art` on a transparent ground. Art that is opaque throughout stands on white: the white
    reached from its edges becomes transparent, with a soft edge whose colour is unmixed from the
    white."""
    rgba = art.convert("RGBA")
    if rgba.getchannel("A").getextrema()[0] < 255:
        return rgba
    rgb = np.asarray(rgba.convert("RGB"), np.float32)
    # A copy: an image made from an array is read-only, and the flood fill writes to it.
    near_white = Image.fromarray(((rgb.min(axis=2) >= 232) * 255).astype(np.uint8)).copy()
    width, height = near_white.size
    for x, y in ((0, 0), (width - 1, 0), (0, height - 1), (width - 1, height - 1)):
        if near_white.getpixel((x, y)) == 255:
            ImageDraw.floodfill(near_white, (x, y), 128)
    ground = (np.asarray(near_white) == 128).astype(np.float32)
    blurred = Image.fromarray((ground * 255).astype(np.uint8)).filter(ImageFilter.GaussianBlur(1.2))
    alpha = 1 - np.asarray(blurred, np.float32) / 255
    # Where the edge is partly transparent, remove the white it was mixed with.
    a = np.clip(alpha, 1e-3, 1)[..., None]
    colour = np.clip((rgb - (1 - a) * 255) / a, 0, 255)
    pixels = np.dstack([colour, alpha[..., None] * 255]).astype(np.uint8)
    return Image.fromarray(pixels, "RGBA")


def circle(art: Image.Image, size: int) -> Image.Image:
    """`art`, a square, at `size` px and cropped to a circle, its edge drawn at 4x and reduced
    so it is smooth."""
    mask = Image.new("L", (size * 4, size * 4), 0)
    ImageDraw.Draw(mask).ellipse((0, 0, size * 4 - 1, size * 4 - 1), fill=255)
    image = art.convert("RGB").resize((size, size), Image.LANCZOS).convert("RGBA")
    image.putalpha(mask.resize((size, size), Image.LANCZOS))
    return image


def measure(half: Image.Image) -> tuple[tuple[int, ...], tuple[int, int], float]:
    """The face on `half`, a flat ground: the ground's colour, the centre of the face's bounds,
    and how far the face reaches from that centre."""
    a = np.asarray(half, np.float32)
    border = np.concatenate([a[0], a[-1], a[:, 0], a[:, -1]])
    ground = np.median(border, axis=0)
    ys, xs = np.nonzero(np.linalg.norm(a - ground, axis=2) > 40)
    x, y = round((xs.min() + xs.max()) / 2), round((ys.min() + ys.max()) / 2)
    return tuple(int(c) for c in ground), (x, y), float(np.hypot(xs - x, ys - y).max())


def avatars() -> None:
    art = Image.open(HERE / "avatars.png").convert("RGB")
    side, inset = art.width // 2, 4  # clear of the seam between the halves
    halves = [
        art.crop((i * side + inset, inset, (i + 1) * side - inset, art.height - inset))
        for i in range(2)
    ]
    faces = [measure(half) for half in halves]
    # One radius for both, so the faces keep their sizes; the grounds are padded out to it.
    radius = round(max(reach for _, _, reach in faces) / AVATAR_FILL)
    for name, half, (ground, (x, y), _) in zip(AVATARS, halves, faces):
        padded = ImageOps.expand(half, border=radius, fill=ground)
        face = padded.crop((x, y, x + 2 * radius, y + 2 * radius))
        images = ASSETS / f"{name}.imageset"
        for scale in (2, 3):
            circle(face, AVATAR_POINTS * scale).save(images / f"{name}@{scale}x.png", optimize=True)


def welcome() -> None:
    art = Image.open(HERE / "welcome.png").convert("RGBA")
    pixels = np.asarray(art, np.float32).copy()
    # Cut out a shade short of opaque, the art's alpha is stretched so its body is whole, and
    # the faint haze around it dropped.
    alpha = pixels[..., 3]
    solid = np.percentile(alpha[alpha > 128], 2)
    pixels[..., 3] = np.clip((alpha - 8) / (solid - 8) * 255, 0, 255)
    art = Image.fromarray(pixels.round().astype(np.uint8), "RGBA")
    art = art.crop(art.getchannel("A").getbbox())
    images = ASSETS / "WelcomeCharacters.imageset"
    for scale in (2, 3):
        width = WELCOME_POINTS * scale
        size = (width, round(art.height * width / art.width))
        art.resize(size, Image.LANCZOS).save(images / f"WelcomeCharacters@{scale}x.png", optimize=True)


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
    logo = transparent(Image.open(HERE / "logo.png"))
    logo = logo.crop(logo.getchannel("A").getbbox())
    images = ASSETS / "Logo.imageset"
    for scale in (2, 3):
        width = 520 * scale
        size = (width, round(logo.height * width / logo.width))
        logo.resize(size, Image.LANCZOS).save(images / f"Logo@{scale}x.png", optimize=True)
    avatars()
    welcome()


if __name__ == "__main__":
    main()
