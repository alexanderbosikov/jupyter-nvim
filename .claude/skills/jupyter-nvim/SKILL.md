---
name: jupyter-nvim
description: Read and edit a .ipynb the user has open in nvim via the jupyter.nvim plugin: snapshot of cells and runs, results from .jupyter-out (parquet/txt/png), safe edits to the live buffer, running cells. Do NOT use mcp__jupyter__* for these — it needs a Jupyter Server.
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
was written by the plugin when the user sent the prompt from the notebook, and it already
carries everything below: the notebook path, the nvim socket, the cell the cursor was on,
the path to that cell's last output, and — this is the part that matters — the number of a
claim that is **already open and already visible to the user**. Read "A prompt sent from the
notebook" below before you touch anything.

```sh
NB=~/work/sandbox/.../01_eda.ipynb                      # the notebook
OUT="$(dirname "$NB")/.jupyter-out/$(basename "$NB" .ipynb)"
cat "$OUT/runtime.json"   # exists only while the kernel is alive
# {"sidecar_pid":91263,"owner_pid":90954,"kernel_pid":91264,"kernel_name":"jupyter-utils",
#  "connection_file":"/var/folders/.../tmpqsjpnp0c.json"}

SOCK=$(lsof -p "$(python3 -c "import json,sys;print(json.load(open(sys.argv[1]))['owner_pid'])" "$OUT/runtime.json")" \
       | grep -o '/[^ ]*nvim\.[0-9]*\.0' | head -1)
```

`owner_pid` is the pid of nvim. If there is no `runtime.json`, the kernel is not running:
the buffer still reads fine, and you can ask the user for the socket address
(`:echo v:servername`). There may be several notebooks and several sockets — match them by
the `notebook` field in the snapshot.

If you get back `attempt to call field 'snapshot_json' (a nil value)` — this nvim session
has a build of the plugin without snapshot and editing. Do not work around it by parsing
fences by hand: ask for a restart of nvim (or a reload of the plugin) and carry on.

## Reading

Order: **snapshot and buffer from nvim, the contents of results from disk.** The cursor
never moves, and unsaved edits are read as well.

```sh
# snapshot: the cells, their ids, boundaries, language and the last run of each
nvim --server "$SOCK" --remote-expr 'luaeval("require(\"jupyter\").snapshot_json()")'

# the whole notebook text (including anything unsaved)
nvim --server "$SOCK" --remote-expr 'luaeval("table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), \"\\n\")")'
```

