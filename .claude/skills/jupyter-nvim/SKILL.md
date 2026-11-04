---
name: jupyter-nvim
description: Work with a .ipynb through the user's nvim (jupyter.nvim plugin) — one they have open, or one you created and need to run: open it there yourself and start the kernel, snapshot of cells and runs, results from .jupyter-out (parquet/txt/png), safe edits to the live buffer, running cells and waiting for them. Also any prompt that starts with `[jupyter.nvim]` — it was sent from that notebook. Do NOT use mcp__jupyter__* for these — it needs a Jupyter Server.
---

# A notebook open in nvim (jupyter.nvim)

Plugin: `~/Projects/jupyter.nvim`. The notebook in nvim is a live buffer in markdown
(jupytext); the plugin starts the kernel itself, and outputs live **outside** the document,
in `.jupyter-out/`. **MCP jupyter does not work here**: `mcp__jupyter__*` addresses a Jupyter
Server, where the plugin's kernels never show up.

The everyday path is below. Topic files lie next to this file — **read the file before
doing what its row names**; the rules marked ❗ apply even without reading it.

| Read before… | File |
|---|---|
| answering a prompt that starts with `[jupyter.nvim]` | `prompt.md` |
| a `jn` refusal you don't recognise (`other_instance`, exit 4), creating a new notebook, `visible: false` / `other_instances` in the snapshot | `session.md` |
| interpreting snapshot fields (`stale`, `running`, `live`, `last.outputs`), reading parquet/png/text results, a cell's earlier runs | `reading.md` |
| any edit: `jn replace`, `jn insert`, deleting cells, opening a claim yourself, magics / `magic_args` | `editing.md` |
| `jn run` / `jn wait`, its exit codes and refusals, «не выполнялись ячейки выше», long (Redshift) runs | `running.md` |
| reading outputs with no nvim at all; touching the user's kernel directly (`explain` with notebook params) | `reference.md` |

❗ Rules that hold everywhere:
- **Everything goes through `jn`** (`~/Projects/jupyter.nvim/bin/jn`, any `python3`), always
  with the notebook's path. No hand-rolled `nvim --remote-expr`, no `--remote-send` (keys),
  no `nvim_buf_set_lines`, never "the current buffer".
- **Never write the notebook file** (`.ipynb` or jupytext `.md`) while it is open in nvim — a
  hook reverts it. Edits only via `jn replace` / `jn insert`.
- **Never save the buffer** (`:w` writes the user's unsaved changes too). When you finish,
  tell the user in one line that the notebook needs `:w`.
- **Never move the cursor**, never start your own nvim.
- **A refusal is not worked around** — re-read and redo, or ask.
- **A claim you hold ends with `jn done`** — always, including "nothing changed", and
  *before* asking the user a question. Cells inside a claim will not run.
- **`stale: true` is a fact**: do not present that output as current.
- **Delete only what the user asked to remove.** Never write magics (`%%sql`) into a body.
- Exit 4 from `jn` (no nvim / a tie) — ask the user, do not pick at random.

## Step 0: find the session

**A prompt starting with `[jupyter.nvim]`** — skip this step and read `prompt.md` first:
a claim is already open and visible to the user.

Otherwise, every time:

```sh
JN=~/Projects/jupyter.nvim/bin/jn
NB=~/work/analysis/.../01_eda.ipynb          # path to the notebook

# make sure it is open in the user's nvim and the kernel is up — idempotent
$JN open "$NB"
# → {"ok": true, "buf": 7, "opened": true, "kernel": true}
```

It opens the notebook as a **hidden** buffer in the user's nvim (no window or cursor change).
`opened: true` — tell the user in one line it is in their buffer list. `jn` finds the nvim
itself; `--sock "$SOCK"` (before the command) pins it. Answers are one line of JSON; exit 1
is a refusal (`ok: false`, `reason`). Anything else → `session.md`.

## Everyday commands

```sh
$JN snapshot "$NB" --brief        # one line per cell: id, lang, rows, heading, last run, stale
$JN text "$NB" --cell e93d        # a cell's body exactly as in the buffer — a ready `old`
$JN replace "$NB" /tmp/jn-old /tmp/jn-new        # old must occur exactly once
$JN replace "$NB" --old 'limit = 100' --new 'limit = 1000'   # one line, simple quoting only
$JN insert "$NB" /tmp/jn-ins --after-cell e93d   # new cells by place, not by anchor text
$JN run "$NB" af4b 13ca           # run by id and wait; prints status + absolute result paths
$JN done "$NB" "$CLAIM"           # release a claim
```

Results are on disk at the printed paths: `.parquet` (read with
`~/work/jupyter-utils/.venv/bin/python` + polars — the system `python3` has none), `.txt`,
`.png`. Details of each command — in its topic file above.
