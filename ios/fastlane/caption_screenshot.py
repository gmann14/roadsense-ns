"""Frame a 1320x2868 simulator capture with a caption for the App Store.

Usage: python3 -I ios/fastlane/caption_screenshot.py raw.png "Caption" out.png
See docs/app-store-submission.md, "Screenshots".
"""
import sys
from PIL import Image, ImageDraw, ImageFont, ImageFilter

W, H = 1320, 2868
BG_TOP, BG_BOTTOM = (11, 41, 54), (16, 62, 78)
FONT = "/System/Library/Fonts/HelveticaNeue.ttc"

def gradient():
    img = Image.new("RGB", (W, H))
    d = ImageDraw.Draw(img)
    for y in range(H):
        t = y / (H - 1)
        d.line([(0, y), (W, y)], fill=tuple(round(a + (b - a) * t) for a, b in zip(BG_TOP, BG_BOTTOM)))
    return img

def wrap(draw, text, font, max_w):
    words, lines, line = text.split(), [], ""
    for w in words:
        trial = (line + " " + w).strip()
        if draw.textlength(trial, font=font) <= max_w:
            line = trial
        else:
            lines.append(line); line = w
    lines.append(line)
    return lines

def make(src, caption, out):
    canvas = gradient()
    d = ImageDraw.Draw(canvas)
    font = ImageFont.truetype(FONT, 104, index=1)  # Helvetica Neue Bold
    lines = wrap(d, caption, font, W - 200)
    y = 190
    for ln in lines:
        w = d.textlength(ln, font=font)
        d.text(((W - w) / 2, y), ln, font=font, fill=(255, 255, 255))
        y += 126
    shot = Image.open(src).convert("RGB")
    top = y + 90
    scale = (H - top - 40) / shot.height
    sw, sh = round(shot.width * scale), round(shot.height * scale)
    shot = shot.resize((sw, sh), Image.LANCZOS)
    radius = 90
    mask = Image.new("L", (sw, sh), 0)
    ImageDraw.Draw(mask).rounded_rectangle([0, 0, sw - 1, sh - 1], radius=radius, fill=255)
    x = (W - sw) // 2
    shadow = Image.new("L", (W, H), 0)
    ImageDraw.Draw(shadow).rounded_rectangle([x, top + 20, x + sw, top + sh + 20], radius=radius, fill=150)
    shadow = shadow.filter(ImageFilter.GaussianBlur(40))
    canvas.paste((0, 0, 0), (0, 0), shadow)
    canvas.paste(shot, (x, top), mask)
    canvas.save(out, "PNG")
    print(out, canvas.size)

if __name__ == "__main__":
    make(sys.argv[1], sys.argv[2], sys.argv[3])
