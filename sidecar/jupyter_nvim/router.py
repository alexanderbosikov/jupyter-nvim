"""Привязка сообщений ядра к ячейкам: msg_id → (cell_id, run_id). ARCHITECTURE.md §4.5.

Единственный источник привязки. FIFO выводов нет нигде — ни здесь, ни в Lua: именно это делает
невозможным баг molten, где `status: idle` от чужого родителя закрывал текущую ячейку.
"""

from __future__ import annotations

import time
from collections import OrderedDict
from dataclasses import dataclass, field
from datetime import datetime, timezone
from typing import Literal

from .protocol import ExecStatus

Origin = Literal["active", "finished", "unknown"]


@dataclass
class Exec:
    msg_id: str
    cell_id: str
    run_id: int
    started_at: str = field(default_factory=lambda: datetime.now(timezone.utc).isoformat())
    _t0: float = field(default_factory=time.monotonic)
    status: str | None = None
    duration_ms: int | None = None
    reply_status: str | None = None
    execution_count: int | None = None
    user_expressions: dict = field(default_factory=dict)
    saw_idle: bool = False
    saw_reply: bool = False
    code_sha: str | None = None

    def close(self, status: str) -> None:
        self.status = status
        self.duration_ms = int((time.monotonic() - self._t0) * 1000)


@dataclass
class Resolution:
    """Куда относится пришедшее сообщение.

    `active` — прогон идёт, событие применяем. `finished` — прогон уже закрыт: это поздний вывод
    (фоновый поток после `idle`), наверх уходит как `late`. `unknown` — родитель неизвестен: `orphan`.
    """

    origin: Origin
    exec: Exec | None = None


class Router:
    def __init__(self, finished_cap: int = 64) -> None:
        self._active: dict[str, Exec] = {}
        self._finished: OrderedDict[str, Exec] = OrderedDict()
        self._finished_cap = finished_cap

    def start(self, msg_id: str, cell_id: str, run_id: int) -> Exec:
        ex = Exec(msg_id=msg_id, cell_id=cell_id, run_id=run_id)
        self._active[msg_id] = ex
        return ex

    def resolve(self, parent_msg_id: str | None) -> Resolution:
        if parent_msg_id is None:
            return Resolution("unknown")
        ex = self._active.get(parent_msg_id)
        if ex is not None:
            return Resolution("active", ex)
        ex = self._finished.get(parent_msg_id)
        if ex is not None:
            return Resolution("finished", ex)
        return Resolution("unknown")

    def finish(self, msg_id: str, status: str = ExecStatus.OK) -> Exec | None:
        ex = self._active.pop(msg_id, None)
        if ex is None:
            return None
        ex.close(status)
        self._finished[msg_id] = ex
        while len(self._finished) > self._finished_cap:
            self._finished.popitem(last=False)
        return ex

    def abort_all(self, status: str = ExecStatus.ABORTED) -> list[Exec]:
        """Рестарт или смерть ядра: ни один активный прогон не получит своего `idle`."""
        return [ex for msg_id in list(self._active) if (ex := self.finish(msg_id, status))]

    def active(self) -> list[Exec]:
        return list(self._active.values())

    def active_for_cell(self, cell_id: str) -> list[Exec]:
        return [ex for ex in self._active.values() if ex.cell_id == cell_id]

    def __len__(self) -> int:
        return len(self._active)
