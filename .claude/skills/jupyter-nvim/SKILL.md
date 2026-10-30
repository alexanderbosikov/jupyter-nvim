---
name: jupyter-nvim
description: Work with a .ipynb through the user's nvim (jupyter.nvim plugin) — one they have open, or one you created and need to run: open it there yourself and start the kernel, snapshot of cells and runs, results from .jupyter-out (parquet/txt/png), safe edits to the live buffer, running cells and waiting for them. Also any prompt that starts with `[jupyter.nvim]` — it was sent from that notebook. Do NOT use mcp__jupyter__* for these — it needs a Jupyter Server.
---

# A notebook open in nvim (jupyter.nvim)

Plugin: `~/Projects/jupyter.nvim`. The notebook in nvim is a live buffer in markdown
(jupytext); the plugin starts the kernel itself, and outputs live **outside** the document,
in `.jupyter-out/`.

**MCP jupyter does not work here.** `mcp__jupyter__*` addresses notebooks on a Jupyter
Server, where the plugin's kernels never show up. If the same file is also open in Lab,
that is an independent third session — your edits will not land there.

## Step 0: find the session

**If the prompt you are reading starts with `[jupyter.nvim]`, skip this step.** That header
was written by the plugin when the user sent the prompt from the notebook: it names the
notebook, the cell the cursor was on, that cell's last output, and — this is the part that
matters — the number of a claim that is **already open and already visible to the user**.
The notebook's full path and the nvim socket are in your pane's file. Read "A prompt sent
from the notebook" below before you touch anything.

**Everything goes through `jn`** — `~/Projects/jupyter.nvim/bin/jn`, stdlib only, any
`python3`. Every command takes the notebook's path, finds the user's nvim by itself (where
the notebook is open, on screen first; else the one in your herdr tab / tmux window; else by
cwd) and passes arguments to nvim as a JSON file, so there is nothing to escape. Exit 4 —
no nvim found, or a tie (candidates on stderr): ask the user, do not pick at random.
`--sock "$SOCK"` (before the command) skips the search when you already know the socket.

```sh
JN=~/Projects/jupyter.nvim/bin/jn
NB=~/work/analysis/.../01_eda.ipynb          # path to the notebook

# make sure it is open in the user's nvim and the kernel is up — idempotent, call it every time
$JN open "$NB"
# → {"ok": true, "buf": 7, "opened": true, "kernel": true}
```

Answers are one line of JSON; exit 1 means the answer is a refusal (`ok: false`, `reason`).
Do not hand-roll `nvim --remote-expr "luaeval(...)"` — the quoting breaks on the first
quote or newline in your text, and calls without the notebook's path act on whatever buffer
the user's cursor is in. Never the current buffer: `snapshot_json()`, buffer `0`,
`ensure_started()`, `s.exec:run_at(...)` from outside all fail silently.

`jn open` loads the notebook as a **hidden** buffer in the user's nvim: no window, cursor
or current buffer changes; it just appears in their buffer list (`:ls`). Do not wait for the
user to open it, and never start your own nvim: buffers are per process, the user would not
see yours, and opening it themselves would make a second copy.

- `opened: false` — it was already open there; nothing changed.
- `opened: true` — you opened it: tell the user in one line that it is in their buffer list.
- `kernel: true` — the kernel is up or starting; the first `jn run` waits for it.
- `reason: "other_instance"` — open in another nvim: `others[1].socket` is where to work.
- `jn: в этом nvim старая сборка плагина` (exit 4) — that nvim runs an older build of the
  plugin: ask the user to restart nvim. Do not work around it (parsing fences by hand,
  sending keys).

The socket is new after every nvim restart — another reason to let `jn` find it instead of
keeping one from earlier. While the kernel is alive, `.jupyter-out/<name>/runtime.json`
also carries it (`socket`, plus `owner_pid`, `kernel_pid`, `connection_file`, `started_at`).

### A new notebook

1. Create the `.ipynb` on disk (it is not open anywhere yet, so writing it is allowed) — e.g.
   write it as jupytext markdown and `jupytext --to ipynb`, or write the json directly.
   Do not `jn open` a path that does not exist: you get an unsaved template buffer
   instead of your file.
