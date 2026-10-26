import json

import pytest

from jupyter_nvim import jn


class Nvim:
    """Подставной nvim: запоминает вызовы, отвечает заготовками по имени функции."""

    def __init__(self, **answers):
        self.calls = []
        self.answers = answers

    def __call__(self, sock, fn, args):
        self.calls.append((sock, fn, args))
        answer = self.answers.get(fn, {"ok": True})
        return answer(args) if callable(answer) else answer


def found(sock="/s"):
    return lambda nb: (sock, [])


def test_socket_is_found_and_args_go_as_values(tmp_path, capsys):
    nb = tmp_path / "a.ipynb"
    nv = Nvim()
    old, new = tmp_path / "old", tmp_path / "new"
    old.write_text('print("x")\n')
    new.write_text("it's\nmulti-line\n")

    assert jn.main(["replace", str(nb), str(old), str(new)], call=nv, locate=found()) == 0

    sock, fn, args = nv.calls[0]
    assert (sock, fn) == ("/s", "edit_replace")
    # кавычки и переводы строк — как есть; перевод строки в конце файла срезан
    assert args == ['print("x")', "it's\nmulti-line", {"notebook": str(nb.resolve())}]


def test_explicit_sock_skips_search(tmp_path):
    nv = Nvim()

    def no_search(_):
        raise AssertionError("искать не должен")

    assert jn.main(["--sock", "/x", "open", str(tmp_path / "a.ipynb")], call=nv, locate=no_search) == 0
    assert nv.calls[0][0] == "/x"


def test_no_nvim_is_exit_4(tmp_path, capsys):
    assert jn.main(["open", str(tmp_path / "a.ipynb")], call=Nvim(), locate=lambda nb: (None, [])) == jn.NO_NVIM
    assert "спроси у человека" in capsys.readouterr().err


def test_refusal_is_exit_1_with_answer(tmp_path, capsys):
    nv = Nvim(edit_done={"ok": False, "reason": "no_claim"})
    assert jn.main(["done", str(tmp_path / "a.ipynb"), "3"], call=nv, locate=found()) == 1
    assert nv.calls[0][2] == [3]
    assert json.loads(capsys.readouterr().out)["reason"] == "no_claim"


def test_insert_place(tmp_path):
    nv = Nvim()
    f = tmp_path / "ins"
    f.write_text("```python\nx = 1\n```\n")
    jn.main(["insert", str(tmp_path / "a.ipynb"), str(f), "--before-heading", "## Ручные запросы"], call=nv, locate=found())
    opts = nv.calls[0][2][0]
    assert opts["before_heading"] == "## Ручные запросы"
    assert opts["text"] == "```python\nx = 1\n```"


def test_run_by_id_and_row_reports_cells_not_run(tmp_path, capsys):
    answers = iter([
        {"ok": True, "cell_id": "e93d", "run_id": 1, "kernel": {"since": "15:07:58"}, "not_run_above": None},
        {"ok": True, "cell_id": "f5a8", "run_id": 2, "kernel": {"since": "15:07:58"}, "not_run_above": ["345e"]},
    ])
    nv = Nvim(agent_run=lambda args: next(answers))

    code = jn.main(["run", str(tmp_path / "a.ipynb"), "e93d", "row:40", "--no-wait"], call=nv, locate=found())

    assert code == 0
    assert [c[2][0].get("cell") or c[2][0].get("row") for c in nv.calls] == ["e93d", 40]
    out = capsys.readouterr()
    assert out.out.strip() == "e93d:1 f5a8:2"
    assert "не выполнялись ячейки выше: 345e" in out.err


def test_run_stops_at_refusal(tmp_path, capsys):
    nv = Nvim(agent_run={"ok": False, "reason": "claimed", "msg": "заявка 3"})
    assert jn.main(["run", str(tmp_path / "a.ipynb"), "e93d", "f5a8"], call=nv, locate=found()) == 1
    assert len(nv.calls) == 1
    assert "claimed" in capsys.readouterr().err


def test_snapshot_brief_and_cell_filter(tmp_path, capsys):
    snap = {
        "notebook": "/w/a.ipynb", "kernel": {"state": "ready"}, "visible": True,
        "cells": [
            {"id": "e93d", "lang": "python", "start_row": 3, "end_row": 9,
             "last": {"run_id": 4, "status": "ok", "kind": "table", "rows": 10, "cols": 2}, "stale": True},
            {"id": "f5a8", "lang": "python", "start_row": 12, "end_row": 14, "last": None},
        ],
    }
    nv = Nvim(snapshot=snap)
    jn.main(["snapshot", str(tmp_path / "a.ipynb"), "--brief", "--cell", "e93d"], call=nv, locate=found())
    out = capsys.readouterr().out
    assert "e93d python 3–9 · #4 ok · table 10×2 · устарел" in out
    assert "f5a8" not in out


def test_pane_prints_shell_assignments(tmp_path, monkeypatch, capsys):
    monkeypatch.setenv("XDG_STATE_HOME", str(tmp_path))
    monkeypatch.delenv("TMUX_PANE", raising=False)
    monkeypatch.setenv("HERDR_PANE_ID", "wJ:p2")
    d = tmp_path / "nvim" / "jupyter" / "panes"
    d.mkdir(parents=True)
    (d / "wJ:p2.json").write_text(json.dumps({
        "/w/mda 1/01_eda.ipynb": {"socket": "/s1", "claim": 7, "at": 2},
        "/old/mda 1/01_eda.ipynb": {"socket": "/s0", "at": 1},
    }))

    assert jn.main(["pane", "mda 1/01_eda.ipynb"]) == 0
    assert capsys.readouterr().out.splitlines() == ["NB='/w/mda 1/01_eda.ipynb'", "SOCK=/s1", "CLAIM=7"]


def test_nvim_error_is_exit_4(tmp_path, capsys):
    def broken(sock, fn, args):
        raise jn.NvimError("в этом nvim старая сборка плагина")

    assert jn.main(["open", str(tmp_path / "a.ipynb")], call=broken, locate=found()) == jn.NO_NVIM
    assert "старая сборка" in capsys.readouterr().err


@pytest.mark.parametrize("cmd", [["text"], ["snapshot"]])
def test_no_buffer_is_refusal(tmp_path, capsys, cmd):
    nv = Nvim(text={"ok": False, "reason": "no_buffer"}, snapshot={"ok": False, "reason": "no_buffer"})
    assert jn.main([cmd[0], str(tmp_path / "a.ipynb")], call=nv, locate=found()) == 1
