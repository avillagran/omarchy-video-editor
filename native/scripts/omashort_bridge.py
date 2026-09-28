"""Safe, compare-and-swap edits to an explicitly selected OmaShort JSON project."""

import fcntl
import hashlib
import json
import math
import os
import subprocess
import tempfile
from pathlib import Path


def _path(value):
    if not isinstance(value, str) or not os.path.isabs(value):
        raise ValueError("project path must be absolute")
    return Path(value)


def _read(path):
    try:
        raw = path.read_bytes()
    except FileNotFoundError as exc:
        raise ValueError("project file does not exist") from None
    except OSError as exc:
        raise ValueError("cannot read project file") from None
    try:
        document = json.loads(raw)
    except (UnicodeDecodeError, json.JSONDecodeError):
        raise ValueError("project is not valid JSON") from None
    if not isinstance(document, dict) or document.get("app") != "omashort" or type(document.get("version")) is not int or document["version"] != 1:
        raise ValueError("expected an OmaShort version 1 project")
    return {"sha256": hashlib.sha256(raw).hexdigest(), "document": document}


def read_project(path):
    return _read(_path(path))


def _number(value, lo, hi, label):
    if type(value) not in (int, float) or not math.isfinite(value) or not lo <= value <= hi:
        raise ValueError(f"invalid {label}")
    return value


def _fields(op, required, optional=()):
    if not required <= op.keys() or not op.keys() <= required | set(optional):
        raise ValueError("invalid operation fields")


def _times(start, end):
    _number(start, 0, 86400, "start time")
    _number(end, 0, 86400, "end time")
    if start >= end:
        raise ValueError("invalid time bounds")


def _video_aspect(path):
    """Best-effort geometry only; importing never requires decodable media."""
    try:
        result = subprocess.run(["ffprobe", "-v", "error", "-select_streams", "v:0",
                                 "-show_entries", "stream=width,height", "-of", "json", str(path)],
                                capture_output=True, text=True, timeout=5, check=True)
        stream = json.loads(result.stdout)["streams"][0]
        width, height = stream["width"], stream["height"]
        return width / height if width > 0 and height > 0 else None
    except (OSError, subprocess.SubprocessError, ValueError, KeyError, IndexError, TypeError, ZeroDivisionError):
        return None


def _fitted_box(source_aspect, canvas_aspect):
    width = 0.35
    height = width * canvas_aspect / source_aspect
    if height > 0.9:
        height = 0.9
        width = height * source_aspect / canvas_aspect
    return width, height


_TEXT_FIELDS = {"text", "x", "y", "size", "color", "opacity", "in_seconds", "out_seconds"}


def _text_fields(op):
    result = {}
    for field in _TEXT_FIELDS & op.keys():
        value = op[field]
        if field == "text":
            if not isinstance(value, str) or not 1 <= len(value) <= 2000:
                raise ValueError("invalid text")
        elif field == "color":
            if not isinstance(value, str) or len(value) != 7 or value[0] != "#" or any(c not in "0123456789abcdefABCDEF" for c in value[1:]):
                raise ValueError("invalid color")
        elif field in ("x", "y", "opacity"):
            _number(value, 0, 1, field)
        elif field == "size":
            _number(value, 1, 512, field)
        else:
            _number(value, 0, 86400, field)
        result[{"in_seconds": "inS", "out_seconds": "outS"}.get(field, field)] = value
    return result


def _apply(doc, op):
    if not isinstance(op, dict):
        raise ValueError("operation must be an object")
    kind = op.get("op")
    if kind == "set_trim":
        _fields(op, {"op", "in_seconds", "out_seconds"})
        start, end = op["in_seconds"], op["out_seconds"]
        _times(start, end)
        if not isinstance(doc.get("trim", {}), dict):
            raise ValueError("invalid project trim")
        doc["trim"] = {**doc.get("trim", {}), "in": start, "out": end}
    elif kind == "set_template":
        _fields(op, {"op", "template"})
        if op["template"] not in ("completa", "apilar", "pip", "circulo"):
            raise ValueError("invalid template")
        doc["template"] = op["template"]
    elif kind in ("add_text_layer", "update_text_layer"):
        required = {"op", "text"} if kind == "add_text_layer" else {"op", "index"}
        _fields(op, required, _TEXT_FIELDS)
        fields = _text_fields(op)
        layers = doc.setdefault("layers", [])
        if not isinstance(layers, list):
            raise ValueError("invalid layers")
        if kind == "add_text_layer":
            start = fields.get("inS", 0)
            end = fields.get("outS", doc.get("trim", {}).get("out", 10) - doc.get("trim", {}).get("in", 0))
            _times(start, end)
            layers.append({"type": "text", "x": 0.5, "y": 0.5, "size": 72,
                           "color": "#ffffff", "opacity": 1, "inS": start, "outS": end,
                           "timingSpace": "cut", **fields})
        else:
            index = op["index"]
            if type(index) is not int or not 0 <= index < len(layers) or not isinstance(layers[index], dict) or layers[index].get("type") != "text":
                raise ValueError("invalid text layer index")
            if not fields:
                raise ValueError("no text fields to update")
            _times(fields.get("inS", layers[index].get("inS", 0)),
                   fields.get("outS", layers[index].get("outS", 10)))
            layers[index].update(fields)
    else:
        raise ValueError("unknown operation")


