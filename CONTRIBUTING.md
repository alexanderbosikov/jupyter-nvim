# Working on jupyter.nvim

The design is in [ARCHITECTURE.md](ARCHITECTURE.md), the behaviour from outside in
[README.md](README.md). Here is only what it takes to get the project running on a clean
machine and to avoid the rakes that have already been paid for.

## An environment from scratch

Three things are needed: nvim with plenary, the sidecar's python environment, and a
registered kernel.

```sh
# 1. the sidecar's environment (python 3.11+): jupyter_client, polars + pytest, ipykernel
python3 -m venv ~/.venvs/jupyter
~/.venvs/jupyter/bin/pip install -e 'sidecar[dev]'

# 2. a kernel named python3 — the tests use this one
~/.venvs/jupyter/bin/python -m ipykernel install --user --name python3
jupyter kernelspec list   # check that it showed up

# 3. plenary for the Lua tests: through any plugin manager, or by hand
git clone https://github.com/nvim-lua/plenary.nvim \
    ~/.local/share/nvim/lazy/plenary.nvim
```

**The kernelspec's `argv` must point at the same python as the sidecar.** A relative path
or a different interpreter, and the kernel comes up without `polars` while a dataframe
result silently fails to be assembled. This has already gone off once; the post-mortem is
in §6.3 of ARCHITECTURE.md.

## Running the tests

```sh
# Lua: headless nvim + plenary. Some of the tests bring up a real sidecar and kernel.
JUPYTER_NVIM_PYTHON=~/.venvs/jupyter/bin/python ./tests/run.sh
./tests/run.sh tests/cells_spec.lua        # a single file

# the sidecar: pytest, no nvim
cd sidecar && PYTHONPATH=. ~/.venvs/jupyter/bin/python -m pytest -q
```

If plenary is not where `tests/minimal_init.lua` looks for it, the path can be given
explicitly: `JUPYTER_NVIM_PLENARY=/path/to/plenary.nvim ./tests/run.sh`.

`run.sh` checks the interpreter itself before starting, and gives plenary a per-file
timeout. It used to do neither, and `integration_spec` quietly never got to the end:
without polars it died on the third test, taking forty-odd following ones with it, and with
the default 50 s timeout the parent abandoned the child halfway. Both cases looked
identical — exit code 1, no summary, no list of failures — and for months were written off
as flakiness of the runner.

## Style

Lua — four spaces, double quotes, `---@param`/`---@return` on public functions. Python —
type annotations, `from __future__ import annotations`. Comments are in Russian and explain
**why**, not what: the "what" is visible in the code, the "why" cannot be reconstructed six
months later. A module's header describes its role and the boundary of its responsibility.

## What "done" means

**A green test is not the same thing as a working feature.** This is the project's main
lesson and it cost the most time: a traceback with a `\n` inside a list element crashed
`nvim_buf_set_lines` asynchronously, inside an event handler, while the test for an error
in a cell passed calmly — it was checking a structure in memory. Hence the rule: **if a
feature ends in drawing, its test must look at the buffer's contents, not at an
intermediate structure.**

The second rule: **flakes are not noise.** A test with a live kernel that fails one time in
five is treated as a bug in the code first. Of five such cases in this project, four turned
out to be real bugs (the table in §9 of ARCHITECTURE.md).

The third: some failures headless cannot see at all — images, tmux, widths in the terminal,
behaviour when windows change. After changes that touch these, a pass by eye in a real
terminal is needed:

1. open an `.ipynb` — the output window is in place, statuses under the cells that have run;
1. insert a cell (`<leader>ja`/`<leader>jb`) — the cursor is in its body and insert mode
   starts at once: headless does not see the mode, neither `startinsert` nor `feedkeys`
   fire there;
