"""Интеграционные тесты против настоящего ipykernel. ARCHITECTURE.md §9.

Ядро — обычный подпроцесс, nvim здесь не участвует. Ожидания — по событиям, а не по sleep:
`sink.wait(...)` крутится до появления нужного сообщения, иначе тесты флаки по определению.
"""

import io

import pytest
from conftest import Sink, wait_until

from jupyter_nvim.kernel import KernelSession
from jupyter_nvim.outdir import OutDir
from jupyter_nvim.protocol import ErrCode, Ev, ExecStatus, KernelState
from jupyter_nvim.router import Router
from jupyter_nvim.rpc import Rpc, RpcError

PNG_1X1 = (
    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8DwHwAFAAH/q842iQAAAABJRU5ErkJggg=="
)


def is_ready(msgs):
    return any(
        m.get("ev") == Ev.KERNEL_STATE and m["data"].get("state") == KernelState.READY
        for m in msgs
    )


def done_for(cell_id):
    def pred(msgs):
        return any(m.get("ev") == Ev.EXEC_DONE and m.get("cell_id") == cell_id for m in msgs)

    return pred


def pick(msgs, ev, cell_id=None):
    return [m for m in msgs if m.get("ev") == ev and (cell_id is None or m.get("cell_id") == cell_id)]


def stream_text(msgs, cell_id):
    lines = []
    for m in pick(msgs, Ev.STREAM, cell_id):
        for op in m["data"]["ops"]:
            if op["op"] == "append":
                lines.append(op["text"])
            else:
                lines[-1:] = [op["text"]]
    return "\n".join(lines)


@pytest.fixture
def live(tmp_path):
    """Поднимает настоящее ядро и гарантированно гасит его после теста."""
    started = []

    def start(env=None, with_outdir=True, history_limit=5):
        sink = Sink()
        rpc = Rpc(stdin=io.StringIO(""), stdout=sink)
        outdir = OutDir(tmp_path / "отчёт.md") if with_outdir else None
        session = KernelSession(
            rpc, Router(), outdir_for=lambda: outdir, poll=0.05, history_limit=history_limit
        )
        session.start(kernel_name="python3", env=env)
        started.append(session)
        sink.wait(is_ready, what="kernel.state=ready")
        return session, sink, outdir

    yield start
    for session in started:
        try:
            session.shutdown()
        except Exception:
            pass


def test_execute_prints_and_finishes(live):
    session, sink, _ = live()
    session.execute("a3f9", 1, "print('привет')")

    msgs = sink.wait(done_for("a3f9"), what="exec.done")

    assert stream_text(msgs, "a3f9") == "привет"
    (started,) = pick(msgs, Ev.EXEC_STARTED, "a3f9")
    assert started["data"]["msg_id"]
    (done,) = pick(msgs, Ev.EXEC_DONE, "a3f9")
    assert done["data"]["status"] == ExecStatus.OK
    assert done["data"]["execution_count"] == 1
    assert done["data"]["duration_ms"] >= 0
    assert done["run_id"] == 1


def test_result_of_last_expression(live):
    session, sink, _ = live()
    session.execute("a3f9", 1, "2 + 2")

    msgs = sink.wait(done_for("a3f9"))

    (result,) = pick(msgs, Ev.RESULT, "a3f9")
    assert result["data"] == {"kind": "text", "text": "4"}


def test_error_carries_ename_and_clean_traceback(live):
    session, sink, _ = live()
    session.execute("a3f9", 1, "1 / 0")

    msgs = sink.wait(done_for("a3f9"))

    (err,) = pick(msgs, Ev.EXEC_ERROR, "a3f9")
    assert err["data"]["ename"] == "ZeroDivisionError"
    assert err["data"]["traceback"], "трейсбек не должен быть пустым"
    assert not any("\x1b" in line for line in err["data"]["traceback"]), "ANSI должен быть снят"
    (done,) = pick(msgs, Ev.EXEC_DONE, "a3f9")
    assert done["data"]["status"] == ExecStatus.ERROR