def patch_project(path, expected_sha256, operations):
    if not isinstance(operations, list) or not operations:
        raise ValueError("operations must be a nonempty list")

    def edit(doc):
        for op in operations:
            _apply(doc, op)

    return _transaction(path, expected_sha256, edit)


def _media_path(mp4_path):
    if not isinstance(mp4_path, str) or not os.path.isabs(mp4_path) or Path(mp4_path).suffix.lower() != ".mp4":
        raise ValueError("MP4 media path must be absolute")
    media = Path(mp4_path)
    if not media.is_file() or media.stat().st_size == 0:
        raise ValueError("MP4 media must be an existing nonempty file")
    return media


def import_render(path, expected_sha256, mp4_path, in_seconds, out_seconds, as_main=False):
    media = _media_path(mp4_path)
    _times(in_seconds, out_seconds)
    if type(as_main) is not bool:
        raise ValueError("as_main must be boolean")

    def edit(doc):
        if as_main:
            if not isinstance(doc.get("trim", {}), dict):
                raise ValueError("invalid project trim")
            doc["video"] = mp4_path
            doc["trim"] = {**doc.get("trim", {}), "in": in_seconds, "out": out_seconds}
        else:
            layers = doc.setdefault("layers", [])
            if not isinstance(layers, list):
                raise ValueError("invalid layers")
            layer = {"type": "video", "path": mp4_path, "x": 0.5, "y": 0.5,
                     "w": 0.35, "h": 0.20, "inS": in_seconds, "outS": out_seconds,
                     "timingSpace": "cut"}
            aspect = _video_aspect(media)
            if aspect:
                main_path = Path(doc.get("video") or "")
                if not main_path.is_absolute():
                    main_path = _path(path).parent / main_path
                program_aspect = _video_aspect(main_path) or 16 / 9
                layer["w"], layer["h"] = _fitted_box(aspect, 9 / 16)
                layer["pw"], layer["ph"] = _fitted_box(aspect, program_aspect)
                layer["sourceAspect"] = aspect
            layers.append(layer)

    return _transaction(path, expected_sha256, edit)


def replace_render(path, expected_sha256, layer_index, mp4_path):
    """Reference a new completed render without resetting the layer's edits."""
    media = _media_path(mp4_path)
    if type(layer_index) is not int or layer_index < 0:
        raise ValueError("invalid video layer index")

    def edit(doc):
        layers = doc.get("layers", [])
        if (not isinstance(layers, list) or layer_index >= len(layers)
                or not isinstance(layers[layer_index], dict)
                or layers[layer_index].get("type") != "video"):
            raise ValueError("invalid video layer index")
        layer = layers[layer_index]
        new_aspect = _video_aspect(media)
        old_aspect = layer.get("sourceAspect")
        if (type(old_aspect) in (int, float) and old_aspect > 0 and new_aspect
                and abs(new_aspect / old_aspect - 1) > 0.01):
            raise ValueError("replacement aspect ratio differs; import as a new layer")
        layer["path"] = mp4_path

    return _transaction(path, expected_sha256, edit)


def _transaction(path, expected_sha256, edit):
    project = _path(path)
    _read(project)  # Do not create a sidecar for a nonexistent project.
    # Advisory lock coordinates multiple bridge processes; editor writes are
    # external and must still be detected by a second hash check before rename.
    with open(str(project) + ".bridge.lock", "a+b") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        state = _read(project)
        if state["sha256"] != expected_sha256:
            raise ValueError("stale project hash; read the project again")
        doc = state["document"]
        edit(doc)
        raw = (json.dumps(doc, ensure_ascii=False, indent=2, allow_nan=False) + "\n").encode("utf-8")
        fd, tmp = tempfile.mkstemp(prefix=".omashort-", suffix=".json", dir=project.parent)
        try:
            os.fchmod(fd, project.stat().st_mode & 0o7777)
            with os.fdopen(fd, "wb") as output:
                output.write(raw)
                output.flush()
                os.fsync(output.fileno())
            if _read(project)["sha256"] != expected_sha256:
                raise ValueError("stale project hash; read the project again")
            os.replace(tmp, project)
        finally:
            if os.path.exists(tmp):
                os.unlink(tmp)
        return _read(project)
