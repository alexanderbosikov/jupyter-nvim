#!/usr/bin/env python3
"""Не давать агенту писать на диск .ipynb, который открыт в nvim (jupyter.nvim).

Открытый ноутбук живёт в буфере nvim: запись в файл мимо буфера либо затрётся
ближайшим :w, либо перечитается поверх несохранённых правок пользователя.
Править такой ноутбук — только через скилл jupyter-nvim (`jn replace` / `jn insert`).

Edit/Write/MultiEdit/NotebookEdit (PreToolUse): путь известен — запрет до записи.

Bash: куда пишет команда, по её тексту не угадать (heredoc, переменные, скрипты), и
каждая попытка угадать давала ложные срабатывания. Поэтому смотрим на результат:
- PreToolUse: открытые ноутбуки — stat (mtime_ns, size, inode) и копия файла;
- PostToolUse: файл изменился — возвращаем копию (вместе с mtime, чтобы nvim не
  заметил подмены) и говорим агенту, что запись откачена.
Изменение, которое сделал сам nvim (`:w` человека во время команды), не откатываем:
jupyter.nvim запоминает stat своей последней записи (`require("jupyter.ipynb").written`).

Опрос nvim стоит 20–50 мс, поэтому снимок берётся, только если в команде есть
`ipynb`, git или конвертеры ноутбуков. Фоновые команды (run_in_background) хук не
ловит: PostToolUse приходит сразу после запуска.
Если nvim недоступен или не отвечает — пропускаем (fail open).
"""
import glob
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time

FILE_TOOLS = {"Edit", "Write", "MultiEdit", "NotebookEdit"}
# команды, которым есть чем задеть ноутбук; остальные не стоят опроса nvim
SUSPECT = re.compile(r"ipynb|\bgit\b|jupytext|nbconvert|nbstripout|nbformat")
LIST_LUA = (
    'luaeval("vim.json.encode(vim.tbl_map(function(b) return vim.api.nvim_buf_get_name(b) end, '
    'vim.tbl_filter(function(b) return vim.api.nvim_buf_is_loaded(b) '
    'and vim.api.nvim_buf_get_name(b):match(\\"%.ipynb$\\") ~= nil end, vim.api.nvim_list_bufs())))")'
)
# отметка последней записи jupyter.nvim по пути; nil — не писал (или старая сборка плагина)
WRITTEN_LUA = (
    "luaeval('vim.json.encode((package.loaded[\"jupyter.ipynb\"] or {written = {}}).written[_A] or vim.NIL)', {path})"
)
STATE = os.path.join(tempfile.gettempdir(), "claude-nb-guard")


def sockets():
    # GUARD_NVIM_SOCKETS — шаблон сокетов для тестов, чтобы не задевать живые nvim
    pattern = os.environ.get("GUARD_NVIM_SOCKETS")
    if not pattern:
        tmp = os.environ.get("TMPDIR") or tempfile.gettempdir()
        pattern = os.path.join(tmp, f"nvim.{os.environ.get('USER', '')}", "*", "nvim.*.0")
    return glob.glob(pattern)


def ask_all(expr):
    """Выражение во все живые nvim параллельно; последняя JSON-строка ответа каждого."""
    procs = []
    for sock in sockets():
        try:
            procs.append(subprocess.Popen(
                ["nvim", "--server", sock, "--remote-expr", expr],
                stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True,
            ))
        except OSError:
            return []
    answers = []
    deadline = time.monotonic() + 2
    for p in procs:
        try:
            out, _ = p.communicate(timeout=max(0.05, deadline - time.monotonic()))
        except subprocess.TimeoutExpired:
            p.kill()
            continue
        for line in reversed(out.splitlines()):
            if line.startswith(("[", "{", "null")):
                try:
                    answers.append(json.loads(line))
                except ValueError:
                    pass
                break
    return answers


def open_notebooks():
    names = set()
    for answer in ask_all(LIST_LUA):
        if isinstance(answer, list):
            names.update(os.path.realpath(n) for n in answer)
    return names


def stat_of(path):
    try:
        st = os.stat(path)
    except OSError:
        return None
    return {"mtime_ns": st.st_mtime_ns, "atime_ns": st.st_atime_ns, "size": st.st_size, "ino": st.st_ino}


def written_by_nvim(path, st):
    """Это изменение записал сам nvim — например, человек нажал :w во время команды."""
    expr = WRITTEN_LUA.replace("{path}", json.dumps(path))
    for mark in ask_all(expr):
        if isinstance(mark, dict) and mark.get("ino") == st["ino"] \
                and mark.get("sec", 0) * 10**9 + mark.get("nsec", 0) == st["mtime_ns"]:
            return True
    return False


