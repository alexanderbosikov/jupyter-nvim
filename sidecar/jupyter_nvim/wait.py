"""`jn-wait <ноутбук> <ячейка>[:<прогон>] ...` — дождаться конца прогонов и напечатать итог.

Для агента: после `agent_run` он запускает это в фоне и узнаёт о конце по завершению
процесса, а не опросом снимка в своём контексте. Читает только `.jupyter-out/` — nvim и
сайдкар не нужны.

На каждую ячейку одна строка, по мере того как они заканчиваются:

    af4b #3 ok · text · 1.2s · af4b/3.txt
    13ca #4 ok · table 1204×8 · 12.3s · 13ca/4.parquet · print: 13ca/4.out.txt
    5e1d #5 error ProgrammingError · 0.4s · 5e1d/5.txt

Код возврата: 0 — все ok; 1 — хоть одна error/aborted; 2 — истёк таймаут; 3 — ядро
умерло (или так и не поднялось за `--start-grace`), а прогона на диске так и нет.

Номер прогона считается в nvim заново после каждого его перезапуска, поэтому `af4b:1`
сегодня и `af4b:1` позавчера — разные прогоны. Засчитываются только записи, начатые не
раньше, чем поднято текущее ядро (`started_at` в `runtime.json`). Без номера — ждём
первый прогон ячейки, которого не было на диске в момент вызова.
"""

from __future__ import annotations

import argparse
import json
import os
import sys
import time
from datetime import datetime
from pathlib import Path
from typing import Any

from .outdir import DEFAULT_DIR, RUNTIME_FILE, OutDir

OK, FAILED, TIMEOUT, GONE = 0, 1, 2, 3


def _time(value: str | None) -> datetime | None:
    if not value:
        return None
    try:
        t = datetime.fromisoformat(value)
    except ValueError:
        return None
    # runtime.json пишет местное время без пояса, индекс — UTC с поясом
    return t.astimezone() if t.tzinfo is None else t


def _runtime(out: OutDir) -> dict[str, Any] | None:
    try:
        return json.loads((out.base / RUNTIME_FILE).read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return None


def _alive(pid: Any) -> bool:
    try:
        os.kill(int(pid), 0)
    except (TypeError, ValueError, ProcessLookupError):
        return False
    except PermissionError:
        return True
    return True


def _key(rec: dict[str, Any]) -> tuple:
    return rec.get("cell_id"), rec.get("run_id"), rec.get("started_at")


def summary(rec: dict[str, Any]) -> str:
    head = f"{rec.get('cell_id')} #{rec.get('run_id')} {rec.get('status')}"
    if rec.get("ename"):
        head += f" {rec['ename']}"
    parts = [head]
    kind = rec.get("kind")
    if kind == "table":
        parts.append(f"table {rec.get('rows')}×{rec.get('cols')}")
    elif kind and kind != "none" and not rec.get("ename"):
        parts.append(kind)
    if rec.get("duration_ms") is not None:
        parts.append(f"{rec['duration_ms'] / 1000:.1f}s")
    if rec.get("path"):
        parts.append(str(rec["path"]))
    if rec.get("text"):
        parts.append(f"print: {rec['text']}")
    return " · ".join(parts)


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(prog="jn-wait", description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("notebook", type=Path)
    ap.add_argument("cells", nargs="+", metavar="ячейка[:прогон]")
    ap.add_argument("--timeout", type=float, default=3600, help="секунд, дефолт 3600")
    ap.add_argument("--dir", default=DEFAULT_DIR, help=f"каталог выводов (дефолт {DEFAULT_DIR})")
    ap.add_argument("--start-grace", type=float, default=120, help="секунд ждать, пока ядро поднимется; дефолт 120")
    ap.add_argument("--poll", type=float, default=1.0, help=argparse.SUPPRESS)
    args = ap.parse_args(argv)

    out = OutDir(args.notebook, args.dir)
    want: dict[str, int | None] = {}
    for spec in args.cells:
        cell, _, run = spec.partition(":")
        want[cell] = int(run) if run else None

    seen = {_key(r) for r in out.records()}
    deadline = time.monotonic() + args.timeout
    code = OK
    gone = False
    ever_up = False
    start_deadline = time.monotonic() + args.start_grace
    while True:
        runtime = _runtime(out)
        since = _time(runtime.get("started_at")) if runtime else None
        for rec in out.records():
            cell = rec.get("cell_id")
            if cell not in want:
                continue
            run = want[cell]
            if run is None:
                if _key(rec) in seen:
                    continue
            else:
                if rec.get("run_id") != run:
                    continue
                started = _time(rec.get("started_at"))
                if since and started and started < since:
                    continue  # тот же номер из прошлой жизни nvim
            print(summary(rec), flush=True)
            if rec.get("status") != "ok":
                code = FAILED
            del want[cell]
        if not want:
            return code
        if runtime is not None:
            ever_up = True
        # Ядра ещё не было — оно, скорее всего, поднимается: первый `agent_run` стартует
        # его сам, и runtime.json появляется через секунды. Умершим считаем ядро, которое
        # было и пропало, или которого так и не дождались за `--start-grace`.
        starting = not ever_up and time.monotonic() < start_deadline
        if not starting and (runtime is None or not _alive(runtime.get("kernel_pid"))):
            # ещё один круг: запись могла лечь между чтением индекса и проверкой ядра
            if gone:
                print(f"ядра нет, прогона не дождаться: {', '.join(want)}", file=sys.stderr)
                return GONE
            gone = True
            continue
        if time.monotonic() >= deadline:
            print(f"таймаут {args.timeout:.0f}s, не закончились: {', '.join(want)}", file=sys.stderr)
            return TIMEOUT
        time.sleep(args.poll)


if __name__ == "__main__":
    raise SystemExit(main())
