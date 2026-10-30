"""`jn <команда> <ноутбук> …` — агентский API jupyter.nvim без `--remote-expr` руками.

    jn open     <nb>                         открыть в nvim человека и поднять ядро
    jn snapshot <nb> [--brief] [--cell ID…]  снимок: ячейки, id, прогоны
    jn text     <nb> [--cell ID]             текст ноутбука (или тело ячейки) из буфера
    jn run      <nb> <ячейка>… [--no-wait]   запустить по id (или row:N) и дождаться
    jn wait     <nb> <ячейка>[:<прогон>]…    дождаться прогонов (как jn-wait)
    jn history  <nb> <ячейка>                последние прогоны ячейки: статус, ошибка, пути
    jn replace  <nb> <old-файл> <new-файл>   заменить кусок, встречающийся ровно раз
    jn replace  <nb> --old ТЕКСТ --new ТЕКСТ  то же для коротких строк
    jn insert   <nb> <файл> (--before-heading H | --after-cell ID | --at-end)
    jn claim    <nb> <файл> [--title T]      заявка на кусок из файла
    jn done     <nb> <заявка>                снять заявку
    jn touch    <nb> <заявка>                продлить заявку
    jn pane     <имя из шапки промпта>       NB, SOCK, CLAIM для [jupyter.nvim]-промпта

Сокет nvim находится сам (jn-nvim): там, где ноутбук открыт, иначе в той же вкладке
herdr / окне tmux. `--sock` — задать явно. Аргументы уходят в nvim JSON-файлом, а не
строкой в `luaeval`: экранировать нечего. nvim зовётся бинарником, мимо функций shell.

Ответы nvim печатаются JSON-ом одной строкой. Код возврата: 0 — ok; 1 — отказ (`ok:
false`, причина в ответе); `run` и `wait` — коды jn-wait (1 error, 2 таймаут, 3 нет
ядра); 4 — nvim не найден или не ответил.
"""

from __future__ import annotations

import argparse
import json
import os
import shlex
import shutil
import subprocess
import sys
import tempfile
from hashlib import sha256
from pathlib import Path
from typing import Any, Callable

from . import find_nvim, wait
from .outdir import OutDir

NO_NVIM = 4

# выражение одно на все вызовы: путь к запросу — единственное, что в нём меняется
EXPR = "luaeval('require(\"jupyter.cli\").call(_A)', {path})"


class NvimError(Exception):
    pass


def remote(sock: str, fn: str, args: list[Any]) -> dict[str, Any]:
    """Позвать `require("jupyter")[fn](args…)` в nvim по сокету, ответ — разобранный JSON."""
    nvim = shutil.which("nvim") or "nvim"
    with tempfile.NamedTemporaryFile("w", suffix=".json", prefix="jn-", delete=False, encoding="utf-8") as f:
        # nil посреди аргументов (edit_replace(old, new, nil)) JSON-ом не передать: argc
        json.dump({"fn": fn, "args": args, "argc": len(args)}, f, ensure_ascii=False)
        req = f.name
    try:
        proc = subprocess.run([nvim, "--server", sock, "--remote-expr", EXPR.replace("{path}", json.dumps(req))],
                              capture_output=True, text=True, timeout=60)
    except (OSError, subprocess.TimeoutExpired) as e:
        raise NvimError(f"nvim не ответил: {e}") from e
    finally:
        os.unlink(req)
    out = proc.stdout.strip()
    if not out.startswith("{"):
        err = (proc.stderr or proc.stdout).strip()
        if "jupyter.cli" in err and "not found" in err:
            err = "в этом nvim старая сборка плагина (нет jupyter.cli) — попроси человека перезапустить nvim"
        raise NvimError(err or "пустой ответ nvim")
    return json.loads(out)


Call = Callable[[str, str, list[Any]], dict[str, Any]]


def _read(path: str) -> str:
    text = sys.stdin.read() if path == "-" else Path(path).expanduser().read_text(encoding="utf-8")
    # как edit_replace_files: перевод строки в конце файла — не часть текста
    return text[:-1] if text.endswith("\n") else text


def _print(res: dict[str, Any]) -> int:
    print(json.dumps(res, ensure_ascii=False))
    return 0 if res.get("ok", True) is not False else 1


