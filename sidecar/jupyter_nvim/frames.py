"""Датафрейм из ядра на диск и постраничное чтение. ARCHITECTURE.md §7.

Ключевой факт конструкции: **сайдкар никогда не видит сам polars-фрейм**. Из ядра приходят только
mime-бандлы, то есть готовый текст и HTML. Поэтому фрейм сериализует само ядро — на каждый `execute`
уезжает `user_expressions` с вызовом вспомогательной функции, которую мы внедрили при старте.
Ответ приходит в `execute_reply`, а `text/plain` там — repr питоновского значения, не JSON.

Что именно сериализовать, решает Lua: она разбирает магию `%%sql` и знает имя переменной. Дефолт — `_`,
последнее выражение ячейки.
"""

from __future__ import annotations

import ast
from pathlib import Path
from typing import Any

HELPER = "__jupyter_nvim_dump"

HELPER_SOURCE = f'''
def {HELPER}(obj, path):
    try:
        import polars as pl
    except ImportError:
        return None
    if isinstance(obj, pl.LazyFrame):
        obj = obj.collect()
    if not isinstance(obj, pl.DataFrame):
        return None
    obj.write_parquet(path)
    return {{"rows": obj.height, "cols": obj.width,
             "schema": [[c, str(t)] for c, t in obj.schema.items()]}}
'''


def dump_call(expr: str, path: str | Path) -> str:
    return f"{HELPER}({expr}, {str(path)!r})"


def parse_dump(entry: dict[str, Any] | None) -> dict[str, Any] | None:
    """Разобрать один элемент `user_expressions` из `execute_reply`.

    Возвращает None во всех «нормальных» случаях: результат не датафрейм, polars нет, выражение
    не вычислилось. Ошибкой это не является — большинство ячеек таблицу не возвращает.
    """
    if not entry or entry.get("status") != "ok":
        return None
    raw = ((entry.get("data") or {}).get("text/plain") or "").strip()
    if not raw or raw == "None":
        return None
    try:
        value = ast.literal_eval(raw)
    except (ValueError, SyntaxError):
        return None
    if not isinstance(value, dict) or "rows" not in value:
        return None
    return {
        "rows": value.get("rows"),
        "cols": value.get("cols"),
        "schema": [list(pair) for pair in value.get("schema") or []],
    }


def _cell(value: Any) -> str:
    return "" if value is None else str(value)


def page(
    path: str | Path,
    offset: int = 0,
    limit: int = 100,
    cols: list[str] | None = None,
) -> dict[str, Any]:
    """Страница parquet-а без чтения файла целиком: `scan_parquet().slice()`.

    Значения отдаются строками — выравнивание колонок делает Lua, она знает ширину окна (§3).
    """
    import polars as pl

    lazy = pl.scan_parquet(path)
    names = lazy.collect_schema().names()
    if cols:
        wanted = set(cols)
        names = [name for name in names if name in wanted]

    total = int(lazy.select(pl.len()).collect().item())
    offset = max(0, min(int(offset), total))
    limit = max(0, int(limit))
    frame = lazy.select(names).slice(offset, limit).collect()
    rows = [[_cell(v) for v in row] for row in frame.iter_rows()]

    return {
        "header": names,
        "rows": rows,
        "total_rows": total,
        "offset": offset,
        "truncated": offset + len(rows) < total,
    }
