"""Draws Silverbath's app icon (Latent/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png, and the
180 px Mark.imageset/Mark.png).

A drop falling into a silver bath: the surface of liquid metal at a low angle, rings spreading
from where the last drop landed, and the next one falling, catching a warm glint of light.
Original work; run `python3 icon.py` here (needs Pillow).
"""
import math

from PIL import Image, ImageChops, ImageDraw, ImageFilter

S = 1024
K = 4  # drawn this many times larger, then scaled down, for smooth edges
W = S * K


def lerp(a, b, t):
    t = max(0.0, min(1.0, t))
    return tuple(int(a[i] + (b[i] - a[i]) * t) for i in range(len(a)))


def radial(size, centre, radius, inner, outer, power=1.0):
    """A radial gradient from `inner` at `centre` to `outer` at `radius` and beyond."""
    img = Image.new("RGB", (size, size))
    px = img.load()
    cx, cy = centre
    for y in range(size):
        for x in range(size):
            t = math.hypot(x - cx, y - cy) / radius
            px[x, y] = lerp(inner, outer, t ** power)
    return img


def main():
    small = 256
    # the whole icon is the bath's surface: liquid silver, lit from the top left
    surface = radial(small, (small * 0.2, small * 0.05), small * 1.25, (236, 238, 242), (38, 40, 46), 1.15)
    img = surface.resize((W, W), Image.BICUBIC).convert("RGBA")
    # a warm light reflected across the top of the surface
    warm = Image.new("RGBA", (W, W), (0, 0, 0, 0))
    ImageDraw.Draw(warm).ellipse([-W * 0.25, -W * 0.45, W * 0.75, W * 0.18], fill=(255, 196, 120, 70))
    img = Image.alpha_composite(img, warm.filter(ImageFilter.GaussianBlur(W // 12)))

    # rings spreading from where the drop landed, seen at a low angle: a dark trough under a
    # bright crest, fading as they spread
    cx, cy = W // 2, int(W * 0.66)
    rings = Image.new("RGBA", (W, W), (0, 0, 0, 0))
    rd = ImageDraw.Draw(rings)
    for i, r in enumerate([0.08, 0.17, 0.28, 0.41, 0.56]):
        rr = int(W * r)
        fade = 1.0 - i * 0.17
        squash = 0.42
        off = W * 0.006
        rd.ellipse([cx - rr, cy - rr * squash + off, cx + rr, cy + rr * squash + off], outline=(20, 22, 28, int(170 * fade)), width=W // 70)
        rd.ellipse([cx - rr, cy - rr * squash - off, cx + rr, cy + rr * squash - off], outline=(255, 255, 255, int(210 * fade)), width=W // 160)
    img = Image.alpha_composite(img, rings.filter(ImageFilter.GaussianBlur(W // 300)))

    # the drop, falling towards the rings' centre: dark silver with a bright streak and a warm
    # glint at its lower edge
    dw = int(W * 0.095)
    dx, dy = cx, int(W * 0.27)
    drop_mask = Image.new("L", (W, W), 0)
    dm = ImageDraw.Draw(drop_mask)
    dm.ellipse([dx - dw, dy, dx + dw, dy + 2 * dw], fill=255)
    dm.polygon([(dx, dy - dw * 1.25), (dx - dw * 0.93, dy + dw * 0.72), (dx + dw * 0.93, dy + dw * 0.72)], fill=255)
    drop_mask = drop_mask.filter(ImageFilter.GaussianBlur(K))
    fill = radial(small, (small * 0.47, small * 0.33), small * 0.17, (170, 176, 188), (30, 32, 38), 0.9)
    fill = fill.resize((W, W), Image.BICUBIC).convert("RGBA")
    fill.putalpha(drop_mask)
    shadow = Image.new("RGBA", (W, W), (0, 0, 0, 0))
    ImageDraw.Draw(shadow).ellipse([cx - dw * 0.9, cy - dw * 0.25, cx + dw * 0.9, cy + dw * 0.25], fill=(0, 0, 0, 120))
    img = Image.alpha_composite(img, shadow.filter(ImageFilter.GaussianBlur(W // 60)))
    img = Image.alpha_composite(img, fill)
    shine = Image.new("RGBA", (W, W), (0, 0, 0, 0))
    sd = ImageDraw.Draw(shine)
    sd.arc([dx - dw * 0.72, dy + dw * 0.2, dx + dw * 0.72, dy + dw * 1.64], 165, 245, fill=(255, 255, 255, 230), width=W // 90)
    sd.arc([dx - dw * 0.8, dy + dw * 0.12, dx + dw * 0.8, dy + dw * 1.8], 20, 80, fill=(255, 200, 130, 220), width=W // 120)
    shine = shine.filter(ImageFilter.GaussianBlur(W // 500))
    shine.putalpha(ImageChops.multiply(shine.getchannel("A"), drop_mask))
    img = Image.alpha_composite(img, shine)

    out = img.convert("RGB").resize((S, S), Image.LANCZOS)
    out.save("Latent/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png")
    out.resize((180, 180), Image.LANCZOS).save("Latent/Assets.xcassets/Mark.imageset/Mark.png")


if __name__ == "__main__":
    main()