def brief(snap: dict[str, Any]) -> str:
    """Снимок по строке на ячейку: глазами читается быстрее JSON."""
    k = snap.get("kernel") or {}
    lines = [f"{snap.get('notebook')} · ядро {k.get('state', '?')}"
             + ("" if snap.get("visible", True) else " · не на экране")
             + (" · изменён" if snap.get("modified") else "")]
    for c in snap.get("cells", []):
        last = c.get("last") or {}
        parts = [f"{c.get('id') or '----'} {c.get('lang', '?'):6} {c.get('start_row')}–{c.get('end_row')}"]
        if c.get("heading"):
            h = c["heading"]
            parts.append(h if len(h) <= 60 else h[:59] + "…")
        if c.get("running"):
            parts.append((c.get("live") or {}).get("status", "running"))
        elif last:
            st = f"#{last.get('run_id')} {last.get('status')}"
            if last.get("ename"):
                st += f" {last['ename']}"
            parts.append(st)
            kind = last.get("kind")
            if kind == "table":
                parts.append(f"table {last.get('rows')}×{last.get('cols')}")
            elif kind and kind != "none":
                parts.append(kind)
        if c.get("stale"):
            parts.append("устарел")
        lines.append(" · ".join(parts))
    return "\n".join(lines)


def _warned_path(notebook: str) -> Path:
    return Path(tempfile.gettempdir(), "jn-warned", sha256(notebook.encode()).hexdigest()[:16] + ".json")


def unwarned(notebook: str, kernel_key: str, missing: list[str]) -> list[str]:
    """Из невыполненных ячеек — те, о которых в этом ядре ещё не предупреждали.

    Иначе каждый `jn run` подряд повторяет один и тот же список, хотя агенту эти ячейки
    не нужны. Ядро сменилось (`kernel_key` другой) — предупреждаем заново.
    """
    path = _warned_path(notebook)
    try:
        state = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        state = {}
    shown = set(state.get("shown", [])) if state.get("kernel") == kernel_key else set()
    new = [c for c in missing if c not in shown]
    if new:
        try:
            path.parent.mkdir(exist_ok=True)
            path.write_text(json.dumps({"kernel": kernel_key, "shown": sorted(shown | set(new))}), encoding="utf-8")
        except OSError:
            pass
    return new


def cell_text(snap: dict[str, Any], text: str, cell: str) -> str | None:
    """Тело ячейки как в буфере — готовый `old` для `jn replace`."""
    for c in snap.get("cells", []):
        if c.get("id") == cell:
            return "\n".join(text.split("\n")[c["start_row"] - 1:c["end_row"]])
    return None


UNSAVED = ("буфер не сохранён: правки только в nvim, в .ipynb на диске их нет (Lab, git, "
           "передача файла их не увидят) — когда закончишь, попроси человека сохранить (:w)")


def _unsaved_path(notebook: str) -> Path:
    return Path(tempfile.gettempdir(), "jn-warned", sha256(notebook.encode()).hexdigest()[:16] + ".unsaved")


def warn_unsaved(nv: Callable[..., dict[str, Any]], notebook: str, always: bool = False) -> None:
    """Сказать агенту, что его правки ещё не на диске.

    После `done` — всегда: работа закончена, пора напомнить человеку. После правки — раз,
    пока буфер не сохранят: иначе каждый `replace` повторял бы одно и то же.
    """
    try:
        res = nv("modified", notebook)
    except NvimError:
        return
    flag = _unsaved_path(notebook)
    if not res.get("modified"):
        flag.unlink(missing_ok=True)
        return
    if always or not flag.exists():
        print(UNSAVED, file=sys.stderr)
        try:
            flag.parent.mkdir(exist_ok=True)
            flag.touch()
        except OSError:
            pass


def history(notebook: str, cell: str) -> int:
    """Прогоны ячейки с диска, старые сверху: снимок знает только последний."""
    out = OutDir(Path(notebook))
    recs = list(out.records(cell))
    if not recs:
        print(f"прогонов {cell} на диске нет ({out.base})", file=sys.stderr)
        return 1
    for rec in recs:
        started = wait._time(rec.get("started_at"))
        when = started.strftime("%d.%m %H:%M") if started else "?"
        print(f"{when} · {wait.summary(rec, out)}")
    return 0


