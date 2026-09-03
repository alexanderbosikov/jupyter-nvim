import json
import threading

import pytest

from jupyter_nvim.protocol import V
from jupyter_nvim.rpc import Rpc


class Sink:
    """stdout сайдкара, разобранный по строкам. Потокобезопасен: события шлёт поток iopub."""

    def __init__(self) -> None:
        self._lock = threading.Lock()
        self._tail = ""
        self.lines: list[str] = []

    def write(self, s: str) -> int:
        with self._lock:
            self._tail += s
            *whole, self._tail = self._tail.split("\n")
            self.lines.extend(whole)
        return len(s)

    def flush(self) -> None:
        pass

    def messages(self) -> list[dict]:
        with self._lock:
            return [json.loads(line) for line in self.lines if line.strip()]

    def events(self, ev: str) -> list[dict]:
        return [m for m in self.messages() if m.get("ev") == ev]

    def wait(self, predicate, timeout: float = 45.0, what: str = "условия") -> list[dict]:
        """Ждёт события, а не спит: тесты с живым ядром иначе становятся флаки.

        Таймаут — страховка от зависания, а не измерение: на загруженной машине старт ядра
        разъезжается в разы, и слишком тесный бюджет даёт ложные падения.
        """
        deadline = threading.Event()
        step = 0.02
        waited = 0.0
        while waited < timeout:
            msgs = self.messages()
            if predicate(msgs):
                return msgs
            deadline.wait(step)
            waited += step
        raise AssertionError(
            f"не дождались {what} за {timeout} с; получено:\n"
            + "\n".join(json.dumps(m, ensure_ascii=False) for m in self.messages())
        )


def wait_until(predicate, timeout: float = 45.0, what: str = "условия") -> None:
    """Ожидание состояния объекта, а не события в потоке."""
    gate = threading.Event()
    waited = 0.0
    while waited < timeout:
        if predicate():
            return
        gate.wait(0.02)
        waited += 0.02
    raise AssertionError(f"не дождались {what} за {timeout} с")


@pytest.fixture
def sink() -> Sink:
    return Sink()


@pytest.fixture
def rpc(sink: Sink) -> Rpc:
    import io

    return Rpc(stdin=io.StringIO(""), stdout=sink)


def req(op: str, id: int | str = 1, v: int = V, **args) -> str:
    return json.dumps({"v": v, "id": id, "op": op, "args": args})
