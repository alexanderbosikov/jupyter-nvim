"""`jupyter out <file> <cell-id>` — прочитать вывод ячейки без nvim и без сайдкара.

Имя бинарника `jupyter-out` — `jupyter_core` подхватывает его как подкоманду родного CLI.
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

from .outdir import DEFAULT_DIR, OutDir


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(prog="jupyter out", description=__doc__)
    ap.add_argument("notebook", type=Path)
    ap.add_argument("cell_id")
    ap.add_argument("--run", type=int, help="номер прогона; по умолчанию последний")
    ap.add_argument("--dir", default=DEFAULT_DIR, help=f"каталог выводов (дефолт {DEFAULT_DIR})")
    ap.add_argument("--json", action="store_true", help="выдать запись индекса, а не содержимое")
    ap.add_argument("--path", action="store_true", help="выдать только путь к файлу вывода")
    args = ap.parse_args(argv)

    out = OutDir(args.notebook, args.dir)
    rec = out.last(args.cell_id, args.run)
    if rec is None:
        print(f"вывода нет: {args.cell_id} в {out.base}", file=sys.stderr)
        return 1

    if args.json:
        print(json.dumps(rec, ensure_ascii=False))
        return 0

    path = out.resolve(rec)
    if args.path:
        print(path if path else "", end="\n" if path else "")
        return 0 if path else 1

    if path is None:
        print(rec.get("text", ""), end="")
    elif path.suffix == ".txt":
        sys.stdout.write(path.read_text(encoding="utf-8"))
    else:
        print(path)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
