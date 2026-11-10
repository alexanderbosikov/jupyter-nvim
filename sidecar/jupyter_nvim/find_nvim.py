"""`jn-nvim [<ноутбук>]` — сокет nvim человека, в котором агенту работать с этим ноутбуком.

Агент, создав ноутбук, открывает его сам (`agent_open`), но открыть надо в nvim человека,
а не в своём: буферы у каждого процесса свои. Живых nvim обычно несколько, и у двух бывает
один cwd — например главный nvim задачи и второй, открытый на минуту под заметку. Поэтому
не по одному признаку, а по очкам, от сильного к слабому:

    ноутбук уже открыт в этом nvim (а на экране — ещё сильнее)
    та же вкладка herdr / то же окно tmux, что и у панели агента
    тот же workspace herdr / та же сессия tmux
    cwd nvim — каталог агента; ноутбук лежит внутри cwd nvim

Просмотрщик не кандидат вовсе, даже с открытым ноутбуком: nvim, запущенный файловым
менеджером (yazi ставит детям $YAZI_LEVEL), или помеченный `vim.g.jupyter_viewer = true`.
Он живёт в панели рядом с агентом и иначе перебивал бы рабочий nvim очками за окно tmux.

Ни у кого нет очков, а nvim всего один (не просмотрщик) — он и есть: агент в другой
вкладке и с другим cwd, а ноутбук ещё нигде не открыт — обычный случай для нового
ноутбука. Раньше это был отказ «нет nvim», хотя nvim был, и агенты обходили `jn` —
собирали `.ipynb` сами мимо буфера.

Печатает сокет победителя. Код возврата 1 — подходящего нет или двое равны: тогда на
stderr кандидаты, и агент спрашивает человека, а не выбирает наугад.
"""

from __future__ import annotations

import argparse
import glob
import json
import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path
from typing import Any, Callable

# одна строка vimscript на nvim: всё, что нужно для очков, за один вызов
EXPR = (
    'json_encode({"pid": getpid(), "cwd": getcwd(), "htab": $HERDR_TAB_ID, "hws": $HERDR_WORKSPACE_ID,'
    ' "tmux_pane": $TMUX_PANE, "viewer": $YAZI_LEVEL != "" || get(g:, "jupyter_viewer", v:false) is v:true,'
    ' "nb": luaeval(\'(function(p) if p == "" then return 0 end'
    " local want = vim.fn.resolve(vim.fn.fnamemodify(p, \":p\"))"
    " for _, b in ipairs(vim.api.nvim_list_bufs()) do"
    " if vim.api.nvim_buf_is_loaded(b) and vim.fn.resolve(vim.api.nvim_buf_get_name(b)) == want then"
    " return vim.fn.bufwinid(b) ~= -1 and 2 or 1 end end return 0 end)(_A)', {path})})"
)


def _temp_dirs() -> list[str]:
    """Где nvim мог положить сокет: его `$TMPDIR`, а он не обязательно равен нашему.

    Шелл без `TMPDIR` (а на маке nvim кладёт сокет в `/var/folders/…/T/`) искал в `/tmp` и
    не видел ни одного nvim. Каталог пользователя на маке знает `getconf`.
    """
    dirs = [os.environ.get("TMPDIR")]
    if sys.platform == "darwin":
        try:
            dirs.append(subprocess.run(["getconf", "DARWIN_USER_TEMP_DIR"], capture_output=True, text=True,
                                       timeout=3).stdout.strip())
        except (OSError, subprocess.TimeoutExpired):
            pass
    dirs += [tempfile.gettempdir(), "/tmp"]
    seen, res = set(), []
    for d in dirs:
        if d and os.path.isdir(d):
            real = os.path.realpath(d)
            if real not in seen:
                seen.add(real)
                res.append(d)
    return res


def _user() -> str:
    """Имя для `nvim.<user>`: по uid, а не из `$USER` — в шелле его может не быть.

    Без `$USER` шаблон превращался в `nvim.` и не находил ни одного сокета.
    """
    try:
        import pwd

        return pwd.getpwuid(os.getuid()).pw_name
    except (ImportError, KeyError):
        return os.environ.get("USER", "")


def sockets() -> list[str]:
    user = _user()
    found: dict[str, str] = {}
    for tmp in _temp_dirs():
        for sock in glob.glob(os.path.join(tmp, f"nvim.{user}", "*", "nvim.*.0")):
            found.setdefault(os.path.realpath(sock), sock)
    return sorted(found.values())


# последний поиск: сколько сокетов нашлось и почему nvim за ними не ответили — для explain.
# Без этого «сокеты есть, но никто не ответил» печаталось как «nvim не запущен»
LAST: dict[str, Any] = {"sockets": 0, "failures": []}


