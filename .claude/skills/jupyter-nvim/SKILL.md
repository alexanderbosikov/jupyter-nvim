---
name: jupyter-nvim
description: Read and edit a .ipynb the user has open in nvim via the jupyter.nvim plugin: snapshot of cells and runs, results from .jupyter-out (parquet/txt/png), safe edits to the live buffer, running cells. Also any prompt that starts with `[jupyter.nvim]` — it was sent from that notebook. Do NOT use mcp__jupyter__* for these — it needs a Jupyter Server.
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

Per cell the snapshot gives: `id` (the `jncell` from the fence — a cell made by the plugin's
insert/split/to-code commands or by your `edit_replace` has one from the start; one the user
typed or pasted by hand gets it at its first run or at your first `edit_replace` touching
it), `lang`,
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
[jupyter.nvim] mda-3957-review/01_eda.ipynb · ячейка a3f9 · python · строки 67–74
вывод: .jupyter-out/01_eda/a3f9/7.parquet · table · 1204×8 · устарел: код правили после прогона
```

The first line names the notebook as `<its directory>/<file>` and the piece of it the
prompt is about — what the user pointed at:

| first line ends with | the user | what is claimed |
|---|---|---|
| `ячейка a3f9 · python · строки 67–74` | had the cursor in that cell | the cell |
| `… · выделено 70–72 — речь про этот кусок` | selected part of the cell | the cell (whole) |
| `строки 40–74: проза и ячейка a3f9` | selected text, cells, or both; or had the cursor in a paragraph (`проза`) | those lines, cells widened to whole |
| `весь ноутбук` | asked about the whole notebook, or the cursor was on a blank line | nothing |

`вывод:` lines (`вывод a3f9:` when there are several cells) are relative to the notebook's
directory; at most three, the rest are in the snapshot.

**The full path, the socket and the claim's number are in your pane's file**, not in the
prompt. The plugin writes them to `~/.local/state/nvim/jupyter/panes/<pane>.json` on every
send, and the pane is yours — its id is in your environment. One entry per notebook
(several nvims may send to one pane): take the one whose path ends with the name from the
header, the latest `at` on a tie. Read it again for every `[jupyter.nvim]` prompt, do not
reuse a socket or a claim from earlier in the session — nvim may have been restarted since.

```sh
F="${XDG_STATE_HOME:-$HOME/.local/state}/nvim/jupyter/panes/${TMUX_PANE:-$HERDR_PANE_ID}.json"
{ read -r NB; read -r SOCK; read -r CLAIM; } < <(python3 -c '
import json, sys
entries = json.load(open(sys.argv[1]))
at, nb, e = max((e["at"], nb, e) for nb, e in entries.items() if nb.endswith("/" + sys.argv[2]))
print(nb); print(e["socket"]); print(e.get("claim") or "")' "$F" "mda-3957-review/01_eda.ipynb")
```

If the header itself carries `ноутбук:`, `сокет nvim:` (and `заявка:`) lines, the plugin
could not write that file — use them as they are. No file and no such lines: fall back to
Step 0.

**The claim is already open — do not open another one.** The plugin put the mark on that
piece the moment the user pressed the key: it has been visible since before you read the
prompt, and the cells inside will not run while it is there. Edit with `edit_replace`
(below) — edits that land inside the claim keep it alive and turn its label from
`отправлено` to `агент`. **When you are done, `edit_done($CLAIM)`** — that is what removes
the mark and lets the cells run again. Done includes "nothing to change" and "I answered in
words": the mark goes either way.

```sh
nvim --server "$SOCK" --remote-expr "luaeval('vim.json.encode(require(\"jupyter\").edit_done($CLAIM))')"
```

Whether the user wants the cell rewritten, a new cell after it, prose fixed, or nothing
changed at all — that is in the prompt, not in the claim. The claim only says *where*.

## Editing

**One operation for everything: `edit_replace(old, new)`.** Prose, a cell's code, several
cells with text between them, a new cell, a deleted cell — all the same: find `old` in the
buffer, put `new` in its place. It works like your own Edit tool:

- `old` must occur in the buffer **exactly once** — `not_found` / `ambiguous` otherwise,
  and nothing is written. That match is also the check that the user did not change this
  text while you were thinking: if they did, `old` is no longer there. Re-read and redo.
- `old` and `new` go in **files**, not inline in the command — no escaping of quotes and
  newlines. A trailing newline at the end of the file is dropped.
- Always pass `notebook = "$NB"`: the current buffer is whatever the user is looking at.

```sh
cat > /tmp/jn-old <<'TXT'
Вывод: всё сходится.
TXT
cat > /tmp/jn-new <<'TXT'
Вывод: расходится на 3% — разница в часовом поясе.
TXT
nvim --server "$SOCK" --remote-expr "luaeval('vim.json.encode(require(\"jupyter\").edit_replace_files(\"/tmp/jn-old\", \"/tmp/jn-new\", {notebook = \"$NB\"}))')"
# → {"ok":true,"start_row":42,"end_row":42}
```

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
at it. `text` is a piece that occurs once — the claim covers its lines, widened to whole cells.

```sh
nvim --server "$SOCK" --remote-expr "luaeval('vim.json.encode(require(\"jupyter\").edit_claim({text = \"Вывод: всё сходится.\", label = \"Claude\", title = \"переписываю вывод\", notebook = \"$NB\"}))')"
# → {"ok":true,"token":3,"kind":"range","start_row":42,"end_row":42,"cells":[]}
# … edit_replace …, then edit_done(3)
```

`claimed` means that piece already has a claim (its `token` is in the answer) — usually the
one the plugin opened for the user's prompt: work in it, do not open another.

**A claim has a lifetime.** The mark counts its own age, and after five minutes with no
word it is dropped by itself — an agent that crashed or went off to ask a question never
sends `done`, and a mark that outlives it lies to the user. Every `edit_replace` inside the
claim restarts the countdown; thinking longer without editing, `edit_touch(token)`.
**Asking the user something, or dropping the task: `edit_done` first** — your question may
hang there for an hour; the mark must not.

**Cells inside a claim will not run** (`запуск отклонён`): their code is about to change.
Finish the edits, `edit_done`, then run.

**Rejections must not be worked around.** Never push a rejected edit through
`nvim_buf_set_lines` / `nvim_buf_set_text` yourself: that is exactly the case the rejection
exists for.

An agent's edit is a separate undo step (with the ids it assigned), and it moves neither the
cursor nor insert mode. Open claims — `:JupyterEdits`; clear them all with `!`.

The older cell-only calls (`edit_begin`, `edit_adopt`, `edit_apply`, `edit_delete`) still
work, but `edit_replace` does everything they do; do not mix the two on one piece.

**Never write magics into the body.** The fence carries the language, and the magic's
parameters live in its info string: ```` ```sql magic_args="df_name=orders" ````. The plugin
prepends `%%sql` itself (`cells.text`) and skips that when the body already starts with
`%%` — which is why a hand-typed magic seems to work, until jupytext adds its own on save
and the `.ipynb` ends up with `%%sql` twice. Do not edit `magic_args` in a fence line yourself — if `df_name`, `limit=0` or `cache` are needed, ask the user to run
`:JupyterCellArgs df_name=orders` on that cell (no arguments opens the current ones).

## Running

```sh
# run the cell whose body starts at line 67; the cursor is left alone
nvim --server "$SOCK" --remote-expr 'luaeval("(function() local jn = require(\"jupyter\") local s = jn.ensure_started() s.exec:run_at(s.buf, 67) return \"sent\" end)()")'
```

Then poll the snapshot until the cell loses `running` and `last.run_id` grows (in Claude
Code, wait with Monitor and an until-condition, not with `sleep`). Take the result from
disk, as above.

The first run of a cell that has no `jncell` yet — one the user typed or pasted by hand —
**modifies the document**: the plugin writes `jncell="…"` into the marker. That is expected,
but it means "just running it" is a buffer change too. Cells made by the plugin's commands or
by your `edit_replace` already carry their id, and running them writes nothing.

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
  have not saved. Edits go through `edit_replace`.
- **A write to the `.ipynb` never reaches the open buffer** (it was converted by jupytext
  when opened), so it looks like it worked and is gone at the next save. Prose is edited
  with `edit_replace` like everything else.
- **Do not use `--remote-send`** (sending keys): it moves the cursor, and it turns into
  garbage if the user is in insert mode. Only `--remote-expr` and the API by buffer number.
- **Do not move the cursor.** Everything you need takes a buffer and a line; read the
  cursor to see where the user is, but never reposition it.
- **Do not reason away a `stale` output.** If the snapshot says the code changed after the
  run, that is a fact, not noise.
