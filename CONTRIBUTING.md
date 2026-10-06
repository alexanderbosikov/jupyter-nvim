# Working on jupyter.nvim

The design is in [ARCHITECTURE.md](ARCHITECTURE.md), the behaviour from outside in
[README.md](README.md). Here is only what it takes to get the project running on a clean
machine and to avoid the rakes that have already been paid for.

## An environment from scratch

Three things are needed: nvim with plenary, the sidecar's python environment, and a
registered kernel.

```sh
# 1. the sidecar's environment (python 3.11+): jupyter_client, polars + pytest, ipykernel.
#    Any path will do — ~/.venvs/jupyter is an example. A work project's environment fits
#    too, as long as it has these packages
python3 -m venv ~/.venvs/jupyter
~/.venvs/jupyter/bin/pip install -e 'sidecar[dev]'

# 2. the python3 kernelspec does not have to be registered: once ipykernel is in the
#    environment, jupyter_client finds its own kernelspec inside the venv
~/.venvs/jupyter/bin/jupyter kernelspec list   # python3 should be in the list

# 3. plenary for the Lua tests: through any plugin manager, or by hand
git clone https://github.com/nvim-lua/plenary.nvim \
    ~/.local/share/nvim/lazy/plenary.nvim
```

**The kernel has to be started by the same python as the sidecar.** Otherwise it comes up
without `polars` and a dataframe result silently fails to be assembled; this has already
gone off once, the post-mortem is in §6.3 of ARCHITECTURE.md. A relative `argv` in the
kernelspec is safe — the sidecar puts its own directory first in the kernel's PATH. What is
dangerous is a user-level `python3` kernelspec
(`~/.local/share/jupyter/kernels/python3`, on a mac `~/Library/Jupyter/kernels/python3`):
it takes priority over the one in the venv and may point at another interpreter.
`:checkhealth jupyter` shows which kernelspec was taken and whether its python is the right
one.

## Running the tests

```sh
# Lua: headless nvim + plenary. Some of the tests bring up a real sidecar and kernel.
JUPYTER_NVIM_PYTHON=~/.venvs/jupyter/bin/python ./tests/run.sh
./tests/run.sh tests/cells_spec.lua        # a single file

# the sidecar: pytest, no nvim
cd sidecar && PYTHONPATH=. ~/.venvs/jupyter/bin/python -m pytest -q
```

Without `JUPYTER_NVIM_PYTHON` the plugin's own search is used: an activated environment
(`source ~/.venvs/jupyter/bin/activate && ./tests/run.sh`) or a `.venv` in the root of the
repository.

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

3. **The intermediate file** — **done** (`ipynb.lua`, `ftdetect/jupyter.lua`, §7.8): our
   own `BufReadCmd`/`BufWriteCmd`, jupytext through pipes, nothing on disk but the
   notebook; raw json instead of an empty buffer on a failed read, a temporary file and
   `rename` on write. What is left is the 137 ms per opening: a proper cache — outside the
   working directory, keyed by path and mtime — would bring them back.

4. **Images.** As long as image.nvim draws them, we are managing someone else's state:
   `state.images` is not cleaned up, and redrawing happens on every scroll. The only way out
   is to take the kitty protocol into our own hands — our own placement ids, and deletion by
   id when the cell changes. That is not a fix but a replacement of a layer, and the
   decision about it belongs to the project's owner, not to whoever came to fix a bug.

5. **The polars dependency, and what half of it actually costs.** polars sits in two
   places, and only one is a dependency of ours. In the sidecar (`frames.page`, `polars>=1`
   in `pyproject.toml`) it is an implementation detail behind parquet: the format is
   neutral, anything reads it, and pyarrow or duckdb would swap in without touching the
   protocol or the layout of `.jupyter-out`. Nothing to fix there. In the **kernel** it is a
   gate on the user's own data — `HELPER_SOURCE` ends at `isinstance(obj, pl.DataFrame)`, so
   a pandas frame returns `None`, no parquet is written, and the whole table (paging, the
   sorting stack, `<CR>` on a value) simply does not exist for that user. The drawer falls
   back to the frame's own repr and nothing says why: `parse_dump` treats `None` as the
   normal case (§7.1), which it usually is. Duck-typing the helper — `write_parquet` /
   `to_parquet`, `collect` for a lazy frame, `height`/`width`/`schema` by branch — is about
   ten lines. The catch: pandas' `to_parquet` needs pyarrow or fastparquet of its own, so
   "works without polars" is not free, it moves the requirement rather than removing it.
   Worth doing only if the plugin goes out to people who are not us.

   The other half of this — `:checkhealth` probing the wrong interpreter — is **done**:
   `health.collect` now reads the kernelspec's argv and, when the kernel's python is an
   explicit path other than ours, asks that one about polars too. A relative argv is left
   alone on purpose: it resolves through PATH, where the sidecar puts our own `bin` first
   (§6.3). Both cases are pinned in `tests/health_spec.lua`.

