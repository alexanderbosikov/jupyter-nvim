"""Нормализация потока вывода: `\\r`, `\\b`, ANSI. ARCHITECTURE.md §6.3.

Делается здесь, а не в UI: наверх уходят готовые операции над строками, drawer их просто применяет.
Прогресс-бар и tqdm перерисовывают одну строку, а не сыплют сотнями новых.
"""

from __future__ import annotations

import re
from dataclasses import dataclass, field
from typing import Literal

ANSI = re.compile(r"\x1b\[[0-9;?]*[ -/]*[@-~]|\x1b[@-Z\\-_]")

OpKind = Literal["append", "replace_last"]


def strip_ansi(text: str) -> str:
    """v1 цвета не поддерживает: escape-последовательности снимаются до разбора."""
    return ANSI.sub("", text)


@dataclass
class LineOp:
    op: OpKind
    text: str

    def as_dict(self) -> dict[str, str]:
        return {"op": self.op, "text": self.text}


@dataclass
class StreamBuffer:
    """Мини-эмулятор строки терминала для одного потока одной ячейки.

    Курсор двигается только внутри последней строки: `\\n` уходит вперёд безвозвратно, `\\r` возвращает
    в начало строки, `\\b` — на символ назад. Назад по строкам (ANSI cursor-up) не поддерживается.
    """

    keep_ansi: bool = False
    lines: list[str] = field(default_factory=lambda: [""])
    col: int = 0
    _sent: int = 0
    _sent_text: str | None = None

    def feed(self, text: str) -> list[LineOp]:
        if not self.keep_ansi:
            text = strip_ansi(text)
        for ch in text:
            self._put(ch)
        return self._flush()

    def _put(self, ch: str) -> None:
        if ch == "\n":
            self.lines.append("")
            self.col = 0
        elif ch == "\r":
            self.col = 0
        elif ch == "\b":
            self.col = max(0, self.col - 1)
        else:
            line = self.lines[-1]
            if self.col < len(line):
                self.lines[-1] = line[: self.col] + ch + line[self.col + 1 :]
            else:
                self.lines[-1] = line.ljust(self.col) + ch
            self.col += 1

    def _flush(self) -> list[LineOp]:
        # последняя строка пустая = курсор на свежей строке, показывать нечего
        n = len(self.lines)
        if self.lines[-1] == "":
            n -= 1

        ops: list[LineOp] = []
        if 0 < self._sent <= n and self.lines[self._sent - 1] != self._sent_text:
            ops.append(LineOp("replace_last", self.lines[self._sent - 1]))
        ops.extend(LineOp("append", line) for line in self.lines[self._sent : n])

        if n:
            self._sent = n
            self._sent_text = self.lines[n - 1]
        return ops

    def text(self) -> str:
        return "\n".join(self.lines)
