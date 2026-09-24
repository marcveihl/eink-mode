"""Write eink.ico, the shortcut icon. Regenerate after changing the tray glyph.

    .venv\\Scripts\\python.exe make_icon.py

The tray glyph itself is drawn at runtime by `create_icon_image` so it can flip
between the ring and the disc and follow the taskbar theme. A shortcut cannot do
that, so this is the fixed form: the ink disc on a paper tile, using the PRD
section 9.4 palette, which reads on a light or a dark Start Menu alike.
"""

from pathlib import Path

from PIL import Image, ImageDraw

PAPER = (244, 241, 232, 255)   # PRD 9.4 "Paper"  #F4F1E8
INK = (24, 24, 23, 255)        # PRD 9.4 "Ink"    #181817
SIZES = [(16, 16), (24, 24), (32, 32), (48, 48), (64, 64), (128, 128), (256, 256)]
OUT = Path(__file__).resolve().parent / "eink.ico"


def tile(size=256):
    """A rounded paper tile with the ink disc centred on it."""
    image = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    draw = ImageDraw.Draw(image)
    pad = size * 0.02
    draw.rounded_rectangle((pad, pad, size - pad, size - pad),
                           radius=size * 0.22, fill=PAPER)
    inset = size * 0.26
    draw.ellipse((inset, inset, size - inset, size - inset), fill=INK)
    return image


def main():
    tile().save(OUT, format="ICO", sizes=SIZES)
    print(f"wrote {OUT} ({', '.join(f'{w}x{h}' for w, h in SIZES)})")


if __name__ == "__main__":
    main()