2. `jn open` as above.
3. Run by **row** (`jn run "$NB" row:12`): cells you wrote outside the plugin have no
   `jncell` yet. The first run assigns one and prints it (`e9ec #1 …`) — use it from then on.
   Take the rows from the snapshot (`start_row` of each cell). After a run that assigned an
   id the buffer is modified (the fence line changed); that is expected.

**Two copies.** The same notebook can be open in two nvims (the kernel lives in the one
named by `owner_pid`), and `jn` prefers the one where it is on screen, but check anyway. Check two fields of the snapshot before you
edit: `visible` (is the buffer shown in a window of this nvim) and `other_instances`
(`[{pid, socket, at}]` — other live nvims with this notebook open). If `visible` is false and
`other_instances` is not empty, the user is most likely looking at the other one: take the
snapshot from that socket (`$JN --sock <socket> snapshot "$NB"`), and if it is `visible`
there, work there (`--sock` on every call). Unsure — ask; an edit
made in the hidden copy is invisible to the user and can overwrite the file on `:wa`.

## Reading

Order: **snapshot and buffer from nvim, the contents of results from disk.** The cursor
never moves, and unsaved edits are read as well.

```sh
$JN snapshot "$NB" --brief        # one line per cell: id, lang, rows, section heading, last run, stale
$JN history "$NB" e93d            # the cell's runs on disk, oldest first: when, status, ename, paths
$JN snapshot "$NB"                # the full snapshot, JSON (--cell e93d f5a8 — only those)
$JN text "$NB"                    # the whole notebook text, including anything unsaved
$JN text "$NB" --cell e93d        # one cell's body, exactly as in the buffer — a ready `old`
```

`no_buffer` — the notebook is not open in that nvim: `jn open` it (Step 0).

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

Reading outputs with no nvim at all (CLI over `index.jsonl`): see `reference.md` next to
this file.

## A prompt sent from the notebook

The user can send you a prompt straight from the buffer (`:JupyterAsk`, `<leader>jq`). It
arrives with a header like this:

```
[jupyter.nvim] mda-3957-review/01_eda.ipynb · ячейка a3f9 · python · строки 67–74
вывод: .jupyter-out/01_eda/a3f9/7.parquet · table · 1204×8 · устарел: код правили после прогона
```

The first line names the notebook as `<its directory>/<file>` and the piece of it the
prompt is about — what the user pointed at:

| first line ends with                       | the user                 | what is claimed    |
|--------------------------------------------|--------------------------|--------------------|
| `ячейка a3f9 · python · строки 67–74`      | had the cursor in that   | the cell           |
|                                            | cell                     |                    |
|                                            |                          |                    |
| `… · выделено 70–72 — речь про этот кусок` | selected part of the     | the cell (whole)   |
|                                            | cell                     |                    |
|                                            |                          |                    |
| `строки 40–74: проза и ячейка a3f9`        | selected text, cells, or | those lines, cells |
|                                            | both; or had the cursor  | widened to whole   |
|                                            | in a paragraph (`проза`) |                    |
|                                            |                          |                    |
| `весь ноутбук`                             | asked about the whole    | nothing            |
|                                            | notebook, or the cursor  |                    |
|                                            | was on a blank line      |                    |

`вывод:` lines (`вывод a3f9:` when there are several cells) are relative to the notebook's
directory; at most three, the rest are in the snapshot.

**The full path, the socket and the claim's number are in your pane's file**, not in the
prompt. The plugin writes them to `~/.local/state/nvim/jupyter/panes/<pane>.json` on every
send, and the pane is yours — its id is in your environment. `jn pane` reads it, with the
name from the header; read it again for every `[jupyter.nvim]` prompt, do not reuse a socket
or a claim from earlier in the session — nvim may have been restarted since.

```sh
eval "$($JN pane mda-3957-review/01_eda.ipynb)"    # sets NB, SOCK, CLAIM
```

Then `--sock "$SOCK"` on the calls below: it is the nvim the prompt came from.

