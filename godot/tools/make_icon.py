"""Draws the Pirates Plunder app icon: a treasure chest spilling gold on a
little island, a pirate flag flying over it, on a sea-blue rounded square.

    python3 tools/make_icon.py      (from the godot/ folder)

Writes icon.png (1024 px, used for the window and the Mac app) and icon.ico
(16-256 px, for the Windows .exe). Everything is drawn at 2x and scaled down
for smooth edges.

Also the icons a phone puts on its home screen when the web version is saved
there (in web_shell/, which tools/package.sh copies beside the page). Those
must be square and solid: an iPhone fills anything see-through with black
and rounds the corners itself, and Android cuts its own shape out of them.
  apple-touch-icon.png            180 px, the iPhone and iPad
  icon-192.png, icon-512.png      Android (the web manifest), full square
  icon-maskable-512.png           Android's shapes: the picture within the
                                  middle 80%, which any shape keeps
"""
from PIL import Image, ImageDraw, ImageFilter

S = 2048          # working size; the final icon is half this
M = 100 * 2       # margin around the rounded square, as macOS icons have


def lerp(a, b, t):
    return tuple(round(x + (y - x) * t) for x, y in zip(a, b))


def sea_gradient(top: int = 0, bottom: int = S) -> Image.Image:
    """The sea, shading from light to deep blue between rows top and bottom."""
    sea = Image.new("RGBA", (S, S))
    sd = ImageDraw.Draw(sea)
    for y in range(S):
        t = min(max((y - top) / (bottom - top), 0.0), 1.0)
        sd.line([(0, y), (S, y)], fill=lerp((54, 140, 190), (14, 48, 82), t) + (255,))
    return sea


def main() -> None:
    img = Image.new("RGBA", (S, S), (0, 0, 0, 0))

    # Sea: a rounded square shading from light to deep blue.
    sea = sea_gradient()
    mask = Image.new("L", (S, S), 0)
    ImageDraw.Draw(mask).rounded_rectangle([M, M, S - M, S - M], radius=360, fill=255)
    img.paste(sea, (0, 0), mask)
    draw_picture(img)

    final = img.resize((1024, 1024), Image.LANCZOS)
    final.save("icon.png")
    final.save("icon.ico", sizes=[(16, 16), (24, 24), (32, 32), (48, 48), (64, 64), (128, 128), (256, 256)])
    print("wrote icon.png and icon.ico")
    web_icons()


def web_icons() -> None:
    """The home-screen icons: the same picture on a sea that fills the square."""
    picture = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    draw_picture(picture)
    # Full square: the Mac icon's rounded square, corners filled in.
    full = sea_gradient(M, S - M)
    full.alpha_composite(picture)
    full = full.crop((M, M, S - M, S - M)).convert("RGB")
    full.resize((180, 180), Image.LANCZOS).save("web_shell/apple-touch-icon.png")
    full.resize((192, 192), Image.LANCZOS).save("web_shell/icon-192.png")
    full.resize((512, 512), Image.LANCZOS).save("web_shell/icon-512.png")
    # Maskable: the picture shrunk into the middle 80% of a whole sea.
    inner = round((S - 2 * M) * 0.8)
    small = picture.crop((M, M, S - M, S - M)).resize((inner, inner), Image.LANCZOS)
    mask_icon = sea_gradient()
    mask_icon.alpha_composite(small, ((S - inner) // 2, (S - inner) // 2))
    mask_icon.convert("RGB").resize((512, 512), Image.LANCZOS).save("web_shell/icon-maskable-512.png")
    print("wrote web_shell/apple-touch-icon.png, icon-192.png, icon-512.png, icon-maskable-512.png")


def draw_picture(img: Image.Image) -> None:
    """Everything on the sea: waves, island, flag, chest and gold."""
    d = ImageDraw.Draw(img)

    # Gentle wave lines.
    for x0, y in [(1380, 470), (1560, 600), (380, 1700), (680, 1820)]:
        d.arc([x0, y - 40, x0 + 260, y + 40], 200, 340, fill=(160, 210, 235, 150), width=18)

    # The island: a sandy shore with a meadow on top.
    d.ellipse([360, 1180, 1688, 1720], fill=(222, 196, 128, 255))
    d.ellipse([470, 1150, 1578, 1560], fill=(98, 160, 70, 255))
    d.ellipse([560, 1180, 1490, 1480], fill=(120, 182, 82, 255))

    # Flag: mast, black flag, white skull with crossbones.
    d.rectangle([520, 520, 556, 1330], fill=(58, 40, 26, 255))
    d.polygon([(556, 540), (960, 600), (556, 860)], fill=(22, 20, 24, 255))
    d.ellipse([650, 600, 790, 730], fill=(240, 234, 220, 255))          # skull
    d.rectangle([680, 700, 760, 760], fill=(240, 234, 220, 255))        # jaw
    d.ellipse([675, 640, 712, 680], fill=(22, 20, 24, 255))             # eyes
    d.ellipse([728, 640, 765, 680], fill=(22, 20, 24, 255))
    for a, b in [((630, 770), (810, 830)), ((630, 830), (810, 770))]:   # crossbones
        d.line([a, b], fill=(240, 234, 220, 255), width=26)

    # Glow behind the chest.
    glow = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    ImageDraw.Draw(glow).ellipse([700, 640, 1540, 1320], fill=(255, 214, 90, 150))
    img.alpha_composite(glow.filter(ImageFilter.GaussianBlur(90)))
    d = ImageDraw.Draw(img)

    # The chest: body, open lid, iron bands, lock, gold piled inside.
    body = [760, 1040, 1420, 1380]
    d.rounded_rectangle(body, radius=30, fill=(132, 74, 34, 255), outline=(70, 38, 16, 255), width=18)
    d.rectangle([760, 1150, 1420, 1190], fill=(196, 150, 60, 255))     # band
    d.rectangle([900, 1040, 950, 1380], fill=(196, 150, 60, 255))
    d.rectangle([1230, 1040, 1280, 1380], fill=(196, 150, 60, 255))
    d.rounded_rectangle([1050, 1130, 1130, 1230], radius=14, fill=(230, 190, 80, 255), outline=(90, 60, 20, 255), width=8)
    d.polygon([(760, 1040), (800, 800), (1380, 800), (1420, 1040)], fill=(110, 60, 26, 255), outline=(70, 38, 16, 255))
    d.polygon([(800, 800), (1380, 800), (1350, 860), (830, 860)], fill=(150, 88, 40, 255))
    # Gold coins heaped in the chest and spilling over the front.
    coins = [(840, 1000), (930, 960), (1030, 940), (1130, 950), (1230, 970), (1330, 1000),
             (890, 1020), (990, 1000), (1090, 990), (1190, 1005), (1290, 1025),
             (980, 1430), (1090, 1460), (1200, 1425), (1310, 1470), (870, 1470)]
    for x, y in coins:
        d.ellipse([x - 52, y - 30, x + 52, y + 30], fill=(250, 206, 70, 255), outline=(176, 128, 30, 255), width=8)
        d.ellipse([x - 26, y - 14, x + 10, y + 2], fill=(255, 238, 160, 255))
    # A red gem for sparkle.
    d.polygon([(1180, 890), (1220, 860), (1260, 890), (1220, 950)], fill=(220, 40, 60, 255), outline=(120, 10, 30, 255))


if __name__ == "__main__":
    main()
