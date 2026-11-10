"""Содержимое выводов прогона для агента: `jn show`, превью в `jn snapshot --cell` и `jn run`.

Формат выбран под читателя-агента, а не под глаза: таблица — CSV (заголовок, значения
полностью, без рамок и обрезки колонок, числа без экспоненты до 1e16), текст — как есть,
но без ANSI-кодов. Раньше снимок отдавал только пути, и каждый прогон заканчивался
ручным `read_parquet` / `cat` — вызовом, который агент каждый раз сочинял заново.

`jn` — только stdlib, а parquet читается polars-ом. Таблицу поэтому читает отдельный
процесс того питона, где polars есть: свой (если вдруг есть), сайдкара из `runtime.json`,
`$JN_PYTHON`. Нет ни одного — превью таблицы нет, путь остаётся.
"""

from __future__ import annotations

import json
import os
import re
import struct
import subprocess
import sys
from pathlib import Path
from typing import Any

from .outdir import RUNTIME_FILE, OutDir

ANSI = re.compile(r"\x1b\[[0-9;?]*[A-Za-z]")
# рамки и разделители отрисовки polars: строка из одних них ничего не сообщает
FRAME = re.compile(r"^[\s\-─━│┃┆┊┌┐└┘├┤┬┴┼╞╡╪═╭╮╯╰]*$")

# Код, который исполняет питон с polars. Самодостаточный: `-I` не видит PYTHONPATH.
# argv: путь, сколько строк (0 — все), формат csv|json
_TABLE = r'''
import json, math, sys
import polars as pl
path, n, fmt = sys.argv[1], int(sys.argv[2]), sys.argv[3]
lazy = pl.scan_parquet(path)
schema = lazy.collect_schema()
total = lazy.select(pl.len()).collect().item()
df = (lazy if n <= 0 else lazy.head(n)).collect()
def native(v):
    if v is None or isinstance(v, (bool, int, str)):
        return v
    if isinstance(v, float):
        return v if math.isfinite(v) else str(v)
    if isinstance(v, (list, dict)):
        return json.dumps(v, ensure_ascii=False, default=str)
    return str(v)
rows = [[native(v) for v in r] for r in df.iter_rows()]
if fmt == "json":
    print(json.dumps({"columns": list(schema.names()), "dtypes": [str(t) for t in schema.dtypes()],
                      "rows": rows, "total_rows": total}, ensure_ascii=False))
    raise SystemExit
def cell(v):
    if v is None:
        return ""
    if isinstance(v, bool):
        return "true" if v else "false"
    if isinstance(v, (int, float)):
        return repr(v)
    if v == "" or any(c in v for c in ',"\n\r') or v != v.strip():
        return '"' + v.replace('"', '""') + '"'
    return v
out = sys.stdout
out.write("# " + ", ".join(f"{c}:{t}" for c, t in schema.items()) + "\n")
out.write(",".join(cell(c) for c in schema.names()) + "\n")
for r in rows:
    out.write(",".join(cell(v) for v in r) + "\n")
if len(rows) < total:
    out.write(f"# … ещё {total - len(rows)} строк из {total}\n")
'''


def _has_polars(python: str) -> bool:
    try:
        return subprocess.run([python, "-I", "-c", "import polars"], capture_output=True, timeout=30).returncode == 0
    except (OSError, subprocess.TimeoutExpired):
        return False


def _process_python(pid: Any) -> str | None:
    """Интерпретатор живого процесса по его argv: сайдкар до `sidecar_python` в runtime.json."""
    try:
        cmd = subprocess.run(["ps", "-o", "command=", "-p", str(int(pid))], capture_output=True, text=True,
                             timeout=5).stdout.split()
    except (OSError, ValueError, TypeError, subprocess.TimeoutExpired):
        return None
    return cmd[0] if cmd and "python" in Path(cmd[0]).name else None


_PYTHON: dict[Path, str | None] = {}


def polars_python(out: OutDir) -> str | None:
    """Питон, у которого есть polars. Ищется раз на каталог выводов за процесс `jn`."""
    if out.base in _PYTHON:
        return _PYTHON[out.base]
    try:
        import polars  # noqa: F401

        found: str | None = sys.executable
    except ImportError:
        found = None
    if found is None:
        try:
            rt = json.loads((out.base / RUNTIME_FILE).read_text(encoding="utf-8"))
        except (OSError, ValueError):
            rt = {}
        candidates = [os.environ.get("JN_PYTHON"), rt.get("sidecar_python"),
                      _process_python(rt.get("sidecar_pid")) if rt.get("sidecar_pid") else None,
                      rt.get("kernel_python")]
        found = next((p for p in candidates if p and os.access(p, os.X_OK) and _has_polars(p)), None)
    _PYTHON[out.base] = found
    return found


class NoPolars(RuntimeError):
    pass


def table(out: OutDir, path: Path, rows: int, fmt: str) -> str:
    """Голова parquet-а: `fmt="csv"` — текст для чтения, `"json"` — для превью в JSON."""
    if not path.exists():
        raise FileNotFoundError(str(path))
    python = polars_python(out)
    if python is None:
        raise NoPolars("нет питона с polars (JN_PYTHON) — таблицу прочитай сам: " + str(path))
    proc = subprocess.run([python, "-I", "-c", _TABLE, str(path), str(rows), fmt],
                          capture_output=True, text=True, timeout=120)
    if proc.returncode != 0:
        raise RuntimeError((proc.stderr.strip().splitlines() or ["polars упал"])[-1])
    return proc.stdout


BOX_ROW = re.compile(r"^\s*[│┃](.*)[│┃]\s*$")


