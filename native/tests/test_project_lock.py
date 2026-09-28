"""Native editor/bridge lock and stale-revision contract (isolated projects)."""
import fcntl
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


class NativeProjectLockTest(unittest.TestCase):
    @unittest.skipUnless(os.environ.get("OMASHORT_LOCK_PROBE"), "build project_lock_probe.pro to run native lock tests")
    def test_editor_autosave_rejects_lock_and_stale_revision(self):
        binary = Path(os.environ["OMASHORT_LOCK_PROBE"])
        self.assertTrue(binary.is_file())
        with tempfile.TemporaryDirectory(prefix="omashort-project-lock-") as root:
            project = Path(root) / "project.json"
            initial = {"app": "omashort", "version": 1, "template": "completa", "layers": []}
            project.write_text(json.dumps(initial))
            env = dict(os.environ, OMASHORT_DATA=root, QT_QPA_PLATFORM="offscreen")

            def launch(save_as=False):
                args = [str(binary), str(project)] + (["--save-as"] if save_as else [])
                proc = subprocess.Popen(args, stdin=subprocess.PIPE,
                                        stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                        text=True, env=env)
                self.assertIsNotNone(proc.stdout)
                self.assertEqual(proc.stdout.readline().strip(), "READY")
                return proc

            def finish(proc):
                stdout, stderr = proc.communicate("\n", timeout=10)
                self.assertEqual(proc.returncode, 0, stderr)
                return stdout.strip()

            # A bridge transaction owning the sidecar must make GUI autosave
            # decline immediately instead of writing across its CAS/rename.
            waiting = launch()
            with (Path(str(project) + ".bridge.lock")).open("a+b") as lock:
                fcntl.flock(lock, fcntl.LOCK_EX)
                self.assertEqual(finish(waiting), "REJECTED")
            self.assertEqual(json.loads(project.read_text()), initial)

            # An external atomic edit since the GUI's last loaded revision
            # must never be overwritten by a delayed autosave.
            stale = launch()
            changed = {**initial, "external": "MCP edit"}
            replacement = Path(root) / "replacement.json"
            replacement.write_text(json.dumps(changed))
            os.replace(replacement, project)
            self.assertEqual(finish(stale), "REJECTED")
            self.assertEqual(json.loads(project.read_text()), changed)

            save_as = launch(save_as=True)
            newer = {**changed, "external": "newer MCP edit"}
            replacement.write_text(json.dumps(newer))
            os.replace(replacement, project)
            self.assertEqual(finish(save_as), "REJECTED")
            self.assertEqual(json.loads(project.read_text()), newer)

            # A fresh in-app edit without contention still saves normally.
            current = launch()
            self.assertEqual(finish(current), "SAVED")
            self.assertEqual(json.loads(project.read_text())["template"], "pip")
            self.assertEqual(json.loads(project.read_text())["external"], "newer MCP edit")