def query(sock: str, notebook: str) -> dict[str, Any] | None:
    expr = EXPR.replace("{path}", json.dumps(notebook))
    nvim = shutil.which("nvim") or "nvim"
    try:
        # stdin не терминал: из интерактивного шелла nvim иначе пишет перед ответом
        # управляющие последовательности, и строка ответа не начинается с `{`
        proc = subprocess.run([nvim, "--server", sock, "--remote-expr", expr],
                              stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=3)
    except (OSError, subprocess.TimeoutExpired) as e:
        LAST["failures"].append((sock, f"{type(e).__name__}: {e}"))
        return None
    for line in reversed(proc.stdout.splitlines()):
        if "{" in line:
            try:
                return json.loads(line[line.index("{"):line.rindex("}") + 1])
            except ValueError:
                break
    err = repr((proc.stderr or proc.stdout).strip())[:200]
    LAST["failures"].append((sock, f"{nvim}: код {proc.returncode}: {err or 'пустой ответ'}"))
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
    if nv.get("viewer"):
        return 0, ["просмотрщик (yazi / g:jupyter_viewer)"]
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
    scored = sorted(((*score(nv, me, notebook), sock, nv) for sock, nv in found.items()),
                    key=lambda r: r[0], reverse=True)
    others = [r for r in scored if not r[3].get("viewer")]
    ranked = [r for r in others if r[0] > 0]
    if not ranked:
        if len(others) == 1:
            pts, why, sock, nv = others[0]
            return sock, [(pts, [*why, "единственный nvim"], sock, nv)]
        # без очков, но есть: их и показать человеку
        return None, others
    if len(ranked) > 1 and ranked[0][0] == ranked[1][0]:
        return None, ranked
    return ranked[0][2], ranked


def locate(notebook: str, socks: list[str] | None = None,
           ask: Callable[[str, str], dict | None] = query) -> tuple[str | None, list]:
    """Сокет nvim для ноутбука и кандидаты по очкам — то, что печатает `main`."""
    notebook = str(Path(notebook).expanduser().resolve()) if notebook else ""
    me = {
        "cwd": os.getcwd(),
        "htab": os.environ.get("HERDR_TAB_ID"),
        "hws": os.environ.get("HERDR_WORKSPACE_ID"),
        "tmux": tmux_where(os.environ.get("TMUX_PANE")),
    }
    found = {}
    socks = socks if socks is not None else sockets()
    LAST.update(sockets=len(socks), failures=[])
    for sock in socks:
        nv = ask(sock, notebook)
        if nv:
            nv["tmux"] = tmux_where(nv.get("tmux_pane")) if me["tmux"] else None
            found[sock] = nv
    return pick(found, me, notebook)


def explain(ranked: list) -> str:
    """Почему сокета нет: для stderr, агенту — спросить человека."""
    if not ranked and LAST["sockets"]:
        lines = [f"сокетов nvim: {LAST['sockets']}, но ни один nvim не ответил — спроси у человека "
                 f"(:echo v:servername, затем jn --sock …):"]
        lines += [f"  {sock}: {why}" for sock, why in LAST["failures"][:3]]
        if len(LAST["failures"]) > 3:
            lines.append(f"  … ещё {len(LAST['failures']) - 3}")
        return "\n".join(lines)
    if not ranked:
        return ("nvim не запущен: сокетов нет в " + ", ".join(_temp_dirs())
                + " — спроси у человека: открыть nvim или дать сокет (:echo v:servername)")
    if all(r[0] == 0 for r in ranked):
        head = "несколько nvim, и ни один не связан с ноутбуком или этой вкладкой — спроси у человека, в каком работать (:echo v:servername):"
    else:
        head = "несколько nvim подходят одинаково — спроси у человека (:echo v:servername):"
    lines = [head]
    for pts, why, sock, nv in ranked:
        lines.append(f"  {sock}  pid {nv.get('pid')}  cwd {nv.get('cwd')}  [{pts}: {', '.join(why) or 'ничего общего'}]")
    return "\n".join(lines)


def main(argv: list[str] | None = None, ask: Callable[[str, str], dict | None] = query) -> int:
    ap = argparse.ArgumentParser(prog="jn-nvim", description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("notebook", nargs="?", default="")
    ap.add_argument("--sockets", nargs="*", help=argparse.SUPPRESS)
    args = ap.parse_args(argv)

    best, ranked = locate(args.notebook, args.sockets, ask)
    if best:
        print(best)
        return 0
    print(explain(ranked), file=sys.stderr)
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