def test_two_cells_in_flight_never_mix(live):
    """Тест-лист §10: две ячейки в очереди."""
    session, sink, _ = live()
    session.execute("a3f9", 1, "import time\nprint('первая')\ntime.sleep(0.3)\nprint('ещё первая')")
    session.execute("b7e1", 2, "print('вторая')")

    msgs = sink.wait(
        lambda ms: done_for("a3f9")(ms) and done_for("b7e1")(ms), what="оба exec.done"
    )

    assert stream_text(msgs, "a3f9") == "первая\nещё первая"
    assert stream_text(msgs, "b7e1") == "вторая"
    assert all(m["run_id"] == 1 for m in pick(msgs, Ev.STREAM, "a3f9"))
    assert all(m["run_id"] == 2 for m in pick(msgs, Ev.STREAM, "b7e1"))


def test_progress_bar_stays_one_line(live):
    """Тест-лист §10: `\\r` в потоке вывода."""
    session, sink, _ = live()
    session.execute(
        "a3f9",
        1,
        "import sys\nfor i in range(5):\n    sys.stdout.write(f'\\r[{i}]')\n    sys.stdout.flush()\n",
    )

    msgs = sink.wait(done_for("a3f9"))

    ops = [op for m in pick(msgs, Ev.STREAM, "a3f9") for op in m["data"]["ops"]]
    assert [op["op"] for op in ops].count("append") == 1, ops
    assert ops[-1]["text"] == "[4]"


def test_late_output_lands_on_its_own_cell_when_nothing_else_runs(live):
    """Тест-лист §10: вывод из фонового потока после `idle` (наш nb_utils/notify.py)."""
    session, sink, _ = live()
    session.execute(
        "a3f9",
        1,
        "import threading\nthreading.Timer(0.4, lambda: print('ФОН')).start()\nprint('тело')",
    )
    sink.wait(done_for("a3f9"))

    msgs = sink.wait(
        lambda ms: any(m.get("ev") == Ev.STREAM and m["data"].get("late") for m in ms),
        what="поздний stream",
    )

    late = [m for m in msgs if m.get("ev") == Ev.STREAM and m["data"].get("late")]
    assert all(m["cell_id"] == "a3f9" and m["run_id"] == 1 for m in late)
    assert any("ФОН" in op["text"] for m in late for op in m["data"]["ops"])


def test_background_output_is_stolen_by_the_running_cell(live):
    """Граница, которую маршрутизация по msg_id не лечит — и это не наш баг.

    Если фоновый поток печатает, пока выполняется ДРУГАЯ ячейка, ipykernel сам ставит в
    `parent_header` идентификатор текущего запроса. Клиент не может это различить: у Jupyter Lab
    ровно то же поведение. Проверено на ipykernel 7.3.0; тест фиксирует факт, чтобы изменение
    в ядре не прошло незамеченным.
    """
    session, sink, _ = live()
    session.execute(
        "a3f9",
        1,
        "import threading\nthreading.Timer(0.5, lambda: print('ФОН')).start()\nprint('тело')",
    )
    sink.wait(done_for("a3f9"))

    session.execute("b7e1", 2, "import time\ntime.sleep(1.5)\nprint('вторая')")
    msgs = sink.wait(done_for("b7e1"), what="exec.done второй ячейки")

    assert "ФОН" in stream_text(msgs, "b7e1"), "поведение ядра изменилось — перечитать §4.4"
    assert not any(m["data"].get("late") for m in pick(msgs, Ev.STREAM, "b7e1"))


