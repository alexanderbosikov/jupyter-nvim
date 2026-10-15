"""`jn-nvim [<ноутбук>]` — сокет nvim человека, в котором агенту работать с этим ноутбуком.

Агент, создав ноутбук, открывает его сам (`agent_open`), но открыть надо в nvim человека,
а не в своём: буферы у каждого процесса свои. Живых nvim обычно несколько, и у двух бывает
один cwd — например главный nvim задачи и второй, открытый на минуту под заметку. Поэтому
не по одному признаку, а по очкам, от сильного к слабому:

    ноутбук уже открыт в этом nvim (а на экране — ещё сильнее)
    та же вкладка herdr / то же окно tmux, что и у панели агента
    тот же workspace herdr / та же сессия tmux
    cwd nvim — каталог агента; ноутбук лежит внутри cwd nvim

Печатает сокет победителя. Код возврата 1 — подходящего нет или двое равны: тогда на
stderr кандидаты, и агент спрашивает человека, а не выбирает наугад.
"""

from __future__ import annotations

import argparse
import glob
import json
import os
import subprocess
import sys
import tempfile
from pathlib import Path
from typing import Any, Callable

# одна строка vimscript на nvim: всё, что нужно для очков, за один вызов
EXPR = (
    'json_encode({"pid": getpid(), "cwd": getcwd(), "htab": $HERDR_TAB_ID, "hws": $HERDR_WORKSPACE_ID,'
    ' "tmux_pane": $TMUX_PANE, "nb": luaeval(\'(function(p) if p == "" then return 0 end'
    " local want = vim.fn.resolve(vim.fn.fnamemodify(p, \":p\"))"
    " for _, b in ipairs(vim.api.nvim_list_bufs()) do"
    " if vim.api.nvim_buf_is_loaded(b) and vim.fn.resolve(vim.api.nvim_buf_get_name(b)) == want then"
    " return vim.fn.bufwinid(b) ~= -1 and 2 or 1 end end return 0 end)(_A)', {path})})"
)


def sockets() -> list[str]:
    tmp = os.environ.get("TMPDIR") or tempfile.gettempdir()
    return sorted(glob.glob(os.path.join(tmp, f"nvim.{os.environ.get('USER', '')}", "*", "nvim.*.0")))


def query(sock: str, notebook: str) -> dict[str, Any] | None:
    expr = EXPR.replace("{path}", json.dumps(notebook))
    try:
        out = subprocess.run(["nvim", "--server", sock, "--remote-expr", expr],
                             capture_output=True, text=True, timeout=3).stdout
    except (OSError, subprocess.TimeoutExpired):
        return None
    for line in reversed(out.splitlines()):
        if line.startswith("{"):
            try:
                return json.loads(line)
            except ValueError:
                return None
    return None


def tmux_where(pane: str | None) -> tuple[str, str] | None:
    """(сессия, окно) панели tmux."""
    if not pane:
        return None
    try:
        out = subprocess.run(["tmux", "display", "-p", "-t", pane, "#{session_id} #{window_id}"],
                             capture_output=True, text=True, timeout=2).stdout.split()
    except (OSError, subprocess.TimeoutExpired):
        return None
    return (out[0], out[1]) if len(out) == 2 else None


def _inside(path: str, root: str) -> bool:
    try:
        Path(path).resolve().relative_to(Path(root).resolve())
        return True
    except ValueError:
        return False


def score(nv: dict[str, Any], me: dict[str, Any], notebook: str) -> tuple[int, list[str]]:
    pts, why = 0, []
    if nv.get("nb"):
        pts += 100 + (10 if nv["nb"] == 2 else 0)
        why.append("ноутбук открыт" + (" и на экране" if nv["nb"] == 2 else ""))
    if me.get("htab") and nv.get("htab") == me["htab"]:
        pts += 20
        why.append("та же вкладка herdr")
    elif me.get("hws") and nv.get("hws") == me["hws"]:
        pts += 5
        why.append("тот же workspace herdr")
    tm, mine = nv.get("tmux"), me.get("tmux")
    if tm and mine:
        if tm == mine:
            pts += 20
            why.append("то же окно tmux")
        elif tm[0] == mine[0]:
            pts += 5
            why.append("та же сессия tmux")
    if nv.get("cwd") and me.get("cwd") and Path(nv["cwd"]).resolve() == Path(me["cwd"]).resolve():
        pts += 3
        why.append("тот же cwd")
    if notebook and nv.get("cwd") and _inside(notebook, nv["cwd"]):
        pts += 2
        why.append("ноутбук внутри cwd")
    return pts, why


def pick(found: dict[str, dict[str, Any]], me: dict[str, Any], notebook: str) -> tuple[str | None, list]:
    ranked = sorted(((*score(nv, me, notebook), sock, nv) for sock, nv in found.items()),
                    key=lambda r: r[0], reverse=True)
    ranked = [r for r in ranked if r[0] > 0]
    if not ranked or (len(ranked) > 1 and ranked[0][0] == ranked[1][0]):
        return None, ranked
    return ranked[0][2], ranked


def main(argv: list[str] | None = None, ask: Callable[[str, str], dict | None] = query) -> int:
    ap = argparse.ArgumentParser(prog="jn-nvim", description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("notebook", nargs="?", default="")
    ap.add_argument("--sockets", nargs="*", help=argparse.SUPPRESS)
    args = ap.parse_args(argv)

    notebook = str(Path(args.notebook).expanduser().resolve()) if args.notebook else ""
    me = {
        "cwd": os.getcwd(),
        "htab": os.environ.get("HERDR_TAB_ID"),
        "hws": os.environ.get("HERDR_WORKSPACE_ID"),
        "tmux": tmux_where(os.environ.get("TMUX_PANE")),
    }
    found = {}
    for sock in args.sockets if args.sockets is not None else sockets():
        nv = ask(sock, notebook)
        if nv:
            nv["tmux"] = tmux_where(nv.get("tmux_pane")) if me["tmux"] else None
            found[sock] = nv
    best, ranked = pick(found, me, notebook)
    if best:
        print(best)
        return 0
    if not ranked:
        print("нет nvim ни в этой вкладке, ни с этим cwd — спроси у человека (:echo v:servername)", file=sys.stderr)
    else:
        print("несколько nvim подходят одинаково — спроси у человека (:echo v:servername):", file=sys.stderr)
        for pts, why, sock, nv in ranked:
            print(f"  {sock}  pid {nv.get('pid')}  cwd {nv.get('cwd')}  [{pts}: {', '.join(why)}]", file=sys.stderr)
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
