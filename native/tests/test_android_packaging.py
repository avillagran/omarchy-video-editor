"""Android build contracts for the native Qt application."""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]
PROJECT = (ROOT / "omashort-native.pro").read_text()
OVERLAY = (ROOT / "qml" / "OverlayLayers.qml").read_text()
OUTPUT = (ROOT / "qml" / "OutputPreview.qml").read_text()
ENGINE = (ROOT / "src" / "engine.cpp").read_text()
MAIN = (ROOT / "qml" / "main.qml").read_text()


class AndroidPackaging(unittest.TestCase):
    def test_mask_uses_cross_platform_qt6_effect(self):
        for source in (OVERLAY, OUTPUT):
            self.assertIn("import QtQuick.Effects", source)
            self.assertIn("MultiEffect {", source)
            self.assertNotIn("Qt5Compat.GraphicalEffects", source)
            self.assertNotIn("OpacityMask {", source)

    def test_android_has_stable_package_source(self):
        self.assertIn("ANDROID_PACKAGE_SOURCE_DIR", PROJECT)
        manifest = (ROOT / "android" / "AndroidManifest.xml").read_text()
        self.assertIn('package="cl.villagranquiroz.omashort"', manifest)
        self.assertIn('android:versionCode="2"', manifest)
        self.assertIn('android:versionName="0.0.2"', manifest)
        self.assertIn('android:allowBackup="false"', manifest)
        self.assertIn('android:screenOrientation="sensorLandscape"', manifest)
        self.assertNotIn('READ_MEDIA_VIDEO', manifest)
        self.assertNotIn('READ_EXTERNAL_STORAGE', manifest)

    def test_android_content_uri_is_copied_and_loaded(self):
        self.assertIn('sourceUrl.scheme() == QLatin1String("content")', ENGINE)
        self.assertIn('openFileDescriptor', ENGINE)
        self.assertNotIn('while (!input.atEnd())', ENGINE)
        self.assertIn('displayName == QLatin1String(".")', ENGINE)
        self.assertIn('::close(fd)', ENGINE)
        self.assertIn('var path = engine.importVideo(fileUrls[i])', MAIN)
        self.assertIn('if (!win.current && imported.length > 0)', MAIN)

    def test_video_layers_preroll_when_added_while_paused(self):
        self.assertIn("function syncLayerPlayer", OVERLAY)
        self.assertIn("MediaPlayer.StoppedState", OVERLAY)
        self.assertIn("pl.play()", OVERLAY)
        self.assertIn("pl.position = pl.position + 1", OVERLAY)
        self.assertIn('layer.enabled: (modelData.shape || "rect") !== "rect"', OVERLAY)
        self.assertIn("layer.effect: MultiEffect", OVERLAY)
        self.assertIn("maskEnabled: true", OVERLAY)

    def test_hidden_dock_copies_do_not_open_video_decoders(self):
        self.assertIn("property bool active: true", OVERLAY)
        self.assertIn("source: { ov.rev; return ov.active", OVERLAY)
        self.assertIn("running: ov.active && ld.visible", OVERLAY)
        self.assertIn("property bool active: true", OUTPUT)
        self.assertIn("source: op.active && op.videoPath", OUTPUT)
        self.assertIn("active: programContent.visible", MAIN)
        self.assertIn("active: outputContent.visible", MAIN)


if __name__ == "__main__":
    unittest.main()
