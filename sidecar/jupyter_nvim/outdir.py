"""Выводы на диске: layout `.jupyter-out/` и `index.jsonl`. ARCHITECTURE.md §7.

Тяжёлые данные не идут через пайп — сайдкар пишет файл, наверх уходит путь. Тот же файл читает
CLI `jupyter out`, поэтому формат — часть контракта, а не деталь реализации.
"""

from __future__ import annotations

import json
import os
import re
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Iterator

CELL_ID = re.compile(r"^[0-9a-f]{4,8}$")
DEFAULT_DIR = ".jupyter-out"
INDEX = "index.jsonl"


class BadCellId(ValueError):
    pass


def check_cell_id(cell_id: str) -> str:
    """cell_id приходит из текста ноутбука, то есть извне: в путь он попадает только проверенным."""
    if not isinstance(cell_id, str) or not CELL_ID.match(cell_id):
        raise BadCellId(f"недопустимый cell_id: {cell_id!r}")
    return cell_id


@dataclass
class OutDir:
    notebook: Path
    dir_name: str = DEFAULT_DIR

    @property
    def base(self) -> Path:
        return self.notebook.parent / self.dir_name / self.notebook.stem

    @property
    def index_path(self) -> Path:
        return self.base / INDEX

    def path_for(self, cell_id: str, run_id: int, ext: str) -> Path:
        p = self.base / check_cell_id(cell_id) / f"{int(run_id)}.{ext.lstrip('.')}"
        p.parent.mkdir(parents=True, exist_ok=True)
        return p

    def append(self, record: dict[str, Any]) -> dict[str, Any]:
        check_cell_id(record["cell_id"])
        self.base.mkdir(parents=True, exist_ok=True)
        with self.index_path.open("a", encoding="utf-8") as f:
            f.write(json.dumps(record, ensure_ascii=False) + "\n")
        return record

    def records(self, cell_id: str | None = None) -> Iterator[dict[str, Any]]:
        if not self.index_path.exists():
            return
        with self.index_path.open(encoding="utf-8") as f:
            for line in f:
                line = line.strip()
                if not line:
                    continue
                try:
                    rec = json.loads(line)
                except ValueError:
                    continue  # обрезанная строка после падения — не повод терять остальные
                if cell_id is None or rec.get("cell_id") == cell_id:
                    yield rec

    def last(self, cell_id: str, run_id: int | None = None) -> dict[str, Any] | None:
        found = None
        for rec in self.records(cell_id):
            if run_id is None or rec.get("run_id") == run_id:
                found = rec
        return found

    def resolve(self, record: dict[str, Any]) -> Path | None:
        rel = record.get("path")
        return self.base / rel if rel else None

    def prune(self, cell_id: str, keep: int) -> list[int]:
        """Оставить последние `keep` прогонов ячейки, остальные удалить вместе с файлами."""
        check_cell_id(cell_id)
        runs = [r.get("run_id") for r in self.records(cell_id)]
        drop = set(runs[:-keep] if keep > 0 else runs)
        if not drop:
            return []

        kept: list[dict[str, Any]] = []
        for rec in self.records():
            if rec.get("cell_id") == cell_id and rec.get("run_id") in drop:
                path = self.resolve(rec)
                if path is not None and path.exists():
                    os.unlink(path)
                continue
            kept.append(rec)

        tmp = self.index_path.with_suffix(".jsonl.tmp")
        with tmp.open("w", encoding="utf-8") as f:
            for rec in kept:
                f.write(json.dumps(rec, ensure_ascii=False) + "\n")
        tmp.replace(self.index_path)
        return sorted(d for d in drop if d is not None)
