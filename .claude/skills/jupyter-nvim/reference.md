# jupyter-nvim — rare paths

Loaded on demand from `SKILL.md`. Everything here is a once-in-a-while case; the hot path
(snapshot, reading results, two-phase editing, running) stays in `SKILL.md`.

## Reading outputs with no nvim at all

There may be no kernel and no editor — the history on disk is still readable:

```sh
PYTHONPATH=~/Projects/jupyter.nvim/sidecar python3 -m jupyter_nvim.cli "$NB" a3f9 --json
cat "$OUT/index.jsonl"      # one line per run
```

`index.jsonl` holds one object per run: `cell_id`, `run_id`, `status`, `kind`, `path`
(relative to the notebook's `.jupyter-out/<name>/`), `rows`, `cols`, `code_sha`,
`duration_ms`, `ename`.

## The kernel directly — only with permission

When the output you need is not on disk (eaten by a table), or you need a slice of a
variable that is already in memory:

```python
from jupyter_client import BlockingKernelClient
kc = BlockingKernelClient(connection_file=cf)   # cf from runtime.json
kc.load_connection_file(); kc.start_channels()
```

This is the **user's working kernel**. Ask for permission; send `store_history=False` so as
not to shift `In [n]`; do not redefine variables; remember that your output reaches neither
the buffer nor `.jupyter-out` — from the user's side the work happens invisibly. A long
query from you holds up their cells: the channel is shared.
