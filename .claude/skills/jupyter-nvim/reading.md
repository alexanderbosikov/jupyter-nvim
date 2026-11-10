# jupyter-nvim — reading the snapshot and results

Order: **snapshot and buffer from nvim, the contents of results from disk.** The cursor
never moves, and unsaved edits are read as well.

```sh
$JN snapshot "$NB" --brief        # one line per cell: id, lang, rows, section heading, last run, stale
$JN history "$NB" e93d            # the cell's runs on disk, oldest first: when, status, ename, paths
$JN show "$NB" e93d               # every output of the last run, whole (--run N — an earlier one)
$JN snapshot "$NB"                # the full snapshot, JSON (--cell e93d f5a8 — only those, with previews)
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
(the main output: `table`/`image`/`text`/`none`), `duration_ms`, `execution_count`,
`started_at`, `outputs` — every output once: `{kind, path}` with an **absolute** path, a
table also `rows`, `cols`, `schema`; with `--cell` each also `preview`. Inside `live` (present only
while the cell is busy or its finished run has not reached the disk yet): `status`, `run_id`, `lines`, `tail`.

- `stale: true` — the output came **not from the current code**, the cell was edited after
  the run. Do not present such a result as current: say so, or offer to re-run.
- `running: true` — the cell is busy; what is on disk is still last time's output. Busy is
  not the same as being computed: after "run all" the kernel takes them one at a time, so
  `live.status` is `queued` for everything still waiting and `running` for the single cell
  the kernel is actually working on. Never report a queue as sixteen cells running.
- `live.lines` and `live.tail` — how much output the current run has already produced and
  its last meaningful line (blank lines and table borders skipped). The index on disk gets its record only when the run ends, so this is the
  only way to tell a moving run from a stuck one.

## The contents: `jn show`

```sh
$JN show "$NB" e93d               # last run; --run 12 — that run (numbers from jn history)
$JN show "$NB" e93d --rows 200    # more table rows (default 50); --all — table and text whole
```

```
e93d #12 ok · table 1070×9 · 42.7s
## text · строк: 1 · /…/.jupyter-out/01_eda/e93d/12.txt
✓ 1,070 строк · 43 с
## table · 1070×9 · /…/.jupyter-out/01_eda/e93d/12.parquet
# cut:String, orders:Int64, volume_usd:Float64
cut,orders,volume_usd
"total, all",46026752,21514503052856.24
,102591,
# … ещё 1020 строк из 1070
```

One section per output, `## <kind> · … · <absolute path>`, in the run's order. The table is
CSV: values whole (no rounding, no cut columns), a value with a comma or quote in quotes,
`""` an empty string, an empty field NULL. Text is as printed, minus ANSI codes, and a
polars table printed in it comes as `a | b | c` rows without frames — **its numbers are
rounded by polars' printing** (`2.8140e11`); exact values only in a parquet. An image is
its path and size: look at it with Read. Reads only the disk — no nvim needed.

`jn snapshot --cell` puts the same thing in short into `last.outputs[*].preview`: a table
`{columns, rows}` (5 rows), a text `{lines, head, tail}`, an image `{width, height}`.

Hand-written polars only for what `show` does not do — filter, aggregate, join:
**`~/work/jupyter-utils/.venv/bin/python`** (the system `python3` has no polars), the path
from `jn path`:

```sh
P=~/work/jupyter-utils/.venv/bin/python
$P -c "import polars as pl, sys; a=pl.read_parquet(sys.argv[1]); b=pl.read_parquet(sys.argv[2]); …" \
   "$($JN path "$NB" d3b8)" "$($JN path "$NB" f34e)"
```

`jn path "$NB" <cell> [--kind table|text|image|html] [--run N]` — the last run's output,
one path per line (several for images); exit 1 with what the run does have otherwise. Never
type a run number into the path: it changes with every run, and the old file stays — a
re-run cell would be read from yesterday's output without a word. `jn` itself is stdlib only; for tables it starts the sidecar's python
(`runtime.json`) or `$JN_PYTHON`, and without one says so instead of a preview.

`last.kind` is the run's **main** output (table, else the first image, else text). The
outputs are in `last.outputs`, grouped: the text file first (every `print()`, stderr, traceback), then each figure
(`12.png`, `12-2.png`, …), then html, then the table. A cell that prints a metric and draws
a plot has both on disk.

Keep in mind:

1. **`print()` next to a table or an image** is the `text` entry of `last.outputs` (and the
   first section of `jn show`); the parquet / png holds only the final value. Runs recorded before
   either existed lost it — re-run the cell if you need it.
2. **History depth is 5 runs** per cell; older ones are trimmed. The snapshot shows only the
   last one — "what was that error" about an earlier run is `$JN history "$NB" <cell>`.
3. **No reason to read the output window (`jupyter://output`)**: it holds a rendering made
   for the screen (a table in pages of 100 rows, columns cut at 40 cells), not the data.


Reading outputs with no nvim at all (CLI over `index.jsonl`): see `reference.md`.