def snapshot_dir(data):
    key = data.get("tool_use_id") or hashlib.sha256(
        (data.get("session_id", "") + ((data.get("tool_input") or {}).get("command") or "")).encode()
    ).hexdigest()[:16]
    return os.path.join(STATE, re.sub(r"[^A-Za-z0-9_-]", "_", key))


def drop_stale():
    # снимки фоновых команд и упавших хуков: старше суток — мусор
    try:
        for name in os.listdir(STATE):
            d = os.path.join(STATE, name)
            if time.time() - os.path.getmtime(d) > 86400:
                shutil.rmtree(d, ignore_errors=True)
    except OSError:
        pass


def before_bash(data):
    command = (data.get("tool_input") or {}).get("command") or ""
    if not SUSPECT.search(command):
        return
    opened = open_notebooks()
    if not opened:
        return
    drop_stale()
    d = snapshot_dir(data)
    os.makedirs(d, exist_ok=True)
    manifest = {}
    for i, path in enumerate(sorted(opened)):
        st = stat_of(path)
        if not st:
            continue
        backup = os.path.join(d, f"{i}.ipynb")
        try:
            shutil.copyfile(path, backup)
        except OSError:
            continue
        manifest[path] = {**st, "backup": backup}
    with open(os.path.join(d, "manifest.json"), "w", encoding="utf-8") as f:
        json.dump(manifest, f)


def after_bash(data):
    d = snapshot_dir(data)
    try:
        with open(os.path.join(d, "manifest.json"), encoding="utf-8") as f:
            manifest = json.load(f)
    except (OSError, ValueError):
        return
    reverted, failed = [], []
    try:
        for path, was in manifest.items():
            now = stat_of(path)
            if now and (now["mtime_ns"], now["size"], now["ino"]) == (was["mtime_ns"], was["size"], was["ino"]):
                continue
            if now and written_by_nvim(path, now):
                continue
            try:
                shutil.copyfile(was["backup"], path)
                os.utime(path, ns=(was["atime_ns"], was["mtime_ns"]))
                reverted.append(path)
            except OSError as e:
                failed.append(f"{path} ({e})")
    finally:
        shutil.rmtree(d, ignore_errors=True)
    if not reverted and not failed:
        return
    msg = []
    if reverted:
        msg.append(
            f"Команда записала в ноутбук, открытый в nvim: {', '.join(reverted)}. Запись откачена — "
            "файл возвращён как был, иначе её затёр бы ближайший :w или она перечиталась бы поверх "
            "несохранённого у пользователя. Правь живой буфер через скилл jupyter-nvim: "
            "~/Projects/jupyter.nvim/bin/jn replace / jn insert. Если запись была не твоей целью "
            "(git checkout, скрипт по соседним файлам) — сделай её так, чтобы ноутбук не задевался."
        )
    if failed:
        msg.append(f"Откатить не удалось: {', '.join(failed)} — скажи пользователю.")
    print(json.dumps({
        # block + reason доходят до агента после PostToolUse; additionalContext — после
        # PostToolUseFailure (команда упала, а запись уже случилась)
        "decision": "block",
        "reason": " ".join(msg),
        "hookSpecificOutput": {"hookEventName": data.get("hook_event_name"), "additionalContext": " ".join(msg)},
        "systemMessage": "guard_open_notebooks: откатил запись агента в открытый ноутбук"
        if reverted else "guard_open_notebooks: не смог откатить запись в открытый ноутбук",
    }, ensure_ascii=False))


def deny(paths):
    shown = ", ".join(sorted(paths))
    print(json.dumps({
        "hookSpecificOutput": {
            "hookEventName": "PreToolUse",
            "permissionDecision": "deny",
            "permissionDecisionReason": (
                f"Ноутбук открыт в nvim ({shown}): запись в файл на диске мимо буфера "
                "затрётся при :w или перепишет несохранённое у пользователя. "
                "Правь живой буфер через скилл jupyter-nvim: "
                "~/Projects/jupyter.nvim/bin/jn replace / jn insert."
            ),
        }
    }, ensure_ascii=False))


def main():
    try:
        data = json.load(sys.stdin)
    except ValueError:
        return
    tool = data.get("tool_name")
    event = data.get("hook_event_name") or "PreToolUse"
    tool_input = data.get("tool_input") or {}

    if tool == "Bash":
        (after_bash if event.startswith("PostToolUse") else before_bash)(data)
    elif tool in FILE_TOOLS and event == "PreToolUse":
        path = tool_input.get("file_path") or tool_input.get("notebook_path") or ""
        if not path.endswith(".ipynb"):
            return
        real = os.path.realpath(os.path.expanduser(path))
        if os.path.exists(real) and real in open_notebooks():
            deny([real])


if __name__ == "__main__":
    main()