def compact(lines: list[str]) -> list[str]:
    """Напечатанные polars-таблицы — строками `a | b | c`, без рамок и строки `---`.

    Рамки — половина символов такой таблицы и ничего не сообщают; значения при этом не
    меняются (они уже округлены polars-ом при печати — точные только в parquet).
    """
    res = []
    for line in lines:
        m = BOX_ROW.match(line)
        if m:
            cells = [c.strip() for c in re.split(r"[┆│┃]", m.group(1))]
            if all(set(c) <= {"-"} for c in cells):
                continue
            res.append(" | ".join(cells))
        elif line.strip() and FRAME.match(line):
            continue
        else:
            res.append(line.rstrip())
    return res


def read_text(path: Path) -> list[str]:
    raw = ANSI.sub("", path.read_text(encoding="utf-8", errors="replace")).rstrip("\n").split("\n")
    return compact(raw)


def meaningful(lines: list[str]) -> list[str]:
    return [line for line in lines if not FRAME.match(line)]


def clip(line: str, width: int = 240) -> str:
    return line if len(line) <= width else line[:width - 1] + "…"


def text_preview(lines: list[str], head: int = 12, tail: int = 4) -> dict[str, Any]:
    """Начало и конец текста без пустых строк и рамок: в конце обычно итог или ошибка."""
    body = [clip(line) for line in meaningful(lines)]
    if len(body) <= head + tail:
        return {"lines": len(lines), "head": body}
    return {"lines": len(lines), "head": body[:head], "tail": body[-tail:]}


def png_size(path: Path) -> tuple[int, int] | None:
    try:
        with path.open("rb") as f:
            sig = f.read(24)
    except OSError:
        return None
    if len(sig) == 24 and sig[:8] == b"\x89PNG\r\n\x1a\n":
        w, h = struct.unpack(">II", sig[16:24])
        return w, h
    return None


def outputs_of(rec: dict[str, Any]) -> list[dict[str, Any]]:
    """Выводы прогона. У записей до `outputs` в индексе — один главный и `text` при нём."""
    if rec.get("outputs"):
        return list(rec["outputs"])
    legacy = []
    if rec.get("text"):
        legacy.append({"kind": "text", "path": rec["text"]})
    if rec.get("path"):
        legacy.append({k: rec.get(k) for k in ("kind", "path", "rows", "cols") if rec.get(k) is not None})
    return legacy


def preview(out: OutDir, item: dict[str, Any], rows: int = 5) -> dict[str, Any] | None:
    """Превью одного вывода для JSON снимка. `path` — абсолютный или от `out.base`."""
    path = out.base / item["path"]
    kind = item.get("kind")
    try:
        if kind == "table":
            data = json.loads(table(out, path, rows, "json"))
            return {"columns": data["columns"], "rows": data["rows"]}
        if kind == "text":
            return text_preview(read_text(path))
        if kind == "image":
            size = png_size(path)
            return {"width": size[0], "height": size[1]} if size else None
    except NoPolars as e:
        return {"error": str(e)}
    except (OSError, ValueError, RuntimeError, subprocess.TimeoutExpired) as e:
        return {"error": f"{type(e).__name__}: {e}"}
    return None


def preview_lines(out: OutDir, rec: dict[str, Any], rows: int = 5, indent: str = "  ") -> list[str]:
    """Превью прогона строками под итогом `jn run` / `jn wait`."""
    lines: list[str] = []
    for item in outputs_of(rec):
        path = out.base / item["path"]
        kind = item.get("kind")
        try:
            if kind == "table":
                lines += table(out, path, rows, "csv").rstrip("\n").split("\n")
            elif kind == "text":
                p = text_preview(read_text(path), head=8, tail=3)
                lines += p["head"]
                if "tail" in p:
                    lines.append(f"… ({p['lines']} строк, целиком: jn show)")
                    lines += p["tail"]
        except NoPolars as e:
            lines.append(f"# {e}")
        except FileNotFoundError:
            continue  # обрезан историей или не записался: путь и так в строке итога
        except (OSError, RuntimeError, subprocess.TimeoutExpired) as e:
            lines.append(f"# не прочитать {item['path']}: {e}")
    return [indent + line for line in lines]


def show(out: OutDir, rec: dict[str, Any], rows: int = 50, max_text: int = 400) -> str:
    """Все выводы прогона целиком, разделами `## <kind> · <путь>`. rows=0 — таблица вся."""
    parts: list[str] = []
    for item in outputs_of(rec):
        path = out.base / item["path"]
        kind = item.get("kind")
        if kind == "table":
            head = f"## table · {item.get('rows')}×{item.get('cols')} · {path}"
            try:
                body = table(out, path, rows, "csv").rstrip("\n")
            except (NoPolars, OSError, RuntimeError, subprocess.TimeoutExpired) as e:
                body = f"# не прочитать: {e}"
        elif kind == "text":
            try:
                lines = read_text(path)
            except OSError as e:
                lines = [f"# не прочитать: {e}"]
            head = f"## text · строк: {len(lines)} · {path}"
            if max_text and len(lines) > max_text:
                keep_tail = max_text // 5
                lines = (lines[:max_text - keep_tail]
                         + [f"# … пропущено {len(lines) - max_text} строк (--all — целиком)"]
                         + lines[-keep_tail:])
            body = "\n".join(lines)
        elif kind == "image":
            size = png_size(path)
            head = f"## image · {f'{size[0]}×{size[1]} · ' if size else ''}{path}"
            body = ""
        else:
            head, body = f"## {kind} · {path}", ""
        parts.append(head + ("\n" + body if body else ""))
    return "\n".join(parts)
