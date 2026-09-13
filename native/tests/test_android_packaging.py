"""Android build contracts for the native Qt application."""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]
PROJECT = (ROOT / "omareel-native.pro").read_text()
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
        self.assertIn('package="cl.villagranquiroz.omareel"', manifest)
        self.assertIn('android:versionName="0.0.1"', manifest)
        self.assertIn('android:allowBackup="false"', manifest)
        self.assertIn('android:screenOrientation="sensorLandscape"', manifest)

    def test_android_content_uri_is_copied_and_loaded(self):
        self.assertIn('sourceUrl.scheme() == QLatin1String("content")', ENGINE)
        self.assertIn('openFileDescriptor', ENGINE)
        self.assertNotIn('while (!input.atEnd())', ENGINE)
        self.assertIn('var imported = engine.importVideo(selectedFile)', MAIN)
        self.assertIn('win.loadVideo(imported)', MAIN)


if __name__ == "__main__":
    unittest.main()
