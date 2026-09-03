"""Константы протокола Lua↔сайдкар. См. ARCHITECTURE.md §4."""

from __future__ import annotations

V = 1
"""Версия протокола. Несовпадение валится на `hello`, а не тихо в рантайме."""


class Op:
    HELLO = "hello"
    KERNEL_START = "kernel.start"
    KERNEL_STATE = "kernel.state"
    KERNEL_RESTART = "kernel.restart"
    KERNEL_SHUTDOWN = "kernel.shutdown"
    EXECUTE = "execute"
    INTERRUPT = "interrupt"
    STDIN_REPLY = "stdin.reply"
    TABLE_PAGE = "table.page"
    PING = "ping"


class Ev:
    OK = "ok"
    ERROR = "error"
    EXEC_STARTED = "exec.started"
    STREAM = "stream"
    DISPLAY = "display"
    RESULT = "result"
    EXEC_ERROR = "exec.error"
    EXEC_DONE = "exec.done"
    INPUT_REQUEST = "input_request"
    KERNEL_STATE = "kernel.state"
    CLEAR_OUTPUT = "clear_output"
    ORPHAN = "orphan"
    LOG = "log"


class ErrCode:
    BAD_JSON = "bad_json"
    BAD_REQUEST = "bad_request"
    PROTOCOL_VERSION = "protocol_version"
    UNKNOWN_OP = "unknown_op"
    BAD_ARGS = "bad_args"
    KERNEL_NOT_READY = "kernel_not_ready"
    KERNEL_DEAD = "kernel_dead"
    NOT_FOUND = "not_found"
    INTERNAL = "internal"


class KernelState:
    NONE = "none"
    STARTING = "starting"
    READY = "ready"
    BUSY = "busy"
    DEAD = "dead"


class ExecStatus:
    OK = "ok"
    ERROR = "error"
    ABORTED = "aborted"
