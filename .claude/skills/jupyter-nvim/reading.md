# jupyter-nvim — reading the snapshot and results

Order: **snapshot and buffer from nvim, the contents of results from disk.** The cursor
never moves, and unsaved edits are read as well.

```sh
$JN snapshot "$NB" --brief        # one line per cell: id, lang, rows, section heading, last run, stale
$JN history "$NB" e93d            # the cell's runs on disk, oldest first: when, status, ename, paths
$JN snapshot "$NB"                # the full snapshot, JSON (--cell e93d f5a8 — only those)
$JN text "$NB"                    # the whole notebook text, including anything unsaved
$JN text "$NB" --cell e93d        # one cell's body, exactly as in the buffer — a ready `old`
```

`no_buffer` — the notebook is not open in that nvim: `jn open` it (`SKILL.md`, Step 0).

Per cell the snapshot gives: `id` (the `jncell` from the fence — a cell made by the plugin's
insert/split/to-code commands or by your `jn replace`/`jn insert` has one from the start; one the user
typed or pasted by hand gets it at its first run or at your first `jn replace` touching
it), `lang`,
`start_row`/`end_row` (the body), `span_start`/`span_end` (with the marker), `runs`,
`stale`, `running`, `live`, `last`. Inside `last`: `run_id`, `status`, `ename`, `kind`
(`table`/`text`/`image`/`none`), `rows`, `cols`, `schema`, `duration_ms`,
`execution_count`, `started_at`, an **absolute** `path`, `outputs` and, for a `table`/`image`
run that also printed something, `text` — the absolute path of that printed output. Inside `live` (present only
while the cell is busy): `status`, `run_id`, `lines`, `tail`.

- `stale: true` — the output came **not from the current code**, the cell was edited after
  the run. Do not present such a result as current: say so, or offer to re-run.
- `running: true` — the cell is busy; what is on disk is still last time's output. Busy is
  not the same as being computed: after "run all" the kernel takes them one at a time, so
  `live.status` is `queued` for everything still waiting and `running` for the single cell
  the kernel is actually working on. Never report a queue as sixteen cells running.
- `live.lines` and `live.tail` — how much output the current run has already produced and
  its last line. The index on disk gets its record only when the run ends, so this is the
  only way to tell a moving run from a stuck one.

Results by `last.path`:

```python
import polars as pl
df = pl.read_parquet(path)     # kind == "table" — the whole frame, not a slice
```

`kind == "text"` — a plain file with stdout/stderr/traceback, read it as text.
`kind == "image"` — a png.

Read parquet with **`~/work/jupyter-utils/.venv/bin/python`** — the system `python3` has no
polars. `jn` needs nothing beyond the stdlib and runs on any `python3`.

`last.kind`/`last.path` is the run's **main** output (table, else the first image, else
text). **All** of them are in `last.outputs` — `[{kind, path, rows?, cols?}]`, absolute
paths, grouped: the text file first (every `print()`, stderr, traceback), then each figure
(`12.png`, `12-2.png`, …), then html, then the table. A cell that prints a metric and draws
a plot has both on disk.

Keep in mind:

1. **`print()` next to a table or an image** is the `text` entry of `last.outputs`, also given
   as `last.text`; the parquet / png holds only the final value. Runs recorded before
   either existed lost it — re-run the cell if you need it.
2. **History depth is 5 runs** per cell; older ones are trimmed. The snapshot shows only the
   last one — "what was that error" about an earlier run is `$JN history "$NB" <cell>`.
3. **No reason to read the output window (`jupyter://output`)**: it holds a rendering made
   for the screen (a table in pages of 100 rows, columns cut at 40 cells), not the data.


Reading outputs with no nvim at all (CLI over `index.jsonl`): see `reference.md`.
