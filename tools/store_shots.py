"""Captioned store screenshots from raw app captures (one design, both stores).

Raw captures: assets/screenshots/raw/*.png (Android emulator, 1080x2400; the
bottom ad area is cropped off). Run with the server-agent venv python:
    python tools/store_shots.py
Writes assets/play/phone_N_v104.png (1080x1920) and
assets/screenshots/ios69_N.png (1320x2868).
"""
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter, ImageFont

ROOT = Path(__file__).resolve().parent.parent
RAW = ROOT / "assets/screenshots/raw"
CROP_H = 1940  # raw 1080x2400: keep down to the bottom deck, drop the ad
SHOTS = [
    ("idle.png", "이어폰 끼고 MR 틀고", "노래하면 노래방 에코!", "내 폰이 노래방 마이크로"),
    ("recording.png", "효과 그대로", "내 노래를 녹음", "다시 듣고, 공유하고"),
    ("autotune.png", "누르는 동안만", "오토튠 ON", "손끝으로 켜는 음정 보정"),
    ("recordings.png", "녹음은 내 폰에만", "안전하게 저장", "서버로 보내지 않습니다"),
]
TOP, BOTTOM = (0x6D, 0x28, 0xD9), (0xDB, 0x27, 0x77)


def render(raw: Path, l1: str, l2: str, sub: str, W: int, H: int) -> Image.Image:
    k = W / 1080  # scale type and margins with the canvas width
    bold = ImageFont.truetype("C:/Windows/Fonts/malgunbd.ttf", int(84 * k))
    thin = ImageFont.truetype("C:/Windows/Fonts/malgun.ttf", int(44 * k))
    bg = Image.new("RGB", (W, H))
    d = ImageDraw.Draw(bg)
    for y in range(H):
        t = y / H
        d.line([(0, y), (W, y)], fill=tuple(int(TOP[i] + (BOTTOM[i] - TOP[i]) * t) for i in range(3)))
    top = int(H * 0.036)
    for txt, font, y in [(l1, bold, top), (l2, bold, top + int(100 * k)), (sub, thin, top + int(215 * k))]:
        d.text(((W - d.textlength(txt, font=font)) / 2, y), txt, font=font, fill="white")
    y0 = top + int(310 * k)
    h = H - y0 - int(H * 0.02)
    w = int(1080 * h / CROP_H)
    if w > W - int(120 * k):  # wide canvas: fit by width instead
        w = W - int(120 * k)
        h = int(CROP_H * w / 1080)
    shot = Image.open(raw).convert("RGB").crop((0, 0, 1080, CROP_H)).resize((w, h), Image.LANCZOS)
    r = int(48 * k)
    mask = Image.new("L", (w, h), 0)
    ImageDraw.Draw(mask).rounded_rectangle((0, 0, w, h), r, fill=255)
    pad = int(20 * k)
    shadow = Image.new("L", (w + 2 * pad, h + 2 * pad), 0)
    ImageDraw.Draw(shadow).rounded_rectangle((pad, pad, w + pad, h + pad), r, fill=110)
    x = (W - w) // 2
    bg.paste((20, 10, 30), (x - pad, y0 - pad + int(14 * k)), shadow.filter(ImageFilter.GaussianBlur(16 * k)))
    bg.paste(shot, (x, y0), mask)
    return bg


def main() -> None:
    for n, (raw, l1, l2, sub) in enumerate(SHOTS, 1):
        render(RAW / raw, l1, l2, sub, 1080, 1920).save(ROOT / f"assets/play/phone_{n}_v104.png")
        render(RAW / raw, l1, l2, sub, 1320, 2868).save(ROOT / f"assets/screenshots/ios69_{n}.png")
    print("ok")


if __name__ == "__main__":
    main()