6. **Duplicate ids.** Copy a whole cell with its fence (`yy`/`p` over the span) and two
   cells carry one `jncell`: their runs land in one history, the snapshot hands both the
   same `last`, and a claim by id takes whichever `cellid.find` meets first. `generate`
   guards against collisions only when *it* makes an id; a pasted duplicate it never sees.
   The fix is to notice, not to forbid: when a run or `repaint` finds an id twice, the
   later cell gets a fresh one (`cellid.generate` with the used set) and the first keeps
   its history — the original is the one that was there before. Open question: which one
   is "first" when both were pasted, and whether to rewrite silently or say so once. About
   30 lines plus a test; `cellid.used` already walks the buffer.

7. **A claim on a cell with no id** — mostly moot since item 10: `edit_replace` edits a
   cell with no id and gives it one, and `edit_claim({text})` marks it. Left: the old
   `edit_begin` path. Cells made by the plugin's commands and by an agent's
   insert get their `jncell` at once (§7.2), but one typed or pasted by hand has none until
   its first run, so an agent can neither edit nor delete it: the snapshot gives such a
   cell no `id` at all, only its `index`. `edit_begin({index = N, sha = …})` would find the
   cell by number, then `cellid.ensure` writes the id inside `begin` and the claim holds on
   to that, not to the number — what `ask.lua` already does when a prompt is sent. The
   number only finds the cell; it drifts if the user inserts a cell in between, so the call
   carries the body's sha from the snapshot and refuses on a mismatch. That means the
   snapshot has to start returning the body's sha for cells without an id — today it has
   none. About an hour.

8. **An atomic batch of edits** — mostly moot since item 10: one `edit_replace` over a
   stretch of several cells is one check and one undo step. Left: the old cell API. Several claims can be open at once, but each is applied
   by its own call and is its own undo step: five edits cost five `u`, and a `changed` on
   one leaves the others already applied — a half-rewritten notebook. `edit_batch` would
   check every claim first (anchor + sha) and touch nothing if one fails, then apply bottom
   to top so line numbers do not shift, inside one undo step. Open: an insert anchored to a
   cell the same batch deletes (an insert holds only an extmark, not an id — untested), and
   one mark for the batch or one per cell. Two to three hours with tests.

9. **`:w` while an end-of-file insert claim is open** wrote an extra empty cell into the
   `.ipynb` (the blank line `pad_eof` adds as a hook for the label) — **done** along with
   item 3: the writer does not pass trailing blank lines to jupytext (§7.8).

10. **Editing prose and mixed pieces** — **done** 2026-10-06, without making markdown a cell
    (§7.5.1): `edit_replace(old, new)` edits any text by an exact unique match and checks
    fences and ids before writing; `edit_claim` / `:JupyterAsk` hold lines (a paragraph, a
    cell, a selection of both) instead of one cell; `edit_done` releases. The claim's number
    went from the prompt header to the pane file. What remains of the original idea — prose
    with an id and a history (`<!-- #region jncell=… -->`, §7.2.2) — has no use case yet.

11. **Preview before an agent's edit lands.** Today `edit_replace` writes straight away; the
    claim's mark is the only warning. A mode where the edit is shown as a diff over the cell
    and lands on a key would suit edits the user wants to vet. Two to three hours.

12. **The prompt transport** — tmux and herdr are **done** (`pane/*.lua`, §7.6). What is
    left is to drop the multiplexer altogether: Claude Code *channels* (research preview)
    let an MCP server of ours push a message straight into a running session, so the
    prompt would reach the session itself rather than its terminal. Deferred until channels
    leave preview: today every session must be started with
    `--dangerously-load-development-channels`, and it is not yet verified that a channel
    message starts a turn on an idle session rather than waiting as context. The pane path
    stays as the fallback either way.

13. **Run status in the multiplexer's sidebar** — **done** for herdr (`sidebar.lua`, §7.7):
    `working` with `N/M`, idle/done, `blocked` on an error, a dead kernel, a dead sidecar or
    `input()`; every ending is pinned on a live kernel. What is left is answering `input()`
    from nvim at all: the sidecar has `stdin.reply`, Lua ignores `input_request`, so such a
    cell can only be interrupted — the sidebar at least says it waits.

