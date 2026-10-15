import json
import os
from datetime import datetime, timezone
import threading
import time

import pytest

from jupyter_nvim.outdir import RUNTIME_FILE, OutDir
from jupyter_nvim.wait import FAILED, GONE, OK, TIMEOUT, main


@pytest.fixture
def out(tmp_path) -> OutDir:
    o = OutDir(tmp_path / "nb.ipynb")
    o.base.mkdir(parents=True)
    return o


# ядро поднято в 06:30 UTC; runtime.json пишет местное время без пояса — как сайдкар
KERNEL_UP = datetime(2026, 10, 15, 6, 30, tzinfo=timezone.utc).astimezone().replace(tzinfo=None)


def alive_kernel(out, started_at=KERNEL_UP.isoformat(timespec="seconds")):
    # pid этого процесса — заведомо живой «kernel_pid»
    (out.base / RUNTIME_FILE).write_text(json.dumps({"kernel_pid": os.getpid(), "started_at": started_at}))


def rec(cell, run, status="ok", started="2026-10-15T07:00:00+00:00", **kw):
    r = {"cell_id": cell, "run_id": run, "status": status, "started_at": started, "duration_ms": 1200,
         "kind": "text", "path": f"{cell}/{run}.txt"}
    r.update(kw)
    return r


def run(out, *args):
    return main([str(out.base.parent.parent / "nb.ipynb"), *args, "--poll", "0.05", "--timeout", "3"])


def later(fn, delay=0.2):
    threading.Timer(delay, fn).start()


def test_waits_for_the_run_and_prints_it(out, capsys):
    alive_kernel(out)
    later(lambda: out.append(rec("af4b", 3, kind="table", rows=5, cols=2, path="af4b/3.parquet", text="af4b/3.out.txt")))
    assert run(out, "af4b:3") == OK
    line = capsys.readouterr().out.strip()
    assert line == "af4b #3 ok · table 5×2 · 1.2s · af4b/3.parquet · print: af4b/3.out.txt"


def test_same_run_id_from_before_the_kernel_started_does_not_count(out):
    # запись из позавчера с тем же номером не годится
    alive_kernel(out)
    out.append(rec("af4b", 1, started="2026-10-12T07:00:00+00:00"))
    later(lambda: out.append(rec("af4b", 1)))
    t = time.monotonic()
    assert run(out, "af4b:1") == OK
    assert time.monotonic() - t >= 0.15


def test_error_and_several_cells(out, capsys):
    alive_kernel(out)
    later(lambda: (out.append(rec("af4b", 1)), out.append(rec("13ca", 2, status="error", ename="ProgrammingError"))))
    assert run(out, "af4b:1", "13ca:2") == FAILED
    lines = capsys.readouterr().out.splitlines()
    assert lines[1].startswith("13ca #2 error ProgrammingError")


def test_without_run_id_waits_for_a_new_record(out):
    alive_kernel(out)
    out.append(rec("af4b", 1))
    later(lambda: out.append(rec("af4b", 2)))
    assert run(out, "af4b") == OK


def test_kernel_never_came_up(out):
    assert run(out, "af4b:1", "--start-grace", "0.1") == GONE


def test_kernel_still_starting_is_waited_for(out):
    # первый agent_run поднимает ядро сам: runtime.json появляется позже вызова
    later(lambda: (alive_kernel(out), out.append(rec("af4b", 1))), delay=0.3)
    assert run(out, "af4b:1") == OK


def test_kernel_died_while_waiting(out):
    alive_kernel(out)
    later(lambda: (out.base / RUNTIME_FILE).unlink())
    assert run(out, "af4b:1") == GONE


def test_timeout(out):
    alive_kernel(out)
    assert main([str(out.base.parent.parent / "nb.ipynb"), "af4b:1", "--poll", "0.05", "--timeout", "0.2"]) == TIMEOUT
