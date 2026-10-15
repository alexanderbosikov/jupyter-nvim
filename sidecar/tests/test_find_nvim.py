from jupyter_nvim.find_nvim import main, pick

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


def test_unrelated_nvim_is_not_a_candidate():
    best, ranked = pick({"a": nv(cwd="/other")}, ME, "/w/task/x.ipynb")
    assert best is None and ranked == []


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
