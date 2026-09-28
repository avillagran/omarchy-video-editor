#!/usr/bin/env python3
"""Make separate motion plates, audio and a real OmaShort editing project.

Prepared parts are cut and composited as timed video layers by OmaShort's
native engine. Optional --capture inserts actual app-only capture into plate 2.
No pre-assembled promotional video is emitted by this script.
"""
from __future__ import annotations
import argparse
import json
import math
import subprocess
import sys
import wave
from pathlib import Path

from PIL import Image, ImageDraw
import build_cinematic_teaser as art
from scaled_drawing import scaled_drawing

from build_cinematic_teaser import (
    DURATION, FPS, H, W, INK, LIME, ORANGE, PAPER, MUTED,
    base, ease, label, scene_bridge, scene_end, scene_hook,
    scene_replace, synth_audio, text,
)

OUT = Path(__file__).with_name("omashort-project")
ASSETS = OUT / "assets"
SCALE = 1.5
OUTPUT_W, OUTPUT_H = round(W * SCALE), round(H * SCALE)
TIMELINE_Y, TIMELINE_H = 495, 550
SCENES = [("01-hook", 0.0, 2.0), ("02-editor", 2.0, 5.7),
          ("03-bridge", 5.7, 8.0), ("04-replace", 8.0, 10.0),
          ("05-end", 10.0, 12.0)]


def capture_frames(path, start=0.0):
    if not path:
        return []
    info = json.loads(subprocess.check_output([
        "ffprobe", "-v", "error", "-select_streams", "v:0", "-show_entries",
        "stream=width,height", "-of", "json", str(path)
    ]))["streams"][0]
    if info["width"] != OUTPUT_W or info["height"] != OUTPUT_H:
        raise ValueError(f"Expected an app-only {OUTPUT_W}x{OUTPUT_H} capture")
    cmd = ["ffmpeg", "-v", "error", "-ss", str(start), "-i", str(path),
           "-vf", f"fps={FPS},crop={OUTPUT_W}:{TIMELINE_H}:0:{TIMELINE_Y}",
           "-frames:v", str(round((SCENES[1][2] - SCENES[1][1]) * FPS)),
           "-f", "rawvideo", "-pix_fmt", "rgb24", "-"]
    payload = subprocess.check_output(cmd)
    n = OUTPUT_W * TIMELINE_H * 3
    count = round((SCENES[1][2] - SCENES[1][1]) * FPS)
    if len(payload) != n * count:
        raise RuntimeError(f"Expected {count} full-resolution captured frames; got {len(payload) // n}")
    return [Image.frombytes("RGB", (OUTPUT_W, TIMELINE_H), payload[i:i+n])
            for i in range(0, len(payload), n)]


def base_hi(t):
    im = Image.new("RGB", (OUTPUT_W, OUTPUT_H), INK)
    d = ImageDraw.Draw(im)
    for i in range(0, W, 72):
        d.line((i + int(9 * math.sin(t + i)), 0, i, H),
               fill=(24, 27, 24), width=1)
    label(im, "OMASHORT   /   EXTERNAL BRIDGE", 64, 35, LIME, 17)
    return im


def editor_plate(im, t, captured):
    d = ImageDraw.Draw(im)
    if not captured:
        # Preparation-stage holder: used only to populate the actual editor timeline
        # before its capture. Final output must pass --capture and must not use this.
        text(im, "EDIT INSIDE", 68, 174, 190)
        text(im, "OMASHORT.", 68, 360, 190, ORANGE)
        for k in range(16):
            xx = 88 + k * 70
            d.rectangle((xx, 610, xx + 55, 658), fill=LIME if k % 3 else ORANGE)
        return
    # Crop only the genuine Qt timeline: the isolated test harness's PROGRAM
    # preview shows an unrepresentative green rectangle, so never present it as
    # finished media. The moving playhead and clip selection remain untouched.
    local = max(0, t - 2.0)
    ix = min(len(captured) - 1, int(local * 30))
    timeline = captured[ix]
    p = ease(local / .34)
    text(im, "CUT IT IN", 66, 72, 110)
    text(im, "OMASHORT.", 67, 175, 110, LIME)
    d.rectangle((0, 320, W, 687), fill=(22, 27, 22))
    # Paste actual captured pixels 1:1 at the final 1080p output resolution.
    # The reveal moves the whole strip without skipping any source frames.
    im.paste(timeline, (round((1 - p) * OUTPUT_W), round(320 * SCALE)))
    d.rectangle((0, 314, W, 320), fill=LIME)
    d.rectangle((0, 687, W, H), fill=INK)
    label(im, "REAL EDITOR TIMELINE / FIVE CLIPS", 52, 689, PAPER, 17)


