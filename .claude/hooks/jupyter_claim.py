#!/usr/bin/env python3
"""Хук Claude Code: заявка из промпта jupyter.nvim не должна пережить ход агента.

Промпт, отправленный из ноутбука (<leader>nq), открывает заявку: на ячейке у человека
встаёт метка «агент правит», и ячейка не запускается, пока агент не скажет edit_done.
Агент, не загрузивший скилл jupyter-nvim, отвечает и уходит — метка висит, пока не истечёт.

UserPromptSubmit: промпт начинается с `[jupyter.nvim]` — находим его заявку в файле панели
(его пишет nvim перед отправкой, ask.remember), запоминаем за сессией и напоминаем агенту,
что в конце её надо снять.

Stop: заявка сессии ещё открыта в nvim — не даём закончить ход, агент возвращается и снимает
её сам. Если он и во второй раз заканчивает с открытой (stop_hook_active), снимаем сами:
висящая метка врёт человеку, а зацикливать агента незачем.

Подключается в ~/.claude/settings.json на оба события одной командой.
"""

import json
import os
import shlex
import shutil
import subprocess
import sys
import time
from pathlib import Path

STATE = Path(os.environ.get("XDG_STATE_HOME", Path.home() / ".local/state")) / "nvim/jupyter"
PANES = STATE / "panes"
SESSIONS = STATE / "hook"
NVIM = shutil.which("nvim") or "/opt/homebrew/bin/nvim"


def pane_id() -> str | None:
    return os.environ.get("HERDR_PANE_ID") or os.environ.get("TMUX_PANE")


def lua(socket: str, expr: str) -> object:
    """Выполнить lua-выражение в nvim по сокету; None — nvim не ответил."""
    try:
        out = subprocess.run(
            [NVIM, "--clean", "--headless", "--server", socket, "--remote-expr", f'luaeval("{expr}")'],
            capture_output=True,
            text=True,
            timeout=5,
        )
    except (OSError, subprocess.TimeoutExpired):
        return None
    if out.returncode != 0:
        return None
    try:
        return json.loads(out.stdout)
    except json.JSONDecodeError:
        return None


def open_tokens(socket: str) -> list[int] | None:
    return lua(socket, "vim.json.encode(vim.tbl_map(function(r) return r.token end, require('jupyter.agent').list()))")


def on_prompt(event: dict) -> None:
    prompt = event.get("prompt") or ""
    if not prompt.startswith("[jupyter.nvim]"):
        return
    pane = pane_id()
    if not pane:
        return
    try:
        entries = json.loads((PANES / f"{pane}.json").read_text())
    except (OSError, json.JSONDecodeError):
        return
    # первая строка шапки: «[jupyter.nvim] каталог/файл.ipynb · …»
    short = prompt.splitlines()[0].removeprefix("[jupyter.nvim]").split("·")[0].strip()
    matches = [(path, e) for path, e in entries.items() if path.endswith("/" + short) and isinstance(e, dict)]
    if not matches:
        return
    notebook, entry = max(matches, key=lambda m: m[1].get("at") or 0)
    claim, socket = entry.get("claim"), entry.get("socket")
    if not isinstance(claim, int) or not socket:
        return  # вопрос про весь ноутбук: заявки нет
    SESSIONS.mkdir(parents=True, exist_ok=True)
    (SESSIONS / f"{event['session_id']}.json").write_text(
        json.dumps({"socket": socket, "claim": claim, "notebook": notebook, "at": int(time.time())})
    )
    print(
        json.dumps(
            {
                "hookSpecificOutput": {
                    "hookEventName": "UserPromptSubmit",
                    "additionalContext": (
                        f"Промпт отправлен из jupyter.nvim ({notebook}). Сначала загрузи скилл jupyter-nvim. "
                        f"На ячейке у человека стоит метка заявки {claim}: до конца ответа ОБЯЗАТЕЛЬНО сними её — "
                        f"`~/Projects/jupyter.nvim/bin/jn --sock {shlex.quote(socket)} done {shlex.quote(notebook)} {claim}`. Это нужно сделать и когда правки не было, "
                        "и перед тем, как задать человеку вопрос."
                    ),
                }
            },
            ensure_ascii=False,
        )
    )


def on_stop(event: dict) -> None:
    path = SESSIONS / f"{event['session_id']}.json"
    try:
        state = json.loads(path.read_text())
    except (OSError, json.JSONDecodeError):
        return
    socket, claim = state["socket"], state["claim"]
    tokens = open_tokens(socket)
    if tokens is None or claim not in tokens:
        path.unlink(missing_ok=True)  # снята, истекла или nvim закрыт
        return
    if not event.get("stop_hook_active"):
        print(
            json.dumps(
                {
                    "decision": "block",
                    "reason": (
                        f"Заявка {claim} из промпта jupyter.nvim всё ещё открыта — метка висит на ячейке "
                        f"у человека, и ячейка не запускается. Сними её: ~/Projects/jupyter.nvim/bin/jn "
                        f"--sock {shlex.quote(socket)} done {shlex.quote(state.get('notebook') or '-')} {claim} "
                        "(скилл jupyter-nvim) и закончи ответ."
                    ),
                },
                ensure_ascii=False,
            )
        )
        return
    lua(socket, f"vim.json.encode(require('jupyter').edit_done({claim}))")
    path.unlink(missing_ok=True)
    print(json.dumps({"systemMessage": f"jupyter.nvim: агент не снял заявку {claim} — снята хуком"}, ensure_ascii=False))


def main() -> None:
    try:
        event = json.load(sys.stdin)
    except json.JSONDecodeError:
        return
    if not event.get("session_id"):
        return
    name = event.get("hook_event_name")
    if name == "UserPromptSubmit":
        on_prompt(event)
    elif name == "Stop":
        on_stop(event)


if __name__ == "__main__":
    main()
