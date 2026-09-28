#!/usr/bin/env python3
"""Render an original motion-first OmaShort x fframes concept teaser.

All interface-like shapes are explanatory motion graphics, not an app capture.
The vertical insert at 3–6s is an actual OmaShort export, never fframes footage.
No network assets or copyrighted music are used.
"""
from __future__ import annotations
import math
import shutil
import subprocess
import tempfile
import wave
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw, ImageFont, ImageFilter

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "examples/omashort-keyframes-fades-preview.mp4"
DEST = Path(__file__).with_name("omashort-fframes-teaser-v2.mp4")
W, H, FPS, DURATION = 1280, 720, 30, 12
INK = (12, 14, 13)
PAPER = (244, 242, 233)
LIME = (204, 255, 77)
ORANGE = (255, 105, 69)
MUTED = (128, 136, 125)
DISPLAY = "/home/node/.local/share/fonts/DIN Condensed Bold.ttf"
SANS = "/home/node/.local/share/fonts/DIN Alternate Bold.ttf"
MONO = "/home/node/.local/share/fonts/fonts/ttf/JetBrainsMono-Medium.ttf"
FONTS = {}


def ft(size, kind="display"):
    key = (size, kind)
    if key not in FONTS:
        FONTS[key] = ImageFont.truetype({"display": DISPLAY, "sans": SANS, "mono": MONO}[kind], size)
    return FONTS[key]


def ease(t):
    t = max(0, min(1, t))
    return 1 - (1 - t) ** 4


def text(im, s, x, y, size, color=PAPER, kind="display", anchor=None, tracking=None):
    d = ImageDraw.Draw(im)
    if tracking is None:
        d.text((int(x), int(y)), s, font=ft(size, kind), fill=color, anchor=anchor)
    else:
        widths = [d.textlength(c, font=ft(size, kind)) for c in s]
        if anchor == "ra":
            x -= sum(widths) + tracking * (len(s) - 1)
        for c, width in zip(s, widths):
            d.text((int(x), int(y)), c, font=ft(size, kind), fill=color)
            x += width + tracking


def label(im, s, x, y, color=MUTED, size=16):
    text(im, s, x, y, size, color, "mono")


def base(t):
    im = Image.new("RGB", (W, H), INK)
    d = ImageDraw.Draw(im)
    # Sparse kinetic guide-lines; avoid literal UI chrome or faux editor captures.
    for i in range(0, W, 72):
        d.line((i + int(9 * math.sin(t + i)), 0, i, H), fill=(24, 27, 24), width=1)
    label(im, "OMASHORT   /   EXTERNAL BRIDGE", 64, 35, LIME, 17)
    return im


def blocks(im, t, count=5):
    d = ImageDraw.Draw(im)
    for k in range(count):
        x = int(((k * 320 + 205 * t) % (W + 250)) - 250)
        y = 240 + k * 80
        d.line((x, y, x + 200, y), fill=LIME if k % 2 else ORANGE, width=3)
        d.rectangle((x, y - 7, x + 12, y + 7), fill=LIME if k % 2 else ORANGE)


def scene_hook(im, t):
    d = ImageDraw.Draw(im)
    s = ease(t / 0.34)
    if t < 0.16:
        # Flash/punch on the opening beat, not a dissolve from a title card.
        d.rectangle((0, 0, W, H), fill=LIME)
        text(im, "MAKE VIDEO", 66, 145, 220, INK)
        text(im, "MOVE.", 70, 340, 255, INK)
        return
    y = int(138 + (1 - s) * 590)
    text(im, "MAKE VIDEO", 63, y, 220)
    text(im, "MOVE.", 65, y + 208, 255, LIME)
    # Kinetic bounding strokes follow the word, not a slide/card template.
    x = int(66 + 775 * ease((t - 0.40) / 0.45))
    d.rectangle((64, 620, min(x, 1150), 633), fill=ORANGE)
    if t > 1.10:
        label(im, "TIMELINE / KEYFRAMES / CUTS", 70, 657, PAPER, 19)
    for i in range(9):
        phase = t * 5 + i * 0.68
        bx = 970 + 130 * math.cos(phase)
        by = 420 + 140 * math.sin(phase * 1.15)
        d.ellipse((bx, by, bx + 6, by + 6), fill=LIME if i % 2 else ORANGE)


