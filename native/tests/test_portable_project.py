"""Portable projects can load media outside the data media folder."""
from pathlib import Path
import re
import unittest

SOURCE = (Path(__file__).resolve().parents[1] / "qml" / "main.qml").read_text()
ENGINE = (Path(__file__).resolve().parents[1] / "src" / "engine.cpp").read_text()
HEADER = (Path(__file__).resolve().parents[1] / "src" / "engine.h").read_text()
I18N = (Path(__file__).resolve().parents[1] / "qml" / "I18n.js").read_text()
TIMELINE = (Path(__file__).resolve().parents[1] / "qml" / "Timeline.qml").read_text()


class PortableProjectMedia(unittest.TestCase):
    def test_apply_project_falls_back_to_direct_video_probe(self):
        body = re.search(r"function applyProject\(d\) \{(.*?)\n  \}", SOURCE, re.S)
        self.assertIsNotNone(body)
        text = body.group(1)
        self.assertIn("engine.probeVideo(d.video)", text)
        self.assertIn("loadVideo(d.video)", text)

    def test_autosave_preserves_relative_media_paths(self):
        self.assertIn('doc[QStringLiteral("_pathHints")] = hints', ENGINE)
        self.assertIn("keepHints ? win.serializedPath(win.current.path) : win.current.path", SOURCE)
        self.assertIn("layers: win.serializedLayers(keepHints)", SOURCE)
        self.assertIn("srt: keepHints ? win.serializedPath(win.srtPath) : win.srtPath", SOURCE)
        self.assertIn("var doc = win.projectDoc(false)", SOURCE)

    def test_opening_project_does_not_immediately_rewrite_it(self):
        self.assertNotIn("lastSavedStr = JSON.stringify(proj); applyProject(proj)", SOURCE)
        self.assertIn("applyProject(proj); lastSavedStr = JSON.stringify(win.projectDoc())", SOURCE)

    def test_save_as_returns_the_atomic_write_result(self):
        self.assertIn("bool OmareelEngine::saveProject", ENGINE)
        self.assertIn("if (!writeProjectFile(target, relativizeProjectPaths(doc, target), &hash)) return false", ENGINE)
        self.assertIn("if (str !== win.lastSavedStr && engine.saveProject(doc))", SOURCE)
        self.assertNotIn("return QFileInfo::exists(projectPath()) && QFileInfo(projectPath()).size() > 0", ENGINE)

    def test_new_project_has_a_toolbar_action_and_safe_fresh_target(self):
        self.assertIn('newProject: "Nuevo proyecto"', I18N)
        self.assertIn('newProject: "New project"', I18N)
        self.assertIn('win.tt("newProject")', SOURCE)
        self.assertIn("function requestNewProject()", SOURCE)
        self.assertIn("engine.saveProject(currentDoc)", SOURCE)
        self.assertIn("function beginNewProject()", SOURCE)
        self.assertIn("engine.newProject()", SOURCE)
        self.assertIn("win.current = null", SOURCE)
        self.assertIn("win.layers = []", SOURCE)
        self.assertIn("win.blocks = []", SOURCE)
        self.assertIn("Q_INVOKABLE QString newProject()", HEADER)
        self.assertIn("QString OmareelEngine::newProject()", ENGINE)

    def test_source_and_timeline_video_deletion_require_confirmation(self):
        self.assertIn("function requestSourceDelete(path, title)", SOURCE)
        self.assertIn("function requestTimelineDelete()", SOURCE)
        self.assertIn("id: deleteConfirmDialog", SOURCE)
        self.assertIn("modal: true", SOURCE)
        self.assertIn("onDeleteVideoRequested: win.requestTimelineDelete()", SOURCE)
        self.assertIn("Q_INVOKABLE bool removeSource", HEADER)
        self.assertIn("bool OmareelEngine::removeSource", ENGINE)
        confirm = re.search(r"function confirmDelete\(\) \{(.*?)\n  \}", SOURCE, re.S)
        self.assertIsNotNone(confirm)
        self.assertIn("engine.removeSource(deleteConfirmDialog.targetPath)", confirm.group(1))
        self.assertNotIn("engine.deleteMedia", confirm.group(1))
        clear_timeline = re.search(r"function clearTimelineVideo\(\) \{(.*?)\n  \}", SOURCE, re.S)
        self.assertIsNotNone(clear_timeline)
        self.assertIn("engine.saveProject(doc)", clear_timeline.group(1))
        self.assertIn('confirmDeleteSource: "¿Quitar', I18N)
        self.assertIn("El archivo seguirá almacenado localmente", I18N)
        self.assertIn('confirmDeleteTimeline: "¿Quitar', I18N)

    def test_sources_can_add_multiple_video_layers_to_timeline(self):
        self.assertIn('addSourceAsLayer: "Agregar como capa de video"', I18N)
        self.assertIn('win.addLayer("video", modelData.path)', SOURCE)
        self.assertIn("function layerTrackLabel(index)", TIMELINE)
        self.assertIn('return "V" + number', TIMELINE)
        self.assertIn("engine.probeVideo(path)", SOURCE)
        self.assertIn("pw: programSize.w", SOURCE)
        self.assertIn("ph: programSize.h", SOURCE)
        self.assertIn("sourceAspect: mediaAspect", SOURCE)
        self.assertIn('shape: "rect"', SOURCE)
        self.assertIn("engine.importVideo(fileUrls[i])", SOURCE)

    def test_video_import_accepts_multiple_files_without_replacement_prompt(self):
        self.assertIn("function importVideos(fileUrls, addAsLayers)", SOURCE)
        self.assertGreaterEqual(SOURCE.count("fileMode: FileDialog.OpenFiles"), 2)
        self.assertGreaterEqual(SOURCE.count("win.importVideos(selectedFiles"), 2)
        self.assertIn("if (!win.current && imported.length > 0)", SOURCE)
        import_dialog = SOURCE[SOURCE.index("id: importDialog"):SOURCE.index("id: importDialog") + 400]
        self.assertNotIn("requestMainVideo", import_dialog)

    def test_video_layer_text_binding_accepts_video_without_text(self):
        self.assertIn('text: modelData.text || ""', SOURCE)

    def test_video_probe_uses_the_video_stream_when_audio_is_first(self):
        engine = (Path(__file__).resolve().parents[1] / "src" / "engine.cpp").read_text()
        self.assertIn('stream=codec_type,width,height:format=duration', engine)
        self.assertIn('value(QStringLiteral("codec_type")).toString() != QLatin1String("video")', engine)
        self.assertIn("for (const QJsonValue &value : streams)", engine)

    def test_legacy_video_layers_are_refit_to_their_source_aspect(self):
        self.assertIn("function normalizeVideoLayerAspect(layer, programAspect)", SOURCE)
        self.assertIn("normalizedLayers.push(win.normalizeVideoLayerAspect", SOURCE)
        self.assertIn("layer.h = layer.w * (9 / 16) / mediaAspect", SOURCE)
        self.assertIn("layer.ph = layer.pw * programAspect / mediaAspect", SOURCE)

    def test_replacing_the_main_video_requires_confirmation(self):
        self.assertIn("function requestMainVideo(path, title)", SOURCE)
        self.assertIn("id: replaceVideoDialog", SOURCE)
        self.assertIn("modal: true", SOURCE)
        self.assertIn("win.confirmMainVideoReplacement()", SOURCE)
        self.assertIn("win.addPendingMainVideoAsLayer()", SOURCE)
        self.assertIn('replaceMainAction: "Reemplazar V1"', I18N)
        self.assertIn('addAsLayerAction: "Agregar como capa"', I18N)
        self.assertIn('confirmReplaceVideo: "¿Reemplazar', I18N)
        self.assertIn("win.requestMainVideo(modelData.path, modelData.title)", SOURCE)

    def test_loading_a_project_without_v1_clears_any_selected_source(self):
        self.assertIn("function clearMainVideoState()", SOURCE)
        self.assertIn("if (!d.video)", SOURCE)
        self.assertIn("win.clearMainVideoState()", SOURCE)
        completed = SOURCE[SOURCE.index("Component.onCompleted:"):]
        self.assertLess(completed.index("engine.loadProject()"), completed.index("sources.length > 0"))

    def test_autosave_persists_layer_only_projects(self):
        timer = SOURCE[SOURCE.index("id: saveTimer"):SOURCE.index("id: saveTimer") + 450]
        self.assertIn('if (win.view !== "edit") return', timer)
        self.assertNotIn("!win.current", timer)

    def test_same_basename_imports_receive_distinct_destinations(self):
        engine = (Path(__file__).resolve().parents[1] / "src" / "engine.cpp").read_text()
        self.assertIn("static bool sameLocalFile", engine)
        self.assertIn("while (QFileInfo::exists(dst))", engine)
        self.assertIn('QStringLiteral("-import-%1.")', engine)

    def test_video_layers_have_independent_audio_tracks(self):
        self.assertIn("audioEnabled: true", SOURCE)
        self.assertIn("audioOffset: 0", SOURCE)
        self.assertIn("signal audioToggled", TIMELINE)
        self.assertIn("signal audioMoved", TIMELINE)
        self.assertIn("function trackCount()", TIMELINE)
        self.assertIn('text: "A" + (index + 1)', TIMELINE)
        self.assertIn('text: track.clipData.audioEnabled === false ? "muted"', TIMELINE)
        self.assertIn("onAudioToggled", SOURCE)
        self.assertIn("onAudioMoved", SOURCE)

    def test_primary_video_has_toggleable_speaker_audio_track(self):
        self.assertIn("primaryAudioEnabled", SOURCE)
        self.assertIn("audioEnabled: win.primaryAudioEnabled", SOURCE)
        self.assertIn("primaryAudioToggled", TIMELINE)
        self.assertIn('text: tl.primaryAudioEnabled ? "󰕾" : "󰖁"', TIMELINE)
        self.assertIn('text: tl.primaryAudioEnabled ? "audio · 100%" : "muted"', TIMELINE)

    def test_timeline_selection_cuts_and_deletes_selected_media(self):
        self.assertIn("signal primaryClicked", TIMELINE)
        self.assertIn("onClicked: tl.primaryClicked()", TIMELINE)
        self.assertIn("function cutSelectedAt(t)", SOURCE)
        self.assertIn("var left = JSON.parse(JSON.stringify(layer))", SOURCE)
        self.assertIn("function deleteSelectedClip()", SOURCE)
        self.assertIn('sequence: "B"', SOURCE)
        self.assertIn('text: "⌫"', SOURCE)
        self.assertIn("win.cutSelectedAt(player.position / 1000)", SOURCE)
        self.assertIn("blocks = [mkBlock(0, durS(), layoutName())]", SOURCE)

    def test_timeline_wheel_zoom_uses_pointer_anchor(self):
        self.assertIn("acceptedModifiers: Qt.NoModifier | Qt.ControlModifier", TIMELINE)
        self.assertIn("var anchorT = (flick.contentX + wheel.x) / tl.pps()", TIMELINE)
        self.assertIn("tl.zoomBy(wheel.angleDelta.y > 0 ? 1.25 : 0.8, anchorT)", TIMELINE)
        self.assertIn("acceptedModifiers: Qt.ShiftModifier", TIMELINE)

    def test_primary_filmstrip_has_an_active_selection_hit_area(self):
        self.assertIn('height: tl.stripH; z: 1', TIMELINE)
        self.assertIn('acceptedButtons: Qt.LeftButton', TIMELINE)
        self.assertIn('tl.primaryClicked()', TIMELINE)

    def test_primary_in_out_selection_can_become_a_new_video_layer(self):
        self.assertIn("signal createPrimaryClip", TIMELINE)
        self.assertIn('text: "✂"', TIMELINE)
        self.assertIn("tl.createPrimaryClip()", TIMELINE)
        self.assertIn("function createClipFromPrimarySelection()", SOURCE)
        self.assertIn('win.addLayer("video", src)', SOURCE)
        self.assertIn("onCreatePrimaryClip", SOURCE)
        self.assertIn("sourceIn: win.trimIn", SOURCE)
        self.assertIn("sourceOut: win.trimOut", SOURCE)
        self.assertIn("l.sourceIn || 0", (Path(__file__).resolve().parents[1] / "qml" / "OverlayLayers.qml").read_text())
        self.assertIn("trim=start=%1:duration=%2", ENGINE)

    def test_selected_timeline_block_can_be_shown_or_hidden(self):
        self.assertIn("visible: true", SOURCE)
        self.assertIn("function toggleSelectedBlockVisibility()", SOURCE)
        self.assertIn("showBlock", I18N)
        self.assertIn("hideBlock", I18N)
        self.assertIn("win.blocks.filter(function (b) { return b.visible !== false })", SOURCE)
        self.assertIn("bb.clipData.visible === false", TIMELINE)

    def test_loop_skips_hidden_blocks_and_restarts_at_visible_block(self):
        self.assertIn("function loopVisibleAt(t)", SOURCE)
        self.assertIn("function loopToVisible(t)", SOURCE)
        self.assertIn("function loopRestartPosition()", SOURCE)
        self.assertIn("if (win.loop && win.blocks.length)", SOURCE)
        self.assertIn("playerRef.position = Math.round((next >= 0 && next < trimOut ? next : loopRestartPosition()) * 1000)", SOURCE)
        self.assertIn("win.loopRestartPosition()", SOURCE)


if __name__ == "__main__":
    unittest.main()
