import io
import json
import subprocess
import sys
import threading

from conftest import req

from jupyter_nvim.protocol import ErrCode, Ev, V
from jupyter_nvim.rpc import Rpc, RpcError


def test_ok_reply_echoes_id(rpc, sink):
    rpc.op("ping")(lambda args: {"pong": True})
    rpc.handle_line(req("ping", id=42))

    (msg,) = sink.messages()
    assert msg == {"v": V, "id": 42, "ev": Ev.OK, "data": {"pong": True}}


def test_args_reach_handler(rpc, sink):
    seen = {}
    rpc.op("execute")(lambda args: seen.update(args) or {"msg_id": "m1"})
    rpc.handle_line(req("execute", cell_id="a3f9", run_id=7, code="1+1"))

    assert seen == {"cell_id": "a3f9", "run_id": 7, "code": "1+1"}


def test_unknown_op_keeps_id(rpc, sink):
    rpc.handle_line(req("nope", id="x"))

    (msg,) = sink.messages()
    assert msg["ev"] == Ev.ERROR and msg["id"] == "x"
    assert msg["data"]["code"] == ErrCode.UNKNOWN_OP


def test_bad_json_reports_without_id(rpc, sink):
    rpc.handle_line("{не json")

    (msg,) = sink.messages()
    assert msg["ev"] == Ev.ERROR and "id" not in msg
    assert msg["data"]["code"] == ErrCode.BAD_JSON


def test_version_mismatch_is_loud(rpc, sink):
    rpc.op("ping")(lambda args: {})
    rpc.handle_line(req("ping", v=99))

    (msg,) = sink.messages()
    assert msg["data"]["code"] == ErrCode.PROTOCOL_VERSION
    assert msg["data"]["expected"] == V


def test_rpc_error_passes_code_and_extra(rpc, sink):
    @rpc.op("execute")
    def _boom(args):
        raise RpcError(ErrCode.KERNEL_NOT_READY, "ядро ещё стартует", state="starting")

    rpc.handle_line(req("execute"))

    (msg,) = sink.messages()
    assert msg["data"] == {
        "code": ErrCode.KERNEL_NOT_READY,
        "msg": "ядро ещё стартует",
        "state": "starting",
    }


def test_handler_crash_does_not_kill_sidecar(rpc, sink):
    rpc.op("boom")(lambda args: 1 / 0)
    rpc.op("ping")(lambda args: {})
    rpc.handle_line(req("boom"))
    rpc.handle_line(req("ping", id=2))

    first, second = sink.messages()
    assert first["data"]["code"] == ErrCode.INTERNAL
    assert "ZeroDivisionError" in first["data"]["msg"]
    assert second["ev"] == Ev.OK


def test_blank_and_whitespace_lines_ignored(rpc, sink):
    rpc.handle_line("")
    rpc.handle_line("   \n")

    assert sink.messages() == []


def test_events_carry_keys_but_no_id(rpc, sink):
    rpc.event(Ev.STREAM, cell_id="a3f9", run_id=3, name="stdout", text="hi")

    (msg,) = sink.messages()
    assert "id" not in msg
    assert msg["cell_id"] == "a3f9" and msg["run_id"] == 3
    assert msg["data"] == {"name": "stdout", "text": "hi"}


def test_concurrent_writers_do_not_tear_lines(sink):
    """События шлёт поток iopub, ответы — основной: строки не должны перемешиваться."""
    rpc = Rpc(stdin=io.StringIO(""), stdout=sink)
    payload = "ы" * 500

    def spam(n):
        for i in range(50):
            rpc.event(Ev.STREAM, cell_id=f"c{n}", run_id=i, text=payload)

    threads = [threading.Thread(target=spam, args=(n,)) for n in range(8)]
    for t in threads:
        t.start()
    for t in threads:
        t.join()

    msgs = sink.messages()
    assert len(msgs) == 400
    assert all(m["data"]["text"] == payload for m in msgs)


def test_serve_reads_until_eof(sink):
    lines = req("ping", id=1) + "\n" + req("ping", id=2) + "\n"
    rpc = Rpc(stdin=io.StringIO(lines), stdout=sink)
    rpc.op("ping")(lambda args: {})
    rpc.serve()

    assert [m["id"] for m in sink.messages()] == [1, 2]


def test_boundary_works_as_a_plain_process():
    """ARCHITECTURE.md §3: сайдкар обязан работать из echo | python -m jupyter_nvim, без nvim."""
    proc = subprocess.run(
        [sys.executable, "-m", "jupyter_nvim"],
        input=req("hello", id=1) + "\n" + req("ping", id=2) + "\n",
        capture_output=True,
        text=True,
        timeout=30,
    )
    assert proc.returncode == 0, proc.stderr

    hello, ping = [json.loads(line) for line in proc.stdout.splitlines() if line.strip()]
    assert hello["ev"] == Ev.OK and hello["data"]["v"] == V
    assert "execute" in hello["data"]["caps"]
    assert ping["ev"] == Ev.OK