def test_clean_run_produces_no_orphans(live):
    """orphan — только настоящая аномалия маршрутизации.

    Служебное (`iopub_welcome`, `execute_input`, проба stdin) и вывод самого ядра без родителя
    (баннер «running over TCP without encryption») аномалией не являются.
    """
    session, sink, _ = live()
    session.execute("a3f9", 1, "print('ок')")

    msgs = sink.wait(done_for("a3f9"))

    assert pick(msgs, Ev.ORPHAN) == []


def test_kernel_own_output_is_reported_as_a_log(live):
    """Вывод ядра без родителя не теряется молча — уходит наверх как log уровня kernel."""
    session, sink, _ = live()
    session.execute("a3f9", 1, "print('ок')")
    sink.wait(done_for("a3f9"))

    kernel_logs = [m for m in sink.messages() if m.get("ev") == Ev.LOG and m["data"].get("level") == "kernel"]
    assert all(m["data"]["msg"] for m in kernel_logs)


def test_display_data_image_goes_to_a_file(live):
    session, sink, outdir = live()
    session.execute(
        "a3f9",
        1,
        f"from IPython.display import publish_display_data\n"
        f"publish_display_data({{'image/png': '{PNG_1X1}'}})",
    )

    msgs = sink.wait(done_for("a3f9"))

    (disp,) = pick(msgs, Ev.DISPLAY, "a3f9")
    assert disp["data"]["kind"] == "image"
    path = outdir.path_for("a3f9", 1, "png")
    assert path.read_bytes().startswith(b"\x89PNG")


def test_stdin_roundtrip(live):
    """Тест-лист §10: `input()` в ячейке."""
    session, sink, _ = live()
    session.execute("a3f9", 1, "имя = input('кто: ')\nprint(f'привет, {имя}')")

    sink.wait(lambda ms: pick(ms, Ev.INPUT_REQUEST), what="input_request")
    (req,) = pick(sink.messages(), Ev.INPUT_REQUEST)
    assert req["data"]["prompt"] == "кто: "
    assert req["cell_id"] == "a3f9"

    session.stdin_reply("Мир")
    msgs = sink.wait(done_for("a3f9"))

    assert "привет, Мир" in stream_text(msgs, "a3f9")


def test_env_reaches_the_kernel(live):
    """Через этот путь ядру уезжает NB_UTILS_ITABLES=0."""
    session, sink, _ = live(env={"JN_TEST_FLAG": "42"})
    session.execute("a3f9", 1, "import os\nprint(os.environ.get('JN_TEST_FLAG'))")

    msgs = sink.wait(done_for("a3f9"))

    assert stream_text(msgs, "a3f9") == "42"


def test_kernel_death_aborts_active_runs(live):
    """Тест-лист §10: ядро умерло."""
    session, sink, _ = live()
    session.execute("a3f9", 1, "import os, signal\nos.kill(os.getpid(), signal.SIGKILL)")

    msgs = sink.wait(
        lambda ms: any(
            m.get("ev") == Ev.KERNEL_STATE and m["data"].get("state") == KernelState.DEAD
            for m in ms
        ),
        what="kernel.state=dead",
    )

    (done,) = pick(msgs, Ev.EXEC_DONE, "a3f9")
    assert done["data"]["status"] == ExecStatus.ABORTED
    assert len(session.router) == 0


def test_restart_clears_namespace_and_returns_to_ready(live):
    """Тест-лист §10: рестарт ядра."""
    session, sink, _ = live()
    session.execute("a3f9", 1, "x = 41")
    sink.wait(done_for("a3f9"))

    report = session.restart()
    wait_until(
        lambda: session.state()["state"] == KernelState.READY, what="ready после рестарта"
    )

    assert report["aborted"] == 0

    session.execute("b7e1", 2, "print(globals().get('x'))")
    msgs = sink.wait(done_for("b7e1"))

    assert stream_text(msgs, "b7e1") == "None"


