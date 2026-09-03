"""Mime-бандл ядра → событие для Lua. ARCHITECTURE.md §4.3, §4.5.

Правило приоритета из §4.5: если в бандле есть `text/plain` — берём его (polars отдаёт и HTML,
и текст, а нам нужен текст). Тяжёлое кладём файлом и отдаём путь, а не байты через пайп.
"""

from __future__ import annotations

import base64
from typing import Any

PLAIN = "text/plain"
PNG = "image/png"
SVG = "image/svg+xml"
HTML = "text/html"


def render(
    data: dict[str, Any],
    *,
    outdir: Any = None,
    cell_id: str | None = None,
    run_id: int | None = None,
) -> dict[str, Any]:
    can_write = outdir is not None and cell_id is not None and run_id is not None

    if PNG in data and can_write:
        path = outdir.path_for(cell_id, run_id, "png")
        path.write_bytes(base64.b64decode(data[PNG]))
        return {"kind": "image", "mime": PNG, "path": str(path)}

    if SVG in data and can_write:
        path = outdir.path_for(cell_id, run_id, "svg")
        path.write_text(data[SVG], encoding="utf-8")
        return {"kind": "image", "mime": SVG, "path": str(path)}

    if PLAIN in data:
        out: dict[str, Any] = {"kind": "text", "text": data[PLAIN]}
        if HTML in data:
            out["has_html"] = True  # §4.5: рендерить нечем, но пусть UI знает, что оно было
        return out

    if HTML in data:
        if can_write:
            path = outdir.path_for(cell_id, run_id, "html")
            path.write_text(data[HTML], encoding="utf-8")
            return {"kind": "html", "path": str(path)}
        return {"kind": "html", "text": data[HTML]}

    return {"kind": "unsupported", "mimes": sorted(data)}
