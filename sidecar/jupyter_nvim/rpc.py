"""JSON-lines поверх stdin/stdout: запросы вниз, события наверх. ARCHITECTURE.md §4.1.

Ответ на запрос ровно один и несёт тот же `id`; события уходят без `id`. Писатель под локом —
события шлёт поток чтения iopub, ответы пишет основной поток.
"""

from __future__ import annotations

import json
import sys
import threading
from typing import Any, Callable, TextIO

from .protocol import ErrCode, Ev, V

Handler = Callable[[dict[str, Any]], dict[str, Any] | None]


class RpcError(Exception):
    """Ошибка, которую надо вернуть вызывающему как `ev: error` с кодом."""

    def __init__(self, code: str, msg: str, **extra: Any) -> None:
        super().__init__(f"{code}: {msg}")
        self.code = code
        self.msg = msg
        self.extra = extra


class Rpc:
    def __init__(self, stdin: TextIO | None = None, stdout: TextIO | None = None) -> None:
        self._in = stdin if stdin is not None else sys.stdin
        self._out = stdout if stdout is not None else sys.stdout
        self._write_lock = threading.Lock()
        self._handlers: dict[str, Handler] = {}
        self._stop = threading.Event()

    def op(self, name: str) -> Callable[[Handler], Handler]:
        def deco(fn: Handler) -> Handler:
            self._handlers[name] = fn
            return fn

        return deco

    # --- наверх ---

    def _write(self, obj: dict[str, Any]) -> None:
        line = json.dumps(obj, ensure_ascii=False, separators=(",", ":"))
        with self._write_lock:
            self._out.write(line + "\n")
            self._out.flush()

    def event(
        self, ev: str, *, cell_id: str | None = None, run_id: int | None = None, **data: Any
    ) -> None:
        msg: dict[str, Any] = {"v": V, "ev": ev}
        if cell_id is not None:
            msg["cell_id"] = cell_id
        if run_id is not None:
            msg["run_id"] = run_id
        msg["data"] = data
        self._write(msg)

    def log(self, level: str, msg: str, **extra: Any) -> None:
        self.event(Ev.LOG, level=level, msg=msg, **extra)

    def reply_ok(self, req_id: Any, data: dict[str, Any] | None = None) -> None:
        self._write({"v": V, "id": req_id, "ev": Ev.OK, "data": data or {}})

    def reply_error(self, req_id: Any, code: str, msg: str, **extra: Any) -> None:
        out: dict[str, Any] = {"v": V, "ev": Ev.ERROR, "data": {"code": code, "msg": msg, **extra}}
        if req_id is not None:
            out["id"] = req_id
        self._write(out)

    # --- вниз ---

    def handle_line(self, line: str) -> None:
        line = line.strip()
        if not line:
            return
        try:
            req = json.loads(line)
        except ValueError as e:
            self.reply_error(None, ErrCode.BAD_JSON, str(e))
            return
        if not isinstance(req, dict):
            self.reply_error(None, ErrCode.BAD_REQUEST, "ожидался JSON-объект")
            return

        req_id = req.get("id")
        if req.get("v") != V:
            self.reply_error(
                req_id,
                ErrCode.PROTOCOL_VERSION,
                f"версия протокола {req.get('v')!r}, поддерживается {V}",
                expected=V,
            )
            return

        handler = self._handlers.get(req.get("op"))
        if handler is None:
            self.reply_error(req_id, ErrCode.UNKNOWN_OP, f"неизвестный op {req.get('op')!r}")
            return

        args = req.get("args") or {}
        if not isinstance(args, dict):
            self.reply_error(req_id, ErrCode.BAD_ARGS, "args должен быть объектом")
            return

        try:
            data = handler(args)
        except RpcError as e:
            self.reply_error(req_id, e.code, e.msg, **e.extra)
        except Exception as e:  # сайдкар не падает из-за одного плохого запроса
            self.reply_error(req_id, ErrCode.INTERNAL, f"{type(e).__name__}: {e}")
        else:
            self.reply_ok(req_id, data)

    def serve(self) -> None:
        for line in self._in:
            if self._stop.is_set():
                break
            self.handle_line(line)

    def stop(self) -> None:
        self._stop.set()
