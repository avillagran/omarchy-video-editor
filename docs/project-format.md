# OmaShort project format (`project.json`)

Single JSON file at `~/.local/share/omashort/project.json`. It is the ENTIRE editor
state: any program (LLM, script, human) can edit it while OmaShort is running and
the UI applies the changes live (~1 s, QFileSystemWatcher + hash guard against
self-writes). OmaShort also saves it automatically every ~1.5 s when something
changed, so manual edits should be quick or done while the user is not editing.

Design goals: flat, obvious names, no ids unless needed, percentages 0-100 for
source-space coords, fractions 0-1 for frame-space coords, seconds for time.

```jsonc
{
  "version": 1,
  "app": "omashort",
  "video": "/abs/path/source.mp4",        // absolute, or relative to this JSON
  "trim":  { "in": 5.0, "out": 10.0 },    // seconds, source timeline
  "template": "completa",                 // global layout when no blocks:
                                          // completa | apilar | pip | circulo
  "region": { "x": 0, "y": 0, "w": 100, "h": 100 },   // % of source (completa)
  "lock916": false,                       // constrain region to 9:16 aspect
  "apilar": {                             // stack layout regions (percent)
    "top":    { "x": 0, "y": 0,  "w": 100, "h": 50 },
    "bottom": { "x": 0, "y": 50, "w": 100, "h": 50 },
    "split":  0.5                         // top-zone height fraction (0.15-0.85)
  },
  "pip": {                                // pip/circulo foreground
    "fg": { "x": 25, "y": 25, "w": 50, "h": 50 },     // % of source
    "fx": 0.5, "fy": 0.72                 // center on the 9:16 frame (0-1)
  },
  "layers": [                             // overlays, z-order = array order
    { "type": "text",  "text": "Hola", "x": 0.5, "y": 0.15, "size": 90,
      "color": "#ffffff", "font": "", "opacity": 1.0,
      "inS": 5.0, "outS": 10.0, "fadeIn": 0.35, "fadeOut": 0.5,
      "keyframes": [
        { "time": 5.0, "x": 0.15, "y": 0.82, "size": 64, "easing": "easeOut" },
        { "time": 8.0, "x": 0.50, "y": 0.15, "size": 96 }
      ] },
    { "type": "gif",   "path": "/abs/a.gif",  "x": 0.5, "y": 0.5, "w": 0.35, "h": 0.20, "inS": 0, "outS": 5 },
    { "type": "image", "path": "/abs/a.png",  "x": 0.5, "y": 0.5, "w": 0.35, "h": 0.20, "inS": 0, "outS": 5 },
    { "type": "video", "path": "/abs/b.mp4",  "x": 0.5, "y": 0.72, "w": 0.40, "h": 0.23,
      "shape": "circle",                       // rect | rounded | circle
      "inS": 0, "outS": 5 }
    // x,y = center on the 1080x1920 frame (0-1); w,h = size fraction of frame
    // px,py (+pw,ph) = SAME layer on the SOURCE/program frame (0-1): dual-format
    //   editing — drag in PROGRAM writes px,py; drag in OUTPUT writes x,y.
    //   Omit px/py to mirror x/y on the program monitor.
    // inS/outS = seconds on the CUT timeline (0 = cut start)
    // keyframes = optional property snapshots. x/y/w/h, px/py/pw/ph, text
    // size and opacity tween in both live previews and ffmpeg exports.
    // fadeIn/fadeOut are layer-edge fades and combine with animated opacity.
    // easing lives on the starting keyframe: linear | easeIn | easeOut |
    // easeInOut | backOut | bounce.
  ],
  "blocks": [                             // timeline blocks (pista B); [] = single
    { "start": 0.0, "end": 3.0, "layout": "completa",
      "split": 0.5, "fx": 0.5, "fy": 0.72,
      "regions": {                          // percent of source
        "main":   { "x": 0, "y": 0, "w": 100, "h": 100 },
        "top":    { "x": 0, "y": 0, "w": 100, "h": 50 },
        "bottom": { "x": 0, "y": 50, "w": 100, "h": 50 },
        "fg":     { "x": 25, "y": 25, "w": 50, "h": 50 } } },
    { "start": 3.0, "end": 7.0, "layout": "apilar",  "regions": { "...": "..." } },
    { "start": 7.0, "end": 10.0, "layout": "circulo", "regions": { "...": "..." } }
  ],
  "srt": "",                              // subtitle file path ("" = none)
  "dock": {                               // UI layout (optional on edits)
    "columns": [["fuentes"], ["program", "output"], ["capas", "galeria"], ["inspector"]],
    "colFr":   [0.2, 0.36, 0.22, 0.22],   // column width fractions
    "rowFr":   { "1": [0.5, 0.5], "2": [0.5, 0.5] },  // panel heights per column
    "collapsed": { "inspector": false },
    "tlHeight": 0                         // timeline px height (0 = auto)
  }
}
```

## Rules for AI editors

- Keep `version: 1` and `app: "omashort"`. Projects using the retired
  `app: "omareel"` value remain readable for compatibility.