def test_interrupt_closes_the_whole_queue(live):
    """Тест-лист §10: прерывание при нескольких ячейках в очереди."""
    session, sink, _ = live()
    session.execute("a3f9", 1, "import sys, time\nprint('пошла', flush=True)\ntime.sleep(60)")
    session.execute("b7e1", 2, "print('вторая')")

    sink.wait(lambda ms: "пошла" in stream_text(ms, "a3f9"), what="тело первой ячейки пошло")
    session.interrupt()

    msgs = sink.wait(
        lambda ms: done_for("a3f9")(ms) and done_for("b7e1")(ms), what="оба прогона закрыты"
    )

    first = pick(msgs, Ev.EXEC_DONE, "a3f9")[0]["data"]["status"]
    second = pick(msgs, Ev.EXEC_DONE, "b7e1")[0]["data"]["status"]
    assert first in (ExecStatus.ERROR, ExecStatus.ABORTED), first
    assert second == ExecStatus.ABORTED, second
    assert len(session.router) == 0


def test_shutdown_removes_the_connection_file(live):
    """В ~/Library/Jupyter/runtime/ 85 брошенных kernel-*.json — за собой убираем."""
    session, sink, _ = live()
    conn = session._km.connection_file
    session.shutdown()

    import os

    assert not os.path.exists(conn)


def test_execute_is_refused_before_the_kernel_is_ready():
    """§6.2: гард встроен в конструкцию, а не прикручен как в §12 п.1 идеи."""
    sink = Sink()
    session = KernelSession(Rpc(stdin=io.StringIO(""), stdout=sink), Router())
    session._km = object()
    session._state = KernelState.STARTING

    with pytest.raises(RpcError) as e:
        session.execute("a3f9", 1, "1+1")

    assert e.value.code == ErrCode.KERNEL_NOT_READY
    assert e.value.extra["state"] == KernelState.STARTING


# --- шаг 2: результат-таблица, персистенс, CLI ---


def test_dataframe_result_becomes_a_table_on_disk(live):
    session, sink, outdir = live()
    session.execute("a3f9", 1, "import polars as pl\npl.DataFrame({'a': [1, 2, 3], 'b': ['x', 'y', 'z']})")

    msgs = sink.wait(done_for("a3f9"))

    tables = [m for m in pick(msgs, Ev.RESULT, "a3f9") if m["data"]["kind"] == "table"]
    assert len(tables) == 1
    data = tables[0]["data"]
    assert data["rows"] == 3 and data["cols"] == 2
    assert data["schema"] == [["a", "Int64"], ["b", "String"]]
    assert outdir.path_for("a3f9", 1, "parquet").exists()

    record = outdir.last("a3f9")
    assert record["kind"] == "table"
    assert record["path"] == "a3f9/1.parquet", "в индексе путь относительный (§7)"
    assert record["status"] == "ok"
    assert len(record["code_sha"]) == 8


def test_named_dataframe_via_result_expr(live):
    """Путь для `%%sql`: имя переменной разбирает Lua и присылает в result_expr."""
    session, sink, outdir = live()
    session.execute(
        "b7e1", 4, "import polars as pl\ndf = pl.DataFrame({'q': [1] * 5})", result_expr="df"
    )

    msgs = sink.wait(done_for("b7e1"))

    (table,) = [m for m in pick(msgs, Ev.RESULT, "b7e1") if m["data"]["kind"] == "table"]
    assert table["data"]["rows"] == 5
    assert outdir.path_for("b7e1", 4, "parquet").exists()


def test_plain_result_produces_no_table(live):
    session, sink, outdir = live()
    session.execute("a3f9", 1, "2 + 2")

    msgs = sink.wait(done_for("a3f9"))

    assert not [m for m in pick(msgs, Ev.RESULT, "a3f9") if m["data"]["kind"] == "table"]
    assert not outdir.path_for("a3f9", 1, "parquet").exists()
    assert outdir.last("a3f9")["kind"] == "text"


