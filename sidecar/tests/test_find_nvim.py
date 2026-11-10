from jupyter_nvim import find_nvim
from jupyter_nvim.find_nvim import explain, main, pick

ME = {"cwd": "/w/task", "htab": "wZ:t1", "hws": "wZ", "tmux": None}


def nv(**kw):
    base = {"pid": 1, "cwd": "/w/task", "htab": None, "hws": None, "nb": 0, "tmux": None}
    base.update(kw)
    return base


def test_same_herdr_tab_beats_same_cwd():
    best, _ = pick({"a": nv(htab="wZ:t2", hws="wZ"), "b": nv(htab="wZ:t1", hws="wZ")}, ME, "/w/task/x.ipynb")
    assert best == "b"


def test_notebook_already_open_wins_over_everything():
    best, _ = pick({"a": nv(htab="wZ:t1", hws="wZ"), "b": nv(cwd="/elsewhere", nb=1)}, ME, "/w/task/x.ipynb")
    assert best == "b"


def test_tie_is_not_resolved_at_random():
    best, ranked = pick({"a": nv(), "b": nv()}, ME, "/w/task/x.ipynb")
    assert best is None and len(ranked) == 2


def test_the_only_nvim_is_taken_even_when_unrelated():
    # агент в другой вкладке, ноутбук ещё нигде не открыт: раньше «нет nvim», хотя он был
    best, ranked = pick({"a": nv(cwd="/other")}, ME, "/w/task/x.ipynb")
    assert best == "a" and "единственный nvim" in ranked[0][1]


def test_several_unrelated_nvims_are_listed_not_guessed():
    best, ranked = pick({"a": nv(cwd="/other"), "b": nv(cwd="/else")}, ME, "/w/task/x.ipynb")
    assert best is None and sorted(r[2] for r in ranked) == ["a", "b"]
    assert "ни один не связан" in explain(ranked)


def test_unrelated_nvim_loses_to_related_one():
    best, _ = pick({"a": nv(cwd="/other"), "b": nv(htab="wZ:t1")}, ME, "/w/task/x.ipynb")
    assert best == "b"


def test_only_a_viewer_is_not_taken():
    best, _ = pick({"yazi": nv(cwd="/other", viewer=True)}, ME, "/w/task/x.ipynb")
    assert best is None


def test_socket_found_without_tmpdir(monkeypatch, tmp_path):
    # шелл без TMPDIR: nvim положил сокет в свой каталог, его надо увидеть всё равно
    sock = tmp_path / "nvim.u" / "abc" / "nvim.1.0"
    sock.parent.mkdir(parents=True)
    sock.touch()
    monkeypatch.setattr(find_nvim, "_user", lambda: "u")
    monkeypatch.delenv("TMPDIR", raising=False)
    monkeypatch.setattr(find_nvim, "_temp_dirs", lambda: ["/nonexistent", str(tmp_path)])
    assert find_nvim.sockets() == [str(sock)]


def test_temp_dirs_include_darwin_user_dir_without_tmpdir(monkeypatch):
    monkeypatch.delenv("TMPDIR", raising=False)
    if find_nvim.sys.platform != "darwin":
        return
    import subprocess
    user_tmp = subprocess.run(["getconf", "DARWIN_USER_TEMP_DIR"], capture_output=True, text=True).stdout.strip()
    assert user_tmp in find_nvim._temp_dirs()


def test_tmux_same_window():
    me = {**ME, "htab": None, "hws": None, "tmux": ("$1", "@3")}
    best, _ = pick({"a": nv(tmux=("$1", "@2")), "b": nv(tmux=("$1", "@3"))}, me, "")
    assert best == "b"


def test_main_prints_socket(monkeypatch, capsys, tmp_path):
    monkeypatch.chdir(tmp_path)
    monkeypatch.setenv("HERDR_TAB_ID", "wZ:t1")
    monkeypatch.delenv("TMUX_PANE", raising=False)
    answers = {"s1": nv(cwd="/other"), "s2": nv(cwd=str(tmp_path), htab="wZ:t1")}
    code = main(["x.ipynb", "--sockets", "s1", "s2", "dead"], ask=lambda s, _nb: answers.get(s))
    assert code == 0
    assert capsys.readouterr().out.strip() == "s2"


def test_viewer_is_never_picked_even_with_notebook_open():
    me = {**ME, "htab": None, "hws": None, "tmux": ("$1", "@1")}
    found = {"yazi": nv(tmux=("$1", "@1"), nb=2, viewer=True), "work": nv(tmux=("$1", "@2"))}
    best, ranked = pick(found, me, "/w/task/x.ipynb")
    assert best == "work" and [r[2] for r in ranked] == ["work"]


def test_socket_found_without_user(monkeypatch, tmp_path):
    # шелл без $USER: имя каталога nvim.<user> берётся по uid
    import pwd, os
    me = pwd.getpwuid(os.getuid()).pw_name
    sock = tmp_path / f"nvim.{me}" / "abc" / "nvim.1.0"
    sock.parent.mkdir(parents=True)
    sock.touch()
    monkeypatch.delenv("USER", raising=False)
    monkeypatch.setattr(find_nvim, "_temp_dirs", lambda: [str(tmp_path)])
    assert find_nvim.sockets() == [str(sock)]


def test_query_from_interactive_terminal(monkeypatch):
    # из интерактивного шелла nvim-клиент получал терминал на stdin и писал перед JSON
    # коды инициализации TUI: строка не начиналась с `{`, и все nvim считались молчащими
    import subprocess

    seen = {}

    def fake_run(cmd, **kw):
        seen.update(kw)
        out = '\x1b[?1049h\x1b[22;0;0t\x1b[?2004h{"pid": 7, "cwd": "/w", "nb": 1}\n'
        return subprocess.CompletedProcess(cmd, 0, stdout=out, stderr="")

    monkeypatch.setattr(find_nvim.subprocess, "run", fake_run)
    assert find_nvim.query("/s", "/w/x.ipynb") == {"pid": 7, "cwd": "/w", "nb": 1}
    assert seen["stdin"] is subprocess.DEVNULL, "терминал nvim-клиенту не отдаём"
