"""Contract tests for the isolated, file-backed external MCP bridge."""
import hashlib
import importlib.util
import json
import asyncio
import os
import sys
import tempfile
import unittest
import shutil
import subprocess
from pathlib import Path

from native.scripts.omashort_bridge import read_project, patch_project, import_render, replace_render


class BridgeTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.path = Path(self.temp.name) / "project.json"
        self.doc = {"app": "omashort", "version": 1, "video": "source.mp4",
                    "trim": {"in": 0, "out": 10, "extra": 7}, "layers": [],
                    "future": {"nested": True}}
        self.path.write_text(json.dumps(self.doc), encoding="utf-8")

    def test_read_and_compare_and_swap_trim_preserve_unknown_fields(self):
        before = self.path.read_bytes()
        state = read_project(str(self.path))
        self.assertEqual(state, {"sha256": hashlib.sha256(before).hexdigest(),
                                 "document": self.doc})
        updated = patch_project(str(self.path), state["sha256"],
                                [{"op": "set_trim", "in_seconds": 1, "out_seconds": 3}])
        self.assertEqual(updated, read_project(str(self.path)))
        self.assertEqual(updated["document"]["trim"], {"in": 1, "out": 3, "extra": 7})
        self.assertEqual(updated["document"]["future"], self.doc["future"])
        snapshot = self.path.read_bytes()
        with self.assertRaisesRegex(ValueError, "stale"):
            patch_project(str(self.path), state["sha256"],
                          [{"op": "set_trim", "in_seconds": 2, "out_seconds": 4}])
        self.assertEqual(self.path.read_bytes(), snapshot)

    def test_invalid_inputs_do_not_change_project(self):
        initial = self.path.read_bytes()
        sha = read_project(str(self.path))["sha256"]
        for operations in (
            [{"op": "set_trim", "in_seconds": -1, "out_seconds": 3}],
            [{"op": "set_trim", "in_seconds": 3, "out_seconds": 3}],
            [{"op": "set_trim", "in_seconds": 0, "out_seconds": float("nan")}],
            [{"op": "delete_everything"}],
        ):
            with self.subTest(operations=operations), self.assertRaises(ValueError):
                patch_project(str(self.path), sha, operations)
            self.assertEqual(self.path.read_bytes(), initial)
        with self.assertRaises(ValueError):
            read_project("relative.json")
        for bad in ({"app": "other"}, {"version": 2}):
            self.path.write_text(json.dumps({**self.doc, **bad}))
            with self.subTest(bad=bad), self.assertRaises(ValueError):
                read_project(str(self.path))
        with self.assertRaisesRegex(ValueError, "project file does not exist") as error:
            patch_project(str(self.path.parent / "missing.json"), sha,
                          [{"op": "set_trim", "in_seconds": 1, "out_seconds": 3}])
        self.assertNotIn(self.temp.name, str(error.exception))
        self.assertFalse((self.path.parent / "missing.json.bridge.lock").exists())

    def test_native_autosave_uses_bridge_lock_and_rejects_stale_projects(self):
        # The editor and bridge must cooperate at the rename boundary; the
        # bridge's final hash check alone cannot stop an interleaved editor save.
        source = (Path(__file__).parents[1] / "src" / "engine.cpp").read_text()
        writer = source.split("static bool writeProjectFile(", 1)[1].split("bool OmareelEngine::saveProject(", 1)[0]
        self.assertIn('QStringLiteral(".bridge.lock")', writer)
        self.assertIn("::flock(", writer)
        self.assertLess(writer.index("::flock("), writer.index("QSaveFile f(path)"))
        self.assertIn("QCryptographicHash::hash(previous.readAll()", writer)
        save = source.split("bool OmareelEngine::saveProject(", 1)[1].split("QString OmareelEngine::newProject(", 1)[0]
        self.assertIn("&m_lastProjHash", save)
        watcher = source.split("&m_projWatcher, &QFileSystemWatcher::fileChanged", 1)[1].split("});", 1)[0]
        self.assertIn("m_lastProjHash =", watcher)

    def test_atomic_write_preserves_project_mode(self):
        os.chmod(self.path, 0o600)
        old_inode = self.path.stat().st_ino
        patch_project(str(self.path), read_project(str(self.path))["sha256"],
                      [{"op": "set_trim", "in_seconds": 1, "out_seconds": 3}])
        self.assertEqual(self.path.stat().st_mode & 0o777, 0o600)
        self.assertNotEqual(self.path.stat().st_ino, old_inode)

    def test_typed_template_and_text_edits_keep_existing_layer_fields(self):
        sha = read_project(str(self.path))["sha256"]
        ops = [{"op": "set_template", "template": "pip"},
               {"op": "add_text_layer", "text": "Title", "x": 0.4, "y": 0.2,
                "size": 72, "in_seconds": 0, "out_seconds": 5}]
        state = patch_project(str(self.path), sha, ops)
        doc = state["document"]
        self.assertEqual(doc["template"], "pip")
        self.assertEqual(doc["layers"][0]["type"], "text")
        self.assertEqual(doc["layers"][0]["text"], "Title")
        self.assertEqual((doc["layers"][0]["inS"], doc["layers"][0]["outS"]), (0, 5))
        doc["layers"][0]["future"] = 42
        self.path.write_text(json.dumps(doc))
        sha = read_project(str(self.path))["sha256"]
        state = patch_project(str(self.path), sha, [{"op": "update_text_layer", "index": 0,
                                                     "text": "Updated", "x": 0.7}])
        self.assertEqual(state["document"]["layers"][0]["future"], 42)
        self.assertEqual(state["document"]["layers"][0]["text"], "Updated")
        self.assertEqual(state["document"]["layers"][0]["x"], 0.7)

    def test_reject_bad_text_bounds_template_and_wrong_layer(self):
        sha = read_project(str(self.path))["sha256"]
        for op in ({"op": "set_template", "template": "unknown"},
                   {"op": "add_text_layer", "text": "x" * 5000},
                   {"op": "add_text_layer", "text": "hi", "x": 2},
                   {"op": "update_text_layer", "index": 0, "text": "oops"},
                   {"op": "set_template", "template": "pip", "unexpected": "ignored?"}):
            with self.subTest(op=op), self.assertRaises(ValueError):
                patch_project(str(self.path), sha, [op])

    def test_import_clip_as_timed_movable_layer(self):
        clip = Path(self.temp.name) / "render.mp4"
        clip.write_bytes(b"test fixture representing rendered media")
        original = clip.read_bytes()
        state = import_render(str(self.path), read_project(str(self.path))["sha256"],
                              str(clip), 1, 4)
        layer = state["document"]["layers"][0]
        self.assertEqual(layer, {"type": "video", "path": str(clip),
                                 "x": 0.5, "y": 0.5, "w": 0.35, "h": 0.20,
                                 "inS": 1, "outS": 4, "timingSpace": "cut"})
        self.assertEqual(state["document"]["video"], "source.mp4")
        self.assertEqual(state, read_project(str(self.path)))
        self.assertEqual(clip.read_bytes(), original)

    def test_import_clip_as_main_preserves_other_project_fields(self):
        clip = Path(self.temp.name) / "render.mp4"
        clip.write_bytes(b"fixture")
        state = import_render(str(self.path), read_project(str(self.path))["sha256"],
                              str(clip), 0.5, 3.5, as_main=True)
        self.assertEqual(state["document"]["video"], str(clip))
        self.assertEqual(state["document"]["trim"], {"in": 0.5, "out": 3.5, "extra": 7})
        self.assertEqual(state["document"]["future"], self.doc["future"])

    @unittest.skipUnless(shutil.which("ffmpeg") and shutil.which("ffprobe"), "FFmpeg required")
    def test_import_real_clip_fits_preview_and_export_coordinates(self):
        clip = Path(self.temp.name) / "render.mp4"
        subprocess.run(["ffmpeg", "-loglevel", "error", "-f", "lavfi", "-i",
                        "color=c=red:s=320x180:r=1", "-frames:v", "1", "-y", str(clip)],
                       check=True, timeout=15)
        self.doc["trim"] = {"in": 5, "out": 10}
        self.path.write_text(json.dumps(self.doc))
        layer = import_render(str(self.path), read_project(str(self.path))["sha256"],
                              str(clip), 0, 1)["document"]["layers"][0]
        self.assertEqual(layer["timingSpace"], "cut")
        self.assertEqual(layer["sourceAspect"], 16 / 9)
        self.assertAlmostEqual(layer["w"], 0.35)
        self.assertAlmostEqual(layer["h"], 0.35 * (9 / 16) / (16 / 9))
        self.assertAlmostEqual(layer["pw"], 0.35)
        self.assertAlmostEqual(layer["ph"], 0.35)

    def test_import_rejects_missing_invalid_and_stale_media(self):
        clip = Path(self.temp.name) / "render.mp4"
        initial = self.path.read_bytes()
        sha = read_project(str(self.path))["sha256"]
        for candidate, start, end in ((str(clip), 0, 3), (str(clip), 3, 3),
                                      ("relative.mp4", 0, 3)):
            with self.subTest(candidate=candidate, start=start), self.assertRaises(ValueError):
                import_render(str(self.path), sha, candidate, start, end)
        clip.write_bytes(b"fixture")
        for candidate, start, end in ((str(clip), -1, 3), (str(clip), 0, 0),
                                      (str(clip), 0, float("inf")),
                                      (str(clip.with_suffix(".mov")), 0, 3)):
            with self.subTest(candidate=candidate, start=start), self.assertRaises(ValueError):
                import_render(str(self.path), sha, candidate, start, end)
        clip.write_bytes(b"")
        with self.assertRaises(ValueError):
            import_render(str(self.path), sha, str(clip), 0, 3)
        self.assertEqual(self.path.read_bytes(), initial)
        clip.write_bytes(b"fixture")
        self.path.write_text(json.dumps({**self.doc, "future": 12}))
        changed = self.path.read_bytes()
        with self.assertRaisesRegex(ValueError, "stale"):
            import_render(str(self.path), sha, str(clip), 0, 3)
        self.assertEqual(self.path.read_bytes(), changed)

    def test_rerender_replaces_only_media_reference_and_keeps_layer_edits(self):
        first = Path(self.temp.name) / "first.mp4"
        second = Path(self.temp.name) / "second.mp4"
        first.write_bytes(b"first completed render")
        second.write_bytes(b"second completed render")
        imported = import_render(str(self.path), read_project(str(self.path))["sha256"],
                                 str(first), 1, 4)
        layer = imported["document"]["layers"][0]
        layer.update({"x": 0.75, "y": 0.35, "opacity": 0.4, "shape": "circle",
                      "keyframes": [{"time": 1, "x": 0.3}]})
        self.path.write_text(json.dumps(imported["document"]))
        before = read_project(str(self.path))
        changed = replace_render(str(self.path), before["sha256"], 0, str(second))
        self.assertEqual(changed["document"]["layers"][0], {**layer, "path": str(second)})
        self.assertEqual(changed["document"]["video"], self.doc["video"])
        self.assertEqual(changed, read_project(str(self.path)))
        self.assertEqual(first.read_bytes(), b"first completed render")
        self.assertEqual(second.read_bytes(), b"second completed render")
        snapshot = self.path.read_bytes()
        with self.assertRaisesRegex(ValueError, "stale"):
            replace_render(str(self.path), before["sha256"], 0, str(first))
        self.assertEqual(self.path.read_bytes(), snapshot)

    def test_rerender_rejects_non_video_index_and_missing_media(self):
        first = Path(self.temp.name) / "first.mp4"
        first.write_bytes(b"first")
        sha = read_project(str(self.path))["sha256"]
        for index, candidate in ((0, str(first)), (-1, str(first)),
                                 (True, str(first)), (0, str(first.with_name("missing.mp4")))):
            with self.subTest(index=index, candidate=candidate), self.assertRaises(ValueError):
                replace_render(str(self.path), sha, index, candidate)

    @unittest.skipUnless(shutil.which("ffmpeg") and shutil.which("ffprobe"), "FFmpeg required")
    def test_rerender_rejects_aspect_change_without_touching_project(self):
        first = Path(self.temp.name) / "wide.mp4"
        second = Path(self.temp.name) / "square.mp4"
        for target, size in ((first, "128x72"), (second, "96x96")):
            subprocess.run(["ffmpeg", "-loglevel", "error", "-f", "lavfi",
                            "-i", f"color=c=black:s={size}:d=0.1", "-y", str(target)],
                           check=True, capture_output=True)
        initial = read_project(str(self.path))
        import_render(str(self.path), initial["sha256"], str(first), 0, 1)
        before = self.path.read_bytes()
        with self.assertRaisesRegex(ValueError, "aspect ratio"):
            replace_render(str(self.path), read_project(str(self.path))["sha256"], 0, str(second))
        self.assertEqual(self.path.read_bytes(), before)

    @unittest.skipUnless(importlib.util.find_spec("mcp.server.fastmcp"), "MCP SDK 1.x FastMCP required")
    def test_mcp_stdio_client_lists_and_calls_tools(self):
        from mcp import ClientSession, StdioServerParameters
        from mcp.client.stdio import stdio_client

        async def roundtrip():
            server = StdioServerParameters(command=sys.executable,
                args=[str(Path(__file__).resolve().parents[1] / "scripts" / "omashort_mcp.py")])
            async with stdio_client(server) as (read, write):
                async with ClientSession(read, write) as session:
                    await session.initialize()
                    tools = await session.list_tools()
                    self.assertEqual({t.name for t in tools.tools},
                                     {"get_project", "patch_project", "import_fframes_render",
                                      "replace_fframes_render"})
                    state = await session.call_tool("get_project", {"path": str(self.path)})
                    self.assertFalse(state.isError)
                    sha = state.structuredContent["sha256"]
                    changed = await session.call_tool("patch_project", {
                        "path": str(self.path), "expected_sha256": sha,
                        "operations": [{"op": "set_trim", "in_seconds": 1, "out_seconds": 3}]})
                    self.assertFalse(changed.isError)
                    self.assertEqual(read_project(str(self.path))["document"]["trim"]["in"], 1)
                    clip = Path(self.temp.name) / "render.mp4"
                    clip.write_bytes(b"fixture")
                    imported = await session.call_tool("import_fframes_render", {
                        "path": str(self.path),
                        "expected_sha256": changed.structuredContent["sha256"],
                        "mp4_path": str(clip), "in_seconds": 0, "out_seconds": 2})
                    self.assertFalse(imported.isError)
                    self.assertEqual(read_project(str(self.path))["document"]["layers"][0]["path"], str(clip))
                    new_clip = Path(self.temp.name) / "updated.mp4"
                    new_clip.write_bytes(b"new render")
                    replaced = await session.call_tool("replace_fframes_render", {
                        "path": str(self.path), "expected_sha256": imported.structuredContent["sha256"],
                        "layer_index": 0, "mp4_path": str(new_clip)})
                    self.assertFalse(replaced.isError)
                    self.assertEqual(read_project(str(self.path))["document"]["layers"][0]["path"], str(new_clip))
                    stale = await session.call_tool("patch_project", {
                        "path": str(self.path), "expected_sha256": sha,
                        "operations": [{"op": "set_trim", "in_seconds": 0, "out_seconds": 2}]})
                    self.assertTrue(stale.isError)

        asyncio.run(roundtrip())
