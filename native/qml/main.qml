// main.qml - OmaShort Native: NLE layout with dockable/collapsible panels
import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import QtQuick.Dialogs
import QtMultimedia
import "I18n.js" as I18n
import "Theme.js" as T
import "CropGeometry.js" as Crop
import "Keyframes.js" as Keyframes

ApplicationWindow {
  id: win
  width: 1440; height: 900; minimumWidth: 1024; minimumHeight: 640
  visible: true
  title: "OmaShort"
  color: engine.theme.app

  // ---- state ----
  property var sources: []
  property var outputs: []
  property var current: null
  property bool primaryAudioEnabled: true
  property string cutPath: ""
  property var jobs: []
  property var layers: []
  // bump on in-place layer edits (text, pos, size, timing): array identity stays
  // stable so editors keep focus, previews refresh via `rev` dependencies
  property int layersRev: 0
  function touchLayers() { layersRev = (layersRev + 1) % 2000000000 }
  property string srtPath: ""
  property string subtitleMode: "normal" // normal = fixed SRT; reel = editable text layers
  property string subtitleStatus: ""
  property real split: 0.5
  property bool editRegions: false   // zone/marco editing in Program (toggle from Inspector)
  property bool loop: false
  property var stripUrls: []
  property string stripFor: ""
  property real trimIn: 0
  property real trimOut: 1
  property int selectedLayer: -1
  property string keyframeEasing: "easeInOut"
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
  property int blocksRev: 0
  property int selectedBlock: -1
  property var fgRegion: ({ x: 25, y: 25, w: 50, h: 50 })
  property real pipFx: 0.5
  property real pipFy: 0.72

  function layoutName() { return tplIndex === 1 ? "apilar" : (tplIndex === 2 ? "pip" : (tplIndex === 3 ? "circulo" : "completa")) }
  function activeLayout() { blocksRev; return selectedBlock >= 0 && blocks[selectedBlock] ? blocks[selectedBlock].layout : layoutName() }
  function activeBlock() { blocksRev; return selectedBlock >= 0 && blocks[selectedBlock] ? blocks[selectedBlock] : null }
  function cpBox(t) { return t ? ({ x: t.x, y: t.y, w: t.w, h: t.h }) : ({ x: 0, y: 0, w: 100, h: 100 }) }
  // fresh copies on purpose: returning live refs means the RegionEditor/Output
  // bindings see "same value" on in-place edits and never refresh (split slider,
  // output divider, inspector spins must move the boxes live)
  function regionAspect(lay, key, splitValue) {
    if (lay === "apilar") {
      var f = key === "A" ? splitValue : 1 - splitValue
      return (9 / 16) / Math.max(0.15, Math.min(0.85, f))
    }
    if (key === "B") return 1 // PiP/round foreground output is square
    return 9 / 16             // full vertical background/output
  }
  function fittedRegion(lay, key, box, splitValue) {
    return Crop.fit(cpBox(box), regionAspect(lay, key, splitValue), srcW, srcH)
  }
  function activeBoxA() {
    var b = activeBlock(), lay = activeLayout(), raw = b ? (lay === "apilar" ? b.regions.top : b.regions.main)
                                                        : (lay === "apilar" ? apilarTop : { x: regionX, y: regionY, w: regionW, h: regionH })
    return fittedRegion(lay, "A", raw, activeSplit())
  }
  function activeBoxB() {
    var b = activeBlock(), lay = activeLayout(), raw = b ? (lay === "apilar" ? b.regions.bottom : b.regions.fg)
                                                        : (lay === "apilar" ? apilarBottom : fgRegion)
    return fittedRegion(lay, "B", raw, activeSplit())
  }
  function setRegion(key, box) {
    box = fittedRegion(activeLayout(), key, box, activeSplit())
    var b = activeBlock()
    if (b) {
      var r = b.regions
      if (b.layout === "apilar") {
        if (key === "A") r.top = box; else r.bottom = box
      }
      else { if (key === "A") r.main = box; else r.fg = box }
      b.regions = r
      var cp = blocks.slice(); cp[selectedBlock] = b; blocks = cp; blocksRev = (blocksRev + 1) % 2000000000
    } else {
      if (activeLayout() === "apilar") {
        if (key === "A") apilarTop = box; else apilarBottom = box
      }
      else if (key === "A") { regionX = box.x; regionY = box.y; regionW = box.w; regionH = box.h }
      else fgRegion = box
    }
  }
  function setSplit(f) {
    f = Math.max(0.15, Math.min(0.85, f))
    var b = activeBlock()
    if (b) {
      b.split = f
      var cp = blocks.slice(); cp[selectedBlock] = b; blocks = cp; blocksRev = (blocksRev + 1) % 2000000000
    } else {
      split = f
    }
  }
  function activeSplit() { var b = activeBlock(); return b ? (b.split || 0.5) : split }
  function mkBlock(st, en, lay) {
    var full = { x: 0, y: 0, w: 100, h: 100 }, cen = { x: 25, y: 25, w: 50, h: 50 }
    return { start: st, end: en, layout: lay, visible: true, split: 0.5, fx: 0.5, fy: 0.72,
             regions: { main: full, top: full, bottom: { x: 0, y: 50, w: 100, h: 50 }, fg: cen } }
  }
  function ensureBlocks() {
    if (blocks.length) return
    blocks = [mkBlock(0, durS(), layoutName())]
    selectedBlock = 0
  }
  function toggleSelectedBlockVisibility() {
    if (selectedBlock < 0 || selectedBlock >= blocks.length) return
    var copy = blocks.slice(), b = Object.assign({}, copy[selectedBlock])
    b.visible = b.visible === false
    copy[selectedBlock] = b; blocks = copy; blocksRev = (blocksRev + 1) % 2000000000
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
  function cutSelectedAt(t) {
    if (selectedLayer >= 0 && selectedLayer < layers.length) {
      var layer = layers[selectedLayer]
      if (layer && t > layer.inS + 0.1 && t < layer.outS - 0.1) {
        var left = JSON.parse(JSON.stringify(layer)), right = JSON.parse(JSON.stringify(layer))
        left.outS = t; right.inS = t
        var copy = layers.slice(); copy.splice(selectedLayer, 1, left, right); layers = copy
        selectedLayer++; touchLayers(); return
      }
    }
    splitBlockAt(t)
  }
  function deleteSelectedClip() {
    if (selectedLayer >= 0 && selectedLayer < layers.length) {
      var copy = layers.slice(); copy.splice(selectedLayer, 1); layers = copy
      selectedLayer = -1; touchLayers(); return
    }
    if (selectedBlock >= 0 && blocks.length > 1) {
      var bp = blocks.slice(); bp.splice(selectedBlock, 1); blocks = bp
      selectedBlock = Math.min(selectedBlock, blocks.length - 1); blocksRev = (blocksRev + 1) % 2000000000
    }
  }
  Shortcut {
    sequence: "B"
    enabled: win.view === "edit"
    onActivated: win.cutSelectedAt(player.position / 1000)
  }
  function setBlockLayout(lay) {
    var b = activeBlock(); if (!b) { tplIndex = lay === "apilar" ? 1 : (lay === "pip" ? 2 : (lay === "circulo" ? 3 : 0)); return }
    b.layout = lay; var cp = blocks.slice(); cp[selectedBlock] = b; blocks = cp
  }
  function playheadBlock() {
    if (!blocks.length) return -1
    var t = playerRef ? playerRef.position / 1000 : 0
    for (var i = 0; i < blocks.length; i++)
      if (blocks[i].visible !== false && t >= blocks[i].start && t < blocks[i].end) return i
    return -1
  }
  function loopVisibleAt(t) {
    if (!blocks.length) return -1
    for (var i = 0; i < blocks.length; i++)
      if (blocks[i].visible !== false && t >= blocks[i].start && t < blocks[i].end) return i
    return -1
  }
  function loopToVisible(t) {
    var first = -1
    for (var i = 0; i < blocks.length; i++) {
      if (blocks[i].visible === false) continue
      if (first < 0) first = i
      if (blocks[i].start >= t) return blocks[i].start
    }
    return first >= 0 ? blocks[first].start : -1
  }
  function loopRestartPosition() {
    var p = loopToVisible(trimIn)
    return p >= 0 ? Math.max(trimIn, p) : trimIn
  }
  function enforceVisibleLoop() {
    if (!loop || !playerRef || !blocks.length || playerRef.playbackState !== MediaPlayer.PlayingState) return
    var t = playerRef.position / 1000
    if (t >= trimOut - 0.03) {
      playerRef.position = Math.round(loopRestartPosition() * 1000)
      return
    }
    if (loopVisibleAt(t) < 0) {
      var next = loopToVisible(t + 0.02)
      playerRef.position = Math.round((next >= 0 && next < trimOut ? next : loopRestartPosition()) * 1000)
    }
  }
  function selectBlockAt(t) {
    if (!blocks.length) { selectedBlock = -1; return }
    for (var i = 0; i < blocks.length; i++)
      if (blocks[i].visible !== false && t >= blocks[i].start && t < blocks[i].end) { selectedBlock = i; return }
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
      return win.blocks.filter(function (b) { return b.visible !== false }).map(function (b) {
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
  property var pendingRenderFormats: []
  property int pendingRenderIndex: 0
  function dialogPath(url) {
    var s = String(url)
    return s.indexOf("file://") === 0 ? decodeURIComponent(s.slice(7)) : s
  }
  function doRender(w, h, space, suffix, outputPath) {
    var src = win.renderSource()
    if (src === "") return
    engine.renderVertical({
      clipPath: src, template: win.layoutName(), audioEnabled: win.primaryAudioEnabled,
      regions: { main: { x: win.regionX, y: win.regionY, w: win.regionW, h: win.regionH } },
      layers: win.layers, srtPath: win.srtPath, segments: win.buildRenderSegments(),
      width: w, height: h, space: space, suffix: suffix, outputPath: outputPath,
      codec: ["h264", "h265", "vp9"][win.renderCodecIdx] || "h264",
      crf: [18, 23, 28][win.renderQualIdx] || 23,
      preset: ["medium", "veryfast", "veryfast"][win.renderQualIdx] || "veryfast"
    })
  }
  function startRender() {
    win.pendingRenderFormats = []
    if (win.fmtV) win.pendingRenderFormats.push({ w: 1080, h: 1920, space: "out", suffix: "-v" })
    if (win.fmtH) win.pendingRenderFormats.push({ w: 1920, h: 1080, space: "prog", suffix: "-h" })
    if (win.pendingRenderFormats.length) { win.pendingRenderIndex = 0; renderSaveDialog.open() }
  }
  function renderSelectedOutput(url) {
    var f = pendingRenderFormats[pendingRenderIndex]
    if (!f) return
    doRender(f.w, f.h, f.space, f.suffix, dialogPath(url))
    pendingRenderIndex++
    if (pendingRenderIndex < pendingRenderFormats.length) renderSaveDialog.open()
  }

  // ---------- project.json (AI-editable, live-reloaded) ----------
  property string lastSavedStr: ""
  property var pathHints: ({})
  function serializedPath(path) { return path && win.pathHints[path] ? win.pathHints[path] : (path || "") }
  function serializedLayers(keepHints) {
    return win.layers.map(function (layer) {
      var copy = Object.assign({}, layer)
      if (keepHints && copy.path) copy.path = win.serializedPath(copy.path)
      return copy
    })
  }
  function projectDoc(keepHints) {
    if (keepHints === undefined) keepHints = true
    return {
      version: 1, app: "omashort",
      video: win.current ? (keepHints ? win.serializedPath(win.current.path) : win.current.path) : "",
      audioEnabled: win.primaryAudioEnabled,
      trim: { "in": Math.round(win.trimIn * 100) / 100, out: Math.round(win.trimOut * 100) / 100 },
      template: win.layoutName(),
      region: { x: win.regionX, y: win.regionY, w: win.regionW, h: win.regionH },
      lock916: win.lock916,
      editRegions: win.editRegions,
      apilar: { top: win.apilarTop, bottom: win.apilarBottom, split: Math.round(win.split * 1000) / 1000 },
      pip: { fg: win.fgRegion, fx: win.pipFx, fy: win.pipFy },
      layers: win.serializedLayers(keepHints),
      blocks: win.blocks,
      srt: keepHints ? win.serializedPath(win.srtPath) : win.srtPath,
      render: { formats: (win.fmtV ? ["v"] : []).concat(win.fmtH ? ["h"] : []),
                codec: ["h264", "h265", "vp9"][win.renderCodecIdx],
                quality: ["high", "med", "low"][win.renderQualIdx] },
      dock: { columns: win.dock, colFr: win.colFr, rowFr: win.rowFr, collapsed: win.collapsed, tlHeight: win.tlHeight }
    }
  }
  function applyProject(d) {
    if (!d || !d.version) return
    if (d.audioEnabled !== undefined) win.primaryAudioEnabled = !!d.audioEnabled
    win.pathHints = d._pathHints || ({})
    if (d.trim) { win.trimIn = d.trim["in"] || 0; win.trimOut = d.trim.out || 1e9 }
    if (d.template) win.tplIndex = d.template === "apilar" ? 1 : (d.template === "pip" ? 2 : (d.template === "circulo" ? 3 : 0))
    if (d.region) { win.regionX = d.region.x; win.regionY = d.region.y; win.regionW = d.region.w; win.regionH = d.region.h }
    if (d.lock916 !== undefined) win.lock916 = !!d.lock916
    if (d.editRegions !== undefined) win.editRegions = !!d.editRegions
    if (d.apilar) { if (d.apilar.top) win.apilarTop = d.apilar.top; if (d.apilar.bottom) win.apilarBottom = d.apilar.bottom; if (d.apilar.split) win.split = d.apilar.split }
    if (d.pip) { if (d.pip.fg) win.fgRegion = d.pip.fg; if (d.pip.fx !== undefined) win.pipFx = d.pip.fx; if (d.pip.fy !== undefined) win.pipFy = d.pip.fy }
    if (d.layers) {
      var programAspect = win.srcW / Math.max(1, win.srcH)
      if (d.video) {
        var mainProbe = engine.probeVideo(d.video)
        if (mainProbe.width > 0 && mainProbe.height > 0)
          programAspect = mainProbe.width / mainProbe.height
      }
      var normalizedLayers = []
      for (var li = 0; li < d.layers.length; li++)
        normalizedLayers.push(win.normalizeVideoLayerAspect(d.layers[li], programAspect))
      win.layers = normalizedLayers
    }
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
    if (!d.video) {
      win.clearMainVideoState()
    } else if (!win.current || win.current.path !== d.video) {
      var foundVideo = false
      for (var i = 0; i < win.sources.length; i++)
        if (win.sources[i].path === d.video) { win.current = win.sources[i]; foundVideo = true; break }
      if (!foundVideo) {
        var probe = engine.probeVideo(d.video)
        win.current = { id: d.video, path: d.video, title: d.video.split("/").pop(),
                        duration: probe.duration || 0, width: probe.width || 0, height: probe.height || 0 }
      }
      win.cutPath = ""
      loadVideo(d.video)
    }
  }
  Timer {
    id: saveTimer; interval: 1500; running: true; repeat: true
    onTriggered: {
      if (win.view !== "edit") return
      var doc = win.projectDoc()
      var str = JSON.stringify(doc)
      if (str !== win.lastSavedStr && engine.saveProject(doc)) win.lastSavedStr = str
    }
  }


  Connections {
    target: engine
    function onProjectFileChanged() { win.refreshOutputs() }
    function onProjectChangedExternally(doc) {
      win.applyProject(doc)
      win.lastSavedStr = JSON.stringify(win.projectDoc()) // avoid immediate re-save loop
    }
  }

  function tt(k) { I18n.lang = engine.language; return I18n.t(k) }
  function requestNewProject() {
    var currentDoc = win.projectDoc()
    var currentStr = JSON.stringify(currentDoc)
    if (currentStr !== win.lastSavedStr && !engine.saveProject(currentDoc)) return
    win.lastSavedStr = currentStr
    win.beginNewProject()
  }
  function beginNewProject() {
    if (!engine.newProject()) return
    playTimer.stop()
    if (win.playerRef) { win.playerRef.stop(); win.playerRef.source = "" }
    win.current = null
    win.primaryAudioEnabled = true
    win.videoPath = ""
    win.cutPath = ""
    win.layers = []
    win.touchLayers()
    win.blocks = []
    win.blocksRev = (win.blocksRev + 1) % 2000000000
    win.selectedLayer = -1
    win.selectedBlock = -1
    win.srtPath = ""
    win.subtitleMode = "normal"
    win.subtitleStatus = ""
    win.stripUrls = []
    win.stripFor = ""
    win.trimIn = 0
    win.trimOut = 1
    win.tplIndex = 0
    win.regionX = 0; win.regionY = 0; win.regionW = 100; win.regionH = 100
    win.apilarTop = ({ x: 0, y: 0, w: 100, h: 50 })
    win.apilarBottom = ({ x: 0, y: 50, w: 100, h: 50 })
    win.split = 0.5
    win.fgRegion = ({ x: 25, y: 25, w: 50, h: 50 })
    win.pipFx = 0.5; win.pipFy = 0.72
    win.lock916 = false
    win.editRegions = false
    win.loop = false
    win.srcW = 1920; win.srcH = 1080
    win.pathHints = ({})
    win.fmtV = true; win.fmtH = false
    win.renderCodecIdx = 0; win.renderQualIdx = 1
    win.view = "edit"
    win.lastSavedStr = JSON.stringify(win.projectDoc())
  }
  function clearMainVideoState() {
    playTimer.stop()
    if (win.playerRef) { win.playerRef.stop(); win.playerRef.source = "" }
    win.current = null
    win.videoPath = ""
    win.cutPath = ""
    win.stripUrls = []
    win.stripFor = ""
  }
  function clearTimelineVideo() {
    win.clearMainVideoState()
    win.trimIn = 0
    win.trimOut = 1
    win.blocks = []
    win.blocksRev = (win.blocksRev + 1) % 2000000000
    win.selectedBlock = -1
    var doc = win.projectDoc()
    if (engine.saveProject(doc)) win.lastSavedStr = JSON.stringify(doc)
  }
  function requestSourceDelete(path, title) {
    deleteConfirmDialog.deleteKind = "source"
    deleteConfirmDialog.targetPath = path
    deleteConfirmDialog.targetName = title || path.split("/").pop()
    deleteConfirmDialog.open()
  }
  function requestTimelineDelete() {
    if (!win.current && win.cutPath === "") return
    deleteConfirmDialog.deleteKind = "timeline"
    deleteConfirmDialog.targetPath = win.current ? win.current.path : win.cutPath
    deleteConfirmDialog.targetName = win.current ? win.current.title : win.cutPath.split("/").pop()
    deleteConfirmDialog.open()
  }
  function confirmDelete() {
    if (deleteConfirmDialog.deleteKind === "timeline") {
      win.clearTimelineVideo()
      return
    }
    if (engine.removeSource(deleteConfirmDialog.targetPath)) win.refreshSources()
  }
  function refreshSources() {
    sources = engine.scanMedia()
    for (var i = 0; i < sources.length; i++) engine.requestThumb(sources[i].path)
  }
  function importVideos(fileUrls, addAsLayers) {
    var imported = []
    for (var i = 0; i < fileUrls.length; i++) {
      var path = engine.importVideo(fileUrls[i])
      if (path !== "" && imported.indexOf(path) < 0) imported.push(path)
    }
    win.refreshSources()
    if (addAsLayers) {
      for (var j = 0; j < imported.length; j++) win.addLayer("video", imported[j])
    } else if (!win.current && imported.length > 0) {
      win.selectMainVideo(imported[0], imported[0].split("/").pop())
    }
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
  function sourceForPath(path, title) {
    for (var i = 0; i < win.sources.length; i++)
      if (win.sources[i].path === path) return win.sources[i]
    var probe = engine.probeVideo(path)
    return { id: path, path: path, title: title || path.split("/").pop(),
             duration: probe.duration || 0, width: probe.width || 0, height: probe.height || 0 }
  }
  function selectMainVideo(path, title) {
    win.current = win.sourceForPath(path, title)
    win.cutPath = ""
    win.trimIn = 0
    win.trimOut = win.current.duration > 0 ? win.current.duration : 1e9
    win.blocks = []
    win.blocksRev = (win.blocksRev + 1) % 2000000000
    win.selectedBlock = -1
    win.loadVideo(path)
  }
  function requestMainVideo(path, title) {
    if (!path) return
    if (win.current && win.current.path === path) return
    if (!win.current) {
      win.selectMainVideo(path, title)
      return
    }
    replaceVideoDialog.targetPath = path
    replaceVideoDialog.targetName = title || path.split("/").pop()
    replaceVideoDialog.open()
  }
  function confirmMainVideoReplacement() {
    win.selectMainVideo(replaceVideoDialog.targetPath, replaceVideoDialog.targetName)
    replaceVideoDialog.close()
  }
  function addPendingMainVideoAsLayer() {
    win.addLayer("video", replaceVideoDialog.targetPath)
    replaceVideoDialog.close()
  }
  Timer { id: playTimer; interval: 250; onTriggered: if (playerRef) playerRef.play() }

  property var playerRef: null
  property string videoPath: ""
  onPlayerRefChanged: if (playerRef && win.current && !playerRef.source.toString()) loadVideo(win.current.path)

  function patchLayer(i, patch) {
    var l = win.layers
    var layer = l[i]
    if (!layer) return
    var keys = ["x", "y", "w", "h", "px", "py", "pw", "ph", "size", "opacity"]
    var animatedPatch = false
    for (var p = 0; p < keys.length; p++) animatedPatch = animatedPatch || patch[keys[p]] !== undefined
    var frames = Array.isArray(layer.keyframes) ? layer.keyframes.slice() : []
    if (frames.length && animatedPatch) {
      // Auto-keyframe edits at the current playhead once animation exists. Start
      // from the interpolated state so dragging a second pose cannot snap back
      // to the first keyframe before the explicit diamond button is pressed.
      var time = Math.round((win.playerRef ? win.playerRef.position / 1000 : 0) * 1000) / 1000
      layer.keyframes = Keyframes.patchedFrames(layer, patch, time, win.keyframeEasing)
    } else {
      for (var name2 in patch) {
        if (keys.indexOf(name2) >= 0 && name2 !== "size") layer[name2] = Math.max(0, Math.min(1, patch[name2]))
        else layer[name2] = patch[name2]
      }
    }
    // Non-animated metadata such as shape always lives on the layer itself.
    for (var name3 in patch) if (keys.indexOf(name3) < 0) layer[name3] = patch[name3]
    win.touchLayers()
  }
  function keyframeAt(i, time) {
    var layer = win.layers[i]
    if (!layer) return
    // Store only animatable/persisted values. This JSON stays simple for manual
    // or LLM editing and is evaluated identically by both previews.
    var frame = { time: Math.round(time * 1000) / 1000, easing: win.keyframeEasing }
    var evaluated = Keyframes.at(layer, time)
    var keys = ["x", "y", "w", "h", "px", "py", "pw", "ph", "size", "opacity"]
    for (var k = 0; k < keys.length; k++)
      if (evaluated[keys[k]] !== undefined) frame[keys[k]] = evaluated[keys[k]]
    var frames = Array.isArray(layer.keyframes) ? layer.keyframes.slice() : []
    var found = -1
    for (var j = 0; j < frames.length; j++)
      if (Math.abs(frames[j].time - frame.time) < 0.001) { found = j; break }
    if (found >= 0) frames[found] = Object.assign({}, frames[found], frame)
    else frames.push(frame)
    frames.sort(function (a, b) { return a.time - b.time })
    layer.keyframes = frames
    win.touchLayers()
  }
  function hasKeyframeAt(i, time) {
    var l = win.layers[i], frames = l && Array.isArray(l.keyframes) ? l.keyframes : []
    for (var j = 0; j < frames.length; j++) if (Math.abs(frames[j].time - time) < 0.001) return true
    return false
  }
  function applyGeneratedSubtitles(path) {
    if (win.subtitleMode === "normal") { win.srtPath = path; win.subtitleStatus = win.tt("subtitleReady"); return }
    var keep = win.layers.filter(function (layer) { return !layer.subtitle })
    win.layers = keep.concat(engine.subtitleLayers(path, true))
    win.selectedLayer = keep.length < win.layers.length ? keep.length : -1
    win.touchLayers()
    win.subtitleStatus = win.tt("subtitleReady")
  }
  function fittedLayerSize(mediaAspect, canvasAspect) {
    var maxW = 0.45, maxH = 0.45
    var aspect = mediaAspect > 0 ? mediaAspect : 16 / 9
    var width = maxW
    var height = width * canvasAspect / aspect
    if (height > maxH) { height = maxH; width = height * aspect / canvasAspect }
    return { w: width, h: height }
  }
  function normalizeVideoLayerAspect(layer, programAspect) {
    layer = Object.assign({}, layer)
    if (layer.type !== "video" || layer.sourceAspect > 0 || !layer.path) return layer
    var probe = engine.probeVideo(layer.path)
    if (!(probe.width > 0 && probe.height > 0)) return layer
    var mediaAspect = probe.width / probe.height
    layer.w = layer.w !== undefined ? layer.w : 0.35
    layer.h = layer.w * (9 / 16) / mediaAspect
    if (layer.h > 0.9) { layer.h = 0.9; layer.w = layer.h * mediaAspect / (9 / 16) }
    layer.pw = layer.pw !== undefined ? layer.pw : layer.w
    layer.ph = layer.pw * programAspect / mediaAspect
    if (layer.ph > 0.9) { layer.ph = 0.9; layer.pw = layer.ph * mediaAspect / programAspect }
    layer.sourceAspect = mediaAspect
    return layer
  }
  function outputHeightForWidth(layer, width) {
    return layer.type === "video" && layer.sourceAspect > 0
        ? width * (9 / 16) / layer.sourceAspect : width * 0.56
  }
  function addLayer(type, path) {
    var l = win.layers.slice()
    if (type === "text")
      l.push({ type: "text", text: "", x: 0.5, y: 0.15, size: 90, opacity: 1, fadeIn: 0, fadeOut: 0, color: "#ffffff", font: "", inS: win.trimIn, outS: win.trimOut })
    else if (type === "video") {
      var probe = engine.probeVideo(path)
      var mediaAspect = probe.width > 0 && probe.height > 0 ? probe.width / probe.height : 16 / 9
      var outputSize = win.fittedLayerSize(mediaAspect, 9 / 16)
      var programSize = win.fittedLayerSize(mediaAspect, win.srcW / Math.max(1, win.srcH))
      l.push({ type: "video", path: path || "", text: "", shape: "rect", sourceIn: win.trimIn, sourceOut: win.trimOut, audioEnabled: true, audioOffset: 0, audioVolume: 1,
               x: 0.5, y: 0.5, w: outputSize.w, h: outputSize.h,
               px: 0.5, py: 0.5, pw: programSize.w, ph: programSize.h,
               sourceAspect: mediaAspect,
               size: 90, opacity: 1, fadeIn: 0, fadeOut: 0, color: "#ffffff", font: "",
               inS: win.trimIn, outS: win.trimOut })
    } else
      l.push({ type: type, path: path || "", text: "", x: 0.5, y: 0.5, w: 0.35, h: 0.20, size: 90, opacity: 1, fadeIn: 0, fadeOut: 0, color: "#ffffff", font: "", inS: win.trimIn, outS: win.trimOut })
    win.layers = l
    win.selectedLayer = l.length - 1
    win.touchLayers()
  }
  function createClipFromPrimarySelection() {
    var src = win.renderSource()
    if (src === "" || win.trimOut - win.trimIn <= 0.1) return
    win.addLayer("video", src)
    win.touchLayers()
  }

  Component.onCompleted: {
    normalizeFr()
    refreshSources(); refreshOutputs()
    var proj = engine.loadProject()
    if (proj && proj.version) { applyProject(proj); lastSavedStr = JSON.stringify(win.projectDoc()) }
    else if (sources.length > 0) { win.current = sources[0]; loadVideo(sources[0].path) }
    if (typeof uitest !== "undefined" && uitest) uitestTimer.restart()
  }

  Timer {
    id: uitestTimer; interval: 900
    onTriggered: {
      win.trimIn = 5; win.trimOut = 10; win.loop = true
      win.layers = [
        // dual-format: output 9:16 top-center, program/source bottom-left
        { type: "text", text: "Título de prueba", x: 0.5, y: 0.15, px: 0.15, py: 0.85, size: 90, color: "#ff9e64", font: "", inS: 5, outS: 10 },
        { type: "text", text: "OmaShort 🔥", x: 0.5, y: 0.85, px: 0.5, py: 0.15, size: 60, color: "#9ece6a", font: "", inS: 6, outS: 9 }
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
      if (win.loop && win.blocks.length) {
        win.enforceVisibleLoop()
        if (win.loopVisibleAt(t) < 0) return
      }
      if (win.blocks.length) { var bi = win.playheadBlock(); if (bi >= 0 && bi !== win.selectedBlock) win.selectedBlock = bi }
      // rewind BEFORE EndOfMedia: reaching the Stopped state clears the
      // VideoOutput (black monitor), so keep a safety margin
      if (playerRef.duration > 0 && t >= durS() - 0.25) {
        if (win.loop) { playerRef.position = Math.round(win.loopRestartPosition() * 1000); if (playerRef.playbackState !== MediaPlayer.PlayingState) playerRef.play() }
        return
      }
      if (win.loop && playerRef.playbackState === MediaPlayer.PlayingState && t >= win.trimOut - 0.03)
        playerRef.position = Math.round(win.loopRestartPosition() * 1000)
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
  Timer {
    id: visibleLoopTimer; interval: 40
    running: win.loop && win.blocks.length > 0 && win.playerRef && win.playerRef.playbackState === MediaPlayer.PlayingState
    repeat: true
    onTriggered: win.enforceVisibleLoop()
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
      if (jobId === "subtitles") win.subtitleStatus = message
    }
    function onSubtitlesReady(path) { win.applyGeneratedSubtitles(path) }
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
    width: lbl.implicitWidth + 18; height: 28; radius: engine.theme.radius
    color: accentBtn ? engine.theme.accent : (active ? engine.theme.accentSoft : (ma.containsMouse ? "#2b3050" : engine.theme.panelAlt))
    border.color: accentBtn ? engine.theme.accent : (active ? engine.theme.accent : engine.theme.border)
    Label { id: lbl; anchors.centerIn: parent; text: parent.text; color: accentBtn ? "#16161e" : engine.theme.text; font.pixelSize: 11; font.bold: accentBtn }
    MouseArea { id: ma; anchors.fill: parent; hoverEnabled: true; onClicked: parent.clicked(); ToolTip.text: parent.tip; ToolTip.visible: containsMouse && parent.tip !== ""; ToolTip.delay: 500 }
  }
  component IconBtn: Rectangle {
    property string glyph: ""
    property string tip: ""
    property bool active: false
    signal clicked()
    width: 30; height: 30; radius: 15
    color: active ? engine.theme.accentSoft : (ma2.containsMouse ? "#2b3050" : "transparent")
    border.color: active ? engine.theme.accent : "transparent"
    Label { anchors.centerIn: parent; text: parent.glyph; color: parent.active ? engine.theme.accent : engine.theme.text; font.pixelSize: 13 }
    MouseArea { id: ma2; anchors.fill: parent; hoverEnabled: true; onClicked: parent.clicked(); ToolTip.text: parent.tip; ToolTip.visible: containsMouse && parent.tip !== ""; ToolTip.delay: 400 }
  }

  // ---------- panel content components ----------
  component FuentesContent: ColumnLayout {
    spacing: 8
    NleButton { text: "⬆ " + win.tt("importVideo"); Layout.fillWidth: true; onClicked: importDialog.open() }
    FileDialog {
      id: importDialog; fileMode: FileDialog.OpenFiles
      nameFilters: ["Video (*.mp4 *.mkv *.mov *.webm)"]
      onAccepted: win.importVideos(selectedFiles, false)
    }
    ListView {
      Layout.fillWidth: true; Layout.fillHeight: true
      model: win.sources; spacing: 6; clip: true
      delegate: Rectangle {
        required property var modelData
        width: ListView.view.width; height: 58; radius: engine.theme.radius
        color: win.current && win.current.path === modelData.path ? engine.theme.accentSoft : (hov.containsMouse ? "#272c42" : engine.theme.panelAlt)
        border.color: win.current && win.current.path === modelData.path ? engine.theme.accent : engine.theme.borderSoft
        RowLayout {
          anchors.fill: parent; anchors.margins: 6; anchors.rightMargin: 74; spacing: 8
          Image {
            Layout.preferredWidth: 76; Layout.preferredHeight: 44
            source: modelData.thumb || ""; fillMode: Image.PreserveAspectCrop
            Rectangle { anchors.fill: parent; color: "#000"; visible: parent.status !== Image.Ready; radius: 3 }
          }
          ColumnLayout { Layout.fillWidth: true; spacing: 2
            Label { text: modelData.title; color: engine.theme.text; elide: Label.ElideRight; Layout.fillWidth: true; font.pixelSize: 10 }
            Label { text: win.fmtDur(modelData.duration) + " · " + win.fmtSize(modelData.size); color: engine.theme.textMuted; font.pixelSize: 9; font.family: engine.theme.fontMono }
          }
        }
        MouseArea { id: hov; anchors.fill: parent; hoverEnabled: true; onClicked: win.requestMainVideo(modelData.path, modelData.title) }
        IconBtn { anchors.right: parent.right; anchors.rightMargin: 38; anchors.verticalCenter: parent.verticalCenter; z: 2; glyph: "+"; tip: win.tt("addSourceAsLayer"); onClicked: win.addLayer("video", modelData.path) }
        IconBtn { anchors.right: parent.right; anchors.rightMargin: 6; anchors.verticalCenter: parent.verticalCenter; z: 2; glyph: "×"; tip: win.tt("deleteSource"); onClicked: win.requestSourceDelete(modelData.path, modelData.title) }
      }
      Label { visible: win.sources.length === 0; text: win.tt("noSources"); color: engine.theme.textDim; wrapMode: Text.WordWrap; width: parent ? parent.width - 16 : 200 }
    }
  }

  component ProgramContent: ColumnLayout {
    id: programContent
    spacing: 6
    Component.onCompleted: if (panelBox && panelBox.modelData === "program") win.playerRef = player
    Component.onDestruction: if (win.playerRef === player) win.playerRef = null
    Rectangle {
      Layout.fillWidth: true; Layout.fillHeight: true; color: "#000"; radius: 4; clip: true
      border.color: engine.theme.borderSoft
      VideoOutput {
        id: videoOut; anchors.fill: parent
        visible: !win.blocks.length || win.loopVisibleAt(player.position / 1000) >= 0
      }
      Label { anchors.centerIn: parent; visible: !player.source.toString(); text: win.tt("preview"); color: engine.theme.textDim }
      MediaPlayer { id: player; videoOutput: videoOut }
      OverlayLayers {
        // pinned to the video frame: program-space fractions map to source pixels
        x: videoOut.contentRect.x; y: videoOut.contentRect.y
        width: videoOut.contentRect.width; height: videoOut.contentRect.height
        visible: videoOut.visible && videoOut.contentRect.width > 4 && videoOut.contentRect.height > 4
        active: programContent.visible
        layers: { win.layersRev; return win.layers.slice() }
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
        // Every source sector painted in OUTPUT is represented here. In PiP and
        // Circle these are MAIN + PIP/CIRCLE; in Apilar they are TOP + BOT.
        mode: win.activeLayout() === "completa" ? 0 : 1
        boxALabel: win.activeLayout() === "apilar" ? "TOP" : "MAIN"
        boxBLabel: win.activeLayout() === "apilar" ? "BOT" : (win.activeLayout() === "circulo" ? "CIRCLE" : "PIP")
        aspectA: win.regionAspect(win.activeLayout(), "A", win.activeSplit())
        aspectB: win.regionAspect(win.activeLayout(), "B", win.activeSplit())
        // The apilar divider belongs to the 9:16 output canvas, not source-space PROGRAM.
        showSplit: false
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
        width: loopLbl.width + 16; height: 22; radius: 11; color: engine.theme.accent
        Label { id: loopLbl; anchors.centerIn: parent; text: "A-B LOOP"; color: "#16161e"; font.pixelSize: 9; font.bold: true }
      }
    }
    Rectangle {
      Layout.fillWidth: true; height: 40; color: engine.theme.panelAlt; radius: engine.theme.radius; border.color: engine.theme.borderSoft
      RowLayout {
        anchors.fill: parent; anchors.leftMargin: 10; anchors.rightMargin: 10; spacing: 2
        IconBtn { glyph: "⏮"; tip: "Inicio"; onClicked: player.position = Math.round(win.trimIn * 1000) }
        IconBtn { glyph: "◂"; tip: "Frame -1 (←)"; onClicked: { player.pause(); player.position = Math.max(0, player.position - 33) } }
        Rectangle {
          width: 36; height: 36; radius: 18
          color: player.playbackState === MediaPlayer.PlayingState ? engine.theme.panel : engine.theme.play
          border.color: player.playbackState === MediaPlayer.PlayingState ? engine.theme.border : engine.theme.play
          Label { anchors.centerIn: parent; text: player.playbackState === MediaPlayer.PlayingState ? "⏸" : "▶"; color: player.playbackState === MediaPlayer.PlayingState ? engine.theme.text : "#16161e"; font.pixelSize: 15 }
          MouseArea { anchors.fill: parent; onClicked: {
            if (player.playbackState === MediaPlayer.PlayingState) win.pausePlayback()
            else { if (player.position >= player.duration - 50) player.position = Math.round(win.trimIn * 1000); player.play() }
          } }
        }
        IconBtn { glyph: "▸"; tip: "Frame +1 (→)"; onClicked: { player.pause(); player.position = Math.min(player.duration, player.position + 33) } }
        IconBtn { glyph: "⏭"; tip: "Fin"; onClicked: player.position = Math.round(win.trimOut * 1000) }
        Rectangle { width: 1; height: 18; color: engine.theme.border; Layout.leftMargin: 6; Layout.rightMargin: 6 }
        IconBtn { glyph: "🔁"; tip: "Loop A-B (L)"; active: win.loop; onClicked: win.loop = !win.loop }
        Item { Layout.fillWidth: true }
        Rectangle {
          height: 26; width: tc.width + 20; radius: 4; color: "#101116"; border.color: engine.theme.border
          Label { id: tc; anchors.centerIn: parent; text: win.fmtTc(player.position / 1000); color: engine.theme.good; font.pixelSize: 13; font.family: engine.theme.fontMono }
        }
        Label { text: "/ " + win.fmtTc(durS()); color: engine.theme.textMuted; font.pixelSize: 11; font.family: engine.theme.fontMono }
        Item { Layout.fillWidth: true }
        NleButton { text: "⟨ I"; tip: "Marcar entrada (I)"; onClicked: win.trimIn = player.position / 1000 }
        NleButton { text: "O ⟩"; tip: "Marcar salida (O)"; onClicked: win.trimOut = player.position / 1000 }
        NleButton { text: "✂B"; tip: "Cut selected media at playhead"; onClicked: win.cutSelectedAt(player.position / 1000) }
        NleButton { text: "⌫"; tip: "Delete selected clip"; enabled: win.selectedLayer >= 0 || win.selectedBlock >= 0; onClicked: win.deleteSelectedClip() }
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
    FileDialog {
      id: vidDialog; fileMode: FileDialog.OpenFiles
      nameFilters: ["Video (*.mp4 *.mkv *.mov *.webm)"]
      onAccepted: win.importVideos(selectedFiles, true)
    }
    FileDialog { id: gifDialog; fileMode: FileDialog.OpenFile; nameFilters: ["GIF (*.gif *.webp)"]; onAccepted: win.addLayer("gif", String(selectedFile).replace("file://", "")) }
    FileDialog { id: imgDialog; fileMode: FileDialog.OpenFile; nameFilters: ["Image (*.png *.jpg *.jpeg *.webp)"]; onAccepted: win.addLayer("image", String(selectedFile).replace("file://", "")) }
    RowLayout { Layout.fillWidth: true
      Label { text: win.tt("subtitles") + ":"; color: engine.theme.textMuted; font.pixelSize: 10 }
      Label { text: win.srtPath ? win.srtPath.split("/").pop() : win.tt("noSrt"); color: engine.theme.text; elide: Label.ElideMiddle; Layout.fillWidth: true; font.pixelSize: 10 }
      NleButton { text: "…"; onClicked: srtDialog.open() }
    }
    RowLayout { Layout.fillWidth: true; spacing: 5
      FnCombo { Layout.fillWidth: true; model: [win.tt("subtitleNormal"), win.tt("subtitleReel")]; currentIndex: win.subtitleMode === "reel" ? 1 : 0; onActivated: win.subtitleMode = currentIndex === 1 ? "reel" : "normal" }
      NleButton { text: "🎤 " + win.tt("subtitleGenerate"); enabled: win.renderSource() !== ""; onClicked: { win.subtitleStatus = win.tt("subtitleWorking"); engine.transcribeAudio(win.renderSource(), engine.language) } }
    }
    Label { visible: win.subtitleStatus !== ""; text: win.subtitleStatus; color: engine.theme.textMuted; wrapMode: Text.WordWrap; Layout.fillWidth: true; font.pixelSize: 9 }
    FileDialog { id: srtDialog; fileMode: FileDialog.OpenFile; nameFilters: ["Subtitles (*.srt *.vtt)"]; onAccepted: win.srtPath = String(selectedFile).replace("file://", "") }

    Rectangle { Layout.fillWidth: true; height: 1; color: engine.theme.border }

    // layer cards (reorderable)
    ListView {
      id: layerList
      Layout.fillWidth: true; Layout.fillHeight: true
      model: win.layers; spacing: 6; clip: true
      delegate: Rectangle {
        id: card
        objectName: "layerCard"
        property bool expanded: false
        required property int index
        required property var modelData
        property var cardLayer: modelData
        readonly property var animatedLayer: {
          win.layersRev
          return Keyframes.at(cardLayer, win.playerRef ? win.playerRef.position / 1000 : 0)
        }
        property int idx: index
        width: ListView.view.width; height: cardCol.implicitHeight + 12; radius: engine.theme.radius
        color: win.selectedLayer === index ? "#26332a" : engine.theme.panelAlt
        border.color: win.selectedLayer === index ? engine.theme.good : engine.theme.borderSoft
        ColumnLayout {
          id: cardCol; anchors.fill: parent; anchors.margins: 6; spacing: 4
          RowLayout { Layout.fillWidth: true
            Label {
              text: "≡"; color: engine.theme.textDim; font.pixelSize: 13
              MouseArea {
                anchors.fill: parent; cursorShape: Qt.SizeVerCursor
                preventStealing: true
                onReleased: function(mouse) {
                  var y = mapToItem(layerList, mouse.x, mouse.y).y + layerList.contentY
                  var target = layerList.indexAt(1, y)
                  if (target < 0) target = layerList.indexAt(1, y + layerList.spacing)
                  if (target < 0) target = y < 0 ? 0 : win.layers.length - 1
                  if (target !== index) {
                    var l = win.layers.slice()
                    var item = l.splice(index, 1)[0]
                    l.splice(target, 0, item)
                    win.selectedLayer = target
                    win.layers = l
                  }
                }
              }
            }
            Label {
              text: modelData.type === "text" ? "🅣" : (modelData.type === "gif" ? "GIF" : (modelData.type === "video" ? "🎬" : "🖼"))
              color: modelData.type === "video" ? engine.theme.orange : engine.theme.magenta; font.pixelSize: 10; font.bold: true
            }
            Label {
              Layout.fillWidth: true; elide: Label.ElideMiddle; font.pixelSize: 10; color: engine.theme.text
              text: {
                win.layersRev
                var l = win.layers[index]
                return l ? (l.type === "text" ? (l.text || win.tt("textPlaceholder")) : (l.path ? l.path.split("/").pop() : "…")) : ""
              }
              MouseArea { anchors.fill: parent; onClicked: { win.selectedLayer = index; card.expanded = !card.expanded } }
            }
            IconBtn {
              objectName: "layerExpandToggle"
              width: 24; height: 24
              glyph: card.expanded ? "▾" : "▸"
              tip: win.tt(card.expanded ? "collapseLayer" : "expandLayer")
              onClicked: { win.selectedLayer = index; card.expanded = !card.expanded }
            }
            IconBtn { width: 24; height: 24; glyph: "✕"; onClicked: { var l = win.layers.slice(); l.splice(index, 1); win.layers = l; win.selectedLayer = -1 } }
          }
          FnField {
            visible: card.expanded && modelData.type === "text"
            Layout.fillWidth: true; placeholderText: win.tt("textPlaceholder"); text: modelData.text || ""
            // Keep the editor alive during in-place edits.
            onTextChanged: { win.layers[index].text = text; win.touchLayers() }
            onActiveFocusChanged: if (activeFocus) win.selectedLayer = index
          }
          RowLayout { visible: card.expanded; Layout.fillWidth: true
            Label { text: modelData.type === "text" ? win.tt("fontSize") : "w%"; color: engine.theme.textDim; font.pixelSize: 10 }
            FnSpin {
              from: modelData.type === "text" ? 20 : 5; to: modelData.type === "text" ? 300 : 100
              value: modelData.type === "text" ? card.animatedLayer.size : Math.round((card.animatedLayer.w || 0.35) * 100)
              onValueModified: if (modelData.type === "text") win.patchLayer(index, { size: value }); else { var width = value / 100; win.patchLayer(index, { w: width, h: win.outputHeightForWidth(modelData, width) }) }
            }
            Label { text: "y%"; color: engine.theme.textDim; font.pixelSize: 10 }
            FnSpin { from: 5; to: 95; value: Math.round(card.animatedLayer.y * 100); onValueModified: win.patchLayer(index, { y: value / 100 }) }
          }
          RowLayout { visible: card.expanded; Layout.fillWidth: true; spacing: 4
            Label { text: "Opacity %"; color: engine.theme.textDim; font.pixelSize: 9 }
            FnSpin { from: 0; to: 100; value: Math.round((card.animatedLayer.opacity === undefined ? 1 : card.animatedLayer.opacity) * 100); onValueModified: win.patchLayer(index, { opacity: value / 100 }) }
            Label { text: "Fade I/O ×0.1s"; color: engine.theme.textDim; font.pixelSize: 9 }
            FnSpin { from: 0; to: 100; value: Math.round((modelData.fadeIn || 0) * 10); onValueModified: win.patchLayer(index, { fadeIn: value / 10 }) }
            FnSpin { from: 0; to: 100; value: Math.round((modelData.fadeOut || 0) * 10); onValueModified: win.patchLayer(index, { fadeOut: value / 10 }) }
          }
          RowLayout {
            visible: card.expanded && card.cardLayer.type === "video"; Layout.fillWidth: true; spacing: 4
            Label { text: "forma"; color: engine.theme.textDim; font.pixelSize: 10 }
            Repeater {
              model: [["rect", "▢"], ["rounded", "⬒"], ["circle", "◯"]]
              delegate: Rectangle {
                required property var modelData
                property string shp: modelData[0]
                width: 26; height: 22; radius: 4
                color: (card.cardLayer.shape || "rect") === shp ? engine.theme.accentSoft : engine.theme.panelDeep
                border.color: (card.cardLayer.shape || "rect") === shp ? engine.theme.accent : engine.theme.border
                Label { anchors.centerIn: parent; text: modelData[1]; color: (card.cardLayer.shape || "rect") === shp ? engine.theme.accent : engine.theme.textMuted; font.pixelSize: 12 }
                MouseArea { anchors.fill: parent; onClicked: win.patchLayer(card.idx, { shape: shp }) }
              }
            }
            Item { Layout.fillWidth: true }
          }
          RowLayout {
            visible: card.expanded; Layout.fillWidth: true; spacing: 5
            property real keyTime: win.playerRef ? win.playerRef.position / 1000 : 0
            NleButton {
              text: win.hasKeyframeAt(index, parent.keyTime) ? "◆ " + win.tt("keyframe") : "◇ " + win.tt("keyframe")
              Layout.fillWidth: true
              tip: win.tt("keyframeTip")
              accentBtn: win.hasKeyframeAt(index, parent.keyTime)
              onClicked: win.keyframeAt(index, parent.keyTime)
            }
            FnCombo {
              Layout.preferredWidth: 104
              model: ["linear", "easeIn", "easeOut", "easeInOut", "backOut", "bounce"]
              currentIndex: model.indexOf(win.keyframeEasing)
              onActivated: win.keyframeEasing = model[currentIndex]
            }
          }
          Label { visible: card.expanded; text: "⏱ " + win.fmtTc(modelData.inS) + " → " + win.fmtTc(modelData.outS); color: engine.theme.textMuted; font.pixelSize: 9; font.family: engine.theme.fontMono }
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
      Label { anchors.centerIn: parent; visible: win.layers.length === 0; text: "+"; color: engine.theme.textDim; font.pixelSize: 24 }
    }
  }

  component RenderContent: ColumnLayout {
    spacing: 8
    property var codecNames: ["H.264 (MP4)", "H.265 / HEVC (MP4)", "VP9 (MP4)"]
    property var qualNames: [win.tt("qualHigh"), win.tt("qualMed"), win.tt("qualLow")]
    Label { text: win.tt("renderFormats").toUpperCase(); color: engine.theme.textDim; font.pixelSize: 9; font.bold: true; font.letterSpacing: 1 }
    Rectangle { Layout.fillWidth: true; height: 28; radius: engine.theme.radius; color: engine.theme.panelDeep; border.color: engine.theme.border
      RowLayout { anchors.fill: parent; anchors.leftMargin: 8; anchors.rightMargin: 8; spacing: 8
        Rectangle { width: 16; height: 16; radius: 4; border.color: engine.theme.border; color: win.fmtV ? engine.theme.accent : engine.theme.panelDeep
          Label { anchors.centerIn: parent; text: "✓"; color: "#16161e"; font.pixelSize: 10; visible: win.fmtV }
          MouseArea { anchors.fill: parent; onClicked: win.fmtV = !win.fmtV } }
        Label { text: win.tt("fmtVertical"); color: engine.theme.text; font.pixelSize: 11; Layout.fillWidth: true; elide: Label.ElideRight }
        Label { text: "OUT"; color: engine.theme.textMuted; font.pixelSize: 9; font.family: engine.theme.fontMono }
      }
    }
    Rectangle { Layout.fillWidth: true; height: 28; radius: engine.theme.radius; color: engine.theme.panelDeep; border.color: engine.theme.border
      RowLayout { anchors.fill: parent; anchors.leftMargin: 8; anchors.rightMargin: 8; spacing: 8
        Rectangle { width: 16; height: 16; radius: 4; border.color: engine.theme.border; color: win.fmtH ? engine.theme.accent : engine.theme.panelDeep
          Label { anchors.centerIn: parent; text: "✓"; color: "#16161e"; font.pixelSize: 10; visible: win.fmtH }
          MouseArea { anchors.fill: parent; onClicked: win.fmtH = !win.fmtH } }
        Label { text: win.tt("fmtHorizontal"); color: engine.theme.text; font.pixelSize: 11; Layout.fillWidth: true; elide: Label.ElideRight }
        Label { text: "PROG"; color: engine.theme.textMuted; font.pixelSize: 9; font.family: engine.theme.fontMono }
      }
    }
    RowLayout { Layout.fillWidth: true; spacing: 6
      Label { text: win.tt("codec"); color: engine.theme.textDim; font.pixelSize: 10 }
      FnCombo { Layout.fillWidth: true; model: codecNames; currentIndex: win.renderCodecIdx; onActivated: win.renderCodecIdx = currentIndex }
    }
    RowLayout { Layout.fillWidth: true; spacing: 6
      Label { text: win.tt("qual"); color: engine.theme.textDim; font.pixelSize: 10 }
      FnCombo { Layout.fillWidth: true; model: qualNames; currentIndex: win.renderQualIdx; onActivated: win.renderQualIdx = currentIndex }
    }
    NleButton {
      Layout.fillWidth: true; text: win.tt("renderStart")
      enabled: win.renderSource() !== "" && (win.fmtV || win.fmtH)
      accentBtn: win.renderSource() !== "" && (win.fmtV || win.fmtH)
      onClicked: win.startRender()
    }
    Label { visible: win.renderSource() === ""; text: win.tt("needSource"); color: engine.theme.textDim; font.pixelSize: 10 }
    Rectangle { Layout.fillWidth: true; height: 1; color: engine.theme.border }
    ColumnLayout { Layout.fillWidth: true; spacing: 4
      Label { text: win.tt("jobs").toUpperCase() + "  (" + win.jobs.length + ")"; color: engine.theme.textDim; font.pixelSize: 9; font.bold: true; font.letterSpacing: 1 }
      Repeater {
        model: win.jobs
        delegate: ColumnLayout {
          required property var modelData
          Layout.fillWidth: true; spacing: 2
          RowLayout { Layout.fillWidth: true
            Label { text: modelData.id.slice(0, 8); color: engine.theme.text; font.pixelSize: 9; font.family: engine.theme.fontMono }
            Item { Layout.fillWidth: true }
            Label { text: modelData.status === "done" ? win.tt("done") : (modelData.status === "error" ? win.tt("error") : win.tt("rendering")); color: modelData.status === "done" ? engine.theme.good : (modelData.status === "error" ? engine.theme.bad : engine.theme.warn); font.pixelSize: 9 }
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
      Label { text: "FORMATO"; color: engine.theme.textDim; font.pixelSize: 9; font.bold: true; font.letterSpacing: 1 }
      Rectangle {
        Layout.fillWidth: true; height: 30; radius: engine.theme.radius; color: engine.theme.panelDeep; border.color: engine.theme.border
        Label { anchors.centerIn: parent; text: "Vertical 9:16 · 1080×1920"; color: engine.theme.text; font.pixelSize: 11 }
      }
      Label { text: win.tt("template").toUpperCase(); color: engine.theme.textDim; font.pixelSize: 9; font.bold: true; font.letterSpacing: 1 }
      Label {
        visible: win.selectedBlock >= 0
        text: { var b = win.activeBlock(); return "BLOQUE " + (win.selectedBlock + 1) + " · " + win.fmtDur(b ? b.end - b.start : 0) }
        color: engine.theme.orange; font.pixelSize: 9; font.bold: true
      }
      NleButton {
        visible: win.selectedBlock >= 0
        Layout.fillWidth: true
        text: { var b = win.activeBlock(); return b && b.visible === false ? "◉ " + win.tt("showBlock") : "◌ " + win.tt("hideBlock") }
        tip: win.tt("blockVisibilityTip")
        onClicked: win.toggleSelectedBlockVisibility()
      }
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
        Label { text: "x/y"; color: engine.theme.textDim }
        Slider { Layout.fillWidth: true; from: 0; to: 1; value: { var b = win.activeBlock(); return b ? (b.fx || 0.5) : win.pipFx }
                 onMoved: { var b = win.activeBlock(); if (b) { b.fx = value; var cp = win.blocks.slice(); cp[win.selectedBlock] = b; win.blocks = cp } else win.pipFx = value } }
        Slider { Layout.fillWidth: true; from: 0; to: 1; value: { var b = win.activeBlock(); return b ? (b.fy || 0.72) : win.pipFy }
                 onMoved: { var b = win.activeBlock(); if (b) { b.fy = value; var cp = win.blocks.slice(); cp[win.selectedBlock] = b; win.blocks = cp } else win.pipFy = value } }
      }
      GridLayout {
        visible: win.activeLayout() !== "apilar"; columns: 4; Layout.fillWidth: true
        Label { text: "x"; color: engine.theme.textDim } FnSpin { from: 0; to: 100; value: win.regionX; onValueModified: win.regionX = value; Layout.fillWidth: true }
        Label { text: "y"; color: engine.theme.textDim } FnSpin { from: 0; to: 100; value: win.regionY; onValueModified: win.regionY = value; Layout.fillWidth: true }
        Label { text: "w"; color: engine.theme.textDim } FnSpin { from: 1; to: 100; value: win.regionW; onValueModified: win.regionW = value; Layout.fillWidth: true }
        Label { text: "h"; color: engine.theme.textDim } FnSpin { from: 1; to: 100; value: win.regionH; onValueModified: win.regionH = value; Layout.fillWidth: true }
      }
      RowLayout {
        visible: win.activeLayout() !== "apilar"
        Rectangle {
          width: 16; height: 16; radius: 4; border.color: engine.theme.border; color: win.lock916 ? engine.theme.accent : engine.theme.panelDeep
          Label { anchors.centerIn: parent; text: "✓"; color: "#16161e"; font.pixelSize: 10; visible: win.lock916 }
          MouseArea { anchors.fill: parent; onClicked: win.lock916 = !win.lock916 }
        }
        Label { text: "9:16"; color: engine.theme.textMuted; font.pixelSize: 10 }
      }
      RowLayout {
        visible: win.activeLayout() === "apilar"; Layout.fillWidth: true
        Label { text: win.tt("split"); color: engine.theme.textDim }
        Slider { Layout.fillWidth: true; from: 0.15; to: 0.85; value: win.activeSplit(); onValueChanged: win.setSplit(value) }
        Label { text: Math.round(win.activeSplit() * 100) + "%"; color: engine.theme.textMuted; font.family: engine.theme.fontMono; font.pixelSize: 10 }
      }
    }
    Item { Layout.fillHeight: true }
  }

  component OutputContent: Item {
    id: outputContent
    OutputPreview {
      anchors.fill: parent; anchors.margins: 6
      active: outputContent.visible
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
      layers: { win.layersRev; return win.layers.slice() }
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
        width: 146; height: 250; radius: engine.theme.radius
        color: oh2.containsMouse ? "#272c42" : engine.theme.panelAlt; border.color: engine.theme.borderSoft
        ColumnLayout {
          anchors.fill: parent; anchors.margins: 8; spacing: 6
          Image {
            Layout.fillWidth: true; Layout.preferredHeight: 158
            source: modelData.thumb || ""; fillMode: Image.PreserveAspectCrop
            Rectangle { anchors.fill: parent; color: "#000"; visible: parent.status !== Image.Ready; radius: 3 }
          }
          Label { text: modelData.name.slice(0, 14) + "…"; color: engine.theme.text; font.pixelSize: 10; font.family: engine.theme.fontMono; Layout.fillWidth: true }
          Label { text: win.fmtSize(modelData.size); color: engine.theme.textMuted; font.pixelSize: 9; font.family: engine.theme.fontMono }
          RowLayout { Layout.fillWidth: true; spacing: 4
            IconBtn { glyph: "▶"; tip: win.tt("playOutput"); onClicked: { win.view = "edit"; loadVideo(modelData.path) } }
            IconBtn { glyph: "📂"; tip: win.tt("openFolder"); onClicked: engine.openFolder(modelData.path) }
            Item { Layout.fillWidth: true }
            IconBtn { glyph: "🗑"; tip: win.tt("deleteOutput"); onClicked: { engine.deleteMedia(modelData.path); win.refreshOutputs() } }
          }
        }
        MouseArea { id: oh2; anchors.fill: parent; hoverEnabled: true; z: -1 }
      }
    }
    Label { anchors.centerIn: parent; visible: win.outputs.length === 0; text: win.tt("noOutputs"); color: engine.theme.textDim }
  }

  // ---------- header ----------
  header: Rectangle {
    height: 44; color: engine.theme.panelAlt
    Rectangle { anchors.bottom: parent.bottom; width: parent.width; height: 1; color: engine.theme.border }
    RowLayout {
      anchors.fill: parent; anchors.leftMargin: 14; anchors.rightMargin: 14
      Label { text: "OMASHORT"; color: engine.theme.text; font.pixelSize: 14; font.bold: true; font.letterSpacing: 2 }
      Rectangle { width: 1; height: 18; color: engine.theme.border }
      Label { text: win.current ? win.current.title : ""; color: engine.theme.textMuted; font.pixelSize: 11; elide: Text.ElideMiddle; Layout.maximumWidth: 320 }
      Item { Layout.fillWidth: true }
      Row {
        spacing: 0
        Rectangle {
          width: et1.width + 22; height: 28; radius: engine.theme.radius
          color: win.view === "edit" ? engine.theme.accentSoft : "transparent"; border.color: win.view === "edit" ? engine.theme.accent : engine.theme.border
          Label { id: et1; anchors.centerIn: parent; text: win.tt("viewEdit"); color: win.view === "edit" ? engine.theme.accent : engine.theme.textMuted; font.pixelSize: 11; font.bold: win.view === "edit" }
          MouseArea { anchors.fill: parent; onClicked: win.view = "edit" }
        }
        Item { width: 6; height: 1 }
        Rectangle {
          width: et2.width + 22; height: 28; radius: engine.theme.radius
          color: win.view === "out" ? engine.theme.accentSoft : "transparent"; border.color: win.view === "out" ? engine.theme.accent : engine.theme.border
          Label { id: et2; anchors.centerIn: parent; text: win.tt("viewOutputs"); color: win.view === "out" ? engine.theme.accent : engine.theme.textMuted; font.pixelSize: 11; font.bold: win.view === "out" }
          MouseArea { anchors.fill: parent; onClicked: { win.view = "out"; win.refreshOutputs() } }
        }
      }
      Item { Layout.fillWidth: true }
      Label { visible: win.view === "edit"; text: "␣ play · ←→ frame · I/O · L loop"; color: engine.theme.textDim; font.pixelSize: 10 }
      Item { Layout.fillWidth: true }
      NleButton { text: "+ " + win.tt("newProject"); tip: engine.projectFile; onClicked: win.requestNewProject() }
      NleButton { text: "↥ " + win.tt("openProject"); tip: engine.projectFile; onClicked: projectOpenDialog.open() }
      NleButton { text: "⇩ " + win.tt("saveAs"); tip: engine.projectFile; onClicked: projectSaveDialog.open() }
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
      background: Rectangle { color: engine.theme.panel; border.color: engine.theme.border; radius: engine.theme.radius }
      contentItem: ColumnLayout {
        spacing: 2
        Label { text: win.tt("panels").toUpperCase(); color: engine.theme.textDim; font.pixelSize: 9; font.bold: true; font.letterSpacing: 1.2; Layout.leftMargin: 6; Layout.topMargin: 4 }
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
                color: prow.checked ? engine.theme.accent : engine.theme.panelDeep
                border.color: prow.checked ? engine.theme.accent : engine.theme.border
                Label { anchors.centerIn: parent; text: "✓"; color: "#16161e"; font.pixelSize: 9; visible: prow.checked }
              }
              Label { text: win.panelTitle(modelData); color: engine.theme.text; font.pixelSize: 11 }
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

  FileDialog {
    id: projectOpenDialog
    fileMode: FileDialog.OpenFile
    nameFilters: ["OmaShort project (*.json)"]
    onAccepted: {
      var doc = engine.openProjectFile(selectedFile)
      if (doc && doc.version) { win.applyProject(doc); win.lastSavedStr = JSON.stringify(win.projectDoc()) }
    }
  }
  FileDialog {
    id: renderSaveDialog
    fileMode: FileDialog.SaveFile
    defaultSuffix: "mp4"
    nameFilters: ["Video MP4 (*.mp4)"]
    onAccepted: win.renderSelectedOutput(selectedFile)
  }
  FileDialog {
    id: projectSaveDialog
    fileMode: FileDialog.SaveFile
    defaultSuffix: "json"
    nameFilters: ["OmaShort project (*.json)"]
    onAccepted: {
      var doc = win.projectDoc(false)
      if (engine.saveProjectAs(selectedFile, doc)) {
        var saved = engine.openProjectFile(selectedFile)
        if (saved && saved.version) win.applyProject(saved)
        win.lastSavedStr = JSON.stringify(win.projectDoc())
      }
    }
  }
  Dialog {
    id: deleteConfirmDialog
    property string deleteKind: ""
    property string targetPath: ""
    property string targetName: ""
    modal: true
    closePolicy: Popup.NoAutoClose
    title: win.tt("confirmDeleteTitle")
    standardButtons: Dialog.Yes | Dialog.No
    width: Math.min(460, win.width - 40)
    x: Math.round((win.width - width) / 2)
    y: Math.round((win.height - height) / 2)
    onAccepted: win.confirmDelete()
    contentItem: Label {
      text: win.tt(deleteConfirmDialog.deleteKind === "source" ? "confirmDeleteSource" : "confirmDeleteTimeline")
              .replace("%1", deleteConfirmDialog.targetName)
      color: engine.theme.text
      wrapMode: Text.WordWrap
      font.pixelSize: 12
    }
  }
  Dialog {
    id: replaceVideoDialog
    property string targetPath: ""
    property string targetName: ""
    modal: true
    closePolicy: Popup.NoAutoClose
    title: win.tt("confirmReplaceTitle")
    width: Math.min(460, win.width - 40)
    x: Math.round((win.width - width) / 2)
    y: Math.round((win.height - height) / 2)
    contentItem: Label {
      text: win.tt("confirmReplaceVideo").replace("%1", replaceVideoDialog.targetName)
      color: engine.theme.text
      wrapMode: Text.WordWrap
      font.pixelSize: 12
    }
    footer: DialogButtonBox {
      Button {
        text: win.tt("replaceMainAction")
        DialogButtonBox.buttonRole: DialogButtonBox.AcceptRole
        onClicked: win.confirmMainVideoReplacement()
      }
      Button {
        text: win.tt("addAsLayerAction")
        DialogButtonBox.buttonRole: DialogButtonBox.ActionRole
        onClicked: win.addPendingMainVideoAsLayer()
      }
      Button {
        text: win.tt("cancel")
        DialogButtonBox.buttonRole: DialogButtonBox.RejectRole
        onClicked: replaceVideoDialog.close()
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
                            color: rma.containsMouse || rma.pressed ? engine.theme.accent : engine.theme.border }
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
                        color: cma.containsMouse || cma.pressed ? engine.theme.accent : engine.theme.border }
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
                  color: tlma.containsMouse || tlma.pressed ? engine.theme.accent : engine.theme.border }
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
      snappingLabel: win.tt("snapping")
      snappingTip: win.tt("snappingTip")
      videoPresent: win.current !== null || win.cutPath !== ""
      primaryAudioEnabled: win.primaryAudioEnabled
      deleteVideoLabel: win.tt("deleteTimelineVideo")
      deleteVideoTip: win.tt("deleteTimelineVideo")
      visible: win.view === "edit"
      Layout.fillWidth: true
      Layout.preferredHeight: win.tlHeight > 0 ? win.tlHeight : 216 + timeline.trackCount() * 29
      duration: Math.max(0.1, durS())
      position: playerRef ? playerRef.position / 1000 : 0
      trimIn: win.trimIn; trimOut: win.trimOut
      stripUrls: win.stripUrls
      layers: { win.layersRev; return win.layers.slice() }
      layersRev: win.layersRev
      selectedLayer: win.selectedLayer
      blocks: { win.blocksRev; return win.blocks.slice() }
      blocksRev: win.blocksRev
      selectedBlock: win.selectedBlock
      onDeleteVideoRequested: win.requestTimelineDelete()
      onSeek: function (t) { if (playerRef) playerRef.position = Math.round(t * 1000); if (win.blocks.length) win.selectBlockAt(t) }
      onBlockClicked: function (i) { win.selectedBlock = i; win.selectedLayer = -1 }
      onBlockEdited: function (i, patch) {
        var cp = win.blocks; var b = cp[i]; if (!b) return
        if (patch.start !== undefined) b.start = patch.start
        if (patch.end !== undefined) b.end = patch.end
        // clamp into neighbors
        if (i > 0 && b.start < cp[i-1].end) cp[i-1].end = b.start
        if (i < cp.length - 1 && b.end > cp[i+1].start) cp[i+1].start = b.end
        win.blocksRev = (win.blocksRev + 1) % 2000000000
      }
      onTrimEdited: function (a, b) { win.trimIn = a; win.trimOut = b }
      onLayerEdited: function (i, a, b) { win.layers[i].inS = a; win.layers[i].outS = b; win.touchLayers() }
      onAudioToggled: function (i) { win.patchLayer(i, { audioEnabled: win.layers[i].audioEnabled === false }) }
      onAudioMoved: function (i, offset) { win.patchLayer(i, { audioOffset: Math.round(offset * 100) / 100 }) }
      onPrimaryAudioToggled: { win.primaryAudioEnabled = !win.primaryAudioEnabled; win.touchLayers() }
      onPrimaryClicked: { win.selectedLayer = -1; win.selectedBlock = -1 }
      onCreatePrimaryClip: { win.createClipFromPrimarySelection() }
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
    color: engine.theme.accent; radius: 2; z: 99
  }

  // drag ghost overlay
  Rectangle {
    id: dragGhost
    visible: win.dragPanel !== ""
    width: ghostLbl.width + 24; height: 30; radius: engine.theme.radius
    color: engine.theme.accentSoft; border.color: engine.theme.accent; opacity: 0.9; z: 100
    y: 60
    Label { id: ghostLbl; anchors.centerIn: parent; text: win.dragPanel.toUpperCase(); color: engine.theme.text; font.pixelSize: 11; font.bold: true }
  }
}
