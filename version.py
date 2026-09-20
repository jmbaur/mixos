"""The project version, read from build.zig.zon, used by pyproject.toml's dynamic version."""

import pathlib
import re

_match = re.search(
    r'^\s*\.version = "([^"]+)",$',
    pathlib.Path(__file__).with_name("build.zig.zon").read_text(),
    re.MULTILINE,
)

if _match is None:
    raise RuntimeError("no `.version` field found in build.zig.zon")

version = _match.group(1)
