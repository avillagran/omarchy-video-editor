# Omareel

![Omareel — native Qt6/QML video editor for Omarchy](preview.png)

Editor de clips local para Omarchy. **Versión nativa C++/Qt6/QML — sin server,
sin internet, sin Electron.** Procesamiento con ffmpeg/ffprobe del sistema.

La versión HTML/Electron (server/ + electron/ + tests CDP) fue archivada en
`~/Desarrollo/Omareel-html-archive/` (2026-09-10); el único producto activo es
`native/`.

## Arquitectura

```
native/
  src/engine.{h,cpp}   engine C++: worker thread + cola de tareas
  src/main.cpp         entry point, --selftest, flags --uitest*
  qml/                 UI QML: main.qml (dock), Timeline, Panel, OverlayLayers,
                       OutputPreview, RegionEditor, Theme.js (tokens), I18n.js
  omareel-native.pro   qmake6
```

- `QProcess` sobre ffmpeg/ffprobe del sistema (rendimiento local, sin wasm).
- Datos en `~/.local/share/omareel/`:
  - `media/` fuentes, `media/clips/` cortes, `out/` renders (`*-v.mp4` vertical,
    `*-h.mp4` horizontal), `out/thumbs/`
  - `project.json` proyecto AI-editable con live reload
  - `native-qml/` QML desplegado (la app corre contra esta copia)

## Build y uso

```bash
cd native && qmake6 omareel-native.pro && make -j4
./omareel-native              # GUI (Wayland/Hyprland)
QT_QPA_PLATFORM=offscreen ./omareel-native --selftest   # pipeline headless: render → verifica

# flags deterministas para screenshots/verificación:
--uitest            # trim 5-10s, loop, 2 textos
--uitest-out        # entra en modo Salidas
--uitest-dock       # dock reordenado + inspector colapsado
--uitest-blocks     # 3 bloques (completa/apilar/círculo)
--uitest-pause      # pausa determinista 2.6s (misma ruta que Space)
--uitest-render     # render dual v+h por la ruta del panel RENDER
```

Despliegue del QML a la VM: `rsync -a --delete native/qml/ <vm>:~/.local/share/omareel/native-qml/`

## Features (UI)

- Paneles dockables: FUENTES | PROGRAM+OUTPUT | CAPAS+GALERÍA | INSPECTOR+RENDER.
  Drag de headers (umbral 6px), doble-click = colapsar, ✕ cierra, **⊞ Paneles**
  los re-habilita. Resize proporcional por fracciones colFr/rowFr.
- PROGRAM: monitor fuente con RegionEditor anclado a `VideoOutput.contentRect`
  (WYSIWYG exacto del crop). OUTPUT: preview 9:16 vertical en vivo.
- **Edición dual de formato**: cada capa tiene `x,y,w,h` (OUTPUT 9:16) y
  `px,py,pw,ph` (PROGRAM/fuente) — arrastrar en un monitor no toca el otro.
- Timeline NLE propia: regla adaptativa, filmstrip cacheado, trim in/out,
  playhead, loop A-B, zoom, bloques (pista B) con layouts por segmento
  (completa/apilar/pip/círculo), reorden de pistas desde headers V1/T1/T2,
  pegada abajo y redimensionable solo en vertical (`tlHeight`).
- Capas: texto (rasterizado QPainter), GIF, imagen, video PiP con forma
  (rect/rounded/circle — OpacityMask en vivo, alphamerge+PNG mask en render).
- Panel RENDER: formato vertical y/o horizontal a la vez, codec H.264/H.265/VP9,
  calidad CRF 18/23/28, cola de trabajos con progreso.
- Proyecto `project.json`: autoguardado ~1.5s + **live reload** ante ediciones
  externas (QFileSystemWatcher + guard por hash) — pensado para LLMs.
  Formato: `docs/project-format.md`.
- i18n es/en (`qml/I18n.js`), persiste en el engine.

## Engine de render

- Filtergraph por bloques: trim → layoutChain (crop cover por región, vstack
  apilar, PiP cuadrado = lado menor/2, círculo = alphamerge con máscara PNG)
  → setsar=1 → concat (video + audio) → overlays acotados a la duración de la
  base (suma de bloques) con `enable='between(t,inS,outS)'`.
- Espacio de capas: `space="out"` usa x,y,w,h; `space="prog"` usa px,py,pw,ph.
- Codec tail: libx264/libx265(-tag:v hvc1)/libvpx-vp9(-b:v 0), `-r <fps>`,
  faststart, salida `<jobId>[-v|-h].mp4`.

## Anti-negro en reproducción (GStreamer/Qt Multimedia)

`VideoOutput` queda negro al pausar/llegar a EndOfMedia en algunos pipelines:
- `pausePlayback()` = pause + micro-seek +1ms (fuerza preroll del frame).
- Guardia: rebobinar ~0.25s antes de EndOfMedia.
- Fallback: play ~90ms + pause si ya cayó en StoppedState.
- Misma política en players secundarios (OUTPUT) vía `syncPlayer()`.

## Pitfalls

- Nunca declarar `property var layer` en un Item: colisiona con el miembro
  FINAL `layer` de QQuickItem → crash silencioso (exit 255, sin log).
- qDebug/qWarning están silenciados en release en Omarchy — usar
  `fprintf(stderr, ...)` para diagnósticos.
- Qt retira paths de QFileSystemWatcher tras rename-replace: re-añadir el path
  al procesar fileChanged.
- Overlays infinitos cuelgan ffmpeg 9: siempre `trim=duration=…` + setpts.
- `rsync --delete` del QML apunta a `~/.local/share/omareel/native-qml/`, no al
  árbol de fuentes.

## Estado verificado (2026-09-10, VM QEMU Omarchy)

- `--selftest`: PASS (render 1080×1920 verificado con ffprobe).
- Render dual end-to-end: `-v.mp4` 1080×1920 y `-h.mp4` 1920×1080, ambos
  10.000s con bloques 0-10s; capas con inS/outS respetadas
  (`between(t,5,10)` / `between(t,6,9)`); textos en posiciones distintas por
  formato (dual-space confirmado visualmente).
