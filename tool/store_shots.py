"""Store screenshots: made-up photos for the demo profile, and the frames.

    python tool/store_shots.py images            # app/test/fixtures/store/*.jpg
    python tool/store_shots.py frame <raw dir>   # store/screenshots{,-windows}

The raw screens come from app/test/store_shots_test.dart:

    cd app
    flutter test test/store_shots_test.dart --dart-define=STORE_SHOTS=<raw dir>

It writes <raw dir>/desktop/*.png and <raw dir>/phone/*.png; `frame` puts
each in a window or phone with its caption, at 1920x1080 for the Microsoft
Store and 1080x1920 for Google Play. Needs Pillow.
"""

import math
import random
import sys
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter, ImageFont

ROOT = Path(__file__).resolve().parent.parent
FIXTURES = ROOT / "app" / "test" / "fixtures" / "store"

# Shot name -> caption, in listing order.
CAPTIONS = {
    "chat": "Group chats with nobody in the middle",
    "call": "Call friends device to device",
    "forums": "Forums for your groups",
    "calendar": "Calendars you share",
    "maps": "See friends who share where they are",
    "files": "Share files straight to friends",
    "plugins": "Add apps and games as plugins",
    "notes": "Notes that stay yours",
}

BACKGROUND = (232, 243, 240)
ACCENT = (19, 98, 89)
FRAME = (19, 125, 114)


def font(size, bold=False):
    for name in (["segoeuib.ttf", "arialbd.ttf"] if bold else ["segoeui.ttf", "arial.ttf"]):
        try:
            return ImageFont.truetype(f"C:/Windows/Fonts/{name}", size)
        except OSError:
            pass
    return ImageFont.load_default(size)


# Photos ---------------------------------------------------------------------


def _lerp(a, b, t):
    return tuple(round(x + (y - x) * t) for x, y in zip(a, b))


def _sky(img, top, bottom):
    d = ImageDraw.Draw(img)
    w, h = img.size
    for y in range(h):
        d.line([(0, y), (w, y)], fill=_lerp(top, bottom, y / h))


def _ridge(img, rnd, base, rough, colour, seed_scale=1.0):
    w, h = img.size
    d = ImageDraw.Draw(img)
    points = [(0, h)]
    phase = [rnd.random() * 6 for _ in range(3)]
    for x in range(0, w + 8, 8):
        y = base
        for i, p in enumerate(phase):
            f = (i + 1) * 0.004 * seed_scale
            y += math.sin(x * f * (1 + i) + p) * rough / (i + 1)
        y += rnd.uniform(-rough * 0.05, rough * 0.05)
        points.append((x, y))
    points.append((w, h))
    d.polygon(points, fill=colour)


def landscape(path, seed, sky, ridges, sun=None, size=(1200, 800)):
    rnd = random.Random(seed)
    img = Image.new("RGB", size)
    _sky(img, *sky)
    if sun:
        (sx, sy, r, colour) = sun
        glow = Image.new("RGBA", size, (0, 0, 0, 0))
        ImageDraw.Draw(glow).ellipse((sx - r * 3, sy - r * 3, sx + r * 3, sy + r * 3), fill=colour + (70,))
        img.paste(glow.filter(ImageFilter.GaussianBlur(r)), (0, 0), glow.filter(ImageFilter.GaussianBlur(r)))
        ImageDraw.Draw(img).ellipse((sx - r, sy - r, sx + r, sy + r), fill=colour)
    for base, rough, colour in ridges:
        _ridge(img, rnd, base * size[1], rough, colour)
    img = img.filter(ImageFilter.GaussianBlur(0.8))
    img.save(path, quality=86)


def images():
    FIXTURES.mkdir(parents=True, exist_ok=True)
    landscape(
        FIXTURES / "edale-ridge.jpg",
        3,
        ((120, 170, 220), (238, 214, 180)),
        [
            (0.52, 60, (122, 138, 160)),
            (0.62, 70, (88, 116, 92)),
            (0.74, 50, (64, 96, 62)),
            (0.86, 30, (44, 70, 44)),
        ],
        sun=(860, 230, 46, (255, 236, 190)),
    )
    landscape(
        FIXTURES / "sunset-crag.jpg",
        11,
        ((60, 52, 110), (246, 152, 96)),
        [
            (0.58, 80, (96, 70, 104)),
            (0.70, 60, (70, 50, 80)),
            (0.84, 40, (40, 30, 52)),
        ],
        sun=(380, 470, 60, (255, 200, 120)),
    )
    landscape(
        FIXTURES / "lake-morning.jpg",
        21,
        ((168, 204, 230), (226, 236, 240)),
        [
            (0.50, 40, (150, 170, 190)),
            (0.58, 50, (108, 140, 128)),
            (0.80, 6, (120, 160, 190)),
            (0.92, 20, (60, 90, 70)),
        ],
    )
    for p in sorted(FIXTURES.glob("*.jpg")):
        print(p.relative_to(ROOT), p.stat().st_size)


# Frames ---------------------------------------------------------------------


