"""Предел на молчание ядра при старте. ARCHITECTURE.md §6.2.

Живое ядро может замолчать, не умерев: `_watchdog` следит только за смертью процесса, и до
предела состояние оставалось STARTING навсегда — очередь запусков в Lua копилась вечно и
показывала «в очереди», а больше ничего не происходило. Наблюдаемая причина —
ipython/ipykernel#1529.

Ядро здесь не поднимается: интересно ровно одно — когда мы объявляем молчание, — а живое
ядро в этом вопросе только добавило бы флаки.
"""

import io
import time

import pytest
from conftest import Sink

from jupyter_nvim.kernel import KernelSession
from jupyter_nvim.protocol import Ev, KernelState
from jupyter_nvim.rpc import Rpc


@pytest.fixture
def starting():
    """Сессия, которая уже в STARTING: ядро запущено, но пока не сказало ни слова."""
    sink = Sink()
    session = KernelSession(Rpc(stdin=io.StringIO(""), stdout=sink))
    session._km = object()  # watchdog пропускает сессию без менеджера, а нам он не нужен
    session._shell_timeout = 0.2
    session._ready_timeout = 0.5
    session._set_state(KernelState.STARTING)
    return session, sink


class _FakeClient:
    """Ровно то, чего касается `_probe_ready`: отправка kernel_info и ничего больше."""

    class _Session:
        def msg(self, mtype, content):
            return {"header": {"msg_id": f"{mtype}-1"}}

    class _Shell:
        def __init__(self):
            self.sent = []

        def send(self, msg):
            self.sent.append(msg)

    def __init__(self):
        self.session = self._Session()
        self.shell_channel = self._Shell()


def states(sink):
    return [m["data"]["state"] for m in sink.events(Ev.KERNEL_STATE)]


def test_молчание_короче_предела_ничего_не_меняет(starting):
    session, sink = starting
    assert session._check_ready_deadline() is False
    assert session._state == KernelState.STARTING
    assert states(sink) == [KernelState.STARTING]


def test_молчание_дольше_предела_объявляется_вслух(starting):
    session, sink = starting
    time.sleep(0.25)

    assert session._check_ready_deadline() is True
    assert session._state == KernelState.STUCK
    assert states(sink) == [KernelState.STARTING, KernelState.STUCK]

    said = sink.events(Ev.KERNEL_STATE)[-1]["data"]
    assert "shell" in said["reason"], "причина должна называть вставший этап"


def test_ответивший_shell_даёт_остальным_этапам_больше_времени(starting):
    """Ответ на shell ни от чего не зависит, а подписка iopub и проба stdin честно дольше."""
    session, sink = starting
    session._shell_ready = True
    time.sleep(0.25)

    assert session._check_ready_deadline() is False, "короткий предел shell тут не при чём"
    assert session._state == KernelState.STARTING

    time.sleep(0.3)
    assert session._check_ready_deadline() is True
    assert "iopub" in sink.events(Ev.KERNEL_STATE)[-1]["data"]["reason"]


def test_причина_различает_iopub_и_stdin(starting):
    """Места и виновники разные, и в журнале должно быть видно, какое именно."""
    session, sink = starting
    session._shell_ready = True
    session._iopub_live = True
    time.sleep(0.55)

    assert session._check_ready_deadline() is True
    assert "stdin" in sink.events(Ev.KERNEL_STATE)[-1]["data"]["reason"]


def test_объявляется_один_раз_а_не_каждый_тик(starting):
    session, sink = starting
    time.sleep(0.25)

    assert session._check_ready_deadline() is True
    for _ in range(5):
        assert session._check_ready_deadline() is False

    assert states(sink).count(KernelState.STUCK) == 1


def test_замолчавшее_но_ответившее_ядро_становится_готовым_само(starting):
    session, sink = starting
    time.sleep(0.25)
    session._check_ready_deadline()
    assert session._state == KernelState.STUCK

    # ядро всё-таки отозвалось по всем трём каналам
    session._shell_ready = True
    session._iopub_live = True
    session._stdin_live = True
    session._stdin_started = True
    session._banner = {}
    session._maybe_ready()

    assert session._state == KernelState.READY, "рестарта для этого требовать незачем"


def test_готовому_ядру_предел_не_страшен(starting):
    session, _ = starting
    session._state = KernelState.READY
    session._state_t0 = time.monotonic() - 3600

    assert session._check_ready_deadline() is False
    assert session._state == KernelState.READY


def test_новый_заход_в_старт_обнуляет_отсчёт(starting):
    session, sink = starting
    time.sleep(0.25)
    session._check_ready_deadline()
    assert session._state == KernelState.STUCK

    session._client = _FakeClient()
    session._pump_stop.set()  # чтобы поток-пробер вышел сразу, а не стучал ещё девять секунд
    session._probe_ready()  # рестарт: отсчёт начинается заново
    assert session._state == KernelState.STARTING
    assert session._check_ready_deadline() is False, "предел считается с этого старта, не с прошлого"
