# OmaShort × fframes teaser

## Revised final cut — assembled and exported by OmaShort

`omashort-fframes-final-v2.mp4` is a 12-second horizontal 1920×1080 H.264/AAC
teaser. Rebuild the parts and editing project with:

```sh
python3 promo/build_omashort_project.py \
  --capture promo/omashort-project/assets/editor-capture-raw.mp4 \
  --capture-start 6.0
```

The five plates in `promo/omashort-project/assets/` are **drawn natively at
1920×1080**, encoded at CRF 10, then placed as five distinct, editable timed
video layers in `teaser.project.json`. OmaShort's native rendering engine
composited those layers and the sound bed at 1920×1080, CRF 12 (`--horizontal
--high-quality` on `native/tests/render_project_probe.cpp`). This is not a
pre-flattened ffmpeg assembly. The previous 720p-to-1080p upscale and a soft,
obstructive native text overlay were removed.

`02-editor.mp4` uses **real continuous footage** of the OmaShort timeline,
not a constructed mockup. It was captured at 30 fps in an independent Xvfb
server (`:99`) while a separate CUA session inspected and targeted only that
window. CUA background clicks did not start playback in this WM-less Xvfb
session; the isolated copy of the app used a one-shot timer to start normal,
uninterrupted playback instead. No physical monitor, user workspace, or user
cursor is part of that display. The clean y=495–1045 crop
shows the ruler, five clips, and advancing playhead without extraneous preview
panels. The captured PROGRAM/OUTPUT monitors were black in this isolated
session and are not presented as final media. The raw 15-second Xvfb capture is
retained as `editor-capture-raw.mp4` for provenance.

The motion-design plates are explanatory graphics. This teaser does not
contain an actual fframes-rendered clip, an embedded chat UI, or editable
fframes SVG/Rust scenes in OmaShort. The integration demonstrated is an
external MCP bridge that can import or replace completed MP4 renders.
`build_cinematic_teaser.py` supplies the source illustration/audio functions
used by `build_omashort_project.py`; the old standalone concepts and draft
exports are not part of this release. Nothing here was published to X.
Credit: Andrés Villagrán.