def pane(name: str) -> tuple[str, dict[str, Any]] | None:
    """Запись панели агента про ноутбук `<каталог>/<файл>` из шапки [jupyter.nvim]-промпта."""
    pane_id = os.environ.get("TMUX_PANE") or os.environ.get("HERDR_PANE_ID")
    if not pane_id:
        return None
    state = os.environ.get("XDG_STATE_HOME") or os.path.expanduser("~/.local/state")
    try:
        entries = json.loads(Path(state, "nvim", "jupyter", "panes", f"{pane_id}.json").read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return None
    hits = [(e.get("at", 0), nb, e) for nb, e in entries.items() if nb.endswith("/" + name) or nb == name]
    if not hits:
        return None
    _, nb, e = max(hits, key=lambda h: h[0])
    return nb, e


def main(argv: list[str] | None = None, call: Call = remote,
         locate: Callable[[str], tuple[str | None, list]] = find_nvim.locate) -> int:
    ap = argparse.ArgumentParser(prog="jn", description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--sock", help="сокет nvim; без него — ищется сам")
    sub = ap.add_subparsers(dest="cmd", required=True)

    def nb_cmd(name: str) -> argparse.ArgumentParser:
        p = sub.add_parser(name)
        p.add_argument("notebook")
        return p

    nb_cmd("open").add_argument("--no-kernel", action="store_true", help="ядро не поднимать")
    p = nb_cmd("snapshot")
    p.add_argument("--brief", action="store_true", help="по строке на ячейку")
    p.add_argument("--cell", nargs="+", default=None, help="только эти ячейки")
    nb_cmd("text").add_argument("--cell", default=None, help="только тело этой ячейки")
    p = nb_cmd("run")
    p.add_argument("cells", nargs="+", metavar="ячейка", help="id или row:N")
    p.add_argument("--no-wait", action="store_true", help="только запустить: печатает пары для jn wait")
    p.add_argument("--timeout", type=float, default=3600)
    nb_cmd("history").add_argument("cell", metavar="ячейка")
    p = nb_cmd("wait")
    p.add_argument("cells", nargs="+", metavar="ячейка[:прогон]")
    p.add_argument("--timeout", type=float, default=3600)
    p = nb_cmd("replace")
    p.add_argument("old", nargs="?", help="файл с текущим текстом куска ('-' — stdin)")
    p.add_argument("new", nargs="?", help="файл с новым текстом")
    p.add_argument("--old", dest="old_text", help="текущий текст строкой, вместо файла")
    p.add_argument("--new", dest="new_text", help="новый текст строкой, вместо файла")
    p = nb_cmd("insert")
    p.add_argument("file", help="файл с вставкой ('-' — stdin)")
    where = p.add_mutually_exclusive_group(required=True)
    where.add_argument("--before-heading")
    where.add_argument("--after-cell")
    where.add_argument("--at-end", action="store_true")
    p = nb_cmd("claim")
    p.add_argument("file", help="файл с куском, встречающимся ровно раз ('-' — stdin)")
    p.add_argument("--title", default=None)
    p.add_argument("--label", default="Claude")
    for name in ("done", "touch"):
        nb_cmd(name).add_argument("token", type=int)
    sub.add_parser("pane").add_argument("name", help="ноутбук как в шапке: <каталог>/<файл>")
    args = ap.parse_args(argv)
    if args.cmd == "replace":
        files = (args.old, args.new)
        flags = (args.old_text, args.new_text)
        if not (all(f is not None for f in files) and flags == (None, None)
                or all(f is not None for f in flags) and files == (None, None)):
            ap.error("replace: два файла (old new) или --old ТЕКСТ --new ТЕКСТ")

    if args.cmd == "pane":
        hit = pane(args.name)
        if not hit:
            print(f"нет записи о {args.name} в файле панели — найди ноутбук сам (jn open)", file=sys.stderr)
            return 1
        nb, e = hit
        print(f"NB={shlex.quote(nb)}\nSOCK={shlex.quote(e.get('socket', ''))}\nCLAIM={shlex.quote(str(e.get('claim') or ''))}")
        return 0

    notebook = str(Path(args.notebook).expanduser().resolve())
    if args.cmd == "history":
        return history(notebook, args.cell)
    if args.cmd == "wait":
        return wait.main([notebook, *args.cells, "--timeout", str(args.timeout)])

    sock = args.sock
    if not sock:
        sock, ranked = locate(notebook)
        if not sock:
            print(find_nvim.explain(ranked), file=sys.stderr)
            return NO_NVIM

    def nv(fn: str, *rest: Any) -> dict[str, Any]:
        return call(sock, fn, list(rest))

    try:
        if args.cmd == "open":
            opts: dict[str, Any] = {"notebook": notebook}
            if args.no_kernel:
                opts["kernel"] = False
            return _print(nv("agent_open", opts))
        if args.cmd == "snapshot":
            snap = nv("snapshot", notebook)
            if snap.get("ok") is False:
                return _print(snap)
            if args.cell:
                snap["cells"] = [c for c in snap.get("cells", []) if c.get("id") in args.cell]
            print(brief(snap) if args.brief else json.dumps(snap, ensure_ascii=False))
            return 0
        if args.cmd == "text":
            res = nv("text", notebook)
            if res.get("ok") is False:
                return _print(res)
            if args.cell:
                body = cell_text(nv("snapshot", notebook), res["text"], args.cell)
                if body is None:
                    return _print({"ok": False, "reason": "no_cell", "msg": f"нет ячейки {args.cell}"})
                print(body)
                return 0
            print(res["text"])
            return 0
        if args.cmd == "run":
            return run(nv, notebook, args)
        if args.cmd == "replace":
            old = args.old_text if args.old_text is not None else _read(args.old)
            new = args.new_text if args.new_text is not None else _read(args.new)
            code = _print(nv("edit_replace", old, new, {"notebook": notebook}))
            if code == 0:
                warn_unsaved(nv, notebook)
            return code
        if args.cmd == "insert":
            opts = {"notebook": notebook, "text": _read(args.file)}
            if args.before_heading:
                opts["before_heading"] = args.before_heading
            elif args.after_cell:
                opts["after_cell"] = args.after_cell
            else:
                opts["at_end"] = True
            code = _print(nv("edit_insert", opts))
            if code == 0:
                warn_unsaved(nv, notebook)
            return code
        if args.cmd == "claim":
            opts = {"notebook": notebook, "text": _read(args.file), "label": args.label}
            if args.title:
                opts["title"] = args.title
            return _print(nv("edit_claim", opts))
        if args.cmd == "done":
            code = _print(nv("edit_done", args.token))
            if code == 0:
                warn_unsaved(nv, notebook, always=True)
            return code
        if args.cmd == "touch":
            return _print(nv("edit_touch", args.token))
    except NvimError as e:
        print(f"jn: {e}", file=sys.stderr)
        return NO_NVIM
    raise AssertionError(args.cmd)


def run(nv: Callable[..., dict[str, Any]], notebook: str, args: argparse.Namespace) -> int:
    pairs, asked, missing = [], set(), []
    for spec in args.cells:
        opts: dict[str, Any] = {"notebook": notebook}
        if spec.startswith("row:"):
            opts["row"] = int(spec[4:])
        else:
            opts["cell"] = spec
        res = nv("agent_run", opts)
        if not res.get("ok"):
            # дальше не идём: следующие ячейки обычно зависят от этой
            print(f"{spec}: не запущена — {res.get('reason')}: {res.get('msg', '')}", file=sys.stderr)
            if pairs:
                print(f"уже в очереди: {' '.join(pairs)}", file=sys.stderr)
            return 1
        asked.add(res["cell_id"])
        pairs.append(f"{res['cell_id']}:{res['run_id']}")
        missing += [c for c in res.get("not_run_above") or [] if c not in missing]
        kernel = res.get("kernel") or {}
    since = kernel.get("since")
    missing = unwarned(notebook, f"{since}|{kernel.get('attached')}", [c for c in missing if c not in asked])
    if missing:
        note = " (ядро подхвачено живым: переменные могут быть)" if kernel.get("attached") else ""
        print(f"в этом ядре{f' (с {since})' if since else ''} не выполнялись ячейки выше: "
              f"{' '.join(missing)}{note}", file=sys.stderr)
    if args.no_wait:
        print(" ".join(pairs))
        return 0
    return wait.main([notebook, *pairs, "--timeout", str(args.timeout)])


if __name__ == "__main__":
    raise SystemExit(main())
