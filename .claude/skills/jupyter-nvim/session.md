# jupyter-nvim — finding the session, opening, a new notebook, two copies

**Everything goes through `jn`** — `~/Projects/jupyter.nvim/bin/jn`, stdlib only, any
`python3`. Every command takes the notebook's path, finds the user's nvim by itself (where
the notebook is open, on screen first; else the one in your herdr tab / tmux window; else by
cwd) and passes arguments to nvim as a JSON file, so there is nothing to escape. Exit 4 —
no nvim found, or a tie (candidates on stderr): ask the user, do not pick at random.
`--sock "$SOCK"` (before the command) skips the search when you already know the socket.

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
2. `$JN open "$NB"` (`SKILL.md`, Step 0).
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

**Lab is a third session.** If the same file is also open in Jupyter Lab, that is an
independent session — your edits will not land there.