14. **Export to HTML/PDF from the outputs we already have.** Today export lives outside the
    plugin: `~/.local/bin/nb-export` wraps `jupyter nbconvert --execute` with a custom
    `report` template, bound to `<leader>ne` / `<leader>nE` in the user's config. It has to
    re-execute because our outputs live in `.jupyter-out`, not in the `.ipynb` (§8) — fine
    for a notebook on local parquet (7 s), but a notebook on Redshift re-runs every query.
    The idea: build a temporary `.ipynb` with outputs from the latest run of each cell
    (`index.jsonl` → parquet as `text/html`, png as `image/png`, txt as `text/plain`) and
    hand it to nbconvert without `--execute`. Forks: a cell edited after its run (`⚠`) —
    export the stale output, skip it, or refuse; a cell never run — empty or refuse; parquet
    tables are pages, not the whole frame — how many rows go into the report. Half a day
    with tests.

15. **Waiting for a run from outside: `jn-wait`.** An agent that runs a cell polls the
    snapshot through `nvim --remote-expr` with an until-condition (the skill's recipe).
    Polling is cheap; what hurts is that every agent rebuilds a long `luaeval` and gets the
    condition wrong (waits on `running` while the cell is still `queued`), that the
    notebook level does not exist outside — the wave, `N/M` and its outcome live only in
    `sidebar.lua` — and that when the user started Run All, the agent has no idea where the
    wave began. The idea: `jn-wait <notebook> [--cell <id>]` blocks until the run ends and
    prints the outcome (`ok 12/12 · 4m31s`, `error in a3f9: ProgrammingError`,
    `interrupted`), exit code 0/1; run in the background, it wakes the agent when it exits
    — a subscription through the harness rather than a poll in the agent's context. For the
    whole notebook: remember the highest `run_id` at the call, wait until a newer run exists
    **and** no cell is busy — that closes the race of subscribing before the run starts.
    Not now: pushing "done" into the agent's pane through `ask.lua` — injected text mixes
    with what the user types or cuts the agent's turn; the proper channel is item 12.
    Forks: the default timeout; `input()` in a cell (return at once with its own code); a
    cell with no id (only the notebook level); whether the wave count moves out of
    `sidebar.lua` into a shared module so the outcome matches herdr. An hour for the script
    and the skill; two to three with the shared wave and tests.

    Added 2026-10-06 — **run and show**: on completion print not only the outcome but what
    the agent needs next — the table's shape and first rows (from the run's parquet), the
    traceback, or the text output. Then "write → run → see the error → fix" is one call for
    the agent, and the user looks at a finished result. `%%sql` cells are not run without
    asking (they are Redshift queries): a rule in the skill, and a refusal without
    `--allow-sql` in the command.

16. **Point in nvim, talk in Claude Code.** The user mostly works from Claude Code and
    rarely sends prompts from nvim: that is where the conversation and its history are.
    So instead of pulling the conversation into nvim, let Claude Code know what the user
    is looking at. The plugin writes the focus — notebook, cell under the cursor, selection,
    time — to the pane file on `CursorHold` / selection change (next to what `ask.remember`
    writes). A Claude Code `UserPromptSubmit` hook reads the file of its own pane and, when
    the focus is fresh (nvim focused in the last ~2 minutes), adds a `[jupyter.nvim] …`
    context line to the prompt — "why is this empty?" and "rewrite this cell lazily" then
    need no paths or ids. `<leader>jq` becomes "claim this piece and switch me to the Claude
    pane"; the prompt float stays for short questions. Forks: the freshness threshold; two
    nvims focusing one pane (latest wins). Two to three hours, plus the hook in the user's
    settings.

17. **Describe a variable in the kernel.** To write polars over `df_usage` the agent needs
    its columns and types; today it reads the last run's parquet (maybe not what is in
    memory) or asks for kernel access. A fixed describe command — type, schema, size,
    `head(5)` — runs the plugin's own code with only an identifier from outside, through
    the sidecar rather than a cell, so it stays out of run history and `Out`. Forks:
    non-frames (`repr`, clipped); a `LazyFrame` gives its schema without `collect`. An hour
    and a half to two.

18. **What the agent changed while you were not looking.** When an agent rewrites half
    the notebook while the user is in Claude Code, there is a flash at write time and a
    single `u`, and nothing to tell what to review. Keep each `edit_replace`'s old/new:
    its lines stay highlighted until the cursor visits them, `]a` / `[a` jump between
    them, and one can be reverted alone (a reverse replace, with the same "text still
    there" check). Listed in `:JupyterEdits`. A cheaper step towards item 11. About three
    hours.
