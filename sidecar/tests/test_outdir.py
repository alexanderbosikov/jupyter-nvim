import json

import pytest

from jupyter_nvim.outdir import BadCellId, OutDir


@pytest.fixture
def out(tmp_path) -> OutDir:
    return OutDir(tmp_path / "отчёт.md")


def record(cell_id="a3f9", run_id=1, **kw) -> dict:
    rec = {
        "cell_id": cell_id,
        "run_id": run_id,
        "started_at": "2026-09-03T10:12:04+00:00",
        "duration_ms": 12300,
        "status": "ok",
        "kind": "table",
        "path": f"{cell_id}/{run_id}.parquet",
        "rows": 1240,
        "code_sha": "9c1f2a",
    }
    rec.update(kw)
    return rec


def test_layout_is_next_to_the_notebook(out, tmp_path):
    assert out.base == tmp_path / ".jupyter-out" / "отчёт"
    assert out.path_for("a3f9", 12, "parquet") == out.base / "a3f9" / "12.parquet"


def test_path_for_creates_parent_only(out):
    p = out.path_for("a3f9", 1, ".png")

    assert p.parent.is_dir() and not p.exists()


def test_append_then_last(out):
    out.append(record(run_id=1))
    out.append(record(run_id=2, rows=7))

    assert out.last("a3f9")["run_id"] == 2
    assert out.last("a3f9", run_id=1)["rows"] == 1240
    assert out.last("нетакой") is None


def test_records_filter_by_cell(out):
    out.append(record("a3f9", 1))
    out.append(record("b7e1", 1))
    out.append(record("a3f9", 2))

    assert [r["run_id"] for r in out.records("a3f9")] == [1, 2]
    assert len(list(out.records())) == 3


def test_index_is_append_only_jsonl(out):
    out.append(record(run_id=1))
    out.append(record(run_id=2))

    lines = out.index_path.read_text(encoding="utf-8").splitlines()
    assert len(lines) == 2
    assert json.loads(lines[0])["run_id"] == 1


def test_truncated_line_does_not_lose_the_rest(out):
    out.append(record(run_id=1))
    with out.index_path.open("a", encoding="utf-8") as f:
        f.write('{"cell_id": "a3f9", "run_i\n')
    out.append(record(run_id=3))

    assert [r["run_id"] for r in out.records("a3f9")] == [1, 3]


def test_bad_cell_id_never_reaches_the_path(out):
    for bad in ["../../etc/passwd", "a3f9/../..", "A3F9", "xyz", "", "a3f9;rm"]:
        with pytest.raises(BadCellId):
            out.path_for(bad, 1, "txt")


def test_bad_cell_id_rejected_on_append(out):
    with pytest.raises(BadCellId):
        out.append(record(cell_id="../boom"))


def test_prune_keeps_last_runs_and_deletes_files(out):
    for run in range(1, 6):
        out.path_for("a3f9", run, "parquet").write_text("x")
        out.append(record(run_id=run))
    out.path_for("b7e1", 1, "parquet").write_text("x")
    out.append(record("b7e1", 1))

    dropped = out.prune("a3f9", keep=2)

    assert dropped == [1, 2, 3]
    assert [r["run_id"] for r in out.records("a3f9")] == [4, 5]
    assert not out.path_for("a3f9", 1, "parquet").exists()
    assert out.path_for("a3f9", 5, "parquet").exists()
    assert [r["run_id"] for r in out.records("b7e1")] == [1]
    assert out.path_for("b7e1", 1, "parquet").exists()


def test_prune_noop_when_within_limit(out):
    out.append(record(run_id=1))

    assert out.prune("a3f9", keep=5) == []
    assert len(list(out.records("a3f9"))) == 1


def test_resolve_returns_none_for_textless_record(out):
    assert out.resolve(record(path=None)) is None
    assert out.resolve(record()) == out.base / "a3f9" / "1.parquet"


def test_custom_dir_name(tmp_path):
    out = OutDir(tmp_path / "n.md", dir_name=".nb-out")

    assert out.base == tmp_path / ".nb-out" / "n"
