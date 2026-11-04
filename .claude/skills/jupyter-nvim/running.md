# jupyter-nvim — running cells and waiting

```sh
# run cells af4b and 13ca of this notebook and wait for both; the cursor is left alone
$JN run "$NB" af4b 13ca
# af4b #3 ok · text · 1.2s · /w/.jupyter-out/01_eda/af4b/3.txt
# 13ca #4 ok · table 1204×8 · 0.0s · cache · /w/.jupyter-out/01_eda/13ca/4.parquet · print: /w/.jupyter-out/01_eda/13ca/4.txt
```

Paths are absolute — read them as they are. `cache` means nb_utils served the query from
its cache (`✓ из кэша` in the output), which is why it took 0.0s; the data is as old as that
cache entry (the age is in the printed text).

Address the cell by **id**, not by line: your own edits shift the lines. `row:N` works too
(any line inside the cell). Several cells in one call queue in the kernel and run in order.
**Run it in the background** (Bash `run_in_background`) when the cells query Redshift: it
blocks until the runs are on disk, and you are woken when it exits — no polling loop of
your own. `--no-wait` only starts them and prints the pairs (`af4b:3 13ca:4`) for a later
`$JN wait "$NB" af4b:3 13ca:4`.

**Read the outcome.** A refusal stops the batch (exit 1, the reason on stderr): `no_buffer`
(notebook not open in this nvim — `jn open` it, see `SKILL.md`, Step 0), `no_cell`, `empty`, `claimed`
(a claim holds the cell: `jn done` it first), `no_python`. Do not report a run you did not
see a line for. Exit codes after the start: 0 all ok, 1 some `error`/`aborted` (the line
carries `ename`), 2 timeout (`--timeout`, default 3600 s), 3 the kernel is gone and the run
never reached disk. Paths are absolute; take the result from there (`reading.md`).

**`в этом ядре … не выполнялись ячейки выше: e93d 345e`** (stderr) — code cells above the
ones you ran that have not run in the current kernel (`row:N` for a cell without an id).
Printed once per kernel: a later `jn run` names only cells not listed before, so silence
does not mean they have run since.
The kernel restarts when the user reopens the notebook or presses restart, and their
variables are gone. If your cell needs one of them, run those first, in the same call
before yours (`$JN run "$NB" e93d 345e af4b`), rather than learning it from a `NameError`.
`ядро подхвачено живым` — the kernel was picked up alive, and the list only means "not run
since nvim attached": the variables may well be there.

What the user sees is the same as for their own key: the status under the cell («в очереди»
→ «выполняется» → ✓) and the output window opening with the run, if the notebook is on
screen (`visible`). The buffer is not saved before the run (their key does `:w`; you do not).

**Your edits stay in the buffer until the user saves.** Never save it yourself: `:w` would
also write their own unsaved changes. `jn replace` / `jn insert` (once until it is saved)
and `jn done` say `буфер не сохранён` on stderr; when you finish, tell the user in one line
that the notebook needs `:w` — until then the `.ipynb` on disk (Lab, git, a file sent on)
has none of your cells.

`jn wait` counts only runs started under the current kernel (run numbers restart with
every nvim restart), so an old `af4b #3` from another day does not satisfy it. Without
`:run_id` it waits for the cell's next new run — the user's own run included.

The first run of a cell that has no `jncell` yet — one the user typed or pasted by hand —
**modifies the document**: the plugin writes `jncell="…"` into the marker. That is expected,
but it means "just running it" is a buffer change too. Cells made by the plugin's commands or
by your `jn replace`/`jn insert` already carry their id, and running them writes nothing.

The commands in full (for a human, not for you): `:JupyterRun`, `:JupyterRunAll`,
`:JupyterRunBelow`, `:JupyterInterrupt`, `:JupyterRestart`, `:JupyterTable`,
`:JupyterSnapshot`, `:JupyterEdits`, `:JupyterLog`, `:checkhealth jupyter`.
