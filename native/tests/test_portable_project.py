"""Portable projects can load media outside the data media folder."""
from pathlib import Path
import re
import unittest

SOURCE = (Path(__file__).resolve().parents[1] / "qml" / "main.qml").read_text()
ENGINE = (Path(__file__).resolve().parents[1] / "src" / "engine.cpp").read_text()


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


if __name__ == "__main__":
    unittest.main()
