# jupyter.nvim

Working with Jupyter notebooks in nvim: cells are plain text, the kernel lives in a
separate process, outputs are stored outside the document.

Three decisions everything else follows from:

- **Output is text in a buffer, not virtual text.** It can be copied, searched and
  scrolled with the editor's own tools.
- **The document stays code.** Neither outputs nor images end up in the `.ipynb`: they
  live next to it, in `.jupyter-out/`. Diffs stay readable, the file does not grow.
- **A dataframe result is saved as parquet.** A table of hundreds of thousands of rows
  does not turn into megabytes of HTML; it is paged through instead of being read whole.

The plugin's own messages are still in Russian. Sample output below is quoted exactly as
the plugin prints it, with a translation where it matters.

## Requirements

- Neovim 0.10+
- Python with `jupyter_client`, `ipykernel` and (for tables) `polars`
- [image.nvim](https://github.com/3rd/image.nvim) — optional, for images
- [jupytext.nvim](https://github.com/GCBallesteros/jupytext.nvim) — if you work with `.ipynb`

**About `.ipynb` and filetype.** `jupytext.nvim` sets `ft=markdown` on the buffer once, in
its own `BufReadCmd`. But nvim re-decides the filetype on **every** `BufRead` from the file
name, and `*.ipynb` in its detection is `json`. The event fires on more than opening: netrw
on `:Ex` triggers `BufRead` on the buffer currently in the window. Open a notebook, step
into `:Ex`, come back — and cells stop being recognised, while the plugin writes
«представление fence при filetype=json» into `:JupyterLog`. Cured by one line in the
config, before `require("jupytext").setup`:

```lua
vim.filetype.add({ extension = { ipynb = "markdown" } })
```

**One more thing worth knowing about jupytext.nvim.** It puts the conversion result into
`<name>.md` next to the notebook and, if that file already exists, **does not convert
again** — it reads it without comparing timestamps (`init.lua:81`). Normally such a file is
treated as temporary and removed when the buffer closes, but one that survives — after a
crash, or created by hand — becomes permanent. From that moment nvim shows it instead of
the notebook: edits made in Jupyter Lab are invisible, and `:w` overwrites them with stale
content. The plugin has nothing to do with this and cannot help — it is handed a
ready-made buffer. Cured by an autocommand that drops the cache when the notebook is newer:

```lua
vim.api.nvim_create_autocmd("BufReadCmd", { -- BEFORE jupytext.setup(): registration order
    pattern = "*.ipynb",
    group = vim.api.nvim_create_augroup("JupytextDropStaleCache", { clear = true }),
    callback = function(ev)
        local notebook = vim.fn.resolve(vim.fn.expand(ev.match))
        local cache = vim.fn.fnamemodify(notebook, ":r") .. ".md"
        if vim.fn.filereadable(cache) == 1 and vim.fn.getftime(cache) < vim.fn.getftime(notebook) then
            vim.fn.delete(cache)
        end
    end,
})
```

## Installation

```lua
{
    "alexanderbosikov/jupyter-nvim",
    ft = { "python", "markdown" },
    main = "jupyter",
    init = function()
        -- the interpreter the sidecar is started with
        vim.g.jupyter_python = vim.fn.expand("~/.venvs/jupyter/bin/python")
    end,
    opts = {
        kernel_name = "python3",
        output = { position = "right", size = 0.5 },
    },
}
```

Check the environment with `:checkhealth jupyter` — the interpreter, library versions, the
handshake with the sidecar, the presence of a kernelspec and of image.nvim. The same report
covers the run history of the open notebook: its weight and the cells that are no longer in
the document (see "Where outputs live").

## Keys and commands

The default maps are set buffer-locally and are replaced wholesale through `opts.keys` (a
value may be a string or a list of keys); `keys = false` turns them off entirely.

| action | default |
|---|---|
| run cell | `<leader>jc` |
| run all / from the current one down | `<leader>jA` / `<leader>jB` |
| cell above / below | `<leader>ja` / `<leader>jb` |
| next / previous cell | `]c` / `[c` |
| output window | `<leader>jo` |
| table, page by page | `<leader>jt` |
| previous / next run of this cell | `[r` / `]r` |
| notebook outline | `<leader>jT` |
| interrupt / restart the kernel | `<leader>ji` / `<leader>jR` |
| cell as a text object | `ic` — the body, `ac` — with the marker |
| magic arguments of the cell | `<leader>jg` |
| ask the agent about this cell | `<leader>jq` (in visual — about the selection) |
| split / join cell | `<leader>js` / `<leader>jM` |
| move cell up / down | `<leader>jK` / `<leader>jJ` |
| to markdown / back to code | `<leader>jm` / `<leader>jy` |
| cell language: python ↔ sql | `<leader>jl` |
| start / end of the current cell | `[C` / `]C` |

The text objects work in visual mode and with operators: `dic` clears the cell and leaves
the marker, `yac` yanks it whole, `vac` selects it. The selection is linewise — a cell is
always whole lines. They are configured separately from the other keys because they live in
other modes: `textobjects = { inner = "ic", around = "ac" }`.

Commands: `:JupyterRun`, `:JupyterRunAll`, `:JupyterRunBelow`, `:JupyterOutput`,
`:JupyterTable`, `:JupyterRunPrev`, `:JupyterRunNext`, `:JupyterInterrupt`,
`:JupyterRestart`, `:JupyterHistory`, `:JupyterToc`, `:JupyterRepaint`,
`:JupyterClearImages`, `:JupyterLog`, `:JupyterStatus`, `:JupyterStop`,
`:JupyterOrphans` (with `!` — clear them), `:JupyterAttach`, `:JupyterRelease`,
`:JupyterCellArgs`, `:JupyterCellLang`, `:JupyterCellStart`, `:JupyterCellEnd`,
`:JupyterSnapshot`, `:JupyterEdits` (with `!` — clear them),
`:JupyterRecover` (with `!` — discard the drafts).

In the output window: `t` — table page by page, `y` — copy the output, `c` — clear,
`q` — close.

In the table window: `H`/`L` — pages, `[[`/`]]` — the edges, `R` — re-read, `q` — close the
tab, `s`/`S` — sort by the column under the cursor, ascending or descending, `c` — drop the
sorting, `y` — copy the page shown, `Y` — the whole result, `<CR>` — copy the cell under the
cursor.

What is copied is TSV — a header and rows, tab-separated, no borders and no alignment:

```
event_date	uids	users
2026-09-08	3181	2941
2026-09-09	751	726
```

Tabs are exactly what Slack, Google Sheets and Excel turn into a table on paste, while
borders and padding would have to be cleaned out by hand. The text goes into both the
unnamed register and the system one (`+`) — otherwise copying would lose its whole point,
and not everyone has `clipboard=unnamedplus`; if there is no clipboard provider, the plugin
says so out loud. `Y` reads the whole file in the current sort order, and above 50 thousand
rows it asks first: a register is not a file. `y` in the output window copies what is in the
window, that is the preview (`output.preview_rows`), and for a table run it says so.

`<CR>` copies a single cell — the **whole** value, not what is drawn. In the table a value is
clipped to `max_col` (`…` at the end): the columns have to line up within the width of the
window, and long text has nowhere to go there. The clipping is drawing only — the value is
taken from the data, exactly like `y`/`Y` take it. Control characters stay escaped (`\n`),
the way the sidecar handed them over: they cannot be told apart from a real backslash in the
data. The plugin says which column and which row of the dataset has been copied.

Sorting accumulates: every next column becomes the primary key, and the ones chosen earlier
stay as tie-breakers. Sort by platform, then by day, and you get an order by day with the
order by platform preserved inside each day. The current order is visible in the status
line; the sorting is done by the sidecar on the parquet side, so paging stays consistent:
page 2 continues page 1.

## Cells

Two representations of the same notebook are understood:

- **percent** — a `.py` with `# %%` markers; `# %% [markdown]` cells are skipped;
- **fenced** — markdown after jupytext; a code cell is ```` ```python ````, and so is a
  fence carrying a magic's language (```` ```sql ````) — jupytext stores such a cell with
  `magic_args` in the info string, and the `%%sql` line is assembled back at the moment the
  cell is sent to the kernel.

A magic's arguments live **on the fence line**, not in the body:

````
```sql magic_args="df_name=orders limit=0"
select 1
```
````

Change a cell's language with `<leader>jl` (toggles python ↔ sql) or `:JupyterCellLang
sql`. Magic arguments are set by `:JupyterCellArgs df_name=orders limit=0` and removed by
the same command with no arguments. `<leader>jg` asks for them in a prompt pre-filled with
the current ones — deliberately separate from the command: conflating "ask" and "remove"
under one name means wiping the arguments with a keystroke one day. Do not type `%%sql
df_name=...` as the first line of the body: the plugin will run such a cell correctly (it
will not prepend the magic twice), but jupytext will add its own on save, and the `.ipynb`
will end up with `%%sql` twice.

## Restructuring cells

`<leader>js` cuts the cell at the cursor: the line under it and everything below move into a
new one. The first half keeps its id and its magic arguments — its code changed, so an
honest `⚠ код изменился` ("the code was edited") appears under it; the second half gets its
own id on its first run.

`<leader>jM` joins the cell with the next one. If there is text between them, or their
languages differ, it refuses with an explanation: joining "through" prose would lose the
prose silently.

`<leader>ja` and `<leader>jb` insert a cell above and below — **in the same language as the
neighbouring one**: after an sql cell comes an sql cell. Magic arguments are not copied
along: `df_name` on two cells at once is a name collision, not a convenience.

`[C` and `]C` put the cursor at the start and the end of **its own** cell. A counterpart to
`]c`/`[c`, which walk to the neighbours: from the middle of a cell there was no way to get
back to its start or to append at its end — you had to jump to the next cell and come back
through a blank line and a closing fence.

`<leader>jK` and `<leader>jJ` swap the cell with the neighbouring **code cell**. Prose
between them stays where it is: the document does not drift apart, and the rule is
explained in one sentence.

`<leader>jm` turns a cell into markdown, `<leader>jy` turns the paragraph under the cursor
back into code. In the percent representation that means commenting out the body and a
`# %% [markdown]` marker; in markdown it means removing and restoring the fences.

`<leader>jl` changes a cell's language: with no argument it toggles python ↔ sql,
`:JupyterCellLang python` sets it explicitly. There are two mechanics because there are two
representations: in fences the language is a word in the info string, and `%%sql` is
assembled from it when the cell goes to the kernel, so the fence is edited and the body is
left alone; in percent there is no fence at all, the magic lives on the first line of the
body — so the body is edited. On the way to python, `magic_args` are dropped: they mean
nothing on a ```` ```python ```` fence, and in the `.ipynb` they would end up as junk in
the cell metadata. If the body starts with a foreign magic (`%%timeit`), the command refuses:
the cell would look like sql while `%%timeit` went to the kernel.

Each operation is a single buffer edit, so one `u` undoes it. The commands are the same:
`:JupyterSplit`, `:JupyterMerge`, `:JupyterMoveUp`, `:JupyterMoveDown`,
`:JupyterToMarkdown`, `:JupyterToCode`.

## Outline

`:JupyterToc` shows the notebook's structure as a list: markdown headings and cells — the
first meaningful line of code together with the state of its run.

```
# Loading data
    df = load()                    ✓ 0.7 с · 1240 × 7
  ## Checks
    sql: select count(*) from t    ⟲ ✓ 3.4 с · 04.09 12:16
    plt.plot(x, y)                 не запускалась
```

(`не запускалась` — "never run", `⟲` — a run from history.)

Navigation and an overview of state in one place: you see where you are, what has been
computed, what failed and what has never been run. For a cell with a magic the query itself
is shown, not the magic line — otherwise, in a notebook made of `%%sql`, every entry would
look the same.

The list is shown through telescope if it is installed: fuzzy search over code and state
plus a preview of the section's contents. There is no dependency on telescope — without it
the built-in `vim.ui.select` is used. Either way the list appears, does its job and
disappears without taking up screen space.

The preview is drawn from the buffer, not from the file: on disk the notebook is an
`.ipynb`, and a file previewer would show JSON instead of code.

The data is available on its own too — `require("jupyter").toc()`, if you want your own
picker.

## What the plugin writes into the document

On a cell's first run an identifier is appended to its marker:

```
```python jncell="a3f9"      # in the markdown representation
# %% jncell="a3f9"           # in percent files
```

This is the only edit to the document, and ordinary undo reverts it. In the `.ipynb` the id
goes into the cell metadata and survives conversion both ways. The id never goes into the
body of a cell — otherwise it would reach the kernel as part of the code.

Run history is found by this id, including from outside the editor.

## Where outputs live

```
<the notebook's directory>/.jupyter-out/<name>/
    index.jsonl          one line per run: status, time, size, code sha
    a3f9/12.parquet      a dataframe result
    a3f9/13.txt          text output
    b7e1/3.png           an image
    kernel.log           the kernel's own log
    drafts/9812-1.md     an unsaved buffer: insurance against a crash
```

The directory is worth adding to `.gitignore`: a re-run restores it.

Read an output from outside nvim:

```sh
python -m jupyter_nvim.cli notebook.ipynb a3f9          # text
python -m jupyter_nvim.cli notebook.ipynb a3f9 --json   # the index record
python -c "import polars as pl; print(pl.read_parquet('.jupyter-out/notebook/a3f9/12.parquet'))"
```

A run is bound to a cell's id, not to its number, so history survives reordering cells and
editing their neighbours. The flip side: if a cell disappeared from the document — deleted,
joined with a neighbour, marker rewritten — its directory and its lines in `index.jsonl`
stay where they are. Trimming (the last 5 runs) happens only for the cell that was run, so
nothing will ever be trimmed under an orphaned id. The output is not lost: it is read by id
with the same `jupyter_nvim.cli`, provided the id is known. The directory is bound to the
file name as well, so after renaming a notebook the whole history stays under the old name.

How much of this has piled up is shown by `:checkhealth jupyter`:

```
ok   история: 29 ячеек, 50 прогонов, 231 КБ в .jupyter-out/01_eda
warn 1 ячеек с историей нет в документе (1 КБ): 3ab4
info 1 ячеек под порядковым id (3 КБ): такой id в документ не пишется
```

(History: 29 cells, 50 runs, 231 KB. One cell with history is missing from the document;
one cell sits under a sequential id, which is never written into the document.)

Sequential ids get a line of their own for a reason: a cell without a marker has nowhere to
write an id (§7.2 of ARCHITECTURE.md), so the id never was and never could be in the
document — such history is orphaned from birth and says nothing about a lost cell. The
report also names files the index does not reference: usually leftovers of an interrupted
write.

All of this is restored by re-running, so the only cleanup is to delete `.jupyter-out`
entirely; the plugin itself deletes nothing.

## The draft of an unsaved buffer

The buffer you edit is markdown from jupytext; on disk there is an `.ipynb`. Every `:w`
therefore runs an external converter and fires `BufWritePre` for every other plugin: a
formatter reformats the markdown right under the cursor, linters take off, gitsigns
redraws. Saving like that on a timer is out of the question. So is losing work to a crashed
terminal or a forgotten `:w`.

So the plugin writes a draft: after a couple of seconds of idling, the buffer's text goes
as it is into `.jupyter-out/<name>/drafts/<pid>-<n>.md` — with no conversion, past the
notebook file and past everyone else's autocommands. One write costs a `writefile` of a
couple dozen kilobytes. The write is atomic, through a temporary file and `rename`: a crash
in the middle of it leaves no stump. Next to it lies a `.json` with the time, the sha of
the text and the notebook's mtime at that moment.

A draft is dropped not on a "buffer saved" flag but on the fact of it: only once the
notebook file on disk has changed since the draft was written. The difference is not
theoretical. jupytext.nvim clears `modified` in its `BufWriteCmd` right after writing the
intermediate `.md` — before the external converter runs, and regardless of whether it runs
at all. That has already cost a session's work once: the buffer said "saved", the `.ipynb`
held a state half an hour old, and the draft had been dropped as unneeded.

Close it unsaved (`:bd!`, `:q!`, a crash) and the draft stays; the next time the notebook is
opened the plugin says:

```
jupyter.nvim: остался несохранённый черновик 14.09 18:32, строк 214 — :JupyterRecover
```

(An unsaved draft from 14.09 18:32, 214 lines, is still around.)

`:JupyterRecover` offers three actions: show the difference (an ordinary `diffsplit`
against the draft), restore it into the buffer, discard it. Restoring puts the text **into
the buffer** and stops there — the plugin does not write to the file, that call is yours:
`:w` if the draft is the right one, `u` if it is not. `:JupyterRecover!` discards what it
found without asking.

Only buffers backed by a real file are drafted. Otherwise synthetic ones creep in:
otter.nvim keeps a copy of the cells' code in a `<notebook>.otter.py` buffer with
`ft=python`, there is no such file on disk and nowhere to save it — yet it used to get a
directory of its own in `.jupyter-out`.

Next to the drafts lies `drafts/trace.log` — one line per action: a write, a drop, a buffer
closing, the editor exiting. It is appended immediately and therefore survives both `:qa!`
and a crash: everything interesting about a draft happens exactly when `:messages` is no
longer there to ask.

The pid in the file name is not decoration. Two nvims on one notebook is a legitimate case,
and a shared draft would mean the second silently overwriting the first one's unsaved work.
A draft belonging to a live process is not touched at all; only an orphaned one is picked
up — from a process that is already gone. If the notebook has been rewritten from outside
since then (Jupyter Lab), the mtime shows it and the message says so plainly: such a draft
must not be slipped in silently, it would overwrite someone else's work.

This does not replace nvim's swapfile; it covers what the swapfile does not. The swap lies
at the `.ipynb` path, holds markdown, is restored non-obviously and is deleted on a clean
exit — that is, "forgot to save and quit" is exactly the case it does not save you from. A
draft is read with your own eyes: it is ordinary cell markdown.

Separately there is `autosave.write_on_run`: actually saving the notebook before a cell is
run. The moment is right in domain terms — the code that ran is then on disk, and
`code_sha` in the history refers to it and not to a phantom in the buffer. It is off by
default precisely because `:w` calls everyone else's autocommands.

## A snapshot of the notebook for an outside reader

Outputs are read by cell id — but to learn an id, an outside tool has to parse the document
itself: find cell boundaries, pull `jncell` out of the fence, compute the path to
`.jupyter-out`, compare shas. Those are the same rules as inside the plugin, written a
second time, and they diverge on the first edge case — a fence inside a string, the percent
representation, a cell without a marker. So the plugin hands out a ready-made snapshot:
cells already matched with their runs.

```vim
:JupyterSnapshot                  " to a temporary file; it tells you the path
:JupyterSnapshot /tmp/snap.json   " to a specific one
```

From a script, without entering the editor (for the socket address, `:echo v:servername`):

```sh
nvim --server "$SOCK" --remote-expr 'luaeval("require(\"jupyter\").snapshot_json()")'
```

```json
{"notebook": "/…/01_eda.md", "representation": "fence", "modified": false, "lines": 99,
 "out_dir": "/…/.jupyter-out/01_eda",
 "kernel": {"state": "ready", "kernel_name": "jupyter-utils", "connection_file": "/…/tmp0k.json"},
 "cells": [
   {"index": 2, "id": "2c38", "lang": "sql", "start_row": 23, "end_row": 37,
    "span_start": 22, "span_end": 38, "runs": 3, "stale": false,
    "last": {"run_id": 4, "status": "ok", "kind": "table", "rows": 100, "cols": 3,
             "execution_count": 4, "duration_ms": 13833,
             "started_at": "2026-09-11T12:51:27.991377+00:00",
             "path": "/…/.jupyter-out/01_eda/2c38/4.parquet",
             "schema": [["button_id", "String"], ["first_seen", "Date"],
                        ["events_number", "Int64"]]}}]}
```

`stale` answers the reader's main question — does this output belong to the current code;
it comes from the same sha comparison that draws `⚠ код изменился` in the output window.
`running` appears on a cell whose run is going on right now: what is on disk is still last
time's output. Busy is not the same as being computed — "run all" sends every cell at once,
and the kernel takes them one at a time — so the run itself comes as `live`: its `status`
(`queued` or `running`), `run_id`, how many `lines` of output it has produced so far and
`tail`, the last of them. Without that, fifteen cells waiting in the queue looked from
outside exactly like fifteen cells being computed. The path in `last.path` is absolute — the parquet or the `.txt` is read
straight away, with no joining to `out_dir`.

The cells' text is deliberately absent from the snapshot: the whole buffer is taken with a
single `nvim_buf_get_lines`, and the boundaries of every cell are in the snapshot already.
The snapshot itself writes nothing into the document and recomputes nothing — it is a
derived view, and the sources are the same as ever: the buffer and `index.jsonl`.

## Fresh output and old

The output window follows the cursor and shows the run of the cell it stands on, including
runs from history — so yesterday's cell output is visible as soon as the file is opened,
with no kernel started. To keep old output from passing itself off as fresh, marks appear in
the status line: the time of the run (`из истории · 03.09 12:46` — "from history"),
`⚠ код изменился` if the cell's code was edited after the run, and `⏳ ещё N` if computation
is still going on somewhere else.

## Editing the notebook from outside

The snapshot answers "what is in the notebook"; editing answers "here is a new version of
this cell". Writing into the buffer by line numbers is not an option: tens of seconds pass
between an outside reader taking a cell and handing back an answer, and the document is
alive the whole time. So editing is two-phase — a claim, then its application:

```lua
local jn = require("jupyter")
local req = jn.edit_begin({ cell = "a3f9", label = "Claude" })  -- the cell is marked in the buffer
-- ... the agent thinks, you keep working ...
jn.edit_apply(req.token, { "x = 2", "print(x)" })
```

To insert a new cell — `edit_begin({ after = "a3f9" })`, or without `after` (at the end of
the document); the language is inherited from the neighbouring cell, as with `<leader>jb`.
Changed your mind — `jn.edit_cancel(req.token)`.

Between the claim and the application you can do anything: add lines above, reorder cells,
edit the neighbours — the edit will still land in the right place. There are two anchors
because shifts come in different kinds: `jncell` survives a whole cell being moved, an
extmark survives edits above and below. On top of both, the sha of the body is checked, and
this is the important part: **if you edited the cell itself while the agent was thinking,
the edit is not applied**:

```json
{"ok": false, "reason": "changed", "msg": "ячейку правили после заявки, правка не применена"}
```

A cell that is gone answers the same way (`cell_gone`). An edit cannot silently overwrite
what you typed — that is the very reason it is built as something more than "write these
lines".

What is visible in the buffer while a claim is open: the piece being worked on is fenced off
by two virtual lines, above and below, each reading ` ⠋ Claude правит · 1м20с ` — a spinner,
whose name, what they are doing and for how long; the body between them is highlighted like
a selection, and every line of it carries a `✎` in the signcolumn. An insertion has nothing
to fence yet, so it shows a single ghost line where the future cell will be. The lines are
virtual: you cannot put the cursor in them, `:w` does not save them and jupytext never sees
them — the document underneath is untouched.

An insert claim puts its label below the blank line that separates cells — the gap where the
new cell is going to appear — and an insert at the very end of the file gets one blank line
appended to hang from, which goes away with the claim (unless you typed something into it by
then). That is the only case where a claim writes into the document.

The spinner says a timer is alive; the age says the *agent* is. That is why both are there.
After application the inserted text flashes briefly, otherwise a twenty-line edit gets lost
on screen. Open claims are shown by `:JupyterEdits` (with the age and how long is left);
`:JupyterEdits!` clears them all. The wording is `agent.verb` if `правит` is not your taste
(`Implementing` and a 10-frame braille spinner is where this comes from —
[ThePrimeagen/99](https://github.com/ThePrimeagen/99)).

**A claimed cell will not run.** `<leader>jc` on it, or a Run All that walks over it, says
`ячейку правит Claude — запуск отклонён` and skips it: the code is about to be replaced, so
the output would belong to a version that will not exist a second later — and it would go
into the history as if it did. Insert claims block nothing; there is no cell yet.

A claim does not outlive the agent. With no word for `agent.ttl_ms` (five minutes by
default) it is dropped by itself, the label turns to a warning colour beforehand, and the
plugin says so out loud — a crash, an exhausted limit or a question asked and never returned
from produces no `cancel`, and a mark left behind claims a cell nobody is working on. An
agent that thinks longer than that says so with `edit_touch(token)`, which restarts the
countdown; an `apply` after the deadline answers `reason: "expired"` — open a new claim and
redo the edit.

An agent's edit is a separate undo step: one `u` rolls it back without taking away what you
typed at the same moment. The cursor does not move: it holds on to text, not to a line
number.

## Asking the agent from the notebook

The other direction: `:JupyterAsk` (`<leader>jq`) opens a small window, you type a prompt,
and it goes to the Claude Code session living in a tmux pane next to nvim.

```
:JupyterAsk                      a window to type in; about the cell under the cursor
:JupyterAsk rewrite with polars  the same, in one line
:JupyterAsk!                     about the whole notebook — nothing is claimed
<leader>jq                       from visual — about the selected lines
:JupyterAgentAttach              pick the pane by hand
```

**What the agent gets along with the text** is the address: the notebook, the nvim socket,
the id of the cell under the cursor with its language and boundaries, the path to that
cell's last output and whether it is stale. That is the whole point — you stop describing in
words which cell you mean, and the agent stops spending turns looking for what you are
already looking at.

**The mark appears the moment you press the key**, not when the agent gets round to reading.
It is the same claim as in the section above (`✎`, a frame, a ticking age) with the first
line of your prompt as its title, and it holds the cell the whole time — the cell will not
run while it is spoken for. The agent takes that claim over instead of opening its own, and
it is the agent who decides what the edit is: rewrite this cell, or add a new one after it —
that is in your prompt, not in the claim. If the prompt fails to go out, the claim is
dropped at once: a mark with nobody behind it is worse than no mark.

The pane is found by itself: the one remembered for this notebook, otherwise the one next to
nvim in the same window, otherwise the only one in this tmux session, otherwise by the
notebook's directory. Only when that is still ambiguous does it ask — `:JupyterAgentAttach`
shows every pane running `claude` with its directory, and the choice is remembered in
`.jupyter-out/<notebook>/agent.json`. Prompts themselves are kept next to it in
`prompts.jsonl` — the same idea as run history, for remembering what you actually asked.

The plugin never starts a session for you: yours is already open, and guessing where a new
one should go is not its business. No `claude` in any pane — it says so and does nothing.

One thing is written into the document: a cell with no `jncell` yet gets one, because
otherwise there is nothing to name to the agent. The plugin does this at the first run
anyway.

The output window belongs to the notebook, not to the screen: every buffer has its own
session. Open another notebook in the same window and the first one's output window goes
away, because its document is no longer in sight; come back to it and the window returns
with the last run. Two notebooks side by side in splits or in different tabs keep both
windows: both documents are in sight there. A window closed by hand does not pop back up by
itself, and a run in a hidden notebook does not raise the window — it waits for you to come
back, rather than barging in over someone else's document.

The session is untouched through all of this: the kernel works, variables are alive, the
queue moves, history accumulates, the statuses under cells update. You can switch between
notebooks with anything — `:e`, telescope, harpoon, a file manager — the buffer is hidden,
not unloaded. Closing a notebook's buffer (`:bd`), on the other hand, means putting out its
kernel: a session lives exactly as long as its buffer.

Under every cell that has been run a status line is drawn: the time, the size of the table,
the exception's name, `⟲` for a run from history and `[12]` — the kernel's counter, the very
`In [12]` from Jupyter Lab (an unfinished run has no number yet, it shows `[*]`). While a
run is going on it says `⏳ выполняется` ("running") — and only on the cell the kernel is
actually computing; the rest from "run all" honestly show `⏳ в очереди` ("queued"). The
time in the status is working time; waiting in the queue is not part of it.

A table from history — both its preview in the output window and the paged view — is read
by the sidecar: polars lives there, not in nvim. So opening a notebook that has a table in
its history starts the sidecar by itself. The kernel is not started with it: these are
different processes, and the kernel's laziness still holds.

## Settings

```lua
opts = {
    kernel_name = "python3",
    python = nil,                    -- defaults to vim.g.jupyter_python
    env = {},                        -- environment variables for the kernel
    filetypes = { "python", "markdown" },
    out_dir = ".jupyter-out",
    keep_kernel_on_exit = false,     -- true: quitting leaves the kernel alive, :JupyterAttach to come back
    center_on_jump = true,           -- jumping between cells centres the screen
    insert_on_new_cell = true,       -- a freshly inserted cell goes straight to insert; it is empty anyway
    images = true,
    highlight = true,                -- own highlight groups for the winbar
    text_progress = true,            -- ask the kernel for a text progress bar, not a widget one
    output = {
        position = "bottom",         -- or "right"
        size = 15,                   -- below one it is a fraction of the screen
        follow_cursor = true,
        preview_rows = 30,           -- rows of the table shown in the output window itself
        open_on_attach = false,      -- open the window when a notebook is opened
    },
    table = { page_size = 100, max_col = 40 },
    status = { enabled = true, position = "below" },
    autosave = {
        draft = true,                -- draft of the unsaved buffer
        debounce_ms = 2000,          -- how much idling before it is written
        write_on_run = false,        -- :w before a cell is run
        write_on_focus_lost = false, -- :w when the editor loses focus
    },
}
```

`text_progress` is about `tqdm`. In a kernel with `ipywidgets` installed `tqdm.auto` draws
its bar as a widget: one frame when it is created, and every update after that goes over the
widget protocol, which a terminal client has no runtime for. A cell looping over a hundred
queries then shows `0%` from the first second to the last and looks stuck. So on startup the
plugin asks the kernel for the text bar instead — the one made of `\r`, which the output
window redraws in place. `false` leaves the kernel alone, and the bar then does not move at
all.

## Kernels and leaving the editor

By default quitting puts the kernel out but does not hold the editor up: the plugin closes
the sidecar's stdin and leaves, and the sidecar puts the kernel out itself — a polite
`shutdown_request` with a one-second deadline, then `SIGTERM` and `SIGKILL`. Waiting for it
to finish would cost 1.9 s on every exit.

The kernel can also be **left alive**: `:JupyterRelease` releases it right now, and
`keep_kernel_on_exit = true` makes that the rule for every exit. Restarting the editor then
stops costing you state: `:JupyterAttach` brings back the same kernel together with its
memory. It is off by default on purpose — a forgotten kernel holds memory and connections,
and noticing it is harder than losing it.

While a kernel is alive, a `runtime.json` lies next to the outputs with the pids of the
sidecar, the kernel and the editor. It is there for the case where the sidecar died an
unnatural death — `SIGKILL`, a crashed interpreter, a terminal killed mid-word — and did
not manage to put the kernel out. A live file with a dead sidecar then means a kernel with
no owner. The plugin says so when the notebook is opened; see them all with
`:JupyterOrphans`, clear them with `:JupyterOrphans!`; the same shows up in
`:checkhealth jupyter`. No daemons and no process watching are kept for this: the check is
reading a single file that usually is not there.

Such a kernel can be met with more than an axe — you can attach to it: `:JupyterAttach`
takes it over together with its memory. This is the way to survive an editor restart: heavy
frames from a long query stay where they are instead of being computed again. The plugin
offers it by itself when it finds a live kernel while opening a notebook.

An attached kernel is someone else's process, so it is managed through its pid: `is_alive`
on a `KernelManager` with no provisioner always answers "no", `interrupt_kernel` raises,
and `shutdown_kernel` leaves the kernel alive. Restarting such a kernel means putting out
someone else's and starting your own — which, from the outside, is exactly what "restart"
is expected to do.

A kernel answering to someone else's pid is not touched: identification goes by the path of
the connection file in the process's command line, not by a number alone.

## Known issues

**Joining cells loses one of them silently.** A miss by a couple of lines across the
boundary (`3dd`) removes the marker line, and two cells become one. The plugin does not
notice. The surviving half is the one whose marker stayed: its id, history and status stay
with it, and only the status gets `⚠ код изменился`, because the body of the cell is
different now. The second half is gone: on save the `.ipynb` loses it together with the
outputs Jupyter Lab sees, and its code cannot be restored from anywhere — the plugin's
history holds only a `code_sha`, not the code itself. While the buffer is open, `u` saves
you. The outputs of the vanished cell stay in `.jupyter-out` and are read by id (see "Where
outputs live").

**Images outlive their output.** The plugin shows them through image.nvim, which keeps what
it has shown in its own state and redraws it on every scroll. An image sometimes stays on
screen after you move to another cell or switch a tmux window; `Ctrl-L` helps. The cause is
outside the plugin — the kitty protocol over tmux.

**Ripple next to concealed lines.** Lines under the cursor sometimes double or disappear,
and `Ctrl-L` cures it. The cause is not in the plugin: nvim (0.12.5) gets confused while
scrolling when a virtual line is attached below a line that is followed by a line concealed
entirely — which is how render-markdown hides a cell's closing fence. The status under a
cell no longer steps on this (it attaches to the next line, see §5.1 of ARCHITECTURE.md),
but the "an agent is editing this cell" mark still can, as can virtual lines from any other
plugin.

**Runs are not cancelled one by one.** `interrupt` hits the kernel as a whole: the current
cell goes down and so does everything queued behind it.

**One kernel per notebook.** A long cell delays the ones after it — they wait in the
kernel's queue. They show `⏳ в очереди`, the working one shows `⏳ выполняется`, and the
output window shows the counter `⏳ ещё N`.

**The representation is chosen by heuristic.** Percent or fences is decided by the
filetype, and with a foreign filetype by the buffer's text (a percent marker, otherwise an
opening fence). A file mixing both will be parsed differently than its author expects. When
the representation had to be guessed, the plugin says so out loud and writes the details
into `:JupyterLog`.

## Tests

The sidecar is pytest; the interpreter is given by an environment variable:

```sh
cd sidecar && PYTHONPATH=. python -m pytest -q
```

Lua is plenary in headless nvim; some of the tests bring up a real sidecar and kernel:

```sh
JUPYTER_NVIM_PYTHON=~/.venvs/jupyter/bin/python ./tests/run.sh
./tests/run.sh tests/cells_spec.lua    # a single file
```

The design and the decisions behind it are in [ARCHITECTURE.md](ARCHITECTURE.md), the
development environment and the work queue in [CONTRIBUTING.md](CONTRIBUTING.md).