def make_part(name, start, end, captured):
    target = ASSETS / f"{name}.mp4"
    frames = round((end - start) * FPS)
    proc = subprocess.Popen([
        "ffmpeg", "-y", "-v", "error", "-f", "rawvideo", "-pix_fmt", "rgb24",
        "-s", f"{OUTPUT_W}x{OUTPUT_H}", "-r", str(FPS), "-i", "-", "-an", "-c:v", "libx264",
        "-preset", "slow", "-crf", "10", "-pix_fmt", "yuv420p",
        "-frames:v", str(frames), "-movflags", "+faststart", str(target)
    ], stdin=subprocess.PIPE)
    assert proc.stdin
    try:
        with scaled_drawing(art, SCALE):
            for i in range(frames):
                t = start + i / FPS
                im = base_hi(t)
                if name == "01-hook": scene_hook(im, t)
                elif name == "02-editor": editor_plate(im, t, captured)
                elif name == "03-bridge": scene_bridge(im, t)
                elif name == "04-replace": scene_replace(im, t)
                else: scene_end(im, t)
                proc.stdin.write(im.tobytes())
    finally:
        proc.stdin.close()
    if proc.wait():
        raise RuntimeError(f"part encode failed: {name}")
    return target


def black_bed():
    soundtrack = ASSETS / "original-sound.wav"
    synth_audio(soundtrack)
    target = ASSETS / "black-with-sound.mp4"
    subprocess.run([
        "ffmpeg", "-y", "-v", "error", "-f", "lavfi", "-i",
        f"color=c=0x0c0e0d:s={OUTPUT_W}x{OUTPUT_H}:r={FPS}:d={DURATION}", "-i", str(soundtrack),
        "-c:v", "libx264", "-preset", "ultrafast", "-crf", "28",
        "-c:a", "aac", "-b:a", "160k", "-t", str(DURATION),
        "-pix_fmt", "yuv420p", "-movflags", "+faststart", str(target)
    ], check=True)
    soundtrack.unlink()
    return target


def project():
    layers = []
    for name, start, end in SCENES:
        layers.append({
            "type": "video", "path": f"assets/{name}.mp4", "name": name,
            "x": .5, "y": .5, "w": 1, "h": 1,
            "px": .5, "py": .5, "pw": 1, "ph": 1,
            "sourceAspect": W/H, "inS": start, "outS": end,
            "timingSpace": "cut", "audioEnabled": False, "opacity": 1
        })
    # The native engine assembles these timed video layers and the source audio.
    # No extra text layer covers the precomposed typography or the timeline.
    doc = {
        "version": 1, "app": "omashort", "video": "assets/black-with-sound.mp4",
        "trim": {"in": 0, "out": DURATION}, "audioEnabled": True,
        "template": "completa", "region": {"x": 0, "y": 0, "w": 100, "h": 100},
        "layers": layers,
        "blocks": [
            {"start": 0, "end": DURATION, "layout": "completa",
             "regions": {"main": {"x": 0, "y": 0, "w": 100, "h": 100}}}
        ],
        "render": {"formats": ["h"], "codec": "h264", "quality": "high"}
    }
    dest = OUT / "teaser.project.json"
    dest.write_text(json.dumps(doc, indent=2) + "\n")
    return dest


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--capture", type=Path, help="real app-only screen recording")
    parser.add_argument("--capture-start", type=float, default=0.0,
                        help="start of one continuous 3.7-second playback window")
    options = parser.parse_args()
    ASSETS.mkdir(parents=True, exist_ok=True)
    captured = capture_frames(options.capture, options.capture_start)
    black_bed()
    for name, start, end in SCENES:
        print(make_part(name, start, end, captured), flush=True)
    print(project())


if __name__ == "__main__":
    main()