def test_text_output_is_persisted_and_readable_without_nvim(live, capsys):
    """§4.6 идеи: результат ячейки читается снаружи, без редактора и без парсинга HTML."""
    from jupyter_nvim.cli import main

    session, sink, outdir = live()
    session.execute("a3f9", 7, "print('строка один')\nprint('строка два')")
    sink.wait(done_for("a3f9"))

    record = outdir.last("a3f9")
    assert record["kind"] == "text" and record["path"] == "a3f9/7.txt"

    rc = main([str(outdir.notebook), "a3f9"])

    assert rc == 0
    assert capsys.readouterr().out == "строка один\nстрока два\n"


def test_error_traceback_lands_in_the_index(live):
    session, sink, outdir = live()
    session.execute("a3f9", 1, "1 / 0")
    sink.wait(done_for("a3f9"))

    record = outdir.last("a3f9")

    assert record["status"] == "error"
    assert record["ename"] == "ZeroDivisionError"
    assert "ZeroDivisionError" in (outdir.base / record["path"]).read_text(encoding="utf-8")


def test_history_is_pruned_to_the_limit(live):
    """§13.1 идеи: история прогонов ячейки живёт, но не растёт бесконечно."""
    session, sink, outdir = live(history_limit=2)
    for run in range(1, 6):
        session.execute("a3f9", run, f"print({run})")
        sink.wait(
            lambda ms, r=run: any(
                m.get("ev") == Ev.EXEC_DONE and m.get("run_id") == r for m in ms
            ),
            what=f"exec.done прогона {run}",
        )

    runs = [r["run_id"] for r in outdir.records("a3f9")]

    assert runs == [4, 5]
    assert not (outdir.base / "a3f9" / "1.txt").exists(), "файлы обрезанных прогонов удаляются"
    assert (outdir.base / "a3f9" / "5.txt").exists()


def test_huge_result_is_paged_not_rendered(live):
    """Тест-лист §10: таблица на 100k строк не должна рендериться целиком."""
    session, sink, outdir = live()
    session.execute("a3f9", 1, "import polars as pl\npl.DataFrame({'n': range(100_000)})")
    msgs = sink.wait(done_for("a3f9"), what="exec.done большой таблицы")

    (table,) = [m for m in pick(msgs, Ev.RESULT, "a3f9") if m["data"]["kind"] == "table"]
    assert table["data"]["rows"] == 100_000

    first = session.table_page(table["data"]["path"], offset=0, limit=50)
    assert len(first["rows"]) == 50 and first["truncated"] is True

    last = session.table_page(table["data"]["path"], offset=99_990, limit=50)
    assert [r[0] for r in last["rows"]][-1] == "99999"
    assert last["truncated"] is False

    beyond = session.table_page(table["data"]["path"], offset=10**9, limit=50)
    assert beyond["rows"] == [] and beyond["offset"] == 100_000


def test_relative_kernelspec_resolves_to_our_interpreter(live):
    """kernelspec с относительным argv не должен зависеть от внешнего PATH.

    У venv'ного `python3` в argv стоит просто "python": в чистом PATH такого бинарника
    может не быть вовсе, и ячейка падает ModuleNotFoundError на первом импорте. Ядро
    обязано подниматься тем же интерпретатором, что и сайдкар.
    """
    import sys as _sys

    session, sink, _ = live()
    session.execute("a3f9", 1, "import sys\nprint(sys.executable)")

    msgs = sink.wait(done_for("a3f9"))

    assert stream_text(msgs, "a3f9") == _sys.executable


def test_polars_is_importable_in_the_kernel(live):
    """Следствие предыдущего: ядро видит те же пакеты, что и сайдкар."""
    session, sink, _ = live()
    session.execute("a3f9", 1, "import polars as pl\nprint(pl.__version__)")

    msgs = sink.wait(done_for("a3f9"))

    assert pick(msgs, Ev.EXEC_ERROR, "a3f9") == []
    assert stream_text(msgs, "a3f9") != ""