def scene_action(im, t, footage):
    d = ImageDraw.Draw(im)
    p = ease((t - 2.05) / 0.38)
    # Full-bleed editorial composition: product output is a large moving object.
    d.rectangle((0, 86, W, 620), fill=(25, 29, 26))
    x = int(840 + (1 - p) * 550)
    y = int(101 + 9 * math.sin(t * 2.8))
    # The footage is the genuine vertical render, shown as an export preview.
    frame = footage[min(len(footage) - 1, max(0, int((t - 2.0) * 15)))]
    im.paste(frame, (x, y))
    d.rectangle((x - 5, y - 5, x + 350, y + 626), outline=LIME, width=3)
    label(im, "ACTUAL OMASHORT EXPORT", x - 1, 655, LIME, 14)
    text(im, "CUT.", 48 + int((1 - p) * -480), 160, 225)
    text(im, "MOVE.", 52 + int((1 - p) * -570), 355, 240, ORANGE)
    for k in range(16):
        rx = int(70 + k * 39 + 8 * math.sin(t * 4 + k))
        h = 9 + 40 * abs(math.sin(t * 7 + k * 1.1))
        d.rectangle((rx, 597 - h, rx + 17, 597), fill=LIME if k % 3 == 0 else (68, 80, 65))
    label(im, "01 / ANIMATE THE TIMELINE", 67, 649, PAPER, 17)


def scene_bridge(im, t):
    d = ImageDraw.Draw(im)
    p = ease((t - 5.72) / 0.40)
    label(im, "02 / EXTERNAL MCP BRIDGE", 67, 118, LIME, 19)
    text(im, "RENDER", 60, 166, 165)
    text(im, "IN FFRAMES.", 64, 317, 178, ORANGE)
    # Route a real-looking media token between named systems; schematic only.
    yy = int(577 + (1 - p) * 240)
    d.rounded_rectangle((70, yy, 423, yy + 72), 3, fill=LIME)
    text(im, "SOURCE / RUST", 94, yy + 22, 21, INK, "mono")
    d.line((435, yy + 36, 799, yy + 36), fill=PAPER, width=3)
    arrowx = int(465 + 318 * ((t - 5.75) % 0.75) / 0.75)
    d.polygon([(arrowx, yy + 24), (arrowx + 21, yy + 36),
               (arrowx, yy + 48)], fill=ORANGE)
    d.rounded_rectangle((817, yy, 1170, yy + 72), 3, outline=PAPER, width=2)
    text(im, "RENDERED MP4", 840, yy + 22, 21, PAPER, "mono")
    label(im, "DIAGRAM / NOT A FFRAMES RENDER", 821, 673, PAPER, 15)


def scene_replace(im, t):
    d = ImageDraw.Draw(im)
    p = ease((t - 8.0) / 0.36)
    label(im, "03 / AGENT-DRIVEN EDITS", 67, 112, LIME, 18)
    text(im, "KEEP THE", 62, 163, 188)
    text(im, "EDIT.", 62, 330, 260, LIME)
    # Timeline carries its same blocks as the media token swaps: concept art.
    yy = 585
    d.rectangle((65, yy - 38, 1200, yy + 93), fill=(26, 30, 27))
    for k in range(19):
        x = 80 + k * 58
        h = 14 + 24 * abs(math.sin(k * 0.75 + t * 3))
        d.rectangle((x, yy + 8 - h, x + 33, yy + 8), fill=(75, 84, 70))
    for k in range(5):
        x = 95 + k * 211
        d.rounded_rectangle((x, yy + 27, x + 197, yy + 66), 3,
                            fill=ORANGE if k == 2 and t < 9.18 else LIME)
    playhead = int(180 + (t - 8) * 475)
    d.line((playhead, yy - 35, playhead, yy + 77), fill=PAPER, width=3)
    for k, c in enumerate((ORANGE, LIME, PAPER)):
        d.ellipse((950 + k * 65 + (1 - p) * 300, 310,
                   1002 + k * 65 + (1 - p) * 300, 362), outline=c, width=5)
    label(im, "NEW RENDER. SAME POSITION + TIMING.", 68, 681, PAPER, 18)


def scene_end(im, t):
    d = ImageDraw.Draw(im)
    if t < 10.13:
        d.rectangle((0, 0, W, H), fill=ORANGE)
        text(im, "OMASHORT", 50, 195, 290, INK)
        text(im, "X FFRAMES", 63, 450, 118, INK)
        return
    d.rectangle((0, 0, W, H), fill=LIME)
    p = ease((t - 10.13) / 0.42)
    x = 57 - int((1 - p) * 500)
    text(im, "OMASHORT", x, 118, 255, INK)
    text(im, "x FFRAMES", x + 7, 346, 135, INK)
    d.rectangle((62, 539, 1216, 544), fill=INK)
    text(im, "NATIVE EDITING. EXTERNAL AGENT CONTROL.", 65, 569, 24, INK, "mono")
    label(im, "ANDRÉS VILLAGRÁN  /  CONCEPT FILM", 65, 662, INK, 15)