- Unknown keys are ignored; missing keys keep their current values.
- Write the file atomically (temp + rename) or in one `write()` — partial JSON
  is ignored (parse fails, no crash).
- Layout names: `completa` (single crop), `apilar` (two stacked zones),
  `pip` (background + square fg), `circulo` (background + circular fg).
- Block `layout` overrides the global `template` for its time range; when
  `blocks` is non-empty, rendering concatenates the blocks in array order.
- The block under the playhead is what PROGRAM/OUTPUT preview and edit.
- `video`, `srt`, and layer `path` values may be relative to the project file;
  this is how projects under `examples/` remain portable.
- `project.json` is the default autosave project. The Open and Save as controls
  can switch to any local `.json` project; autosave and live reload follow the
  selected file.

## External MCP bridge

The optional `native/scripts/omashort_mcp.py` stdio server exposes three tools
for an external MCP client. Configuration and SDK setup are in the README.
All project paths must be absolute and name an existing `app: "omashort"`,
`version: 1` JSON file. Each read returns `{ "sha256": "...", "document": {...} }`.
Mutating calls return the same shape with the new hash; always use the hash
from the latest read. Edits are atomic (same-directory rename), preserve
unknown JSON fields and file permissions, and reject stale hashes.

`get_project(path)` reads. `patch_project(path, expected_sha256, operations)`
accepts a nonempty array of these typed operations, executed in order:

```json
[
  {"op": "set_trim", "in_seconds": 1, "out_seconds": 4},
  {"op": "set_template", "template": "completa"},
  {"op": "add_text_layer", "text": "Hello", "x": 0.5, "y": 0.2,
   "size": 72, "color": "#ffffff", "opacity": 1,
   "in_seconds": 0, "out_seconds": 3},
  {"op": "update_text_layer", "index": 0, "text": "Updated"}
]
```

Trim times are source seconds (0–86400, `in < out`). Templates are `completa`,
`apilar`, `pip`, or `circulo`. Text-layer indices are zero-based; updates touch
only supplied fields. Text is 1–2000 characters, size 1–512, coordinates and
opacity 0–1, color `#RRGGBB`; optional text-layer timing is in cut-timeline
seconds (0–86400, `inS < outS`). New text layers carry
`timingSpace: "cut"` so both previews map the trimmed source playhead to
cut time; existing layers without that marker retain source-time preview
behavior. Absent text fields use defaults. Existing non-text layers cannot
be updated through these operations.

`import_fframes_render(path, expected_sha256, mp4_path, in_seconds,
out_seconds, as_main=false)` requires an existing nonempty absolute `.mp4`
file. By default it appends a movable, centered, **aspect-fitted overlay**
`video` layer, timed in **cut-timeline** seconds (`inS`/`outS`,
`timingSpace: "cut"`). For example, with main `trim.in = 5`, an imported
layer at `inS = 0`, `outS = 3` appears while the source playhead is at
5–8 seconds in both previews **when there are no skipped blocks**. With
visible composition blocks, cut-time is the sum of preceding visible block
durations plus the offset in the current block; hidden source intervals have
no corresponding cut frame or keyframe. New cut-timed layer keyframes created
in the UI use this same time, while legacy layers without `timingSpace`
continue using source-playhead seconds. Export already uses cut-timeline
layer seconds.
The bridge probes MP4 dimensions when ffprobe is available and stores fitted
output (`w`/`h`) and program (`pw`/`ph`) boxes plus `sourceAspect` so preview
and export share the same geometry. If probing fails, the fallback centered
box is 0.35 × 0.20 of the canvas, and the editor may refit it on load after a
successful probe. The overlay does **not** fill the frame. `as_main=true`
instead sets the main `video` path and source-timeline `trim.in`/`trim.out`;
it does not clear existing layers or blocks. The MP4 is referenced, not copied
or rendered. Neither tool checks actual media duration or decodability; choose
times within the finished clip and keep it at that path. fframes is an external
renderer, not an editor plugin: its Rust/SVG vectors and timeline are **not
directly editable** in OmaShort. Only the resulting video layer's placement and
timing can be changed in OmaShort. Keep the fframes source separately for later
regeneration; this MVP does not persist a source-project reference in the layer.
`replace_fframes_render(path, expected_sha256, layer_index, mp4_path)` points an
existing video layer (zero-based index) at a newly rendered MP4 while preserving
its positioning, timing, keyframes and other properties. Use the latest project
hash; the replacement must have the same aspect ratio when both files can be
probed, or import it as a new layer. Render to a distinct path so the decoder
sees the media change; this does not watch or execute fframes code automatically.
For `as_main=true`, a live project reload keeps the requested source-time
`trim.in` instead of resetting it during the video source swap.

On Unix, the updated editor and bridge share a sidecar advisory lock.
The editor also rejects autosave when its loaded project revision has changed;
the watcher reloads a valid external revision and updates that hash. This
prevents the editor's atomic save from racing the bridge's final check and
rename. Uncooperative writers and older running editor binaries do not honor
the lock: pause them during the MCP transaction and read back the final state.
If UI changes have not yet autosaved when an external edit arrives, coordinate
with the editor operator before accepting the reload. The bridge does not add
an in-app chat interface or output-gallery entry.
