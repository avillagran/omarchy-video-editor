# OmaShort + fframes MCP Bridge Implementation Plan

> **For Hermes:** Use subagent-driven-development skill to implement this plan task-by-task.

**Goal:** Let an external LLM inspect and safely edit an OmaShort project, and incorporate finished fframes MP4 clips without rewriting either renderer.

**Architecture:** A local stdio MCP server operates on an explicitly named, absolute OmaShort project JSON path. The editor's existing file watcher picks up atomic writes. fframes remains a separate Rust project: the agent renders to an explicit MP4, then imports that file into the OmaShort timeline. No hidden hosted service or automatic execution of untrusted Rust code.

**Tech Stack:** Python 3, `mcp` SDK 1.x (`FastMCP`), unittest, OmaShort JSON v1, existing Qt QFileSystemWatcher.

---

### Task 1: Atomic typed project edits

**Objective:** Support read with SHA-256 and compare-and-swap typed edits without losing unknown keys.

**Files:**
- Create: `native/scripts/omashort_bridge.py`
- Test: `native/tests/test_omashort_bridge.py`

**Step 1: Write failing tests:** In a temporary project JSON, call `read_project(path)` and assert `sha256` and document; call `patch_project(path, hash, [{"op":"set_trim","in_seconds":1,"out_seconds":3}])`, assert only trim changed; assert stale hashes reject without writing. Also reject wrong app/version, nonabsolute path, out-of-range trim and unknown operation.

**Step 2: Verify red:** `python3 -m unittest native.tests.test_omashort_bridge -v` fails for missing module/API.

**Step 3: Implement:** Validate path/identity; require expected SHA-256; permit `set_trim`, `set_template`, `add_text_layer`, `update_text_layer`, with bounded numeric/text fields and path-safe error messages; preserve unrelated fields; write JSON to a named same-directory temp file and `os.replace`, preserve file permissions; read back and return hash. Serialize bridge writers with advisory file lock and recheck immediately before replace. Do not create projects implicitly.

**Step 4: Verify green:** same test command passes. Keep source, tests and docs English.

### Task 2: fframes clip import

**Objective:** Import a completed MP4 as a new timed, movable video layer or main clip into the active JSON.

**Files:**
- Modify: `native/scripts/omashort_bridge.py`
- Modify: `native/tests/test_omashort_bridge.py`

**Step 1: Write failing tests:** `import_render(path, hash, mp4_path, in_seconds, out_seconds, as_main=False)` appends a `video` layer with absolute media path, bounds, and default output/program geometry; `as_main=True` sets `video` and `trim`, preserving other fields. Reject non-MP4, missing/zero-length file and invalid times; assert original file is untouched and stale hash rejects.

**Step 2: Verify red:** run the single test.

**Step 3: Implement:** Reuse same CAS transaction; only reference existing video, do not pretend to transcode or render it. No implicit file copying or output-gallery claim.

**Step 4: Verify green:** run tests.

### Task 3: MCP wiring and instructions

**Objective:** Expose the two actions as stdio MCP tools with actionable setup instructions.

**Files:**
- Create: `native/scripts/omashort_mcp.py`
- Modify: `README.md`
- Modify: `docs/project-format.md`
- Test: `native/tests/test_omashort_bridge.py`

**Step 1: Write failing tests:** MCP module's tool functions can be imported and delegate to core; validate tool metadata via actual SDK client session where available.

**Step 2: Verify red:** run focused unittest.

**Step 3: Implement:** `mcp.server.fastmcp.FastMCP` stdio server with `get_project`, `patch_project`, `import_fframes_render`. Make setup pin `mcp>=1,<2`; explicit JSON config for agents; example fframes CLI `cargo run --release -- render -o /absolute/clip.mp4 --json`, then import. Explain live reload and autosave collision limitation; no in-app chat yet.

**Step 4: Verify:** focused tests, entire `native/tests` suite, and a real in-process MCP client stdio roundtrip on isolated test fixture; no writes to user's project. Run existing editor `--selftest` only if source media is available. Review git diff and warning output before reporting.
