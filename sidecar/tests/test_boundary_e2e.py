"""Сквозная проверка границы §3: сайдкар как процесс, только JSON-lines, никакого nvim.

Юниты дергают питоновский API напрямую; здесь проверяется то, что в реальности видит Lua —
проводка `__main__`, конверты, корреляция `id`↔ответ и события в одном потоке stdout.
"""

import json
import pathlib
import subprocess
import sys
import threading

import pytest

from jupyter_nvim.protocol import Ev, KernelState, V


class Sidecar:
    def __init__(self) -> None:
        self.proc = subprocess.Popen(
            [sys.executable, "-m", "jupyter_nvim"],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            bufsize=1,
        )
        self._lock = threading.Lock()
        self._msgs: list[dict] = []
        self._next_id = 0
        threading.Thread(target=self._read, daemon=True).start()

    def _read(self) -> None:
        for line in self.proc.stdout:
            if line.strip():
                with self._lock:
                    self._msgs.append(json.loads(line))

    def messages(self) -> list[dict]:
        with self._lock:
            return list(self._msgs)

    def send(self, op: str, **args) -> int:
        self._next_id += 1
        self.proc.stdin.write(json.dumps({"v": V, "id": self._next_id, "op": op, "args": args}) + "\n")
        self.proc.stdin.flush()
        return self._next_id

    def call(self, op: str, timeout: float = 30.0, **args) -> dict:
        req_id = self.send(op, **args)
        msgs = self.wait(lambda ms: any(m.get("id") == req_id for m in ms), timeout, f"ответ на {op}")
        reply = next(m for m in msgs if m.get("id") == req_id)
        assert reply["ev"] == Ev.OK, reply
        return reply["data"]

    def wait(self, pred, timeout: float = 30.0, what: str = "условия") -> list[dict]:
        gate = threading.Event()
        waited = 0.0
        while waited < timeout:
            msgs = self.messages()
            if pred(msgs):
                return msgs
            gate.wait(0.02)
            waited += 0.02
        raise AssertionError(f"не дождались {what}: {json.dumps(self.messages(), ensure_ascii=False)}")

    def close(self) -> None:
        try:
            self.proc.stdin.close()
        except Exception:
            pass
        self.proc.wait(timeout=30)


@pytest.fixture
def sidecar():
    s = Sidecar()
    yield s
    s.close()


def test_full_cycle_over_json_lines(sidecar, tmp_path):
    notebook = tmp_path / "отчёт.md"
    notebook.write_text("# отчёт\n", encoding="utf-8")

    hello = sidecar.call("hello")
    assert hello["v"] == V and "execute" in hello["caps"]

    started = sidecar.call("kernel.start", kernel_name="python3", notebook=str(notebook))
    assert started["connection_file"].endswith(".json")

    sidecar.wait(
        lambda ms: any(
            m.get("ev") == Ev.KERNEL_STATE and m["data"].get("state") == KernelState.READY
            for m in ms
        ),
        what="kernel.state=ready",
    )

    sidecar.call(
        "execute",
        cell_id="a3f9",
        run_id=1,
        code="import polars as pl\nprint('считаю')\npl.DataFrame({'n': range(1000)})",
    )
    msgs = sidecar.wait(
        lambda ms: any(m.get("ev") == Ev.EXEC_DONE and m.get("cell_id") == "a3f9" for m in ms),
        what="exec.done",
    )

    stream = [m for m in msgs if m.get("ev") == Ev.STREAM]
    assert any(op["text"] == "считаю" for m in stream for op in m["data"]["ops"])

    (table,) = [
        m for m in msgs if m.get("ev") == Ev.RESULT and m["data"].get("kind") == "table"
    ]
    assert table["data"]["rows"] == 1000

    page = sidecar.call("table.page", path=table["data"]["path"], offset=998, limit=10)
    assert page["header"] == ["n"]
    assert page["rows"] == [["998"], ["999"]]
    assert page["total_rows"] == 1000

    index = (notebook.parent / ".jupyter-out" / "отчёт" / "index.jsonl").read_text(encoding="utf-8")
    assert json.loads(index.strip())["kind"] == "table"

    sidecar.call("kernel.shutdown")


def test_unknown_op_does_not_kill_the_process(sidecar):
    sidecar.send("такого-нет")
    sidecar.wait(lambda ms: any(m.get("ev") == Ev.ERROR for m in ms), what="ошибка")

    assert sidecar.call("ping") == {}
    assert sidecar.proc.poll() is None


def test_kernel_banner_does_not_pollute_our_stderr(tmp_path):
    """stderr сайдкара — только под его собственные падения.

    ipykernel печатает баннер про TCP без шифрования на каждом старте. Если наследовать
    наш stderr, этот баннер доезжает до пользователя красным уведомлением при каждом
    запуске ядра, а настоящие ошибки тонут в шуме.
    """
    s = Sidecar()
    notebook = tmp_path / "отчёт.md"
    started = s.call("kernel.start", kernel_name="python3", notebook=str(notebook))
    s.wait(
        lambda ms: any(
            m.get("ev") == Ev.KERNEL_STATE and m["data"].get("state") == KernelState.READY
            for m in ms
        ),
        what="ready",
    )
    s.close()

    stderr = s.proc.stderr.read()
    assert "encryption" not in stderr, f"баннер ядра попал в наш stderr: {stderr[:300]}"
    assert stderr.strip() == "", f"в stderr сайдкара мусор: {stderr[:300]}"

    log = pathlib.Path(started["kernel_log"])
    assert log.exists(), "лог ядра должен лежать рядом с выводами"
    assert log.parent == notebook.parent / ".jupyter-out" / "отчёт"


def test_process_exits_cleanly_on_eof(tmp_path):
    s = Sidecar()
    s.call("kernel.start", kernel_name="python3", notebook=str(tmp_path / "n.md"))
    s.close()

    assert s.proc.returncode == 0


def test_readonly_notebook_dir_disables_history_not_kernel(sidecar, tmp_path):
    """Ноутбук в каталоге без записи: история невозможна, выполнение — вполне.

    Раньше одна упавшая mkdir не давала стартовать ядру: путь к логу ядра лежал внутри
    каталога выводов. То есть ноутбук на примонтированной только для чтения шаре не
    работал вовсе, хотя ядру этот каталог не нужен.
    """
    ro = tmp_path / "только-чтение"
    ro.mkdir()
    notebook = ro / "отчёт.md"
    notebook.write_text("# отчёт\n", encoding="utf-8")
    ro.chmod(0o555)
    try:
        sidecar.call("hello")
        sidecar.call("kernel.start", kernel_name="python3", notebook=str(notebook))
        sidecar.wait(
            lambda ms: any(
                m.get("ev") == Ev.KERNEL_STATE and m["data"].get("state") == KernelState.READY
                for m in ms
            ),
            what="готовности ядра",
        )

        sidecar.call("execute", code="print('вопреки всему')", cell_id="0001", run_id=1)
        msgs = sidecar.wait(
            lambda ms: any(m.get("ev") == Ev.EXEC_DONE for m in ms),
            what="завершения ячейки",
        )

        done = next(m for m in msgs if m.get("ev") == Ev.EXEC_DONE)
        assert done["data"]["status"] == "ok", done
        # и пользователю сказано, почему истории не будет
        warns = [
            m for m in msgs
            if m.get("ev") == Ev.LOG and "история выключена" in m["data"].get("msg", "")
        ]
        assert warns, "молча терять историю нельзя"
    finally:
        ro.chmod(0o755)
