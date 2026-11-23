"""Draws Latent's app icon (Latent/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png).

Three frames stepping forward from faint to bright, like an image coming up in the developer, with a
warm safelight glow in the front one. Original work; run `python3 icon.py` here (needs Pillow).
"""
from PIL import Image, ImageChops, ImageDraw

S = 1024


def lerp(a, b, t):
    return tuple(int(a[i] + (b[i] - a[i]) * t) for i in range(3))


def main():
    bg = Image.new("RGB", (S, S))
    d = ImageDraw.Draw(bg)
    for y in range(S):
        d.line([(0, y), (S, y)], fill=lerp((24, 24, 28), (8, 8, 10), y / S))
    img = bg.convert("RGBA")
    size, step = 440, 56
    x0 = (S - (size + 2 * step)) // 2
    for i, (x, alpha) in enumerate([(x0, 0.16), (x0 + step, 0.40), (x0 + 2 * step, 1.0)]):
        box = [x, x, x + size, x + size]
        if i == 2:
            glow = Image.new("RGBA", (S, S), (0, 0, 0, 0))
            gd = ImageDraw.Draw(glow)
            cx, cy = box[0] + size * 0.6, box[1] + size * 0.6
            for r in range(330, 0, -3):
                t = r / 330
                gd.ellipse([cx - r, cy - r, cx + r, cy + r], fill=lerp((255, 206, 128), (200, 80, 30), t) + (int(255 * (1 - t) ** 1.25),))
            mask = Image.new("L", (S, S), 0)
            ImageDraw.Draw(mask).rounded_rectangle(box, radius=52, fill=255)
            glow.putalpha(ImageChops.multiply(glow.getchannel("A"), mask))
            img = Image.alpha_composite(img, glow)
        layer = Image.new("RGBA", (S, S), (0, 0, 0, 0))
        ImageDraw.Draw(layer).rounded_rectangle(box, radius=52, outline=(242, 242, 242, int(255 * alpha)), width=22)
        img = Image.alpha_composite(img, layer)
    img.convert("RGB").save("Latent/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png")


if __name__ == "__main__":
    main()
