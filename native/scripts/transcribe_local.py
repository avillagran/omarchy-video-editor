#!/usr/bin/env python3
"""Offline faster-whisper transcription for OmaShort.

Usage: transcribe_local.py MODEL CLIP OUTPUT.srt LANGUAGE
The model path must be a local CTranslate2 Whisper snapshot. No network access
or model download is attempted.
"""
from __future__ import annotations

import sys
from pathlib import Path


def stamp(seconds: float) -> str:
    milliseconds = round(max(0.0, seconds) * 1000)
    hours, milliseconds = divmod(milliseconds, 3_600_000)
    minutes, milliseconds = divmod(milliseconds, 60_000)
    seconds, milliseconds = divmod(milliseconds, 1000)
    return f"{hours:02}:{minutes:02}:{seconds:02},{milliseconds:03}"


def main(argv: list[str]) -> int:
    if len(argv) != 5:
        print("usage: transcribe_local.py MODEL CLIP OUTPUT.srt LANGUAGE", file=sys.stderr)
        return 2
    model_dir, clip, out = map(Path, argv[1:4])
    language = argv[4]
    if not model_dir.is_dir() or not (model_dir / "model.bin").is_file():
        print(f"local CTranslate2 Whisper model not found: {model_dir}", file=sys.stderr)
        return 3
    if not clip.is_file():
        print(f"clip not found: {clip}", file=sys.stderr)
        return 4
    try:
        from faster_whisper import WhisperModel
    except ImportError:
        print("faster-whisper is not installed in this Python runtime", file=sys.stderr)
        return 5
    try:
        model = WhisperModel(str(model_dir), device="cpu", compute_type="int8")
        segments, _ = model.transcribe(str(clip), language=language, task="transcribe",
                                      word_timestamps=True, vad_filter=True,
                                      condition_on_previous_text=False)
        cues = list(segments)
    except Exception as exc:
        print(f"local Whisper failed: {exc}", file=sys.stderr)
        return 6
    out.parent.mkdir(parents=True, exist_ok=True)
    with out.open("w", encoding="utf-8") as handle:
        for index, segment in enumerate(cues, 1):
            text = segment.text.strip()
            if not text:
                continue
            handle.write(f"{index}\n{stamp(segment.start)} --> {stamp(segment.end)}\n{text}\n\n")
    print(f"cues={len(cues)} output={out}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
