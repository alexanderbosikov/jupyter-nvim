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


# Управляющие символы в значении: строка таблицы обязана остаться одной строкой.
# Перевод строки внутри значения разложил бы её по строкам буфера — колонки разъехались
# бы, а нумерация строк начала врать. Показываем их видимо, как это делает repr.
_ESCAPES = {ord("\n"): "\\n", ord("\r"): "\\r", ord("\t"): "\\t"}
_ESCAPES.update({code: f"\\x{code:02x}" for code in range(32) if code not in _ESCAPES})
_ESCAPES[0x7F] = "\\x7f"


def _cell(value: Any) -> str:
    """Пустая строка и NULL — разные вещи, и выглядеть должны по-разному.

    Совпадаем с тем, как рисует сам polars: пустая строка пустая, NULL — слово `null`.
    Неоднозначность со строкой "null" при этом та же, что в polars и в Lab.
    """
    return "null" if value is None else str(value).translate(_ESCAPES)


class UnknownColumn(ValueError):
    pass


def page(
    path: str | Path,
    offset: int = 0,
    limit: int = 100,
    cols: list[str] | None = None,
    order_by: list[dict[str, Any]] | None = None,
) -> dict[str, Any]:
    """Страница parquet-а без чтения файла целиком: `scan_parquet().slice()`.

    Значения отдаются строками — выравнивание колонок делает Lua, она знает ширину окна (§3).

    `order_by` — список `{column, desc}` в порядке важности: первый элемент главный ключ,
    остальные разрешают равенство. Сортировка идёт до нарезки страницы, поэтому листание
    остаётся согласованным: страница 2 продолжает страницу 1, а не сортирует её отдельно.
    """
    import polars as pl

    lazy = pl.scan_parquet(path)
    names = lazy.collect_schema().names()
    if cols:
        wanted = set(cols)
        names = [name for name in names if name in wanted]

    if order_by:
        keys = [str(item["column"]) for item in order_by]
        unknown = [key for key in keys if key not in lazy.collect_schema().names()]
        if unknown:
            raise UnknownColumn("нет таких колонок: " + ", ".join(unknown))
        lazy = lazy.sort(
            by=keys,
            descending=[bool(item.get("desc")) for item in order_by],
            nulls_last=True,
        )

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
        "order_by": order_by or [],
    }