def synth_audio(path):
    rate, length = 48000, DURATION
    audio = np.zeros(rate * length, dtype=np.float32)
    rng = np.random.default_rng(731)
    def lay(start, signal):
        pos = int(start * rate)
        end = min(len(audio), pos + len(signal))
        if pos < end:
            audio[pos:end] += signal[:end - pos]
    for beat in np.arange(0, length, 0.5):
        n = int(0.32 * rate)
        q = np.arange(n, dtype=np.float32) / rate
        phase = 2 * np.pi * (48 * q + 83 * (1 - np.exp(-q * 22)) / 22)
        kick = np.sin(phase) * np.exp(-q * 17) * 0.63
        lay(float(beat), kick)
        if round(beat * 2) % 2:
            snare = rng.standard_normal(int(0.16 * rate)).astype(np.float32)
            envelope = np.exp(-np.arange(len(snare)) / rate * 31)
            lay(float(beat), 0.15 * snare * envelope)
    for h in np.arange(0.25, length, 0.25):
        n = int(rate * 0.050)
        noise = rng.standard_normal(n).astype(np.float32)
        # High-pass-ish by subtracting a one-sample delayed copy.
        hat = np.concatenate(([noise[0]], np.diff(noise))) * np.exp(-np.arange(n) / (rate * .009)) * .042
        lay(float(h), hat)
    for start in (0, 2, 5.65, 8, 10):
        n = int(0.24 * rate)
        q = np.arange(n, dtype=np.float32) / rate
        zap = np.sin(2*np.pi*(480*q - 1300*q*q)) * np.exp(-q * 25) * .12
        lay(start, zap)
    fade = np.minimum(1, np.arange(len(audio)) / (rate * 0.04))
    fade *= np.minimum(1, np.arange(len(audio))[::-1] / (rate * 0.27))
    audio = np.clip(audio * fade, -.9, .9)
    with wave.open(str(path), "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(rate)
        w.writeframes((audio * 32767).astype("<i2").tobytes())


def load_footage():
    # 3 seconds of real OmaShort output for one beat; scale and sample at 15 fps.
    cmd = ["ffmpeg", "-loglevel", "error", "-ss", "2.0", "-i", str(SOURCE),
           "-t", "3.4", "-vf", "fps=15,scale=350:622:flags=lanczos",
           "-pix_fmt", "rgb24", "-f", "rawvideo", "-"]
    data = subprocess.check_output(cmd)
    frame_size = 350 * 622 * 3
    assert len(data) % frame_size == 0 and len(data) >= frame_size * 45
    return [Image.frombytes("RGB", (350, 622), data[i:i + frame_size])
            for i in range(0, len(data), frame_size)]


def main():
    for tool in ("ffmpeg", "ffprobe"):
        if not shutil.which(tool):
            raise RuntimeError(f"Missing {tool}")
    if not SOURCE.is_file():
        raise FileNotFoundError(SOURCE)
    footage = load_footage()
    with tempfile.TemporaryDirectory(prefix="omashort-film-") as td:
        audio = Path(td) / "original-sound.wav"
        synth_audio(audio)
        cmd = ["ffmpeg", "-y", "-hide_banner", "-loglevel", "error", "-f", "rawvideo",
               "-pix_fmt", "rgb24", "-s", f"{W}x{H}", "-r", str(FPS), "-i", "-",
               "-i", str(audio), "-c:v", "libx264", "-preset", "fast", "-crf", "18",
               "-pix_fmt", "yuv420p", "-c:a", "aac", "-b:a", "160k", "-r", str(FPS),
               "-frames:v", str(FPS * DURATION), "-shortest", "-movflags", "+faststart", str(DEST)]
        proc = subprocess.Popen(cmd, stdin=subprocess.PIPE)
        assert proc.stdin
        try:
            for n in range(FPS * DURATION):
                t = n / FPS
                im = base(t)
                if t < 2:
                    scene_hook(im, t)
                elif t < 5.7:
                    scene_action(im, t, footage)
                elif t < 8:
                    scene_bridge(im, t)
                elif t < 10:
                    scene_replace(im, t)
                else:
                    scene_end(im, t)
                proc.stdin.write(im.tobytes())
        finally:
            proc.stdin.close()
        if proc.wait() != 0:
            raise RuntimeError("ffmpeg failed")
    print(DEST)


if __name__ == "__main__":
    main()
