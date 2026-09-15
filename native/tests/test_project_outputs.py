"""Rendered clips are scoped to the active project."""
from pathlib import Path
import re
import unittest

NATIVE = Path(__file__).resolve().parents[1]
ENGINE = (NATIVE / "src" / "engine.cpp").read_text()
HEADER = (NATIVE / "src" / "engine.h").read_text()
MAIN = (NATIVE / "qml" / "main.qml").read_text()


class ProjectOutputs(unittest.TestCase):
    def test_project_output_directory_is_derived_from_project_path(self):
        self.assertIn("QString projectOutputDir() const", HEADER)
        self.assertIn("QString OmareelEngine::projectOutputDir() const", ENGINE)
        self.assertIn("QCryptographicHash::Sha256", ENGINE)
        self.assertIn("m_projectFile", ENGINE)

    def test_render_and_gallery_share_the_project_output_directory(self):
        render = re.search(r"void OmareelEngine::renderVertical\(.*?\n\}", ENGINE, re.S)
        gallery = re.search(r"QVariantList OmareelEngine::listOutputs\(\).*?\n\}", ENGINE, re.S)
        self.assertIsNotNone(render)
        self.assertIsNotNone(gallery)
        self.assertIn('t.params[QStringLiteral("outputDir")] = projectOutputDir()', render.group(0))
        self.assertIn("QDir dir(projectOutputDir())", gallery.group(0))
        self.assertIn('task.params.value(QStringLiteral("outputDir"),', ENGINE)

    def test_gallery_refreshes_when_active_project_changes(self):
        self.assertIn("function onProjectFileChanged()", MAIN)
        self.assertIn("win.refreshOutputs()", MAIN)

    def test_render_always_requests_an_explicit_output_path(self):
        self.assertIn("id: renderSaveDialog", MAIN)
        self.assertIn("fileMode: FileDialog.SaveFile", MAIN)
        self.assertIn("renderSaveDialog.open()", MAIN)
        self.assertIn("outputPath: outputPath", MAIN)
        self.assertIn('task.params.value(QStringLiteral("outputPath"))', ENGINE)

    def test_legacy_global_outputs_are_assigned_to_default_project(self):
        self.assertIn("void OmareelEngine::migrateLegacyOutputs()", ENGINE)
        self.assertIn('QStringLiteral("/out")', ENGINE)
        self.assertIn("projectOutputDir()", ENGINE)
        self.assertIn("migrateLegacyOutputs();", ENGINE)


if __name__ == "__main__":
    unittest.main()
