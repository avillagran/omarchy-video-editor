"""PROGRAM region labels must describe the active output layout."""
from pathlib import Path
import re
import unittest

SOURCE = (Path(__file__).resolve().parents[1] / "qml" / "main.qml").read_text()


class ProgramRegionLayoutContract(unittest.TestCase):
    def test_program_represents_every_source_region_used_by_output(self):
        program = re.search(r"component ProgramContent:.*?(?=\n  component \w+Content:)", SOURCE, re.S)
        self.assertIsNotNone(program)
        text = program.group(0)
        self.assertIn('mode: win.activeLayout() === "completa" ? 0 : 1', text)
        self.assertIn('boxALabel: win.activeLayout() === "apilar" ? "TOP" : "MAIN"', text)
        self.assertIn('boxBLabel: win.activeLayout() === "apilar" ? "BOT"', text)

    def test_active_boxes_are_fitted_to_their_output_aspects(self):
        self.assertIn('return fittedRegion(lay, "A", raw, activeSplit())', SOURCE)
        self.assertIn('return fittedRegion(lay, "B", raw, activeSplit())', SOURCE)

    def test_region_edits_keep_full_precision_during_drag(self):
        body = re.search(r"function setRegion\(key, box\) \{(.*?)\n  \}", SOURCE, re.S)
        self.assertIsNotNone(body)
        self.assertNotIn("Math.round", body.group(1))


if __name__ == "__main__":
    unittest.main()