If the header itself carries `ноутбук:`, `сокет nvim:` (and `заявка:`) lines, the plugin
could not write that file — use them as they are. No file and no such lines: fall back to
Step 0.

**The claim is already open — do not open another one.** The plugin put the mark on that
piece the moment the user pressed the key: it has been visible since before you read the
prompt, and the cells inside will not run while it is there. Edit with `jn replace`
(below) — edits that land inside the claim keep it alive and turn its label from
`отправлено` to `агент`. **When you are done, `jn done`** — that is what removes
the mark and lets the cells run again. Done includes "nothing to change" and "I answered in
words": the mark goes either way.

```sh
$JN --sock "$SOCK" done "$NB" "$CLAIM"
```

Whether the user wants the cell rewritten, a new cell after it, prose fixed, or nothing
changed at all — that is in the prompt, not in the claim. The claim only says *where*.

## Editing

**One operation for everything: `jn replace <nb> <old> <new>`.** Prose, a cell's code, several
cells with text between them, a new cell, a deleted cell — all the same: find `old` in the
buffer, put `new` in its place. It works like your own Edit tool:

- `old` must occur in the buffer **exactly once** — `not_found` / `ambiguous` otherwise,
  and nothing is written. That match is also the check that the user did not change this
  text while you were thinking: if they did, `old` is no longer there. Re-read and redo.
- `old` and `new` go in **files** (heredocs with a quoted `'TXT'`): quotes, backslashes and
  newlines arrive as they are. A trailing newline at the end of the file is dropped.

```sh
cat > /tmp/jn-old <<'TXT'
Вывод: всё сходится.
TXT
cat > /tmp/jn-new <<'TXT'
Вывод: расходится на 3% — разница в часовом поясе.
TXT
$JN replace "$NB" /tmp/jn-old /tmp/jn-new
# → {"ok": true, "start_row": 42, "end_row": 42}

# a one-line change: inline, no files
$JN replace "$NB" --old 'limit = 100' --new 'limit = 1000'
```

Inline `--old`/`--new` only for a single line without tricky quoting; anything multi-line
goes through files.

**Adding new cells or text — `jn insert`, by place, not by an anchor text.** Do not use
the tail of the previous cell as `old` for an append: that is how the structure slides.

~~~sh
cat > /tmp/jn-ins <<'TXT'
```python
df_dups = run_query("queries/25_dups.sql")
```
TXT
# before a heading (outside cells, must occur once): the end of a section
$JN insert "$NB" /tmp/jn-ins --before-heading "## Ручные запросы"
# → {"ok": true, "start_row": 176, "end_row": 178, "cell_ids": ["13ca"]}
~~~

Place: `--before-heading` (the whole heading line), `--after-cell <id>`, or `--at-end`.
Blank lines around the piece are added when missing; the new cells' ids come back in `cell_ids` — run them by those. Refusals:
`not_found` / `ambiguous` (heading), `no_cell`, plus the checks below.

**The plugin checks the document before writing** and refuses (nothing written) if after the
edit:

- a ```` ``` ```` is left unclosed (`fences`) — everything below would turn into code;
- two fences carry the same `jncell` (`duplicate_id`) — you copied a fence line; write a new
  cell's fence **without** `jncell`, the plugin assigns one;
- a cell lost its `jncell` but is still there (`id_lost`) — keep fence lines as they are when
  you change a cell's code (or include only the body in `old`).

Deleting a whole cell (its fences included) is fine — its id goes with it. **Delete only
what the user asked you to remove** (or agreed to when you proposed it) — never as a side
effect of "cleaning up".

**Cells and prose in the markdown representation:**

- a code cell is ```` ```python ```` / ```` ```sql ```` … ```` ``` ````; a new one is written as
  exactly that, with an empty line before and after, and gets its `jncell` on write;
