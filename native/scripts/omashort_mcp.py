"""External stdio MCP server for explicitly selected OmaShort projects.

Run with an isolated environment containing mcp>=1,<2. No editor process or
fframes renderer is started by this server.
"""

from typing import Any

from mcp.server.fastmcp import FastMCP

try:
    from . import omashort_bridge as bridge
except ImportError:  # Direct script invocation by a stdio MCP client.
    import omashort_bridge as bridge


mcp = FastMCP("OmaShort external project bridge")


@mcp.tool()
def get_project(path: str) -> dict[str, Any]:
    """Read an absolute OmaShort project JSON path; return document and SHA-256 for edits."""
    return bridge.read_project(path)


@mcp.tool()
def patch_project(path: str, expected_sha256: str, operations: list[dict[str, Any]]) -> dict[str, Any]:
    """CAS edit a project. Ops: set_trim(in_seconds,out_seconds), set_template(template), add_text_layer(text,...), update_text_layer(index,...). Read again on stale hash."""
    return bridge.patch_project(path, expected_sha256, operations)


@mcp.tool()
def import_fframes_render(path: str, expected_sha256: str, mp4_path: str,
                          in_seconds: float, out_seconds: float,
                          as_main: bool = False) -> dict[str, Any]:
    """Reference an existing absolute nonempty MP4 as a timed layer or main video; does not render/copy media. CAS hash required."""
    return bridge.import_render(path, expected_sha256, mp4_path,
                                in_seconds, out_seconds, as_main)


@mcp.tool()
def replace_fframes_render(path: str, expected_sha256: str, layer_index: int,
                            mp4_path: str) -> dict[str, Any]:
    """Reference a new completed MP4 in an existing video layer, preserving its timing and placement. Use the latest project SHA-256."""
    return bridge.replace_render(path, expected_sha256, layer_index, mp4_path)


if __name__ == "__main__":
    mcp.run(transport="stdio")