Per cell the snapshot gives: `id` (the `jncell` from the fence), `lang`,
`start_row`/`end_row` (the body), `span_start`/`span_end` (with the marker), `runs`,
`stale`, `running`, `live`, `last`. Inside `last`: `run_id`, `status`, `ename`, `kind`
(`table`/`text`/`image`/`none`), `rows`, `cols`, `schema`, `duration_ms`,
`execution_count`, `started_at` and an **absolute** `path`. Inside `live` (present only
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

Three things to keep in mind:

1. **One artifact per run.** If the result is a table or an image, `print()` from that same
   run **does not reach** the disk. If you need the text, either re-run the cell without
   the table, or ask the kernel directly.
2. **History depth is 5 runs** per cell; older ones are trimmed.
3. **No reason to read the output window (`jupyter://output`)**: it holds a rendering made
   for the screen (a table in pages of 100 rows, columns cut at 40 cells), not the data.

Reading outputs with no nvim at all (CLI over `index.jsonl`): see `reference.md` next to
this file.

## A prompt sent from the notebook

The user can send you a prompt straight from the buffer (`:JupyterAsk`, `<leader>jq`). It
arrives with a header like this:

```
[jupyter.nvim] ноутбук открыт в nvim; читать и править его — через скилл jupyter-nvim.
ноутбук: /Users/…/01_eda.ipynb
сокет nvim: /tmp/nvim.12345.0
ячейка: a3f9 · python · строки 67–74
вывод ячейки: /Users/…/.jupyter-out/01_eda/runs/0007.parquet · table · 1204×8 · устарел…
заявка: 7 — уже открыта, метка стоит в буфере, человек её видит.
  взять её: edit_adopt(7) — перепишешь тело ячейки;
           edit_adopt(7, {after = true}) — допишешь новую после неё.
```

**Take the claim, do not open your own.** The plugin opened it the moment the user pressed
the key — that is the whole point of it: the mark has been sitting on that cell since
before you read the prompt, so the user has known all along that the cell is spoken for.
Calling `edit_begin` here puts a *second* mark on the same cell.

```sh
# the cell is to be rewritten
nvim --server "$SOCK" --remote-expr 'luaeval("vim.json.encode(require(\"jupyter\").edit_adopt(7, {label = \"Claude\"}))")'
# → {"ok":true,"kind":"replace","cell_id":"a3f9","start_row":67,"end_row":74,"sha":"13306dab"}

# …or a new cell goes after it ("add a completeness check after this")
nvim --server "$SOCK" --remote-expr 'luaeval("vim.json.encode(require(\"jupyter\").edit_adopt(7, {label = \"Claude\", after = true}))")'
# → {"ok":true,"kind":"insert","after":"a3f9","at_row":75}
```

- **Which of the two it is, is in the prompt, not in the claim.** The plugin cannot know
  whether "add a check" means rewriting the cell or appending one, so it leaves the kind
  open and `edit_apply` refuses (`{"ok":false,"reason":"not_adopted"}`) until you say.
- `label` is your name, shown in the mark. `title` overrides the user's own words with
  yours ("переписываю на lazy-скан") — worth it when what you are doing turned out to be
  something other than what the first line of the prompt says.
- The sha is taken **at adopt time**, not when the prompt was sent: whatever the user typed
  while the prompt was in flight is part of what you read, not a reason to reject your edit.
- Everything afterwards is unchanged: `edit_apply(7, lines)`, `edit_touch(7)`,
  `edit_cancel(7)`.
- `заявки нет` in the header means the question is not about one cell (the user asked about
  the whole notebook, or the cursor was in prose). Nothing is marked; if you end up editing,
  open a claim yourself with `edit_begin`.

## Editing

This is the path for an edit **you** initiated — no `[jupyter.nvim]` header, no claim
waiting for you. Two-phase: claim, then apply. In between the user keeps working, so writing by the line
numbers from the first phase is **not allowed** — the plugin resolves them by anchor
itself.

```sh
# 1. claim: the cell is marked in the buffer (highlight + "✎ Claude"), the user sees it
nvim --server "$SOCK" --remote-expr 'luaeval("vim.json.encode(require(\"jupyter\").edit_begin({cell = \"a3f9\", label = \"Claude\"}))")'
# → {"ok":true,"token":1,"start_row":67,"end_row":74,"sha":"13306dab"}

# 2. apply. The code comes from a file: no escaping of quotes or newlines
cat > /tmp/cell.sql <<'EOF'
select button_id, count(*) as events
from events
group by 1
EOF
nvim --server "$SOCK" --remote-expr 'luaeval("vim.json.encode(require(\"jupyter\").edit_apply(1, vim.fn.readfile(\"/tmp/cell.sql\")))")'
# → {"ok":true,"kind":"replace","cell_id":"a3f9","start_row":72,"end_row":74}
```

**If a claim was already opened for you, `edit_adopt` it instead of everything below.**
See "A prompt sent from the notebook".

**The claim comes first, right after the snapshot — before you read the cell bodies, before
you write a line of code.** That is its whole point: the user is sitting in this buffer, and
the mark is the only thing telling them that a cell is spoken for. A claim opened one second
before the write tells them nothing — from their side an edit still lands out of nowhere
after a long silence.

- Insert a cell: `edit_begin({after = "a3f9"})`; without `after` it goes to the end. The
  language is inherited from the neighbouring cell. The body is written with the same
  `edit_apply`. Claim it the moment you know where the new cell goes — a ghost line appears
  in the buffer, and the user knows something is coming.
- Changed your mind: `edit_cancel(token)`. Open claims — `:JupyterEdits`; clear them all
  with `!`.

**A claim has a lifetime.** The mark counts its own age (`✎ Claude · 2м10с`), and after five
minutes with no word it is dropped by itself — an agent that crashed, hit a limit or went off
to ask a question never sends a `cancel`, and a mark that outlives it lies to the user about
the cell being taken.

- Thinking longer than that, or going into a long step (a query, a big read, waiting for the
  user): `edit_touch(token)` — "still here". It restarts the countdown and is the only way to
  hold a claim open past its lifetime.
- **Asking the user something, or dropping the task: `edit_cancel` first.** Your question may
  hang there for an hour; the mark must not.
- `{"ok":false,"reason":"expired"}` on apply means the claim was dropped by time, not that
  you got the token wrong: re-read the snapshot, open a new claim, redo the edit.
- **A cell you are holding will not run.** `exec:run_at` on it returns `nil` and the user
  sees `запуск отклонён` — its code is about to change, so the output would be from a
  version that is already gone. Apply the edit first, then run.

```sh
# still thinking — restart the countdown
nvim --server "$SOCK" --remote-expr 'luaeval("vim.json.encode(require(\"jupyter\").edit_touch(1))")'
```

**Only a code cell can be inserted.** The language comes from the neighbour
(`cells.insert`) and cannot be set — `edit_begin` silently ignores `lang`, `cell_type` and
the like, still returns `ok`, and puts a plain ```` ```<neighbour's language> ```` in the
buffer. Markdown inserted this way therefore lands inside a code fence: it never appears in
the snapshot, and the next Run All fails on it. Prose is the user's job — ask them to add
the heading, or give the text in your reply, or write it into the task's `.md` note. Never
leave markdown in a code fence silently: that is a broken document, not a cosmetic detail.

**Never write magics into the body.** The fence carries the language, and the magic's
parameters live in its info string: ```` ```sql magic_args="df_name=orders" ````. The plugin
prepends `%%sql` itself (`cells.text`) and skips that when the body already starts with
`%%` — which is why a hand-typed magic seems to work, until jupytext adds its own on save
and the `.ipynb` ends up with `%%sql` twice. `edit_apply` writes the body only, never the
info string: if `df_name`, `limit=0` or `cache` are needed, ask the user to run
`:JupyterCellArgs df_name=orders` on that cell (no arguments opens the current ones).

**Rejections must not be worked around.** `{"ok":false,"reason":"changed"}` means the user
edited that cell themselves while you were thinking: re-read the snapshot, redo the edit,
open a new claim. `cell_gone` — the cell is no longer there. Never push a rejected edit
through `nvim_buf_set_lines` using the old line numbers: that is exactly the case the
rejection exists for.

An agent's edit is a separate undo step, and it moves neither the cursor nor insert mode.

## Running

```sh
# run the cell whose body starts at line 67; the cursor is left alone
nvim --server "$SOCK" --remote-expr 'luaeval("(function() local jn = require(\"jupyter\") local s = jn.ensure_started() s.exec:run_at(s.buf, 67) return \"sent\" end)()")'
```

Then poll the snapshot until the cell loses `running` and `last.run_id` grows (in Claude
Code, wait with Monitor and an until-condition, not with `sleep`). Take the result from
disk, as above.

The first run of a new cell **modifies the document**: the plugin writes `jncell="…"` into
the marker. That is expected, but it means "just running it" is a buffer change too.

The commands in full (for a human, not for you): `:JupyterRun`, `:JupyterRunAll`,
`:JupyterRunBelow`, `:JupyterInterrupt`, `:JupyterRestart`, `:JupyterTable`,
`:JupyterSnapshot`, `:JupyterEdits`, `:JupyterLog`, `:checkhealth jupyter`.

## The kernel directly

Needed when the output is not on disk (eaten by a table) or you want a slice of a variable
already in memory. It is the **user's working kernel**, so ask for permission first; the
client code and the rules are in `reference.md`.

## What not to do

- **Do not write to the notebook file** (`.ipynb` or the jupytext `.md`) while it is open
  in nvim: their `:w` will overwrite your edit, and your write will overwrite what they
  have not saved. Edits go through `edit_begin`/`edit_apply`.
- **Do not use `--remote-send`** (sending keys): it moves the cursor, and it turns into
  garbage if the user is in insert mode. Only `--remote-expr` and the API by buffer number.
- **Do not move the cursor.** Everything you need takes a buffer and a line; read the
  cursor to see where the user is, but never reposition it.
- **Do not reason away a `stale` output.** If the snapshot says the code changed after the
  run, that is a fact, not noise.
