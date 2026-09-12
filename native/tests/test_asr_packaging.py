"""The bundled offline ASR helper must resolve in source builds."""
from pathlib import Path
import unittest

SOURCE = (Path(__file__).resolve().parents[1] / "src" / "engine.cpp").read_text()
PROJECT = (Path(__file__).resolve().parents[1] / "omareel-native.pro").read_text()
MAIN = (Path(__file__).resolve().parents[1] / "src" / "main.cpp").read_text()


class AsrScriptPackaging(unittest.TestCase):
    def test_default_searches_the_scripts_directory_next_to_binary(self):
        self.assertIn('applicationDirPath() + QStringLiteral("/scripts/transcribe_local.py")', SOURCE)

    def test_shadow_build_and_install_copy_the_helper(self):
        self.assertIn("QMAKE_POST_LINK", PROJECT)
        self.assertIn("asr.files = scripts/transcribe_local.py", PROJECT)
        self.assertIn("INSTALLS += target asr", PROJECT)

    def test_qml_has_an_embedded_release_fallback(self):
        self.assertIn("RESOURCES += qml.qrc", PROJECT)
        self.assertIn('qrc:/qml/main.qml', MAIN)


if __name__ == "__main__":
    unittest.main()