2. run a python cell, a cell with a language magic, a cell with an error;
3. the table: `<leader>jt`, pages `H`/`L`, sorting `s`/`S`/`c`, row numbers;
4. an image from matplotlib — moving to another cell, another tmux window, another session;
5. history: `[r`/`]r`, restart nvim — the outputs are in place;
6. the outline, and jumping through it;
7. interrupt a long cell, restart the kernel.
8. an agent's claim (`:lua =require("jupyter").edit_begin({cell = "<id>"})`) — the cell's
   area is highlighted and labelled, `:JupyterEdits` shows it; after `edit_apply` the
   inserted text flashes and the mark goes away. Check it while typing in a neighbouring
   cell: the edit must neither knock the mode off nor move the cursor.

## The invariants the audit holds

The tests check the intended behaviour; what always broke was hostile input. The classes
below have already gone off in this project, the audit against them has been done, and
**every new piece of code is required to hold them** — otherwise the class comes right back:

- **someone else's text in the buffer.** `nvim_buf_set_lines` does not accept a `\n` inside
  an element, and that is exactly what arrives from the kernel — a traceback as a list, a
  multi-line value in a table cell. Everything that writes foreign text goes through
  `common.set_lines`; the table's layout is held by `table.format`, and the string form of
  values by the sidecar (`frames._cell` escapes control characters). NUL, contrary to
  expectation, is safe: it stays NUL through the API too;
- **`vim.NIL`.** A JSON `null` without `luanil` becomes userdata, and userdata in Lua is
  **truthy** — the "there is a value" check passes and `polars vim.NIL` ends up in the
  report. Every `vim.json.decode` sets `luanil` for objects and arrays;
- **widths and unicode.** There are three units — bytes, characters, screen cells — and
  they must not be confused: bytes tear Cyrillic apart, characters miss by a factor of two
  on emoji and CJK. There is one clipping helper for everyone: `common.clip`;
- **the edges of failure.** Having nowhere to write must not break execution: history and
  the kernel's work are different things. The scenarios are in `tests/boundaries_spec.lua`;
- **races between deferred callbacks.** stdout callbacks arrive in a fast event context;
  delivery goes through `vim.schedule` and under pcall. Between scheduling and running, the
  buffer may have been wiped — checked in the same place.

## The work queue

Ordered by benefit against risk.

1. **Granular interrupt.** Right now an interrupt hits the kernel as a whole, taking the
   queue down with it. Cancelling a single request means keeping its `msg_id`. The catch:
   the Jupyter protocol cannot cancel a queued request — only interrupt the current one,
   after which the kernel drops the rest. So the queue would have to be kept in the sidecar
   and sent one at a time.

2. **Protection against accidentally joining cells.** A miss by a couple of lines across a
   boundary joins two cells silently, and on save the notebook loses a cell together with
   its outputs (verified: 25/21 → 24/20). The code of the vanished cell cannot be restored
   — the history holds only a `code_sha`. **Forbidding the edit is not an option**: a guard
   that reverts changes cannot tell a slip from an intention, breaks undo, and sooner or
   later eats something you needed. The idea is to notice instead: compare the set of ids
   against the history before and after an edit, and speak up when such an id has
   disappeared from the document. The signal is narrow, cells with no runs stay silent.
   About 40 lines; `repaint` already walks every cell.

3. **The intermediate file.** Right now reading and writing an `.ipynb` goes through a
   `<name>.md` on disk — that is how jupytext.nvim works, and that is where the whole
   "stale snapshot" class comes from (see README, "Requirements"). jupytext can work through
   pipes; all three links have been verified, including `--update` from stdin with outputs
   preserved. Our own `BufReadCmd`/`BufWriteCmd` (~150 lines) remove the file entirely, and
   with it the second source of truth and the dependency itself. Mandatory: do not leave an
   empty buffer when the conversion fails, and write through a temporary file with `rename`,
   otherwise an interrupted save corrupts the notebook. On top of that, those 137 ms can be
   brought back with a proper cache — outside the working directory, keyed by path and
   mtime.

4. **Images.** As long as image.nvim draws them, we are managing someone else's state:
   `state.images` is not cleaned up, and redrawing happens on every scroll. The only way out
   is to take the kitty protocol into our own hands — our own placement ids, and deletion by
   id when the cell changes. That is not a fix but a replacement of a layer, and the
   decision about it belongs to the project's owner, not to whoever came to fix a bug.
