"""Содержимое выводов для агента: `jn show`, превью в снимке и под итогом `jn run`/`wait`.

Проверяется не «работает», а что агенту приходит полезное: значения целиком, без рамок,
итог и ошибка в конце текста не теряются.
"""

import json

import pytest

from jupyter_nvim import jn, peek, wait
from jupyter_nvim.outdir import OutDir

pl = pytest.importorskip("polars")

POLARS_PRINT = """\
✓ 2 строк · 1.2 с
shape: (2, 2)
┌─────────┬───────────┐
│ broker  ┆ volume    │
│ ---     ┆ ---       │
│ str     ┆ f64       │
╞═════════╪═══════════╡
│ OANDA   ┆ 2.8140e11 │
│ IBKR    ┆ 1.1163e11 │
└─────────┴───────────┘
"""


@pytest.fixture
def out(tmp_path) -> OutDir:
    o = OutDir(tmp_path / "nb.ipynb")
    (o.base / "af4b").mkdir(parents=True)
    return o


def table_run(out, rows=3, **extra):
    df = pl.DataFrame({
        "cut": ["total, all", "", None][:rows] + [f"r{i}" for i in range(max(0, rows - 3))],
        "volume_usd": [22786821603971.12, 0.5, None][:rows] + [float(i) for i in range(max(0, rows - 3))],
    })
    df.write_parquet(out.base / "af4b/3.parquet")
    (out.base / "af4b/3.txt").write_text("✓ 1,070 строк · 43 с\n")
    rec = {"cell_id": "af4b", "run_id": 3, "status": "ok", "kind": "table", "path": "af4b/3.parquet",
           "rows": rows, "cols": 2, "duration_ms": 1200, "text": "af4b/3.txt",
           "outputs": [{"kind": "text", "path": "af4b/3.txt"},
                       {"kind": "table", "path": "af4b/3.parquet", "rows": rows, "cols": 2}]}
    rec.update(extra)
    out.append(rec)
    return rec


def test_printed_polars_table_loses_frames_not_values():
    lines = peek.compact(POLARS_PRINT.rstrip("\n").split("\n"))

    assert lines == [
        "✓ 2 строк · 1.2 с",
        "shape: (2, 2)",
        "broker | volume",
        "str | f64",
        "OANDA | 2.8140e11",
        "IBKR | 1.1163e11",
    ]


def test_text_preview_keeps_the_end_where_the_result_is():
    lines = [f"строка {i}" for i in range(40)] + ["", "NameError: name 'x' is not defined"]

    p = peek.text_preview(lines, head=5, tail=2)

    assert p["head"] == [f"строка {i}" for i in range(5)]
    assert p["tail"] == ["строка 39", "NameError: name 'x' is not defined"]
    assert p["lines"] == 42


def test_show_prints_table_as_csv_with_full_values(out, capsys):
    table_run(out)

    assert jn.main(["show", str(out.notebook), "af4b"]) == 0

    text = capsys.readouterr().out
    assert text.startswith("af4b #3 ok · table 3×2 · 1.2s\n"), "строка итога без путей: они в разделах"
    assert "## text · строк: 1 · " in text and "✓ 1,070 строк · 43 с" in text
    assert "# cut:String, volume_usd:Float64" in text
    # запятая в значении — в кавычках, пустая строка — "", NULL — пусто; число целиком
    assert 'cut,volume_usd\n"total, all",22786821603971.12\n"",0.5\n,\n' in text


def test_show_cuts_long_table_and_says_so(out, capsys):
    table_run(out, rows=60)

    jn.main(["show", str(out.notebook), "af4b", "--rows", "10"])
    text = capsys.readouterr().out
    assert "# … ещё 50 строк из 60" in text

    jn.main(["show", str(out.notebook), "af4b", "--all"])
    assert "ещё" not in capsys.readouterr().out


def test_show_picks_run_and_reports_missing(out, capsys):
    table_run(out)

    assert jn.main(["show", str(out.notebook), "af4b", "--run", "9"]) == 1
    assert "jn history" in capsys.readouterr().err


