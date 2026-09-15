"""OmaShort product identity and legacy-data compatibility contracts."""
from pathlib import Path
import unittest

REPO = Path(__file__).resolve().parents[2]
NATIVE = REPO / "native"


class ProductIdentity(unittest.TestCase):
    def test_visible_product_identity_is_omashort(self):
        main_cpp = (NATIVE / "src" / "main.cpp").read_text()
        main_qml = (NATIVE / "qml" / "main.qml").read_text()
        readme = (REPO / "README.md").read_text()
        self.assertIn('setApplicationName(QStringLiteral("omashort"))', main_cpp)
        self.assertIn('setApplicationDisplayName(QStringLiteral("OmaShort"))', main_cpp)
        self.assertIn('title: "OmaShort"', main_qml)
        self.assertIn('text: "OMASHORT"', main_qml)
        self.assertIn('app: "omashort"', main_qml)
        self.assertTrue(readme.startswith("# OmaShort\n"))

    def test_native_and_android_identifiers_use_omashort(self):
        project_path = NATIVE / "omashort-native.pro"
        self.assertTrue(project_path.exists())
        self.assertFalse((NATIVE / "omareel-native.pro").exists())
        project = project_path.read_text()
        manifest = (NATIVE / "android" / "AndroidManifest.xml").read_text()
        self.assertIn("TARGET = omashort-native", project)
        self.assertIn('package="cl.villagranquiroz.omashort"', manifest)
        self.assertIn('android:label="OmaShort"', manifest)
        self.assertIn('android:value="omashort-native"', manifest)

    def test_demo_and_assets_use_omashort_names(self):
        self.assertTrue((REPO / "assets" / "omashort.png").exists())
        self.assertTrue((REPO / "examples" / "assets" / "omashort-motion-source.mp4").exists())
        self.assertTrue((REPO / "examples" / "omashort-keyframes-fades-preview.mp4").exists())
        demo = (REPO / "examples" / "keyframes-fades-demo.project.json").read_text()
        self.assertIn('"app": "omashort"', demo)
        self.assertIn('"text": "OMASHORT"', demo)
        self.assertIn('"video": "assets/omashort-motion-source.mp4"', demo)

    def test_legacy_environment_and_data_remain_migratable(self):
        engine = (NATIVE / "src" / "engine.cpp").read_text()
        self.assertIn('OMASHORT_DATA', engine)
        self.assertIn('OMAREEL_DATA', engine)
        self.assertIn('QStringLiteral("/omareel")', engine)
        self.assertIn('QStringLiteral("/omashort")', engine)
        self.assertIn("ensureLegacyDataAlias", engine)
        self.assertIn("canonicalFilePath()", engine)
        self.assertIn("if (legacyInfo.exists())", engine)
        self.assertIn("if (legacyInfo.isSymLink()) QFile::remove(legacyData)", engine)

    def test_new_project_reserves_unsaved_targets(self):
        engine_h = (NATIVE / "src" / "engine.h").read_text()
        engine_cpp = (NATIVE / "src" / "engine.cpp").read_text()
        self.assertIn("QSet<QString> m_reservedProjectFiles", engine_h)
        self.assertIn("m_reservedProjectFiles.contains(candidate)", engine_cpp)
        self.assertIn("m_reservedProjectFiles.insert(candidate)", engine_cpp)


if __name__ == "__main__":
    unittest.main()
