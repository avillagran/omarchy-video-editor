# Omareel project format (`project.json`)

Single JSON file at `~/.local/share/omareel/project.json`. It is the ENTIRE editor
state: any program (LLM, script, human) can edit it while Omareel is running and
the UI applies the changes live (~1 s, QFileSystemWatcher + hash guard against
self-writes). Omareel also saves it automatically every ~1.5 s when something
changed, so manual edits should be quick or done while the user is not editing.

Design goals: flat, obvious names, no ids unless needed, percentages 0-100 for
source-space coords, fractions 0-1 for frame-space coords, seconds for time.

```jsonc
{
  "version": 1,
  "app": "omareel",
  "video": "/abs/path/source.mp4",        // library video shown in PROGRAM
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
      "color": "#ffffff", "font": "", "inS": 5.0, "outS": 10.0 },
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

- Keep `version: 1` and `app: "omareel"`.
- Unknown keys are ignored; missing keys keep their current values.
- Write the file atomically (temp + rename) or in one `write()` — partial JSON
  is ignored (parse fails, no crash).
- Layout names: `completa` (single crop), `apilar` (two stacked zones),
  `pip` (background + square fg), `circulo` (background + circular fg).
- Block `layout` overrides the global `template` for its time range; when
  `blocks` is non-empty, rendering concatenates the blocks in array order.
- The block under the playhead is what PROGRAM/OUTPUT preview and edit.