def test_wait_prints_preview_under_summary(out, capsys, monkeypatch):
    table_run(out)
    monkeypatch.setattr(wait, "_runtime", lambda o: {"kernel_pid": __import__("os").getpid()})

    assert wait.main([str(out.notebook), "af4b:3", "--timeout", "2", "--poll", "0.05"]) == 0

    lines = capsys.readouterr().out.splitlines()
    assert lines[0].startswith("af4b #3 ok · table 3×2")
    assert lines[1:] == [
        "  ✓ 1,070 строк · 43 с",
        "  # cut:String, volume_usd:Float64",
        "  cut,volume_usd",
        '  "total, all",22786821603971.12',
        '  "",0.5',
        "  ,",
    ]


def test_wait_without_preview_is_one_line(out, capsys, monkeypatch):
    table_run(out)
    monkeypatch.setattr(wait, "_runtime", lambda o: {"kernel_pid": __import__("os").getpid()})

    wait.main([str(out.notebook), "af4b:3", "--timeout", "2", "--poll", "0.05", "--no-preview"])

    assert len(capsys.readouterr().out.splitlines()) == 1


def test_snapshot_of_cells_carries_previews(out, capsys):
    table_run(out)
    (out.base / "af4b/4.txt").write_text(POLARS_PRINT)
    snap = {"notebook": str(out.notebook), "cells": [
        {"id": "af4b", "last": {"outputs": [
            {"kind": "text", "path": str(out.base / "af4b/4.txt")},
            {"kind": "table", "path": str(out.base / "af4b/3.parquet"), "rows": 3, "cols": 2},
        ]}},
        {"id": "beef", "last": None},
    ]}

    def nv(sock, fn, args):
        return json.loads(json.dumps(snap))

    assert jn.main(["snapshot", str(out.notebook), "--cell", "af4b"], call=nv, locate=lambda nb: ("/s", [])) == 0

    cell = json.loads(capsys.readouterr().out)["cells"][0]
    text, table = cell["last"]["outputs"]
    assert text["preview"]["head"][-1] == "IBKR | 1.1163e11"
    assert table["preview"] == {"columns": ["cut", "volume_usd"],
                                "rows": [["total, all", 22786821603971.12], ["", 0.5], [None, None]]}


def test_no_polars_anywhere_keeps_path_and_says_so(out, monkeypatch):
    table_run(out)
    monkeypatch.setattr(peek, "polars_python", lambda o: None)

    p = peek.preview(out, {"kind": "table", "path": "af4b/3.parquet"})

    assert "JN_PYTHON" in p["error"] and "af4b/3.parquet" in p["error"]


def test_path_of_last_table_and_of_text(out, capsys):
    table_run(out)
    out.append({"cell_id": "af4b", "run_id": 5, "status": "ok", "kind": "table", "path": "af4b/5.parquet",
                "outputs": [{"kind": "table", "path": "af4b/5.parquet"}]})

    assert jn.main(["path", str(out.notebook), "af4b"]) == 0
    assert capsys.readouterr().out.strip() == str(out.base / "af4b/5.parquet"), "последний прогон, не #3"

    assert jn.main(["path", str(out.notebook), "af4b", "--run", "3", "--kind", "text"]) == 0
    assert capsys.readouterr().out.strip() == str(out.base / "af4b/3.txt")


def test_path_without_such_output_says_what_there_is(out, capsys):
    table_run(out)

    assert jn.main(["path", str(out.notebook), "af4b", "--kind", "image"]) == 1
    assert "есть: table, text" in capsys.readouterr().err
    assert jn.main(["path", str(out.notebook), "beef"]) == 1


def test_new_sends_text_to_agent_new(tmp_path, capsys):
    src = tmp_path / "cells.md"
    src.write_text("# EDA\n\n```python\nx = 1\n```\n")
    calls = []

    def nv(sock, fn, args):
        calls.append((fn, args))
        return {"ok": True, "cell_ids": ["a3f9"], "kernel": True}

    nb = tmp_path / "01.ipynb"
    assert jn.main(["new", str(nb), str(src)], call=nv, locate=lambda n: ("/s", [])) == 0
    assert calls == [("agent_new", [{"notebook": str(nb.resolve()), "text": "# EDA\n\n```python\nx = 1\n```"}])]
    assert json.loads(capsys.readouterr().out)["cell_ids"] == ["a3f9"]
