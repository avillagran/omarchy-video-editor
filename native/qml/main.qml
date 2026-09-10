// main.qml - Omareel Native: NLE layout with dockable/collapsible panels
import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import QtQuick.Dialogs
import QtMultimedia
import "I18n.js" as I18n
import "Theme.js" as T

ApplicationWindow {
  id: win
  width: 1440; height: 900; minimumWidth: 1024; minimumHeight: 640
  visible: true
  title: "Omareel"
  color: T.app

  // ---- state ----
  property var sources: []
  property var outputs: []
  property var current: null
  property string cutPath: ""
  property var jobs: []
  property var layers: []
  // bump on in-place layer edits (text, pos, size, timing): array identity stays
  // stable so editors keep focus, previews refresh via `rev` dependencies
  property int layersRev: 0
  function touchLayers() { layersRev = (layersRev + 1) % 2000000000 }
  property string srtPath: ""
  property real split: 0.5
  property bool editRegions: false   // zone/marco editing in Program (toggle from Inspector)
  property bool loop: false
  property var stripUrls: []
  property string stripFor: ""
  property real trimIn: 0
  property real trimOut: 1
  property int selectedLayer: -1
  property string view: "edit"   // "edit" | "out"
  property int tplIndex: 0
  property int regionX: 0
  property int regionY: 0
  property int regionW: 100
  property int regionH: 100

  // ---- docking state (columns of vertically-stacked panels) ----
  property var dock: [["fuentes"], ["program", "output"], ["capas", "galeria"], ["inspector", "render"]]
  // panels hidden via ✕ / panel manager (dock keeps their order for restore)
  property var hidden: ({})
  property var allPanels: ["fuentes", "program", "output", "capas", "galeria", "inspector", "render"]
  // ---- render settings (panel RENDER) ----
  property bool fmtV: true
  property bool fmtH: false
  property int renderCodecIdx: 0
  property int renderQualIdx: 1
  function visibleDock() {
    var out = []
    for (var i = 0; i < dock.length; i++) {
      var c = []
      for (var j = 0; j < dock[i].length; j++)
        if (!win.hidden[dock[i][j]]) c.push(dock[i][j])
      if (c.length) out.push(c)
    }
    return out
  }
  function setPanelHidden(id, hide) {
    var h = Object.assign({}, win.hidden)
    if (hide) h[id] = true; else delete h[id]
    win.hidden = h
  }
  // resizable dock: column width fractions + per-column panel height fractions
  property var colFr: [0.20, 0.36, 0.22, 0.22]
  property real tlHeight: 0   // 0 = auto; timeline pinned to bottom, vertical resize only
  property var rowFr: ({})
  onDockChanged: normalizeFr()
  onHiddenChanged: normalizeFr()
  function normalizeFr() {
    var vd = visibleDock()
    // columns: pad/trim to visible length, renormalize
    var fr = colFr.slice(0, vd.length)
    while (fr.length < vd.length) fr.push(0.2)
    var sum = fr.reduce(function (a, b) { return a + b }, 0) || 1
    colFr = fr.map(function (f) { return f / sum })
    // rows: equal split per column (keep existing where sizes match)
    var rf = {}
    for (var i = 0; i < vd.length; i++) {
      var n = vd[i].length
      if (rowFr[i] && rowFr[i].length === n) rf[i] = rowFr[i]
      else { var arr = []; for (var j = 0; j < n; j++) arr.push(1 / Math.max(1, n)); rf[i] = arr }
    }
    rowFr = rf
  }
  function resizeCol(i, dFr) {
    if (i < 0 || i >= colFr.length - 1) return
    var fr = colFr.slice()
    var a = fr[i] + dFr, b = fr[i + 1] - dFr
    if (a < 0.07 || b < 0.07) return
    fr[i] = a; fr[i + 1] = b
    colFr = fr
  }
  function resizeRow(col, j, dFr) {
    var rf = Object.assign({}, rowFr)
    var arr = (rf[col] || []).slice()
    if (j < 0 || j >= arr.length - 1) return
    var a = arr[j] + dFr, b = arr[j + 1] - dFr
    if (a < 0.08 || b < 0.08) return
    arr[j] = a; arr[j + 1] = b
    rf[col] = arr
    rowFr = rf
  }
  property var collapsed: ({})          // id -> bool
  property string dragPanel: ""         // id being dragged
  property var panelBoxes: ({})         // id -> item (geometry registry)
  property var dropSlot: null           // {x,y,w,h} indicator rect in content coords
  property var apilarTop: ({ x: 0, y: 0, w: 100, h: 50 })
  property var apilarBottom: ({ x: 0, y: 50, w: 100, h: 50 })
  // blocks: per-range layouts on the cut timeline; empty = single implicit block (global template)
  property var blocks: []
  property int selectedBlock: -1
  property var fgRegion: ({ x: 25, y: 25, w: 50, h: 50 })
  property real pipFx: 0.5
  property real pipFy: 0.72

  function layoutName() { return tplIndex === 1 ? "apilar" : (tplIndex === 2 ? "pip" : (tplIndex === 3 ? "circulo" : "completa")) }
  function activeLayout() { return selectedBlock >= 0 && blocks[selectedBlock] ? blocks[selectedBlock].layout : layoutName() }
  function activeBlock() { return selectedBlock >= 0 && blocks[selectedBlock] ? blocks[selectedBlock] : null }
  function cpBox(t) { return t ? ({ x: t.x, y: t.y, w: t.w, h: t.h }) : ({ x: 0, y: 0, w: 100, h: 100 }) }
  // fresh copies on purpose: returning live refs means the RegionEditor/Output
  // bindings see "same value" on in-place edits and never refresh (split slider,
  // output divider, inspector spins must move the boxes live)
  function activeBoxA() { var b = activeBlock(); if (b) return cpBox(b.layout === "apilar" ? b.regions.top : b.regions.main); return cpBox({ x: regionX, y: regionY, w: regionW, h: regionH }) }
  function activeBoxB() { var b = activeBlock(); if (b) return cpBox(b.layout === "apilar" ? b.regions.bottom : b.regions.fg); return cpBox(activeLayout() === "apilar" ? apilarBottom : fgRegion) }
  function setRegion(key, box) {
    box = { x: Math.round(box.x * 10) / 10, y: Math.round(box.y * 10) / 10, w: Math.round(box.w * 10) / 10, h: Math.round(box.h * 10) / 10 }
    var b = activeBlock()
    if (b) {
      var r = b.regions
      if (b.layout === "apilar") { if (key === "A") r.top = box; else r.bottom = box }
      else { if (key === "A") r.main = box; else r.fg = box }
      b.regions = r
      var cp = blocks.slice(); cp[selectedBlock] = b; blocks = cp
    } else {
      if (activeLayout() === "apilar") { if (key === "A") apilarTop = box; else apilarBottom = box }
      else if (key === "A") { regionX = box.x; regionY = box.y; regionW = box.w; regionH = box.h }
      else fgRegion = box
    }
  }
  function setSplit(f) {
    f = Math.max(0.15, Math.min(0.85, f))
    var b = activeBlock()
    if (b) { b.split = f; var cp = blocks.slice(); cp[selectedBlock] = b; blocks = cp }
    else split = f
  }
  function activeSplit() { var b = activeBlock(); return b ? (b.split || 0.5) : split }
  function mkBlock(st, en, lay) {
    var full = { x: 0, y: 0, w: 100, h: 100 }, cen = { x: 25, y: 25, w: 50, h: 50 }
    return { start: st, end: en, layout: lay, split: 0.5, fx: 0.5, fy: 0.72,
             regions: { main: full, top: full, bottom: { x: 0, y: 50, w: 100, h: 50 }, fg: cen } }
  }
  function ensureBlocks() {
    if (blocks.length) return
    blocks = [mkBlock(0, durS, layoutName())]
    selectedBlock = 0
  }
  function splitBlockAt(t) {
    ensureBlocks()
    var cp = blocks.slice()
    for (var i = 0; i < cp.length; i++) {
      var b = cp[i]
      if (t > b.start + 0.2 && t < b.end - 0.2) {
        var b1 = JSON.parse(JSON.stringify(b)), b2 = JSON.parse(JSON.stringify(b))
        b1.end = t; b2.start = t
        cp.splice(i, 1, b1, b2)
        blocks = cp; selectedBlock = i + 1
        return
      }
    }
  }
  function setBlockLayout(lay) {
    var b = activeBlock(); if (!b) { tplIndex = lay === "apilar" ? 1 : (lay === "pip" ? 2 : (lay === "circulo" ? 3 : 0)); return }
    b.layout = lay; var cp = blocks.slice(); cp[selectedBlock] = b; blocks = cp
  }
  function playheadBlock() {
    if (!blocks.length) return -1
    var t = playerRef ? playerRef.position / 1000 : 0
    for (var i = 0; i < blocks.length; i++)
      if (t >= blocks[i].start && t < blocks[i].end) return i
    return blocks.length - 1
  }
  function selectBlockAt(t) {
    if (!blocks.length) { selectedBlock = -1; return }
    for (var i = 0; i < blocks.length; i++)
      if (t >= blocks[i].start && t < blocks[i].end) { selectedBlock = i; return }
    selectedBlock = blocks.length - 1
  }
  property bool lock916: false
  property int srcW: 1920
  property int srcH: 1080

  function panelTitle(id) {
    return id === "fuentes" ? tt("sources")
         : id === "program" ? "PROGRAM"
         : id === "capas" ? tt("capasPanel")
         : id === "output" ? "OUTPUT"
         : id === "galeria" ? tt("outputs").toUpperCase()
         : id === "render" ? tt("render").toUpperCase()
         : "INSPECTOR"
  }
  // drop target for (gx, gy) in window content coords; returns {x,y,w,h,apply} slot
  function computeDrop(gx, gy) {
    var id = win.dragPanel
    for (var pid in panelBoxes) {
      if (pid === id) continue
      var it = panelBoxes[pid]
      if (!it) continue
      var pt = it.mapToItem(win.contentItem, 0, 0)
      var r = { x: pt.x, y: pt.y, w: it.width, h: it.height }
      if (gx < r.x || gx > r.x + r.w || gy < r.y || gy > r.y + r.h) continue
      // edge zones -> new column left/right
      if (gx < r.x + r.w * 0.18) return { x: r.x - 5, y: r.y, w: 4, h: r.h, target: { pid: pid, where: "left" } }
      if (gx > r.x + r.w * 0.82) return { x: r.x + r.w + 1, y: r.y, w: 4, h: r.h, target: { pid: pid, where: "right" } }
      if (gy < r.y + r.h / 2) return { x: r.x, y: r.y - 5, w: r.w, h: 4, target: { pid: pid, where: "above" } }
      return { x: r.x, y: r.y + r.h + 1, w: r.w, h: 4, target: { pid: pid, where: "below" } }
    }
    return null
  }
  function applyDrop(target) {
    var id = win.dragPanel
    if (!id || !target) return
    var d = dock.map(function (c) { return c.slice() })
    // remove from source
    for (var i = 0; i < d.length; i++) {
      var k = d[i].indexOf(id)
      if (k >= 0) d[i].splice(k, 1)
    }
    d = d.filter(function (c) { return c.length > 0 })
    // insert at target
    for (i = 0; i < d.length; i++) {
      var j = d[i].indexOf(target.pid)
      if (j < 0) continue
      if (target.where === "left")  { d.splice(i, 0, [id]); break }
      if (target.where === "right") { d.splice(i + 1, 0, [id]); break }
      if (target.where === "above") { d[i].splice(j, 0, id); break }
      if (target.where === "below") { d[i].splice(j + 1, 0, id); break }
    }
    dock = d
  }


  // ---------- render: dual-format export ----------
  function renderSource() { return win.cutPath !== "" ? win.cutPath : (win.current ? win.current.path : "") }
  function buildRenderSegments() {
    if (win.blocks.length) {
      return win.blocks.map(function (b) {
        return { start: b.start, end: b.end, layout: b.layout,
                 regions: b.layout === "apilar"
                   ? { top: b.regions.top, bottom: b.regions.bottom, split: b.split || 0.5 }
                   : (b.layout === "pip" || b.layout === "circulo")
                     ? { main: b.regions.main, fg: b.regions.fg, fx: b.fx || 0.5, fy: b.fy || 0.72 }
                     : { main: b.regions.main } }
      })
    }
    var lay = win.layoutName()
    var endS = win.cutPath !== "" ? win.durS() : (win.current ? win.current.duration : 0)
    return [{ start: 0, end: endS, layout: lay,
              regions: lay === "apilar" ? { top: win.apilarTop, bottom: win.apilarBottom, split: win.split }
                    : (lay === "pip" || lay === "circulo")
                      ? { main: { x: win.regionX, y: win.regionY, w: win.regionW, h: win.regionH }, fg: win.fgRegion, fx: win.pipFx, fy: win.pipFy }
                      : { main: { x: win.regionX, y: win.regionY, w: win.regionW, h: win.regionH } } }]
  }
  // space "out": layers use x,y,w,h (vertical canvas); space "prog": px,py,pw,ph (source frame)
  function doRender(w, h, space, suffix) {
    var src = win.renderSource()
    if (src === "") return
    engine.renderVertical({
      clipPath: src, template: win.layoutName(),
      regions: { main: { x: win.regionX, y: win.regionY, w: win.regionW, h: win.regionH } },
      layers: win.layers, srtPath: win.srtPath, segments: win.buildRenderSegments(),
      width: w, height: h, space: space, suffix: suffix,
      codec: ["h264", "h265", "vp9"][win.renderCodecIdx] || "h264",
      crf: [18, 23, 28][win.renderQualIdx] || 23,
      preset: ["medium", "veryfast", "veryfast"][win.renderQualIdx] || "veryfast"
    })
  }
  function startRender() {
    if (win.fmtV) win.doRender(1080, 1920, "out", "-v")
    if (win.fmtH) win.doRender(1920, 1080, "prog", "-h")
  }

  // ---------- project.json (AI-editable, live-reloaded) ----------
  property string lastSavedStr: ""
  function projectDoc() {
    return {
      version: 1, app: "omareel",
      video: win.current ? win.current.path : "",
      trim: { "in": Math.round(win.trimIn * 100) / 100, out: Math.round(win.trimOut * 100) / 100 },
      template: win.layoutName(),
      region: { x: win.regionX, y: win.regionY, w: win.regionW, h: win.regionH },
      lock916: win.lock916,
      editRegions: win.editRegions,
      apilar: { top: win.apilarTop, bottom: win.apilarBottom, split: Math.round(win.split * 1000) / 1000 },
      pip: { fg: win.fgRegion, fx: win.pipFx, fy: win.pipFy },
      layers: win.layers,
      blocks: win.blocks,
      srt: win.srtPath,
      render: { formats: (win.fmtV ? ["v"] : []).concat(win.fmtH ? ["h"] : []),
                codec: ["h264", "h265", "vp9"][win.renderCodecIdx],
                quality: ["high", "med", "low"][win.renderQualIdx] },
      dock: { columns: win.dock, colFr: win.colFr, rowFr: win.rowFr, collapsed: win.collapsed, tlHeight: win.tlHeight }
    }
  }
  function applyProject(d) {
    if (!d || !d.version) return
    if (d.trim) { win.trimIn = d.trim["in"] || 0; win.trimOut = d.trim.out || 1e9 }
    if (d.template) win.tplIndex = d.template === "apilar" ? 1 : (d.template === "pip" ? 2 : (d.template === "circulo" ? 3 : 0))
    if (d.region) { win.regionX = d.region.x; win.regionY = d.region.y; win.regionW = d.region.w; win.regionH = d.region.h }
    if (d.lock916 !== undefined) win.lock916 = !!d.lock916
    if (d.editRegions !== undefined) win.editRegions = !!d.editRegions
    if (d.apilar) { if (d.apilar.top) win.apilarTop = d.apilar.top; if (d.apilar.bottom) win.apilarBottom = d.apilar.bottom; if (d.apilar.split) win.split = d.apilar.split }
    if (d.pip) { if (d.pip.fg) win.fgRegion = d.pip.fg; if (d.pip.fx !== undefined) win.pipFx = d.pip.fx; if (d.pip.fy !== undefined) win.pipFy = d.pip.fy }
    if (d.layers) win.layers = d.layers
    if (d.blocks) { win.blocks = d.blocks; win.selectedBlock = d.blocks.length ? 0 : -1 }
    if (d.srt !== undefined) win.srtPath = d.srt
    if (d.render) {
      var fmts = d.render.formats || ["v"]
      win.fmtV = fmts.indexOf("v") >= 0
      win.fmtH = fmts.indexOf("h") >= 0
      var ci = ["h264", "h265", "vp9"].indexOf(d.render.codec || "")
      win.renderCodecIdx = ci >= 0 ? ci : 0
      var qi = ["high", "med", "low"].indexOf(d.render.quality || "")
      win.renderQualIdx = qi >= 0 ? qi : 1
    }
    if (d.dock) {
      if (d.dock.columns) win.dock = d.dock.columns
      // migration: ensure the render panel has a dock slot in old projects
      var hasRender = false
      for (var di = 0; di < win.dock.length; di++) if (win.dock[di].indexOf("render") >= 0) hasRender = true
      if (!hasRender) { var nd = win.dock.slice(); nd[nd.length - 1] = nd[nd.length - 1].concat(["render"]); win.dock = nd }
      if (d.dock.colFr) win.colFr = d.dock.colFr
      if (d.dock.rowFr) win.rowFr = d.dock.rowFr
      if (d.dock.collapsed) win.collapsed = d.dock.collapsed
      if (d.dock.tlHeight !== undefined) win.tlHeight = d.dock.tlHeight
      win.normalizeFr()
    }
    if (d.video && (!win.current || win.current.path !== d.video)) {
      for (var i = 0; i < win.sources.length; i++)
        if (win.sources[i].path === d.video) { win.current = win.sources[i]; win.cutPath = ""; loadVideo(d.video); break }
    }
  }
  Timer {
    id: saveTimer; interval: 1500; running: true; repeat: true
    onTriggered: {
      if (!win.current || win.view !== "edit") return
      var doc = win.projectDoc()
      var str = JSON.stringify(doc)
      if (str !== win.lastSavedStr) { win.lastSavedStr = str; engine.saveProject(doc) }
    }
  }


  Connections {
    target: engine
    function onProjectChangedExternally(doc) {
      win.lastSavedStr = JSON.stringify(doc)   // avoid immediate re-save loop
      win.applyProject(doc)
    }
  }

  function tt(k) { I18n.lang = engine.language; return I18n.t(k) }
  function refreshSources() {
    sources = engine.scanMedia()
    for (var i = 0; i < sources.length; i++) engine.requestThumb(sources[i].path)
  }
  function refreshOutputs() {
    outputs = engine.listOutputs()
    for (var i = 0; i < outputs.length; i++) engine.requestThumb(outputs[i].path)
  }
  function fmtDur(s) {
    s = Math.round(s); var h = Math.floor(s/3600), m = Math.floor(s%3600/60), ss = s%60
    return (h>0 ? h+":" : "") + String(m).padStart(2,"0") + ":" + String(ss).padStart(2,"0")
  }
  function fmtTc(s) {
    var m = Math.floor(s/60), ss = Math.floor(s%60), d = Math.floor((s%1)*10)
    return String(m).padStart(2,"0") + ":" + String(ss).padStart(2,"0") + "." + d
  }
  function fmtSize(b) {
    if (b > 1e9) return (b/1e9).toFixed(1) + " GB"
    if (b > 1e6) return Math.round(b/1e6) + " MB"
    return Math.round(b/1e3) + " KB"
  }
  function durS() { return playerRef && playerRef.duration > 0 ? playerRef.duration / 1000 : 0 }
  function loadVideo(path) {
    if (!playerRef) return
    playerRef.stop()
    win.videoPath = path
    playerRef.source = "file://" + path
    var pr = engine.probeVideo(path)
    if (pr.width) { win.srcW = pr.width; win.srcH = pr.height }
    trimIn = 0
    if (stripFor !== path) { stripUrls = []; stripFor = path; engine.requestStrip(path) }
    playTimer.restart()
  }
  Timer { id: playTimer; interval: 250; onTriggered: if (playerRef) playerRef.play() }

  property var playerRef: null
  property string videoPath: ""
  onPlayerRefChanged: if (playerRef && win.current && !playerRef.source.toString()) loadVideo(win.current.path)

  function patchLayer(i, patch) {
    var l = win.layers
    if (!l[i]) return
    if (patch.x !== undefined) l[i].x = Math.max(0, Math.min(1, patch.x))
    if (patch.y !== undefined) l[i].y = Math.max(0, Math.min(1, patch.y))
    // program/source-space coords (dual-format editing)
    if (patch.px !== undefined) l[i].px = Math.max(0, Math.min(1, patch.px))
    if (patch.py !== undefined) l[i].py = Math.max(0, Math.min(1, patch.py))
    if (patch.pw !== undefined) l[i].pw = Math.max(0, Math.min(1, patch.pw))
    if (patch.ph !== undefined) l[i].ph = Math.max(0, Math.min(1, patch.ph))
    if (patch.shape !== undefined) l[i].shape = patch.shape
    win.touchLayers()
  }
  function addLayer(type, path) {
    var l = win.layers.slice()
    if (type === "text")
      l.push({ type: "text", text: "", x: 0.5, y: 0.15, size: 90, color: "#ffffff", font: "", inS: win.trimIn, outS: win.trimOut })
    else
      l.push({ type: type, path: path || "", text: "", x: 0.5, y: 0.5, w: 0.35, h: 0.20, size: 90, color: "#ffffff", font: "", inS: win.trimIn, outS: win.trimOut })
    win.layers = l
    win.selectedLayer = l.length - 1
  }

  Component.onCompleted: {
    normalizeFr()
    refreshSources(); refreshOutputs()
    if (sources.length > 0) { win.current = sources[0]; loadVideo(sources[0].path) }
    var proj = engine.loadProject()
    if (proj && proj.version) { lastSavedStr = JSON.stringify(proj); applyProject(proj) }
    if (typeof uitest !== "undefined" && uitest) uitestTimer.restart()
  }

  Timer {
    id: uitestTimer; interval: 900
    onTriggered: {
      win.trimIn = 5; win.trimOut = 10; win.loop = true
      win.layers = [
        // dual-format: output 9:16 top-center, program/source bottom-left
        { type: "text", text: "Título de prueba", x: 0.5, y: 0.15, px: 0.15, py: 0.85, size: 90, color: "#ff9e64", font: "", inS: 5, outS: 10 },
        { type: "text", text: "Omareel 🔥", x: 0.5, y: 0.85, px: 0.5, py: 0.15, size: 60, color: "#9ece6a", font: "", inS: 6, outS: 9 }
      ]
      win.selectedLayer = 0
      if (typeof uitestOut !== "undefined" && uitestOut) { win.view = "out"; win.refreshOutputs(); return }
      if (typeof uitestDock !== "undefined" && uitestDock) {
        // collapsed inspector + reordered columns (program first)
        var c = {}; c["inspector"] = true; win.collapsed = c
        win.dock = [["program"], ["capas"], ["fuentes"], ["inspector"]]
      }
      if (typeof uitestBlocks !== "undefined" && uitestBlocks) {
        // blocks scenario: 3 blocks with different layouts, middle one selected (apilar)
        win.blocks = [
          win.mkBlock(0, 3, "completa"),
          win.mkBlock(3, 7, "apilar"),
          win.mkBlock(7, 10, "circulo")
        ]
        win.selectedBlock = 1
        win.split = 0.55
        // exercise the resize path (same functions the drag handles call)
        win.resizeCol(1, 0.10)   // widen PROGRAM+OUTPUT column
        win.resizeRow(1, 0, -0.18) // shrink PROGRAM, grow OUTPUT
      }
      if (playerRef) { playerRef.position = 6500; playerRef.play() }
      if (typeof uitestPause !== "undefined" && uitestPause) pauseProbeTimer.restart()
      if (typeof uitestRender !== "undefined" && uitestRender) { win.fmtV = true; win.fmtH = true; renderProbeTimer.restart() }
    }
  }
  // --uitest-render: deterministic dual-format render through the same path as the panel button
  Timer {
    id: renderProbeTimer; interval: 1500
    onTriggered: win.startRender()
  }
  // --uitest-pause: deterministic pause 2.6s in, through the same path as the UI
  Timer {
    id: pauseProbeTimer; interval: 2600
    onTriggered: if (playerRef) win.pausePlayback()
  }

  Connections {
    target: win.playerRef
    function onPositionChanged() {
      var t = playerRef.position / 1000
      if (win.blocks.length) { var bi = win.playheadBlock(); if (bi >= 0 && bi !== win.selectedBlock) win.selectedBlock = bi }
      // rewind BEFORE EndOfMedia: reaching the Stopped state clears the
      // VideoOutput (black monitor), so keep a safety margin
      if (playerRef.duration > 0 && t >= durS() - 0.25) {
        if (win.loop) { playerRef.position = Math.round(win.trimIn * 1000); if (playerRef.playbackState !== MediaPlayer.PlayingState) playerRef.play() }
        return
      }
      if (win.loop && playerRef.playbackState === MediaPlayer.PlayingState && t >= win.trimOut - 0.03)
        playerRef.position = Math.round(win.trimIn * 1000)
      if (playerRef.duration > 0 && win.trimOut > durS()) win.trimOut = durS()
    }
    function onDurationChanged() { if (win.trimOut <= 0.2 || win.trimOut > durS()) win.trimOut = durS() }
    function onPlaybackStateChanged() {
      if (playerRef.playbackState === MediaPlayer.StoppedState) {
        // EndOfMedia safety net (EOS raced past the position guard): Qt clears
        // the VideoOutput on Stopped. Rewind to the cut start, render one
        // brief play so the frame paints, then settle paused — never black.
        playerRef.position = Math.round(win.trimIn * 1000)
        playerRef.play()
        endPauseTimer.restart()
        return
      }
      if (playerRef.playbackState === MediaPlayer.PlayingState && playerRef.position >= playerRef.duration - 50)
        playerRef.position = Math.round(win.trimIn * 1000)
    }
  }
  Timer {
    id: endPauseTimer; interval: 90
    onTriggered: if (playerRef && playerRef.playbackState === MediaPlayer.PlayingState) win.pausePlayback()
  }

  Connections {
    target: engine
    function onThumbReady(videoPath, thumbUrl) {
      var s = sources.slice()
      for (var i = 0; i < s.length; i++) if (s[i].path === videoPath) s[i].thumb = thumbUrl
      sources = s
      var o = outputs.slice()
      for (var j = 0; j < o.length; j++) if (o[j].path === videoPath) o[j].thumb = thumbUrl
      outputs = o
    }
    function onStripReady(videoPath, urls) { if (videoPath === win.stripFor) win.stripUrls = urls }
    function onCutDone(clipId, clipPath, duration) { cutPath = clipPath; loadVideo(clipPath); trimOut = duration }
    function onRenderProgress(jobId, pct) {
      var j = jobs.slice(); var found = false
      for (var i = 0; i < j.length; i++) if (j[i].id === jobId) { j[i].pct = pct; j[i].status = "rendering"; found = true }
      if (!found) j.push({ id: jobId, status: "rendering", pct: pct, out: "" })
      jobs = j
    }
    function onRenderDone(jobId, outPath) {
      var j = jobs.slice()
      for (var i = 0; i < j.length; i++) if (j[i].id === jobId) { j[i].status = "done"; j[i].pct = 1; j[i].out = outPath }
      jobs = j; refreshOutputs()
    }
    function onTaskError(jobId, message) {
      var j = jobs.slice(); var found = false
      for (var i = 0; i < j.length; i++) if (j[i].id === jobId) { j[i].status = "error"; j[i].error = message; found = true }
      if (!found) j.push({ id: jobId, status: "error", pct: 0, error: message })
      jobs = j
    }
  }

  // Pause that keeps the current frame on screen. Qt Multimedia + GStreamer
  // flushes the sink on pause() and VideoOutput renders black; a 1ms micro-seek
  // forces a preroll of the frame at the current position while paused.
  function pausePlayback() {
    if (!playerRef) return
    playerRef.pause()
    playerRef.position = playerRef.position + 1
  }

  Shortcut { sequence: "Space"; onActivated: {
    if (!playerRef) return
    if (playerRef.playbackState === MediaPlayer.PlayingState) win.pausePlayback()
    else { if (playerRef.position >= playerRef.duration - 50) playerRef.position = Math.round(win.trimIn * 1000); playerRef.play() }
  } }
  Shortcut { sequence: "Left"; onActivated: if (playerRef) { playerRef.pause(); playerRef.position = Math.max(0, playerRef.position - 33) } }
  Shortcut { sequence: "Right"; onActivated: if (playerRef) { playerRef.pause(); playerRef.position = Math.min(playerRef.duration, playerRef.position + 33) } }
  Shortcut { sequence: "I"; onActivated: if (playerRef) win.trimIn = playerRef.position / 1000 }
  Shortcut { sequence: "O"; onActivated: if (playerRef) win.trimOut = playerRef.position / 1000 }
  Shortcut { sequence: "L"; onActivated: win.loop = !win.loop }

  // ---------- shared controls ----------
  component NleButton: Rectangle {
    property string text: ""
    property string tip: ""
    property bool active: false
    property bool accentBtn: false
    signal clicked()
    width: lbl.implicitWidth + 18; height: 28; radius: T.radius
    color: accentBtn ? T.accent : (active ? T.accentSoft : (ma.containsMouse ? "#2b3050" : T.panelAlt))
    border.color: accentBtn ? T.accent : (active ? T.accent : T.border)
    Label { id: lbl; anchors.centerIn: parent; text: parent.text; color: accentBtn ? "#16161e" : T.text; font.pixelSize: 11; font.bold: accentBtn }
    MouseArea { id: ma; anchors.fill: parent; hoverEnabled: true; onClicked: parent.clicked(); ToolTip.text: parent.tip; ToolTip.visible: hovered && parent.tip !== ""; ToolTip.delay: 500 }
  }
  component IconBtn: Rectangle {
    property string glyph: ""
    property string tip: ""
    property bool active: false
    signal clicked()
    width: 30; height: 30; radius: 15
    color: active ? T.accentSoft : (ma2.containsMouse ? "#2b3050" : "transparent")
    border.color: active ? T.accent : "transparent"
    Label { anchors.centerIn: parent; text: parent.glyph; color: parent.active ? T.accent : T.text; font.pixelSize: 13 }
    MouseArea { id: ma2; anchors.fill: parent; hoverEnabled: true; onClicked: parent.clicked(); ToolTip.text: parent.tip; ToolTip.visible: hovered && parent.tip !== ""; ToolTip.delay: 400 }
  }

  // ---------- panel content components ----------
  component FuentesContent: ColumnLayout {
    spacing: 8
    NleButton { text: "⬆ " + win.tt("importVideo"); Layout.fillWidth: true; onClicked: importDialog.open() }
    FileDialog {
      id: importDialog; fileMode: FileDialog.OpenFile
      nameFilters: ["Video (*.mp4 *.mkv *.mov *.webm)"]
      onAccepted: { engine.importVideo(selectedFile); win.refreshSources() }
    }
    ListView {
      Layout.fillWidth: true; Layout.fillHeight: true
      model: win.sources; spacing: 6; clip: true
      delegate: Rectangle {
        required property var modelData
        width: ListView.view.width; height: 58; radius: T.radius
        color: win.current && win.current.path === modelData.path ? T.accentSoft : (hov.containsMouse ? "#272c42" : T.panelAlt)
        border.color: win.current && win.current.path === modelData.path ? T.accent : T.borderSoft
        RowLayout {
          anchors.fill: parent; anchors.margins: 6; spacing: 8
          Image {
            Layout.preferredWidth: 76; Layout.preferredHeight: 44
            source: modelData.thumb || ""; fillMode: Image.PreserveAspectCrop
            Rectangle { anchors.fill: parent; color: "#000"; visible: parent.status !== Image.Ready; radius: 3 }
          }
          ColumnLayout { Layout.fillWidth: true; spacing: 2
            Label { text: modelData.title; color: T.text; elide: Label.ElideRight; Layout.fillWidth: true; font.pixelSize: 10 }
            Label { text: win.fmtDur(modelData.duration) + " · " + win.fmtSize(modelData.size); color: T.textMuted; font.pixelSize: 9; font.family: T.fontMono }
          }
        }
        MouseArea { id: hov; anchors.fill: parent; hoverEnabled: true; onClicked: { win.current = modelData; win.cutPath = ""; loadVideo(modelData.path) } }
      }
      Label { visible: win.sources.length === 0; text: win.tt("noSources"); color: T.textDim; wrapMode: Text.WordWrap; width: parent ? parent.width - 16 : 200 }
    }
  }

  component ProgramContent: ColumnLayout {
    spacing: 6
    Component.onCompleted: if (panelBox && panelBox.modelData === "program") win.playerRef = player
    Component.onDestruction: if (win.playerRef === player) win.playerRef = null
    Rectangle {
      Layout.fillWidth: true; Layout.fillHeight: true; color: "#000"; radius: 4; clip: true
      border.color: T.borderSoft
      VideoOutput { id: videoOut; anchors.fill: parent }
      Label { anchors.centerIn: parent; visible: !player.source.toString(); text: win.tt("preview"); color: T.textDim }
      MediaPlayer { id: player; videoOutput: videoOut }
      OverlayLayers {
        // pinned to the video frame: program-space fractions map to source pixels
        x: videoOut.contentRect.x; y: videoOut.contentRect.y
        width: videoOut.contentRect.width; height: videoOut.contentRect.height
        visible: videoOut.contentRect.width > 4 && videoOut.contentRect.height > 4
        layers: win.layers
        space: "prog"
        rev: win.layersRev
        refH: win.srcH
        position: playerRef ? playerRef.position / 1000 : 0
        playing: player.playbackState === MediaPlayer.PlayingState
        onLayerMoved: function (i, patch) { win.patchLayer(i, patch) }
        onLayerPressed: function (i) { win.selectedLayer = i }
      }
      RegionEditor {
        // pin to the ACTUAL video frame (contentRect), not the panel:
        // percent coords map exactly to source pixels, like the ffmpeg crop
        x: videoOut.contentRect.x; y: videoOut.contentRect.y
        width: videoOut.contentRect.width; height: videoOut.contentRect.height
        visible: videoOut.contentRect.width > 4 && videoOut.contentRect.height > 4 && win.editRegions
        mode: win.activeLayout() === "completa" ? 0 : 1
        showSplit: win.activeLayout() === "apilar"
        boxA: win.activeBoxA()
        boxB: win.activeBoxB()
        splitFrac: win.activeSplit()
        lock916: win.lock916
        srcW: win.srcW; srcH: win.srcH
        onBoxAEdited: function (b) { win.setRegion("A", b) }
        onBoxBEdited: function (b) { win.setRegion("B", b) }
        onSplitEdited: function (f) { win.setSplit(f) }
      }
      Rectangle {
        visible: win.loop; anchors.top: parent.top; anchors.right: parent.right; anchors.margins: 10
        width: loopLbl.width + 16; height: 22; radius: 11; color: T.accent
        Label { id: loopLbl; anchors.centerIn: parent; text: "A-B LOOP"; color: "#16161e"; font.pixelSize: 9; font.bold: true }
      }
    }
    Rectangle {
      Layout.fillWidth: true; height: 40; color: T.panelAlt; radius: T.radius; border.color: T.borderSoft
      RowLayout {
        anchors.fill: parent; anchors.leftMargin: 10; anchors.rightMargin: 10; spacing: 2
        IconBtn { glyph: "⏮"; tip: "Inicio"; onClicked: player.position = Math.round(win.trimIn * 1000) }
        IconBtn { glyph: "◂"; tip: "Frame -1 (←)"; onClicked: { player.pause(); player.position = Math.max(0, player.position - 33) } }
        Rectangle {
          width: 36; height: 36; radius: 18
          color: player.playbackState === MediaPlayer.PlayingState ? T.panel : T.play
          border.color: player.playbackState === MediaPlayer.PlayingState ? T.border : T.play
          Label { anchors.centerIn: parent; text: player.playbackState === MediaPlayer.PlayingState ? "⏸" : "▶"; color: player.playbackState === MediaPlayer.PlayingState ? T.text : "#16161e"; font.pixelSize: 15 }
          MouseArea { anchors.fill: parent; onClicked: {
            if (player.playbackState === MediaPlayer.PlayingState) win.pausePlayback()
            else { if (player.position >= player.duration - 50) player.position = Math.round(win.trimIn * 1000); player.play() }
          } }
        }
        IconBtn { glyph: "▸"; tip: "Frame +1 (→)"; onClicked: { player.pause(); player.position = Math.min(player.duration, player.position + 33) } }
        IconBtn { glyph: "⏭"; tip: "Fin"; onClicked: player.position = Math.round(win.trimOut * 1000) }
        Rectangle { width: 1; height: 18; color: T.border; Layout.leftMargin: 6; Layout.rightMargin: 6 }
        IconBtn { glyph: "🔁"; tip: "Loop A-B (L)"; active: win.loop; onClicked: win.loop = !win.loop }
        Item { Layout.fillWidth: true }
        Rectangle {
          height: 26; width: tc.width + 20; radius: 4; color: "#101116"; border.color: T.border
          Label { id: tc; anchors.centerIn: parent; text: win.fmtTc(player.position / 1000); color: T.good; font.pixelSize: 13; font.family: T.fontMono }
        }
        Label { text: "/ " + win.fmtTc(durS()); color: T.textMuted; font.pixelSize: 11; font.family: T.fontMono }
        Item { Layout.fillWidth: true }
        NleButton { text: "⟨ I"; tip: "Marcar entrada (I)"; onClicked: win.trimIn = player.position / 1000 }
        NleButton { text: "O ⟩"; tip: "Marcar salida (O)"; onClicked: win.trimOut = player.position / 1000 }
        NleButton { text: "✂B"; tip: "Split block at playhead"; onClicked: win.splitBlockAt(player.position / 1000) }
        NleButton { text: "B−"; tip: "Clear blocks"; enabled: win.blocks.length > 0; onClicked: { win.blocks = []; win.selectedBlock = -1 } }
        NleButton { text: "✂ " + win.tt("makeCut"); accentBtn: true; onClicked: if (win.current) engine.cut(win.cutPath || win.current.path, win.trimIn, win.trimOut) }
      }
    }
  }

  component CapasContent: ColumnLayout {
    spacing: 8
    RowLayout { Layout.fillWidth: true; spacing: 6
      NleButton { text: "🅣 " + win.tt("addText"); Layout.fillWidth: true; onClicked: win.addLayer("text") }
      NleButton { text: "GIF…"; Layout.fillWidth: true; onClicked: gifDialog.open() }
      NleButton { text: "🖼…"; Layout.fillWidth: true; tip: win.tt("addImage"); onClicked: imgDialog.open() }
      NleButton { text: "🎬…"; Layout.fillWidth: true; tip: win.tt("addVideo"); onClicked: vidDialog.open() }
    }
    FileDialog { id: vidDialog; fileMode: FileDialog.OpenFile; nameFilters: ["Video (*.mp4 *.mkv *.mov *.webm)"]; onAccepted: win.addLayer("video", String(selectedFile).replace("file://", "")) }
    FileDialog { id: gifDialog; fileMode: FileDialog.OpenFile; nameFilters: ["GIF (*.gif *.webp)"]; onAccepted: win.addLayer("gif", String(selectedFile).replace("file://", "")) }
    FileDialog { id: imgDialog; fileMode: FileDialog.OpenFile; nameFilters: ["Image (*.png *.jpg *.jpeg *.webp)"]; onAccepted: win.addLayer("image", String(selectedFile).replace("file://", "")) }
    RowLayout { Layout.fillWidth: true
      Label { text: win.tt("subtitles") + ":"; color: T.textMuted; font.pixelSize: 10 }
      Label { text: win.srtPath ? win.srtPath.split("/").pop() : win.tt("noSrt"); color: T.text; elide: Label.ElideMiddle; Layout.fillWidth: true; font.pixelSize: 10 }
      NleButton { text: "…"; onClicked: srtDialog.open() }
    }
    FileDialog { id: srtDialog; fileMode: FileDialog.OpenFile; nameFilters: ["Subtitles (*.srt *.vtt)"]; onAccepted: win.srtPath = String(selectedFile).replace("file://", "") }

    Rectangle { Layout.fillWidth: true; height: 1; color: T.border }

    // layer cards (reorderable)
    ListView {
      id: layerList
      Layout.fillWidth: true; Layout.fillHeight: true
      model: win.layers; spacing: 6; clip: true
      delegate: Rectangle {
        id: card
        required property int index
        required property var modelData
        property var cardLayer: modelData
        property int idx: index
        width: ListView.view.width; height: cardCol.implicitHeight + 12; radius: T.radius
        color: win.selectedLayer === index ? "#26332a" : T.panelAlt
        border.color: win.selectedLayer === index ? T.good : T.borderSoft
        ColumnLayout {
          id: cardCol; anchors.fill: parent; anchors.margins: 6; spacing: 4
          RowLayout { Layout.fillWidth: true
            Label {
              text: "≡"; color: T.textDim; font.pixelSize: 13
              MouseArea {
                anchors.fill: parent; cursorShape: Qt.SizeVerCursor
                property real startY: 0
                onPressed: startY = mapToItem(null, mouse.x, mouse.y).y
                onReleased: {
                  var dy = mapToItem(null, mouse.x, mouse.y).y - startY
                  var step = 90
                  var target = Math.max(0, Math.min(win.layers.length - 1, index + Math.round(dy / step)))
                  if (target !== index) {
                    var l = win.layers.slice()
                    var item = l.splice(index, 1)[0]
                    l.splice(target, 0, item)
                    win.layers = l
                    win.selectedLayer = target
                  }
                }
              }
            }
            Label {
              text: modelData.type === "text" ? "🅣" : (modelData.type === "gif" ? "GIF" : (modelData.type === "video" ? "🎬" : "🖼"))
              color: modelData.type === "video" ? T.orange : T.magenta; font.pixelSize: 10; font.bold: true
            }
            FnField {
              visible: modelData.type === "text"
              Layout.fillWidth: true; placeholderText: win.tt("textPlaceholder"); text: modelData.text
              // in-place update: reassigning win.layers rebuilds this Repeater and
              // steals focus on every keystroke
              onTextChanged: { win.layers[index].text = text; win.touchLayers() }
              onActiveFocusChanged: win.selectedLayer = index
            }
            Label {
              visible: modelData.type !== "text"
              Layout.fillWidth: true; elide: Label.ElideMiddle; font.pixelSize: 10; color: T.text
              text: modelData.path ? modelData.path.split("/").pop() : "…"
            }
            IconBtn { glyph: "✕"; onClicked: { var l = win.layers.slice(); l.splice(index, 1); win.layers = l; win.selectedLayer = -1 } }
          }
          RowLayout { Layout.fillWidth: true
            Label { text: modelData.type === "text" ? win.tt("fontSize") : "w%"; color: T.textDim; font.pixelSize: 10 }
            FnSpin {
              from: modelData.type === "text" ? 20 : 5; to: modelData.type === "text" ? 300 : 100
              value: modelData.type === "text" ? modelData.size : Math.round((modelData.w || 0.35) * 100)
              onValueChanged: { if (modelData.type === "text") win.layers[index].size = value; else { win.layers[index].w = value / 100; win.layers[index].h = value / 100 * 0.56 } win.touchLayers() }
            }
            Label { text: "y%"; color: T.textDim; font.pixelSize: 10 }
            FnSpin { from: 5; to: 95; value: Math.round(modelData.y * 100); onValueChanged: { win.layers[index].y = value / 100; win.touchLayers() } }
          }
          RowLayout {
            visible: card.cardLayer.type === "video"; Layout.fillWidth: true; spacing: 4
            Label { text: "forma"; color: T.textDim; font.pixelSize: 10 }
            Repeater {
              model: [["rect", "▢"], ["rounded", "⬒"], ["circle", "◯"]]
              delegate: Rectangle {
                required property var modelData
                property string shp: modelData[0]
                width: 26; height: 22; radius: 4
                color: (card.cardLayer.shape || "rect") === shp ? T.accentSoft : T.panelDeep
                border.color: (card.cardLayer.shape || "rect") === shp ? T.accent : T.border
                Label { anchors.centerIn: parent; text: modelData[1]; color: (card.cardLayer.shape || "rect") === shp ? T.accent : T.textMuted; font.pixelSize: 12 }
                MouseArea { anchors.fill: parent; onClicked: win.patchLayer(card.idx, { shape: shp }) }
              }
            }
            Item { Layout.fillWidth: true }
          }
          Label { text: "⏱ " + win.fmtTc(modelData.inS) + " → " + win.fmtTc(modelData.outS); color: T.textMuted; font.pixelSize: 9; font.family: T.fontMono }
        }
        // click anywhere on the card focuses the layer (kept below child controls)
        MouseArea {
          anchors.fill: parent; z: -1
          onClicked: win.selectedLayer = index
        }
      }
      Connections {
        target: win
        function onSelectedLayerChanged() {
          if (win.selectedLayer >= 0 && win.selectedLayer < win.layers.length)
            layerList.positionViewAtIndex(win.selectedLayer, ListView.Contain)
        }
      }
      Label { anchors.centerIn: parent; visible: win.layers.length === 0; text: "+"; color: T.textDim; font.pixelSize: 24 }
    }
  }

  component RenderContent: ColumnLayout {
    spacing: 8
    property var codecNames: ["H.264 (MP4)", "H.265 / HEVC (MP4)", "VP9 (MP4)"]
    property var qualNames: [win.tt("qualHigh"), win.tt("qualMed"), win.tt("qualLow")]
    Label { text: win.tt("renderFormats").toUpperCase(); color: T.textDim; font.pixelSize: 9; font.bold: true; font.letterSpacing: 1 }
    Rectangle { Layout.fillWidth: true; height: 28; radius: T.radius; color: T.panelDeep; border.color: T.border
      RowLayout { anchors.fill: parent; anchors.leftMargin: 8; anchors.rightMargin: 8; spacing: 8
        Rectangle { width: 16; height: 16; radius: 4; border.color: T.border; color: win.fmtV ? T.accent : T.panelDeep
          Label { anchors.centerIn: parent; text: "✓"; color: "#16161e"; font.pixelSize: 10; visible: win.fmtV }
          MouseArea { anchors.fill: parent; onClicked: win.fmtV = !win.fmtV } }
        Label { text: win.tt("fmtVertical"); color: T.text; font.pixelSize: 11; Layout.fillWidth: true; elide: Label.ElideRight }
        Label { text: "OUT"; color: T.textMuted; font.pixelSize: 9; font.family: T.fontMono }
      }
    }
    Rectangle { Layout.fillWidth: true; height: 28; radius: T.radius; color: T.panelDeep; border.color: T.border
      RowLayout { anchors.fill: parent; anchors.leftMargin: 8; anchors.rightMargin: 8; spacing: 8
        Rectangle { width: 16; height: 16; radius: 4; border.color: T.border; color: win.fmtH ? T.accent : T.panelDeep
          Label { anchors.centerIn: parent; text: "✓"; color: "#16161e"; font.pixelSize: 10; visible: win.fmtH }
          MouseArea { anchors.fill: parent; onClicked: win.fmtH = !win.fmtH } }
        Label { text: win.tt("fmtHorizontal"); color: T.text; font.pixelSize: 11; Layout.fillWidth: true; elide: Label.ElideRight }
        Label { text: "PROG"; color: T.textMuted; font.pixelSize: 9; font.family: T.fontMono }
      }
    }
    RowLayout { Layout.fillWidth: true; spacing: 6
      Label { text: win.tt("codec"); color: T.textDim; font.pixelSize: 10 }
      FnCombo { Layout.fillWidth: true; model: codecNames; currentIndex: win.renderCodecIdx; onActivated: win.renderCodecIdx = currentIndex }
    }
    RowLayout { Layout.fillWidth: true; spacing: 6
      Label { text: win.tt("qual"); color: T.textDim; font.pixelSize: 10 }
      FnCombo { Layout.fillWidth: true; model: qualNames; currentIndex: win.renderQualIdx; onActivated: win.renderQualIdx = currentIndex }
    }
    NleButton {
      Layout.fillWidth: true; text: win.tt("renderStart")
      enabled: win.renderSource() !== "" && (win.fmtV || win.fmtH)
      accentBtn: win.renderSource() !== "" && (win.fmtV || win.fmtH)
      onClicked: win.startRender()
    }
    Label { visible: win.renderSource() === ""; text: win.tt("needSource"); color: T.textDim; font.pixelSize: 10 }
    Rectangle { Layout.fillWidth: true; height: 1; color: T.border }
    ColumnLayout { Layout.fillWidth: true; spacing: 4
      Label { text: win.tt("jobs").toUpperCase() + "  (" + win.jobs.length + ")"; color: T.textDim; font.pixelSize: 9; font.bold: true; font.letterSpacing: 1 }
      Repeater {
        model: win.jobs
        delegate: ColumnLayout {
          required property var modelData
          Layout.fillWidth: true; spacing: 2
          RowLayout { Layout.fillWidth: true
            Label { text: modelData.id.slice(0, 8); color: T.text; font.pixelSize: 9; font.family: T.fontMono }
            Item { Layout.fillWidth: true }
            Label { text: modelData.status === "done" ? win.tt("done") : (modelData.status === "error" ? win.tt("error") : win.tt("rendering")); color: modelData.status === "done" ? T.good : (modelData.status === "error" ? T.bad : T.warn); font.pixelSize: 9 }
          }
          ProgressBar { Layout.fillWidth: true; value: modelData.pct }
        }
      }
      Item { Layout.fillHeight: true }
    }
  }

  component InspectorContent: ColumnLayout {
    spacing: 10
    ColumnLayout { Layout.fillWidth: true; spacing: 6
      Label { text: "FORMATO"; color: T.textDim; font.pixelSize: 9; font.bold: true; font.letterSpacing: 1 }
      Rectangle {
        Layout.fillWidth: true; height: 30; radius: T.radius; color: T.panelDeep; border.color: T.border
        Label { anchors.centerIn: parent; text: "Vertical 9:16 · 1080×1920"; color: T.text; font.pixelSize: 11 }
      }
      Label { text: win.tt("template").toUpperCase(); color: T.textDim; font.pixelSize: 9; font.bold: true; font.letterSpacing: 1 }
      Label { visible: win.selectedBlock >= 0; text: "BLOQUE " + (win.selectedBlock + 1) + " · " + win.fmtDur(win.blocks[win.selectedBlock] ? win.blocks[win.selectedBlock].end - win.blocks[win.selectedBlock].start : 0); color: T.orange; font.pixelSize: 9; font.bold: true }
      FnCombo { Layout.fillWidth: true; model: [win.tt("tplCompleta"), win.tt("tplApilar"), "PiP", "Círculo"]
        currentIndex: { var l = win.activeLayout(); return l === "apilar" ? 1 : (l === "pip" ? 2 : (l === "circulo" ? 3 : 0)) }
        onActivated: win.setBlockLayout(["completa", "apilar", "pip", "circulo"][currentIndex]) }
      NleButton {
        Layout.fillWidth: true; accentBtn: win.editRegions
        text: (win.editRegions ? "◉ " : "○ ") + win.tt("editFrames")
        tip: win.tt("editFramesTip")
        onClicked: win.editRegions = !win.editRegions
      }
      RowLayout {
        visible: win.activeLayout() === "pip" || win.activeLayout() === "circulo"; Layout.fillWidth: true
        Label { text: "x/y"; color: T.textDim }
        Slider { Layout.fillWidth: true; from: 0; to: 1; value: { var b = win.activeBlock(); return b ? (b.fx || 0.5) : win.pipFx }
                 onMoved: { var b = win.activeBlock(); if (b) { b.fx = value; var cp = win.blocks.slice(); cp[win.selectedBlock] = b; win.blocks = cp } else win.pipFx = value } }
        Slider { Layout.fillWidth: true; from: 0; to: 1; value: { var b = win.activeBlock(); return b ? (b.fy || 0.72) : win.pipFy }
                 onMoved: { var b = win.activeBlock(); if (b) { b.fy = value; var cp = win.blocks.slice(); cp[win.selectedBlock] = b; win.blocks = cp } else win.pipFy = value } }
      }
      GridLayout {
        visible: win.activeLayout() !== "apilar"; columns: 4; Layout.fillWidth: true
        Label { text: "x"; color: T.textDim } FnSpin { from: 0; to: 100; value: win.regionX; onValueModified: win.regionX = value; Layout.fillWidth: true }
        Label { text: "y"; color: T.textDim } FnSpin { from: 0; to: 100; value: win.regionY; onValueModified: win.regionY = value; Layout.fillWidth: true }
        Label { text: "w"; color: T.textDim } FnSpin { from: 1; to: 100; value: win.regionW; onValueModified: win.regionW = value; Layout.fillWidth: true }
        Label { text: "h"; color: T.textDim } FnSpin { from: 1; to: 100; value: win.regionH; onValueModified: win.regionH = value; Layout.fillWidth: true }
      }
      RowLayout {
        visible: win.activeLayout() !== "apilar"
        Rectangle {
          width: 16; height: 16; radius: 4; border.color: T.border; color: win.lock916 ? T.accent : T.panelDeep
          Label { anchors.centerIn: parent; text: "✓"; color: "#16161e"; font.pixelSize: 10; visible: win.lock916 }
          MouseArea { anchors.fill: parent; onClicked: win.lock916 = !win.lock916 }
        }
        Label { text: "9:16"; color: T.textMuted; font.pixelSize: 10 }
      }
      RowLayout {
        visible: win.activeLayout() === "apilar"; Layout.fillWidth: true
        Label { text: win.tt("split"); color: T.textDim }
        Slider { Layout.fillWidth: true; from: 0.15; to: 0.85; value: win.activeSplit(); onValueChanged: win.setSplit(value) }
        Label { text: Math.round(win.activeSplit() * 100) + "%"; color: T.textMuted; font.family: T.fontMono; font.pixelSize: 10 }
      }
    }
    Item { Layout.fillHeight: true }
  }

  component OutputContent: Item {
    OutputPreview {
      anchors.fill: parent; anchors.margins: 6
      videoPath: win.videoPath
      position: win.playerRef ? win.playerRef.position / 1000 : 0
      playing: win.playerRef ? win.playerRef.playbackState === MediaPlayer.PlayingState : false
      layout: win.activeLayout()
      mainRegion: win.activeBoxA()
      topRegion: win.activeLayout() === "apilar" ? win.activeBoxA() : ({ x: 0, y: 0, w: 100, h: 100 })
      bottomRegion: win.activeLayout() === "apilar" ? win.activeBoxB() : ({ x: 0, y: 50, w: 100, h: 50 })
      fgRegion: win.activeBoxB()
      pipFx: { var b = win.activeBlock(); return b ? (b.fx || 0.5) : win.pipFx }
      pipFy: { var b = win.activeBlock(); return b ? (b.fy || 0.72) : win.pipFy }
      splitFrac: win.activeSplit()
      layers: win.layers
      layersRev: win.layersRev
      srcW: win.srcW; srcH: win.srcH
      onSplitEdited: function (f) { win.setSplit(f) }
      onLayerMoved: function (i, patch) { win.patchLayer(i, patch) }
      onLayerPressed: function (i) { win.selectedLayer = i }
    }
  }

  component OutputsContent: Item {
    GridView {
      anchors.fill: parent; anchors.margins: 4
      model: win.outputs
      cellWidth: 156; cellHeight: 260; clip: true
      delegate: Rectangle {
        required property var modelData
        width: 146; height: 250; radius: T.radius
        color: oh2.containsMouse ? "#272c42" : T.panelAlt; border.color: T.borderSoft
        ColumnLayout {
          anchors.fill: parent; anchors.margins: 8; spacing: 6
          Image {
            Layout.fillWidth: true; Layout.preferredHeight: 158
            source: modelData.thumb || ""; fillMode: Image.PreserveAspectCrop
            Rectangle { anchors.fill: parent; color: "#000"; visible: parent.status !== Image.Ready; radius: 3 }
          }
          Label { text: modelData.name.slice(0, 14) + "…"; color: T.text; font.pixelSize: 10; font.family: T.fontMono; Layout.fillWidth: true }
          Label { text: win.fmtSize(modelData.size); color: T.textMuted; font.pixelSize: 9; font.family: T.fontMono }
          RowLayout { Layout.fillWidth: true; spacing: 4
            IconBtn { glyph: "▶"; tip: win.tt("playOutput"); onClicked: { win.view = "edit"; loadVideo(modelData.path) } }
            IconBtn { glyph: "📂"; tip: win.tt("openFolder"); onClicked: engine.openFolder(modelData.path) }
            Item { Layout.fillWidth: true }
            IconBtn { glyph: "🗑"; tip: win.tt("deleteSource"); onClicked: { engine.deleteMedia(modelData.path); win.refreshOutputs() } }
          }
        }
        MouseArea { id: oh2; anchors.fill: parent; hoverEnabled: true; z: -1 }
      }
    }
    Label { anchors.centerIn: parent; visible: win.outputs.length === 0; text: win.tt("noOutputs"); color: T.textDim }
  }

  // ---------- header ----------
  header: Rectangle {
    height: 44; color: T.panelAlt
    Rectangle { anchors.bottom: parent.bottom; width: parent.width; height: 1; color: T.border }
    RowLayout {
      anchors.fill: parent; anchors.leftMargin: 14; anchors.rightMargin: 14
      Label { text: "OMAREEL"; color: T.text; font.pixelSize: 14; font.bold: true; font.letterSpacing: 2 }
      Rectangle { width: 1; height: 18; color: T.border }
      Label { text: win.current ? win.current.title : ""; color: T.textMuted; font.pixelSize: 11; elide: Text.ElideMiddle; Layout.maximumWidth: 320 }
      Item { Layout.fillWidth: true }
      Row {
        spacing: 0
        Rectangle {
          width: et1.width + 22; height: 28; radius: T.radius
          color: win.view === "edit" ? T.accentSoft : "transparent"; border.color: win.view === "edit" ? T.accent : T.border
          Label { id: et1; anchors.centerIn: parent; text: win.tt("viewEdit"); color: win.view === "edit" ? T.accent : T.textMuted; font.pixelSize: 11; font.bold: win.view === "edit" }
          MouseArea { anchors.fill: parent; onClicked: win.view = "edit" }
        }
        Item { width: 6; height: 1 }
        Rectangle {
          width: et2.width + 22; height: 28; radius: T.radius
          color: win.view === "out" ? T.accentSoft : "transparent"; border.color: win.view === "out" ? T.accent : T.border
          Label { id: et2; anchors.centerIn: parent; text: win.tt("viewOutputs"); color: win.view === "out" ? T.accent : T.textMuted; font.pixelSize: 11; font.bold: win.view === "out" }
          MouseArea { anchors.fill: parent; onClicked: { win.view = "out"; win.refreshOutputs() } }
        }
      }
      Item { Layout.fillWidth: true }
      Label { visible: win.view === "edit"; text: "␣ play · ←→ frame · I/O · L loop"; color: T.textDim; font.pixelSize: 10 }
      Item { Layout.fillWidth: true }
      NleButton { text: "⊞ " + win.tt("panels"); onClicked: panelsPopup.open() }
      NleButton { text: win.tt("langButton"); onClicked: engine.language = engine.language === "es" ? "en" : "es" }
    }

    // panel manager: show/hide any panel (restore closed ones)
    Popup {
      id: panelsPopup
      parent: Overlay.overlay
      x: parent.width - width - 12; y: 48
      padding: 6
      closePolicy: Popup.CloseOnEscape | Popup.CloseOnPressOutside
      background: Rectangle { color: T.panel; border.color: T.border; radius: T.radius }
      contentItem: ColumnLayout {
        spacing: 2
        Label { text: win.tt("panels").toUpperCase(); color: T.textDim; font.pixelSize: 9; font.bold: true; font.letterSpacing: 1.2; Layout.leftMargin: 6; Layout.topMargin: 4 }
        Repeater {
          model: win.allPanels
          delegate: Rectangle {
            id: prow
            required property string modelData
            Layout.preferredWidth: 190; Layout.preferredHeight: 28; radius: 4
            color: pma.containsMouse ? "#2b3050" : "transparent"
            property bool checked: !win.hidden[modelData]
            RowLayout {
              anchors.fill: parent; anchors.leftMargin: 8; anchors.rightMargin: 8; spacing: 8
              Rectangle {
                width: 14; height: 14; radius: 3
                color: prow.checked ? T.accent : T.panelDeep
                border.color: prow.checked ? T.accent : T.border
                Label { anchors.centerIn: parent; text: "✓"; color: "#16161e"; font.pixelSize: 9; visible: prow.checked }
              }
              Label { text: win.panelTitle(modelData); color: T.text; font.pixelSize: 11 }
            }
            MouseArea {
              id: pma; anchors.fill: parent; hoverEnabled: true
              onClicked: win.setPanelHidden(modelData, !win.hidden[modelData])
            }
          }
        }
      }
    }
  }

  // ---------- body ----------
  ColumnLayout {
    anchors.fill: parent; anchors.margins: 8; spacing: 8

    // dockable panels: columns of vertically-stacked panels
    RowLayout {
      id: dockRow
      visible: win.view === "edit"
      Layout.fillWidth: true; Layout.fillHeight: true; spacing: 8

      Repeater {
        model: win.visibleDock()
        delegate: Item {
          id: dockColWrap
          required property int index
          required property var modelData
          Layout.fillHeight: true
          Layout.fillWidth: true
          Layout.preferredWidth: (win.colFr[dockColWrap.index] || 0.25) * 1000

          ColumnLayout {
          id: dockCol
          anchors.fill: parent
          spacing: 8
          property int colIndex: dockColWrap.index

          Repeater {
            model: dockColWrap.modelData
            delegate: Panel {
              id: panelBox
              required property int index
              required property string modelData
              property bool isCollapsed: !!win.collapsed[modelData]
              Layout.fillWidth: true
              Layout.fillHeight: true
              Layout.preferredHeight: isCollapsed ? 40 : ((win.rowFr[dockCol.colIndex] || [])[panelBox.index] || 0.5) * 1000
              Layout.maximumHeight: isCollapsed ? 40 : 100000
              Layout.minimumHeight: isCollapsed ? 40 : 60
              title: win.panelTitle(modelData)
              collapsible: true
              collapsed: isCollapsed
              onCollapseToggled: { var c = Object.assign({}, win.collapsed); c[modelData] = !isCollapsed; win.collapsed = c }
              closable: true
              onCloseRequested: win.setPanelHidden(modelData, true)
              panelId: modelData
              onHeaderDragStart: win.dragPanel = modelData
              onHeaderDragMove: function (gx, gy) {
                dragGhost.x = gx - dragGhost.width / 2; dragGhost.y = gy - 15
                win.dropSlot = win.computeDrop(gx, gy)
              }
              onHeaderDragEnd: function (gx, gy) {
                var slot = win.computeDrop(gx, gy)
                if (slot) win.applyDrop(slot.target)
                win.dropSlot = null
                win.dragPanel = ""
              }
              Component.onCompleted: { win.panelBoxes[modelData] = panelBox }
              Component.onDestruction: { delete win.panelBoxes[modelData] }

              FuentesContent { anchors.fill: parent; anchors.margins: 8; visible: modelData === "fuentes" }
              ProgramContent { anchors.fill: parent; anchors.margins: 8; visible: modelData === "program" }
              CapasContent { anchors.fill: parent; anchors.margins: 8; visible: modelData === "capas" }
              InspectorContent { anchors.fill: parent; anchors.margins: 10; visible: modelData === "inspector" }
              RenderContent { anchors.fill: parent; anchors.margins: 10; visible: modelData === "render" }
              OutputContent { anchors.fill: parent; visible: modelData === "output" }
              OutputsContent { anchors.fill: parent; visible: modelData === "galeria" }

              // row resize handle (bottom edge, between stacked panels)
              Rectangle {
                visible: !panelBox.isCollapsed && panelBox.index < dockColWrap.modelData.length - 1
                         && !win.collapsed[dockColWrap.modelData[panelBox.index + 1]]
                anchors.left: parent.left; anchors.right: parent.right; anchors.bottom: parent.bottom
                anchors.bottomMargin: -6
                height: 12; z: 30; color: "transparent"
                Rectangle { anchors.centerIn: parent; width: parent.width; height: 3; radius: 1.5
                            color: rma.containsMouse || rma.pressed ? T.accent : T.border }
                MouseArea {
                  id: rma; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.SizeVerCursor
                  property real startY: 0
                  onPressed: startY = mapToItem(dockRow, mouse.x, mouse.y).y
                  onPositionChanged: if (pressed) {
                    var y = mapToItem(dockRow, mouse.x, mouse.y).y
                    win.resizeRow(dockCol.colIndex, panelBox.index, (y - startY) / Math.max(1, dockCol.height))
                    startY = y
                  }
                }
              }
            }
          }
          }

          // column resize handle (right edge, between columns)
          Rectangle {
            visible: dockColWrap.index < win.dock.length - 1
            anchors.right: parent.right; anchors.top: parent.top; anchors.bottom: parent.bottom
            anchors.rightMargin: -6
            width: 12; z: 30; color: "transparent"
            Rectangle { anchors.centerIn: parent; width: 3; height: parent.height; radius: 1.5
                        color: cma.containsMouse || cma.pressed ? T.accent : T.border }
            MouseArea {
              id: cma; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.SizeHorCursor
              property real startX: 0
              onPressed: startX = mapToItem(dockRow, mouse.x, mouse.y).x
              onPositionChanged: if (pressed) {
                var x = mapToItem(dockRow, mouse.x, mouse.y).x
                win.resizeCol(dockColWrap.index, (x - startX) / Math.max(1, dockRow.width))
                startX = x
              }
            }
          }
        }
      }
    }

    // outputs mode
    Panel {
      visible: win.view === "out"
      Layout.fillWidth: true; Layout.fillHeight: true
      title: win.tt("viewOutputs")
      OutputsContent { anchors.fill: parent; anchors.margins: 4 }
    }

    // timeline resize handle (timeline stays pinned to the bottom, vertical resize only)
    Rectangle {
      visible: win.view === "edit"
      Layout.fillWidth: true; Layout.preferredHeight: 7; color: "transparent"
      Rectangle { anchors.centerIn: parent; width: 64; height: 3; radius: 1.5
                  color: tlma.containsMouse || tlma.pressed ? T.accent : T.border }
      MouseArea {
        id: tlma; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.SizeVerCursor
        property real startY: 0; property real startH: 0
        onPressed: { startY = mapToItem(win.contentItem, mouse.x, mouse.y).y; startH = timeline.height }
        onPositionChanged: if (pressed) {
          var y = mapToItem(win.contentItem, mouse.x, mouse.y).y
          win.tlHeight = Math.max(120, Math.min(win.height * 0.7, startH - (y - startY)))
        }
      }
    }
    // timeline (pinned to bottom)
    Timeline {
      id: timeline
      visible: win.view === "edit"
      Layout.fillWidth: true
      Layout.preferredHeight: win.tlHeight > 0 ? win.tlHeight : 216 + win.layers.length * 29
      duration: Math.max(0.1, durS())
      position: playerRef ? playerRef.position / 1000 : 0
      trimIn: win.trimIn; trimOut: win.trimOut
      stripUrls: win.stripUrls
      layers: win.layers
      selectedLayer: win.selectedLayer
      blocks: win.blocks
      selectedBlock: win.selectedBlock
      onSeek: function (t) { if (playerRef) playerRef.position = Math.round(t * 1000); if (win.blocks.length) win.selectBlockAt(t) }
      onBlockClicked: function (i) { win.selectedBlock = i }
      onBlockEdited: function (i, patch) {
        var cp = win.blocks.slice(); var b = cp[i]; if (!b) return
        if (patch.start !== undefined) b.start = patch.start
        if (patch.end !== undefined) b.end = patch.end
        // clamp into neighbors
        if (i > 0 && b.start < cp[i-1].end) cp[i-1].end = b.start
        if (i < cp.length - 1 && b.end > cp[i+1].start) cp[i+1].start = b.end
        win.blocks = cp
      }
      onTrimEdited: function (a, b) { win.trimIn = a; win.trimOut = b }
      onLayerEdited: function (i, a, b) { win.layers[i].inS = a; win.layers[i].outS = b; win.touchLayers() }
      onLayerClicked: function (i) { win.selectedLayer = i }
      onLayerMoved: function (from, to) {
        var l = win.layers.slice()
        var it = l.splice(from, 1)[0]
        l.splice(to, 0, it)
        win.layers = l
        win.selectedLayer = to
      }
    }
  }

  // drop target indicator
  Rectangle {
    visible: win.dropSlot !== null && win.dragPanel !== ""
    x: win.dropSlot ? win.dropSlot.x : 0; y: win.dropSlot ? win.dropSlot.y : 0
    width: win.dropSlot ? win.dropSlot.w : 0; height: win.dropSlot ? win.dropSlot.h : 0
    color: T.accent; radius: 2; z: 99
  }

  // drag ghost overlay
  Rectangle {
    id: dragGhost
    visible: win.dragPanel !== ""
    width: ghostLbl.width + 24; height: 30; radius: T.radius
    color: T.accentSoft; border.color: T.accent; opacity: 0.9; z: 100
    y: 60
    Label { id: ghostLbl; anchors.centerIn: parent; text: win.dragPanel.toUpperCase(); color: T.text; font.pixelSize: 11; font.bold: true }
  }
}
