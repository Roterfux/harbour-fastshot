"""Render the launcher icon at the Sailfish sizes (needs Pillow; development only).

    python3 tools/make_icons.py
"""
import os

from PIL import Image, ImageDraw

SIZES = (86, 108, 128, 172)
BIG = 1024


def render():
    img = Image.new("RGBA", (BIG, BIG), (0, 0, 0, 0))
    bg = Image.new("RGB", (BIG, BIG))
    px = bg.load()
    for y in range(BIG):
        for x in range(BIG):
            t = (x * 0.4 + y * 0.6) / BIG
            px[x, y] = (int(0x24 + (0x10 - 0x24) * t), int(0x3B + (0x1A - 0x3B) * t), int(0x55 + (0x2E - 0x55) * t))
    mask = Image.new("L", (BIG, BIG), 0)
    ImageDraw.Draw(mask).rounded_rectangle((0, 0, BIG - 1, BIG - 1), radius=230, fill=255)
    img.paste(bg, (0, 0), mask)
    d = ImageDraw.Draw(img)
    c = BIG // 2 + 30
    d.ellipse((c - 300, c - 300, c + 300, c + 300), fill=(255, 255, 255, 255))          # lens body
    d.ellipse((c - 225, c - 225, c + 225, c + 225), fill=(0x1A, 0x22, 0x30, 255))       # lens
    d.ellipse((c - 120, c - 120, c + 120, c + 120), fill=(0x2F, 0x6B, 0xF2, 255))       # glass
    d.ellipse((c - 95, c - 110, c - 25, c - 40), fill=(255, 255, 255, 200))             # reflection
    # speed bolt (top right): fast + enhanced
    d.polygon([(800, 90), (650, 330), (745, 330), (690, 520), (880, 250), (775, 250), (850, 90)],
              fill=(0xFF, 0xC2, 0x3D, 255))
    return img


if __name__ == "__main__":
    big = render()
    root = os.path.join(os.path.dirname(__file__), "..", "icons")
    for s in SIZES:
        folder = os.path.join(root, "%dx%d" % (s, s))
        os.makedirs(folder, exist_ok=True)
        big.resize((s, s), Image.LANCZOS).save(os.path.join(folder, "harbour-fastshot.png"))
        print("wrote %dx%d" % (s, s))
