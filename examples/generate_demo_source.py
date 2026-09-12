#!/usr/bin/env python3
"""Generate the deterministic abstract motion source used by the demo project."""
import math
import subprocess
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter

W, H, FPS, SECONDS = 960, 540, 30, 10
OUT = Path(__file__).with_name("assets") / "omareel-motion-source.mp4"
OUT.parent.mkdir(parents=True, exist_ok=True)

cmd = [
    "ffmpeg", "-v", "error", "-y", "-f", "rawvideo", "-pix_fmt", "rgb24",
    "-s", f"{W}x{H}", "-r", str(FPS), "-i", "-", "-an", "-c:v", "libx264",
    "-preset", "fast", "-crf", "20", "-pix_fmt", "yuv420p", "-movflags", "+faststart", str(OUT),
]
proc = subprocess.Popen(cmd, stdin=subprocess.PIPE)

base = Image.new("RGB", (W, H))
base_px = base.load()
for y in range(H):
    k = y / H
    color = (int(7 + 7 * k), int(10 + 10 * k), int(24 + 18 * k))
    for x in range(W):
        base_px[x, y] = color

for frame_no in range(FPS * SECONDS):
    t = frame_no / FPS
    image = base.copy()

    glow = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    gd = ImageDraw.Draw(glow)
    orbs = [
        (0.23 + 0.12 * math.sin(t * 0.55), 0.28 + 0.10 * math.cos(t * 0.47), 190, (45, 212, 255, 155)),
        (0.76 + 0.11 * math.cos(t * 0.43), 0.42 + 0.14 * math.sin(t * 0.52), 220, (151, 82, 255, 135)),
        (0.52 + 0.16 * math.sin(t * 0.31 + 2), 0.78 + 0.08 * math.cos(t * 0.61), 170, (255, 116, 86, 95)),
    ]
    for fx, fy, radius, color in orbs:
        cx, cy = int(fx * W), int(fy * H)
        gd.ellipse((cx - radius, cy - radius, cx + radius, cy + radius), fill=color)
    glow = glow.filter(ImageFilter.GaussianBlur(85))
    image = Image.alpha_composite(image.convert("RGBA"), glow)

    overlay = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    draw = ImageDraw.Draw(overlay)
    for x in range(-H, W + H, 54):
        shift = int((t * 13) % 54)
        draw.line((x + shift, H, x + H + shift, 0), fill=(125, 211, 252, 18), width=1)
    for y in range(42, H, 54):
        draw.line((0, y, W, y), fill=(190, 205, 255, 11), width=1)
    for i in range(48):
        fx = (i * 0.61803398875 + t * (0.006 + (i % 5) * 0.001)) % 1
        fy = (i * 0.38196601125 + 0.06 * math.sin(t * 0.4 + i)) % 1
        r = 1 + i % 3
        alpha = 35 + (i * 17) % 65
        draw.ellipse((fx * W - r, fy * H - r, fx * W + r, fy * H + r), fill=(180, 225, 255, alpha))
    for lane in range(3):
        points = []
        for x in range(-20, W + 21, 12):
            y = H * (0.38 + lane * 0.12) + 18 * math.sin(x / 95 + t * (0.8 + lane * 0.13) + lane)
            points.append((x, y))
        draw.line(points, fill=((90, 220, 255, 70), (175, 110, 255, 58), (255, 140, 95, 48))[lane], width=2)
    image = Image.alpha_composite(image, overlay).convert("RGB")
    proc.stdin.write(image.tobytes())

proc.stdin.close()
if proc.wait() != 0:
    raise SystemExit("ffmpeg failed")
print(OUT)
