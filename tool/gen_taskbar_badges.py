from PIL import Image, ImageDraw, ImageFont
import os
import struct

out = os.path.join(os.path.dirname(__file__), "..", "assets", "badges")
os.makedirs(out, exist_ok=True)


def render(text, s):
    img = Image.new("RGBA", (s, s), (0, 0, 0, 0))
    draw = ImageDraw.Draw(img)
    margin = max(1, s // 16)
    draw.ellipse(
        [margin, margin, s - 1 - margin, s - 1 - margin],
        fill=(220, 38, 38, 255),
    )
    font_size = max(8, int(s * (0.55 if len(text) == 1 else 0.40)))
    try:
        font = ImageFont.truetype("C:/Windows/Fonts/arialbd.ttf", font_size)
    except Exception:
        font = ImageFont.load_default()
    bbox = draw.textbbox((0, 0), text, font=font)
    tw, th = bbox[2] - bbox[0], bbox[3] - bbox[1]
    x = (s - tw) / 2 - bbox[0]
    y = (s - th) / 2 - bbox[1] - max(0, s // 32)
    draw.text((x, y), text, fill=(255, 255, 255, 255), font=font)
    return img


def png_bytes(img):
    import io

    buf = io.BytesIO()
    img.save(buf, format="PNG")
    return buf.getvalue()


def write_ico(path, images):
    # Manual multi-size ICO writer (PNG-compressed entries)
    count = len(images)
    # ICONDIR + ICONDIRENTRY * count
    offset = 6 + 16 * count
    entries = []
    data_blobs = []
    for img in images:
        blob = png_bytes(img)
        w = 0 if img.width >= 256 else img.width
        h = 0 if img.height >= 256 else img.height
        entries.append((w, h, len(blob), offset))
        data_blobs.append(blob)
        offset += len(blob)

    with open(path, "wb") as f:
        f.write(struct.pack("<HHH", 0, 1, count))
        for w, h, size, off in entries:
            f.write(struct.pack("<BBBBHHII", w, h, 0, 0, 1, 32, size, off))
        for blob in data_blobs:
            f.write(blob)
    print("wrote", path, os.path.getsize(path))


def make_badge(text, filename):
    sizes = [16, 32, 48, 64]
    images = [render(text, s) for s in sizes]
    write_ico(os.path.join(out, filename), images)


for i in range(1, 10):
    make_badge(str(i), f"badge_{i}.ico")
make_badge("9+", "badge_9plus.ico")
print("done")
