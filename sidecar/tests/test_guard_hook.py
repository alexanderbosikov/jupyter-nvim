"""Хук .claude/hooks/guard_open_notebooks.py против живого headless nvim с открытым ноутбуком."""
import json
import os
import shutil
import subprocess
import sys
import time
from pathlib import Path

import pytest

HOOK = Path(__file__).resolve().parents[2] / ".claude" / "hooks" / "guard_open_notebooks.py"
ORIG = '{"cells": [], "metadata": {}, "nbformat": 4, "nbformat_minor": 5}\n'
OLD_MTIME = 1_700_000_000_000_000_000

pytestmark = pytest.mark.skipif(shutil.which("nvim") is None, reason="нет nvim")


@pytest.fixture
def env(tmp_path):
    nb = Path(os.path.realpath(tmp_path)) / "nb.ipynb"
    nb.write_text(ORIG)
    os.utime(nb, ns=(OLD_MTIME, OLD_MTIME))
    sock = tmp_path / "nvim.1.0"
    nv = subprocess.Popen(["nvim", "--headless", "--clean", "--listen", str(sock), str(nb)], stdin=subprocess.DEVNULL)
    for _ in range(50):
        if sock.exists():
            break
        time.sleep(0.05)
    state = tmp_path / "state"
    state.mkdir()
    e = {**os.environ, "GUARD_NVIM_SOCKETS": str(tmp_path / "nvim.*.0"), "TMPDIR": str(state)}
    yield nb, sock, e
    nv.kill()


def hook(e, event, tool, tool_input, tid="t1"):
    data = {"hook_event_name": event, "tool_name": tool, "tool_input": tool_input, "tool_use_id": tid}
    p = subprocess.run([sys.executable, str(HOOK)], input=json.dumps(data), capture_output=True, text=True, env=e)
    return p.stdout.strip()


def bash(e, command, act, event="PostToolUse"):
    cmd = {"command": command}
    hook(e, "PreToolUse", "Bash", cmd)
    act()
    return hook(e, event, "Bash", cmd)


def test_write_to_open_notebook_is_reverted(env):
    nb, _, e = env
    out = bash(e, f"python3 -c \"open('{nb}','w').write('x')\"", lambda: nb.write_text("испорчено"))
    assert nb.read_text() == ORIG
    assert os.stat(nb).st_mtime_ns == OLD_MTIME, "mtime тот же — nvim не заметит подмены"
    assert "откачена" in json.loads(out)["reason"]


def test_failed_command_that_wrote_is_reverted_too(env):
    nb, _, e = env
    out = bash(e, f"cp /dev/null {nb}; false", lambda: nb.write_text(""), event="PostToolUseFailure")
    assert nb.read_text() == ORIG
    assert "откачена" in json.loads(out)["hookSpecificOutput"]["additionalContext"]


def test_other_file_next_to_notebook_path_is_left_alone(env, tmp_path):
    # было ложное срабатывание: `NB=…ipynb sed -i … queries/05.sql`
    nb, _, e = env
    sql = tmp_path / "q.sql"
    sql.write_text("select 1\n")
    assert bash(e, f"NB={nb} sed -i '' s/1/2/ {sql}", lambda: sql.write_text("select 2\n")) == ""


def test_nvim_own_write_is_not_reverted(env):
    # человек нажал :w во время команды агента: jupyter.nvim оставил отметку своей записи
    nb, sock, e = env
    new = ORIG.replace("[]", "[ ]")

    def save_from_nvim():
        nb.write_text(new)
        st = os.stat(nb)
        lua = (f"package.loaded['jupyter.ipynb'] = {{written = {{['{nb}'] = {{sec = {st.st_mtime_ns // 10**9}, "
               f"nsec = {st.st_mtime_ns % 10**9}, ino = {st.st_ino}}}}}}}")
        subprocess.run(["nvim", "--server", str(sock), "--remote-send", f"<Cmd>lua {lua}<CR>"], check=True)
        time.sleep(0.3)

    assert bash(e, f"jn run {nb} e93d", save_from_nvim) == ""
    assert nb.read_text() == new


def test_write_tool_on_open_notebook_is_denied(env):
    nb, _, e = env
    out = json.loads(hook(e, "PreToolUse", "Write", {"file_path": str(nb)}))
    assert out["hookSpecificOutput"]["permissionDecision"] == "deny"


def test_unrelated_command_takes_no_snapshot(env):
    _, _, e = env
    hook(e, "PreToolUse", "Bash", {"command": "ls -la"}, tid="t6")
    assert not (Path(e["TMPDIR"]) / "claude-nb-guard" / "t6").exists()
