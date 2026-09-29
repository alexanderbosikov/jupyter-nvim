"""Дисциплина отправки в shell-канал. Живое ядро тут не нужно — важен порядок и замок.

Сокет один, и он не потокобезопасен, а пишут в него три источника: пользовательский
`execute`, скрытые ячейки и `kernel_info` от сторожа готовности — каждый из своего потока.
Стоит одной отправке уйти мимо общего замка, как кадры двух многокадровых сообщений
перемешиваются, ядро перестаёт разбирать поток и замолкает навсегда.

Тесты структурные: проверяют не результат, а то, что в момент `send` соблюдены оба
инварианта — замок взят и метка пробы уже стоит. Проверить это через живое ядро нельзя:
гонка ловится примерно на одном старте из полусотни.
"""

import io
import types

from conftest import Sink

from jupyter_nvim.kernel import KernelSession
from jupyter_nvim.rpc import Rpc


def session_with_fake_client(record):
    """Сессия, у которой shell-канал только запоминает обстановку на момент отправки."""
    session = KernelSession(Rpc(stdin=io.StringIO(""), stdout=Sink()))
    counter = {"n": 0}

    class FakeSession:
        def msg(self, msg_type, content):
            counter["n"] += 1
            return {
                "header": {"msg_id": f"msg-{counter['n']}", "msg_type": msg_type},
                "content": content,
            }

    class FakeShell:
        def send(self, msg):
            record.append({
                "msg_id": msg["header"]["msg_id"],
                "msg_type": msg["header"]["msg_type"],
                "locked": session._lock.locked(),
                "probe_current": session._probe_current,
                "known_probe": msg["header"]["msg_id"] in session._probe_msg_ids,
            })

    session._client = types.SimpleNamespace(session=FakeSession(), shell_channel=FakeShell())
    return session


def test_kernel_info_is_sent_under_the_same_lock():
    """Сторож готовности шлёт kernel_info из своего потока — мимо замка ему нельзя."""
    sent = []
    session = session_with_fake_client(sent)

    session._send_kernel_info()

    assert len(sent) == 1
    assert sent[0]["msg_type"] == "kernel_info_request"
    assert sent[0]["locked"], "kernel_info уходит мимо общего замка — кадры перемешаются"


def test_hidden_cell_is_sent_under_the_same_lock():
    sent = []
    session = session_with_fake_client(sent)

    session._send_hidden("pass")

    assert sent[0]["locked"]


def test_probe_is_registered_before_it_is_sent():
    """Пробу узнаёт поток iopub, поэтому метка должна стоять раньше отправки."""
    sent = []
    session = session_with_fake_client(sent)

    msg_id = session._send_hidden("pass", allow_stdin=True, as_probe=True)

    assert sent[0]["probe_current"] == msg_id, "метку пробы поставили после отправки — это гонка"
    assert sent[0]["known_probe"], "msg_id пробы должен быть известен до отправки"


def test_ordinary_hidden_cell_does_not_claim_the_probe():
    """Помощник из §7.1 — тоже скрытая ячейка, но пробой он не является."""
    sent = []
    session = session_with_fake_client(sent)

    session._send_hidden("pass")

    assert sent[0]["probe_current"] is None