- everything outside fences is markdown. **One** blank line keeps text in the same markdown
  cell, **two** split it into two cells (jupytext's rule) — a new section with its own
  heading usually wants two;
- never write prose inside a code fence: it is not a cell then, and Run All fails on it.

**Your own claim, when you started the edit yourself** (no `[jupyter.nvim]` prompt): open it
before you start thinking about the change, so the user sees the mark before the write, not
at it. The file holds a piece that occurs once — the claim covers its lines, widened to whole
cells.

```sh
$JN claim "$NB" /tmp/jn-old --title "переписываю вывод"
# → {"ok": true, "token": 3, "kind": "range", "start_row": 42, "end_row": 42, "cells": []}
# … jn replace …, then: $JN done "$NB" 3
```

`claimed` means that piece already has a claim (its `token` is in the answer) — usually the
one the plugin opened for the user's prompt: work in it, do not open another.

**A claim has a lifetime.** The mark counts its own age, and after five minutes with no
word it is dropped by itself — an agent that crashed or went off to ask a question never
sends `done`, and a mark that outlives it lies to the user. Every `jn replace` inside the
claim restarts the countdown; thinking longer without editing, `jn touch "$NB" <token>`.
**A Stop hook checks this** (`.claude/hooks/jupyter_claim.py`): end your turn with the prompt's claim still open and you are sent back to close it; the second time the hook closes it itself and tells the user.
**Asking the user something, or dropping the task: `jn done` first** — your question may
hang there for an hour; the mark must not.

**Cells inside a claim will not run** (`запуск отклонён`): their code is about to change.
Finish the edits, `jn done`, then run.

**Rejections must not be worked around.** Never push a rejected edit through
`nvim_buf_set_lines` / `nvim_buf_set_text` yourself: that is exactly the case the rejection
exists for.

An agent's edit is a separate undo step (with the ids it assigned), and it moves neither the
cursor nor insert mode. Open claims — `:JupyterEdits`; clear them all with `!`.

The older cell-only calls (`edit_begin`, `edit_adopt`, `edit_apply`, `edit_delete`) still
work, but `jn replace` does everything they do; do not mix the two on one piece.

**Never write magics into the body.** The fence carries the language, and the magic's
parameters live in its info string: ```` ```sql magic_args="df_name=orders" ````. The plugin
prepends `%%sql` itself (`cells.text`) and skips that when the body already starts with
`%%` — which is why a hand-typed magic seems to work, until jupytext adds its own on save
and the `.ipynb` ends up with `%%sql` twice. Do not edit `magic_args` in a fence line yourself — if `df_name`, `limit=0` or `cache` are needed, ask the user to run
`:JupyterCellArgs df_name=orders` on that cell (no arguments opens the current ones).

## Running

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
(notebook not open in this nvim — `jn open` it, see Step 0), `no_cell`, `empty`, `claimed`
(a claim holds the cell: `jn done` it first), `no_python`. Do not report a run you did not
see a line for. Exit codes after the start: 0 all ok, 1 some `error`/`aborted` (the line
carries `ename`), 2 timeout (`--timeout`, default 3600 s), 3 the kernel is gone and the run
never reached disk. Paths are absolute; take the result from there, as above.

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

## The kernel directly

Needed when you want a slice of a variable already in memory that no cell outputs. It is the **user's working kernel**, so ask for permission first; the
client code and the rules are in `reference.md`.

## What not to do

- **Do not write to the notebook file** (`.ipynb` or the jupytext `.md`) while it is open
  in nvim: their `:w` will overwrite your edit, and your write will overwrite what they
  have not saved. Edits go through `jn replace` / `jn insert`. A hook
  (`.claude/hooks/guard_open_notebooks.py`) denies Edit/Write on an open `.ipynb` and
  reverts a Bash command's write to one (`git checkout` included) right after the command,
  telling you so: redo that change through `jn`, do not repeat the command.
- **A write to the `.ipynb` never reaches the open buffer** (it was converted by jupytext
  when opened), so it looks like it worked and is gone at the next save. Prose is edited
  with `jn replace` like everything else.
- **Do not use `--remote-send`** (sending keys): it moves the cursor, and it turns into
  garbage if the user is in insert mode. Only `jn`.
- **Do not move the cursor.** Everything you need takes a buffer and a line; read the
  cursor to see where the user is, but never reposition it.
- **Do not reason away a `stale` output.** If the snapshot says the code changed after the
  run, that is a fact, not noise.
