# jupyter-nvim — editing the live buffer

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
Blank lines around the piece are added when missing; the new cells' ids come back in `cell_ids` — run them by those; do not dig them out of
the snapshot (`grep -A1`). Refusals:
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