def _shadow(canvas, box, radius, blur=24, offset=10):
    shadow = Image.new("RGBA", canvas.size, (0, 0, 0, 0))
    x0, y0, x1, y1 = box
    ImageDraw.Draw(shadow).rounded_rectangle((x0, y0 + offset, x1, y1 + offset), radius, fill=(0, 40, 35, 70))
    canvas.alpha_composite(shadow.filter(ImageFilter.GaussianBlur(blur)))


def _rounded(img, radius):
    mask = Image.new("L", img.size, 0)
    ImageDraw.Draw(mask).rounded_rectangle((0, 0, img.width - 1, img.height - 1), radius, fill=255)
    out = Image.new("RGBA", img.size, (0, 0, 0, 0))
    out.paste(img, (0, 0), mask)
    return out


def _caption(canvas, text, centre_y, size):
    d = ImageDraw.Draw(canvas)
    f = font(size, bold=True)
    while d.textlength(text, font=f) > canvas.width - 120:
        size -= 4
        f = font(size, bold=True)
    d.text((canvas.width / 2, centre_y), text, font=f, fill=ACCENT, anchor="mm")


def desktop(raw, caption):
    canvas = Image.new("RGBA", (1920, 1080), BACKGROUND + (255,))
    _caption(canvas, caption, 78, 72)
    screen = raw.convert("RGBA")
    bar = 32
    w, h = screen.width, screen.height + bar
    x0, y0 = (1920 - w) // 2, 1080 - h - 30
    _shadow(canvas, (x0, y0, x0 + w, y0 + h), 12)
    window = Image.new("RGBA", (w, h), (32, 32, 32, 255))
    d = ImageDraw.Draw(window)
    # Title bar: icon, name, and the three window buttons.
    d.ellipse((14, 9, 28, 23), fill=(64, 196, 180))
    d.text((38, bar / 2), "OurNet", font=font(15), fill=(235, 235, 235), anchor="lm")
    # Close, maximise and minimise, from the right, as Windows 11 draws them.
    grey = (220, 220, 220)
    cx, cy = w - 23, bar // 2
    d.line((cx - 5, cy - 5, cx + 5, cy + 5), fill=grey)
    d.line((cx - 5, cy + 5, cx + 5, cy - 5), fill=grey)
    cx -= 46
    d.rounded_rectangle((cx - 5, cy - 5, cx + 5, cy + 5), 1, outline=grey)
    cx -= 46
    d.line((cx - 5, cy, cx + 5, cy), fill=grey)
    window.paste(screen, (0, bar))
    canvas.alpha_composite(_rounded(window, 10), (x0, y0))
    return canvas.convert("RGB")


def phone(raw, caption):
    canvas = Image.new("RGBA", (1080, 1920), BACKGROUND + (255,))
    status = 56
    screen = Image.new("RGBA", (raw.width, raw.height + status), (0, 0, 0, 0))
    screen.paste(raw.convert("RGBA"), (0, status))
    # The status bar takes the app's top colour.
    top = raw.convert("RGB").getpixel((raw.width // 2, 2))
    d = ImageDraw.Draw(screen)
    d.rectangle((0, 0, raw.width, status), fill=top)
    d.text((40, status / 2 + 4), "9:30", font=font(26), fill=(40, 40, 40), anchor="lm")
    # Wifi wedge and battery.
    bx = raw.width - 44
    d.rounded_rectangle((bx, 18, bx + 16, 42), 3, fill=(40, 40, 40))
    d.pieslice((bx - 46, 12, bx - 10, 48), 225, 315, fill=(40, 40, 40))
    bezel = 16
    w, h = screen.width + bezel * 2, screen.height + bezel * 2
    x0, y0 = (1080 - w) // 2, 1920 - h - 40
    _caption(canvas, caption, y0 // 2, 64)
    _shadow(canvas, (x0, y0, x0 + w, y0 + h), 64)
    body = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    ImageDraw.Draw(body).rounded_rectangle((0, 0, w - 1, h - 1), 64, fill=FRAME)
    body.alpha_composite(_rounded(screen, 50), (bezel, bezel))
    canvas.alpha_composite(body, (x0, y0))
    return canvas.convert("RGB")


def frame(raw_dir):
    raw_dir = Path(raw_dir)
    targets = [
        ("desktop", ROOT / "store" / "screenshots-windows", desktop),
        ("phone", ROOT / "store" / "screenshots", phone),
    ]
    for form, out, make in targets:
        out.mkdir(parents=True, exist_ok=True)
        for old in out.glob("*.png"):
            old.unlink()
        n = 0
        for name, caption in CAPTIONS.items():
            source = raw_dir / form / f"{name}.png"
            if not source.exists():
                print("missing", source)
                continue
            n += 1
            target = out / f"{n:02d}-{name}.png"
            make(Image.open(source), caption).save(target, optimize=True)
            print(target.relative_to(ROOT))


if __name__ == "__main__":
    if sys.argv[1:2] == ["images"]:
        images()
    elif sys.argv[1:2] == ["frame"] and len(sys.argv) == 3:
        frame(sys.argv[2])
    else:
        print(__doc__)
        sys.exit(2)
