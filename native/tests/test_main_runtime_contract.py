"""Static guards for QML names that fail only at runtime."""
from pathlib import Path
import unittest

SOURCE = (Path(__file__).resolve().parents[1] / "qml" / "main.qml").read_text()


class MainRuntimeContract(unittest.TestCase):
    def test_mousearea_tooltips_use_contains_mouse(self):
        self.assertNotIn("ToolTip.visible: hovered", SOURCE)
        self.assertIn("ToolTip.visible: containsMouse", SOURCE)


if __name__ == "__main__":
    unittest.main()
