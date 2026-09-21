# jupyter.nvim — architecture

How the plugin is built and why exactly this way. Each decision is written down together
with its price and with whatever forced it: most of them were verified by experiment, not
picked from general considerations.

**Names.** The plugin is `jupyter.nvim`, the Lua root is `lua/jupyter/`, the commands are
`:Jupyter*`, the sidecar is the `jupyter_nvim` package (not `jupyter`: `import jupyter` is
already taken by the metapackage), and the CLI is a `jupyter-out` binary that
`jupyter_core` picks up as a subcommand of its own CLI.

## 1. Decisions

| fork in the road | decision | why | what it costs |
|---|---|---|---|
| transport to the kernel | **a separate process, JSON-lines over stdin/stdout** | the sidecar becomes an ordinary process, and acceptance testing runs from a terminal with no nvim. This is the main argument, ahead of typed calls | correlating request↔response by hand, ~40 lines once |
| where cell state lives | **in Lua** | the sidecar is almost stateless: a connection and a routing table. One place of truth across restarts | the kernel does not survive an nvim restart |
| cell boundaries | **regexes behind a detector interface** | they work, and the interface makes treesitter a one-module replacement | edge cases such as a fence inside a string |
| output | **one scratch buffer per notebook plus a status under the cell** | output is copied, searched and scrolled by the usual means; the state of every cell is visible at once | you cannot see the output of two cells at the same time |
| cell id | **a short hash in the document's text** | output is found outside the editor, without starting nvim | a cell's first run edits the buffer (one undo-able edit) |
| interpreter | **a path from the config** | the kernel and the sidecar have to come from the same environment | no isolation of dependencies |

## 2. Processes and data flows

```
┌─────────────────── nvim ───────────────────┐
│  buffer (.py / .md after jupytext)         │
│  cell-id in the text · status under cell   │
│  output drawer · table tab                 │
│              lua/jupyter/*                 │
└───────────────┬────────────────────────────┘
                │ JSON-lines (stdin/stdout)
                │ requests ↓   events ↑
┌───────────────┴────────────────────────────┐
│  jupyter_nvim (python)                     │
│  jupyter_client · router(msg_id) · polars  │
└───────────────┬────────────────────────────┘
                │ ZeroMQ (shell/iopub/stdin/control)
┌───────────────┴────────────────────────────┐
│  ipykernel                                 │
└────────────────────────────────────────────┘

    .jupyter-out/<notebook>/   ← written by the sidecar; read by the drawer, the CLI, outside scripts
```

Three channels, and that is deliberate:

- **requests** — Lua calls the sidecar (execute, interrupt, a page of a table);
- **events** — the sidecar pushes upwards (stream, result, done, kernel state);
- **disk** — heavy data (tables, images) never goes through the pipe at all, only paths do.

## 3. Boundaries of responsibility

**Lua knows:** buffers, cells, windows, keys, `run_id`, the run history in memory, column
widths when drawing a table.
**Lua does not know:** ZeroMQ, the structure of jupyter messages, mime bundles, polars,
parquet.

**Python knows:** the kernel protocol, `parent_header.msg_id`, mime bundles,
polars/parquet, the layout of `.jupyter-out/`.
**Python does not know:** line numbers, buffers, windows. To it a cell is only a `cell_id`
string that came from above.

The practical test of the boundary: the sidecar must work entirely from
`echo '{...}' | python -m jupyter_nvim`. If that stops being true for some feature, the
boundary has leaked.

## 4. The protocol

JSON-lines: one JSON string per message, UTF-8. The version is `v`; a mismatch fails loudly
on `hello` instead of quietly at runtime.

### 4.1. The envelope

```json
// Lua → sidecar (a request)
{"v": 1, "id": "7", "op": "execute", "args": {"cell_id": "a3f9", "run_id": 12, "code": "..."}}

// sidecar → Lua (a reply to a request: it has an id)
{"v": 1, "id": "7", "ev": "ok",    "data": {"msg_id": "3f2c..."}}
{"v": 1, "id": "7", "ev": "error", "data": {"code": "kernel_not_ready", "msg": "..."}}

// sidecar → Lua (an event: no id)
{"v": 1, "ev": "stream", "cell_id": "a3f9", "run_id": 12, "data": {"name": "stdout", "ops": [...]}}
```

### 4.2. Requests

| op | args | ok.data |
|---|---|---|
| `hello` | `{v}` | `{v, version, python, caps[], kernel}` |
| `kernel.start` | `{kernel_name, cwd, env{}, notebook?, out_dir?, history_limit?}` | `{kernel_id, connection_file, kernel_log, attached: false}` |
| `kernel.attach` | the same plus `{connection_file, pid?}` | `{kernel_id, connection_file, kernel_log, attached: true}` |
| `kernel.release` | `{}` | `{released, kernel_pid?}` |
| `kernel.state` | — | `{state, since_ms, ...}` |
| `kernel.restart` / `kernel.shutdown` | `{}` | `{kernel_id, aborted}` / `{}` |
| `execute` | `{cell_id, run_id, code, result_expr?}` | `{msg_id}` |
| `interrupt` | `{}` | `{active}` |
| `stdin.reply` | `{value}` | `{}` |
| `table.page` | `{path, offset, limit, cols[]?, order_by[]?}` | `{header[], rows[][], total_rows, offset, truncated, order_by[]}` |
| `ping` | — | `{}` |

`execute` is rejected while the kernel is not ready: the guard is built into the
construction rather than bolted on the side. `result_expr` is what to serialise into
parquet, `_` by default; for magics Lua sends the name of the variable (§7.1).

### 4.3. Events

| ev | fields of data |
|---|---|
| `exec.started` | `{msg_id, started_at}` — the kernel has taken the request into work |
| `stream` | `{name, ops[]}` — a list of `{op, text}`, where `op` is `append \| replace_last` |
| `display` / `result` | `{kind, mime?, path?, text?, rows?, cols?, schema?}` |
| `exec.error` | `{ename, evalue, traceback[]}` — ANSI stripped |
| `exec.done` | `{status, duration_ms, execution_count, user_expressions?}` |
| `clear_output` | `{wait}` |
| `input_request` | `{prompt, password}` |
| `kernel.state` | `{state, reason?, language_version?}` |
| `orphan` | `{parent_msg_id, msg_type}` |
| `log` | `{level, msg}` — `level: kernel` is output of the kernel itself |

`stream` carries a list of operations rather than a string, because a single `\r` in the
stream means redrawing the line, not adding a new one, and that is not for the UI to decide.

**`exec.started` means "begun", not "sent".** An `execute_request` goes to the kernel
immediately, and "run all" sends them in one burst, but they are executed one at a time.
The event is born on an iopub `status: busy` for that parent; the start mark (`Exec.begin`)
is put down there too, and `duration_ms` is counted from it. While it was counted from
being queued, twelve cells of 20 ms each reported the same seven minutes — exactly the time
they had spent in the queue — and each of them said "running" while only one was working.
A run cancelled before it began takes its duration from the queueing: it has no other
starting point.

Any event may carry `late: true` — the run it belongs to is already closed. There is
deliberately no separate event type for this: Lua decides whether to show it with a mark or
to hide it.

**A run is closed from two ends.** `idle` arrives over iopub, and `execute_reply` with the
status over shell. These are different channels, the order of delivery between them is not
guaranteed, and the error status lives only in the reply. So `exec.done` goes out once both
have arrived. The exception is `aborted`: such a run will never get an `idle` of its own,
so it is closed immediately.

### 4.4. Two keys instead of one: what `run_id` is for

`cell_id` answers "which cell", `run_id` answers "which run". Without the second key,
output that arrived from a background thread after `idle` lands in the panel of the second
run of the same cell. Both keys travel in every event; Lua discards everything whose
`run_id` is not the current one for that cell.

`run_id` is issued by Lua (a monotonic counter per buffer) — that way it is not lost when
the sidecar restarts.

**What routing by `msg_id` does not cure** (verified on ipykernel 7.3):

| when a background thread prints | what ipykernel puts in `parent_header` | what we see |
|---|---|---|
| nothing else is running | the msg_id of an already closed cell | the right cell, `late: true` — works |
| **another** cell is running | the msg_id of the current request | the output lands in a foreign cell, indistinguishable |

The second case cannot be cured by any client: the kernel itself attributed the message to
the wrong cell. Browser Jupyter behaves the same way. The behaviour is pinned by a test, so
that a change in the kernel does not go unnoticed.

### 4.5. The routing invariant

`active_executions: dict[msg_id, (cell_id, run_id)]` in the sidecar is the only source of
the binding. There is no FIFO of outputs anywhere, neither in Lua nor in Python.

Messages outside that table fall into three cases, and they must not be mixed:

- **`parent_header.msg_id` is set but unknown** → `ev: orphan`, an anomaly: log it, do not
  apply it;
- **`parent_header` is empty** → output of the kernel itself (banners and warnings at
  start). It goes out as a `log` of level `kernel`: it must be shown, but it is not an
  anomaly;
- **housekeeping** — `status`, `iopub_welcome`, `execute_input`, the messages of the
  internal probes from §6.2 — silently ignored.

## 5. The Lua modules (`lua/jupyter/`)

| module | responsibility | what it does not do |
|---|---|---|
| `init.lua` | `setup()`, a session per buffer, lazy kernel start, the public API | no logic — wiring only |
| `cells.lua` | cell boundaries behind a detector interface: percent and fences; collecting, jumping, inserting | knows nothing about output or about the kernel |
| `cellid.lua` | generating, parsing and inserting an id in the text, checking for collisions | — |
| `sidecar.lua` | the process, the JSON-lines codec, correlating `id`↔reply, dispatching events | does not know what the events mean |
| `kernel.lua` | the state machine, a queue of runs until readiness | — |
| `exec.lua` | runs, `run_id`, rejecting stale events, `result_expr` | does not draw |
| `store.lua` | reading `index.jsonl` back, assembling a run for drawing; where a notebook's directory is | does not write |
| `draft.lua` | the draft of an unsaved buffer: debounce, atomic write, finding orphaned ones | never writes into the notebook file |
| `highlight.lua` | highlight groups: contrast from `Normal`, meaning from `Diagnostic*` | defines no colours of its own |
| `ui/common.lua` | scratch buffer, window options, **actions → keys** | not a single hard-coded key |
| `ui/output.lua` | the drawer: output, table preview, status in the winbar | — |
| `ui/table.lua` | paged viewing of parquet, column alignment, the sorting stack, a cell's whole value | does not read parquet itself and does not sort |
| `ui/status.lua` | the status line under a cell | stores no positions |
| `images.lua` | the path and the anchor in image.nvim, removing images | has no renderer of its own |
| `edit.lua` | restructuring cells: split, join, move, change the type | does not look for boundaries — it takes them from `cells` |
| `pane.lua` | the tmux pane the agent lives in: the search ladder, liveness, putting a prompt into its PTY | knows nothing about notebooks or claims |
| `ask.lua` | a prompt from the notebook: the address, the claim opened before sending, the float to type in, the log | does not talk to tmux itself |
| `orphans.lua` | kernels with no owner: reading the trace, identification by connection file, clearing | monitors nothing, works on demand |
| `toc.lua` | the outline: headings and cells with their state | does not draw the list itself |
| `ui/picker.lua` | showing a list: telescope if present, otherwise `vim.ui.select` | no dependency on telescope |
| `commands.lua` | `:Jupyter*` | — |
| `health.lua` | `:checkhealth jupyter`; collection is separated from drawing and therefore covered by tests | — |

There is deliberately no separate module for extmark positions: while the id lives in the
text, binding output needs no positions, and statuses are redrawn wholesale from the
current boundaries.

### 5.1. The status attaches to the line AFTER the cell

The virtual status line is anchored to the next line of the document with
`virt_lines_above = true`, rather than to the cell's last line with
`virt_lines_above = false`. It looks the same, and this is not style but a cure.

The symptom: while moving around the notebook, the lines under the cursor either double or
disappear, and only a forced redraw fixes it. The cause is in nvim (verified on 0.12.5),
not in the plugin: `virt_lines` glued below a line that is followed by a line concealed
entirely (`conceal_lines`) break the height recalculation during scrolling. `conceal_lines`
is what render-markdown uses to hide a cell's closing fence, so in the markdown
representation of a notebook such a pair stood at every single cell.

It reproduces on a bare `nvim --clean -u NONE`: 12 blocks, `conceal_lines` on every
closing ```` ``` ```` fence, `virt_lines` on the line before it, jumping between blocks with
`zz`. It was measured by comparing a screen snapshot with itself after `Ctrl-L` and looking
for doubled lines:

| where `virt_lines` sits | screens with artefacts |
|---|---|
| on the body's last line, below (before) | 4 out of 4 |
| on the concealed fence line | 0 out of 4, but **the status is not visible at all** |
| on the next line, above (now) | 0 out of 4 |
| far away from the concealed line | 0 out of 4 |

Two consequences follow in the code. First: `repaint` hands out `span_end` — the end of the
cell together with its fence — and not `end_row`; the status must not stand between the
body and the fence, and on the fence itself it will not be drawn. In the percent
representation these are the same line, so nothing changes there. Second: the workaround
lives in a single function, `common.virt_line_below`, rather than scattered around — the
same pair of "our virtual line above someone's concealed line" is possible everywhere the
plugin draws `virt_lines` (the agent's edit mark is the next candidate).

The same investigation removed a second source of ripple: `images.lua` was sending the
kitty deletion sequence to the terminal (23 bytes past nvim's renderer, into the same tty
the TUI thread writes to) on **every** redraw of the output window, that is on every move
between cells — even in a notebook with no images at all. Now it is sent only when there
was something to remove; the emergency cleanup (`:JupyterClearImages`) still sends it
unconditionally.

## 6. The Python modules (`jupyter_nvim/`)

| module | responsibility |
|---|---|
| `__main__.py` | the stdio loop, wiring `op` → session methods |
| `rpc.py` | JSON-lines, dispatch, the error envelope, the protocol version |
| `kernel.py` | `jupyter_client`, states, readiness (§6.2), restart, interrupt, stdin |
| `router.py` | `active_executions`, `msg_id → (cell_id, run_id)`, orphans, closing runs |
| `mime.py` | mime bundle → event: `text/plain` first, an image as a file |
| `frames.py` | the helper for serialising a dataframe, parsing the reply, `table.page` |
| `stream.py` | accumulating stream text with the semantics of `\r` and `\b`, stripping ANSI |
| `progress.py` | the hidden cell that turns a widget progress bar into a text one (§6.6) |
| `outdir.py` | the layout of `.jupyter-out/`, `index.jsonl`, trimming history |
| `cli.py` | `jupyter out <file> <cell-id>` |

### 6.1. Registration before sending

An `execute_request` is assembled by hand rather than through `client.execute()`: the
`msg_id` is needed in advance, to register the run in the router **before** sending.
Otherwise the very first message from iopub can arrive ahead of its own record.

### 6.2. Kernel readiness is three channels, not one

`wait_for_ready` is never called: it sprays `kernel_info_request`s, each with its own
busy/idle pair on iopub, and on success it **drains the whole of iopub**, carrying away the
output of cells that are already running.

But "a reply on shell" is not readiness either. That was found out experimentally: the
kernel said `ready`, an `execute` went out — and not a single event came back, or the first
half of the output was lost. Each channel becomes usable at its own moment:

| channel | socket type | what proves readiness |
|---|---|---|
| shell | DEALER→ROUTER, reliable | a reply to our `kernel_info_request` |
| iopub | **PUB/SUB** | any message received at all. Everything published before the subscription was set up is lost irrecoverably — ZeroMQ's "slow subscriber" |
| stdin | DEALER→**a ROUTER on the kernel's side** | a confirmed round trip: a ROUTER does not route to an identity that has not connected yet, and an `input_request` in that window is lost silently. The measured window is 50–300 ms |

Readiness = all three. While iopub stays silent, `kernel_info_request` is re-asked every
150 ms. The stdin route is confirmed by a real `input()`: a hidden cell calls it inside
`except BaseException`, the arrival of `input_request` is the proof, and we answer with an
empty string. If it does not arrive — `interrupt` and try again.

A dead end worth not repeating: sending an empty `input_reply` in advance so that the
ROUTER learns the identity. It works in four cases out of five, and in the fifth it arrives
**in the gap between `input_request` and the wait for a reply**, and the kernel takes it
for the user's answer: `input()` returns an empty string. A hang turns into silently wrong
data.

**The stages of readiness are sequential.** First the kernel proves that its main loop is
alive, and only then do we have the right to send it hidden cells, let alone an
`interrupt`: a SIGINT arriving at a kernel that is still importing modules aborts its own
startup.

### 6.3. The kernel's PATH

A kernelspec may give the interpreter relatively (`"argv": ["python", ...]`). The kernel is
then taken from PATH, and the PATH of an nvim started from a GUI is arbitrary — to the
point where there is no `python` binary in it at all, and the cell dies with a
`ModuleNotFoundError` on its first import. We already know the right interpreter — the one
the sidecar runs on — so we put its directory first in the kernel's PATH. Absolute argv is
untouched by this.

### 6.4. The kernel's stderr

Goes into a separate file next to the outputs. An inherited stderr would mean that
ipykernel's own warnings reach the user as errors of the sidecar, while real crashes drown
in the noise.

### 6.5. An attached kernel is managed through its pid

Attaching to a live kernel (`kernel.attach`) exists to survive a restart of the editor: the
kernel is not our child, it calmly lives on, and its memory still holds the frames the long
query was made for.

Exchanging messages with someone else's kernel is no different from our own:
`load_connection_file`, `client()`, the channels, the same readiness path. Managing it, on
the other hand, differs entirely. Verified on jupyter_client 8.9.1:

| call | our own kernel | an attached one |
|---|---|---|
| `is_alive()` | as expected | always `False` — there is no provisioner |
| `interrupt_kernel()` | as expected | `RuntimeError: No kernel is running` |
| `shutdown_kernel()` | as expected | `AssertionError`, the kernel stays alive |

So for an attached kernel liveness is checked with signal 0, interruption is `SIGINT`, and
shutting down repeats jupyter_client's ladder by hand: a request over the protocol,
`SIGTERM` halfway through the deadline, `SIGKILL` at the end. Without that, the watchdog
would declare a live kernel dead on its very first tick, and `kernel.shutdown` would
quietly leave the process in the system.

Restarting an attached kernel means putting out someone else's and starting our own: we
have no provisioner that could restart it. The startup arguments for that are remembered at
the moment of attaching.

The inverse operation is `kernel.release`: close our channels and forget about the kernel
without putting it out. Without it, attaching would only save you from a crash and not from
an ordinary `:qa`. The subtlety this used to break on: `KernelManager.__del__` calls
`cleanup_connection_file`, so releasing a kernel means releasing ownership of the file too.
Otherwise the process stays alive with no way left to attach to it — the file is gone. The
trace on disk is deliberately kept when releasing: our pid will soon be a dead one, and the
record turns by itself into exactly what `jupyter.orphans` looks for.

### 6.6. A progress bar we can see

`tqdm.auto` in a kernel that has `ipywidgets` installed resolves to `tqdm.notebook`, and
that one does not print a bar at all. It sends a single `display_data` when the bar is
created and then a `comm_msg` per update — the widget protocol, which needs a front-end
runtime we do not have. What reaches us is the first frame and nothing after it, so a cell
that spent an hour walking 73 query windows sat on `Периоды: 0%| 0/73` the whole time and
looked stuck. The kernel was working; the plugin was drawing the only thing it had been
told.

Two ways out, and the cheap one is better. Understanding the widget protocol means keeping
the state of `ipywidgets` models on our side and knowing the layout tqdm builds its bar
from (an `HBox` of a `FloatProgress` and two `HTML`s) — someone else's protocol plus a
dependency on a version of someone else's library, for one progress bar. The other way is
to tell the kernel the truth: there is no widget runtime here, print text. A text bar is a
`\r` in stderr, and `stream.py` has understood that from the first day.

So `progress.py`: a hidden cell sent on readiness, next to the helper from §7.1, before any
cell of the user's. It replaces the bar in `tqdm.auto` — and in every already imported
module that holds one of its own, because `from tqdm.auto import tqdm` in a third-party
package is exactly such a reference and, on `kernel.attach`, that package was imported long
before us. It is silent about any outcome of its own: cosmetics must not break a kernel.

The toggle is `text_progress` (on by default, `kernel.start`/`kernel.attach` carry it).
Turning it off means the kernel is left alone — and the bar then does not move at all.

## 7. Data on disk

```
<directory>/.jupyter-out/<notebook name>/
  index.jsonl                     append-only, one object per run
  a3f9/12.parquet                 <cell-id>/<run-id>.<ext>
  a3f9/13.txt
  b7e1/3.png
  kernel.log
  runtime.json                    while the kernel is alive: pids of the sidecar, kernel and editor
  drafts/9812-1.md                the text of an unsaved buffer, as it is
  drafts/9812-1.json              the time, the sha of the text, the notebook's mtime back then
```

`runtime.json` is the only file that lives exactly as long as the kernel. The sidecar
writes it at start and removes it on shutdown. It is needed because nvim does not wait for
the sidecar to finish (otherwise quitting the editor would cost 1.9 s), while the sidecar
may not live to put the kernel out: `SIGKILL`, a crashed interpreter, a closed terminal. A
live file with a dead sidecar is a kernel with no owner, and there is no other way to
identify one. The check is lazy and on demand: when a notebook is opened and in
`:checkhealth`, no daemons. Identification goes by the path of the connection file in the
process's argv: a pid may have been handed out again, and we do not kill what is not ours.

```json
{"cell_id":"a3f9","run_id":12,"started_at":"2026-09-03T10:12:04Z","duration_ms":12300,
 "status":"ok","kind":"table","path":"a3f9/12.parquet","rows":1240,"cols":7,
 "code_sha":"9c1f2a","execution_count":12,"ename":null}
```

- `code_sha` is the hash of the code at the moment of the run: it shows that the output is
  stale relative to the cell's text;
- a cell's history = all the records with that `cell_id`, the extra ones trimmed by
  `history_limit`;
- paths in the index are relative, in events they are full;
- the directory is restored by a re-run and its place is in `.gitignore`.

When reading the index, decoding with `luanil` is mandatory: otherwise a JSON `null`
arrives as `vim.NIL` — userdata, which is truthy and passes a "the field is not set" check.

### 7.1. Who serialises the dataframe

**The sidecar never sees the frame**: only mime bundles come from the kernel, that is
ready-made text and HTML, while the object itself lives in the kernel's memory. So the
kernel does the serialising:

1. at start, before the first user `execute`, a hidden cell goes out (`silent`, no history)
   with the definition of a helper function: it checks the type, writes the parquet and
   returns `{rows, cols, schema}`. No polars — it returns `None`;
2. every `execute` carries `user_expressions` with a call to that helper; the kernel
   evaluates it **after** the cell, so `_` already holds the result;
3. the answer arrives in `execute_reply.user_expressions`. Careful: `text/plain` there is
   **the repr of a Python value, not JSON**, so it is parsed with `ast.literal_eval`;
4. if a dict came back, a `result` with `kind: table` and the path to the parquet goes up.

**What to serialise is decided by Lua.** The sidecar does not know what a cell is, let
alone a magic; Lua parses it and sends the variable's name in `result_expr`. The default
`_` covers ordinary cells.

The price: one function with a dunder-like name appears in the kernel's namespace. The
alternative would require changes in a package on the kernel's side, that is, it would tie
the plugin to that package.

### 7.2. Where a cell's id lives

The requirement: the id is stable and lies **in the text**, otherwise an outside tool
cannot find the output. Exactly where was settled by measurements on a real notebook
(65 cells):

| hypothesis | result |
|---|---|
| the native nbformat 4.5 cell `id` | every cell has one, but jupytext **regenerates them all** on the reverse conversion: 0 out of 65 matched. Useless for persistence |
| `cell_metadata_filter=all` | does not help, the fences stay bare |
| a comment in the cell's body | **dangerous**: in a cell with a language magic `#` is not a comment but part of the code in that language |
| a key in the fence's info string | **works.** `jncell="a3f9"` reaches the `.ipynb` as honest cell metadata and comes back verbatim. With a hyphen (`cell-id=`) jupytext complains and puts the value into `incorrectly_encoded_metadata` |

The result: `jncell="a3f9"` in the fence's info string, and on the marker line in percent.
The md → ipynb → md round trip was checked on all 65 cells: 65 out of 65 survived, and not
one leaked into a cell's body. Pinned by a test.

The id is derived deterministically from the cell's content: an unsaved buffer gets the
same id on a re-run and does not lose its history. A cell with no marker (code before the
first `# %%`) has nowhere to write an id — there the cell's number remains, and the history
of such a cell does not survive a neighbour being inserted. That is a deliberate boundary.

### 7.2.2. A markdown cell is not a cell here

The id above is a code cell's. Prose has none, and the reason is one level below ids: in the
fence representation a markdown cell is **plain text with no fence at all** (converting a
cell to markdown literally strips the fences — `edit.lua:to_markdown`), while `cells.lua`
collects only fences whose language is a code language. Prose is therefore invisible to the
whole model: no enumeration, no id, no anchor, no claim. An outside reader can read it and
cannot be offered any safe way to change it (§8).

That is a decision of ours, not a limit of the format. Measured on jupytext 1.19.5:

| question | answer |
|---|---|
| where is the boundary between two markdown cells? | a run of **two** blank lines. One blank line keeps the text in the same cell — checked both ways: `Абзац.\n\nАбзац.` comes back as one cell, `\n\n\n` as two |
| can a markdown cell carry metadata? | yes: with metadata it is written as `<!-- #region jncell="m1f2" -->` … `<!-- #endregion -->` and returns to the `.ipynb` with that metadata intact |
| can we write that region ourselves? | yes — a hand-written region becomes its own markdown cell with that id, exactly as `jncell="…"` in an info string does for code |
| does the round trip lose cells? | no: `ipynb → md → ipynb` over six cells kept all six, adjacent metadata-less markdown cells included |

So the mechanism for making prose first-class is jupytext's own, and an HTML comment is
invisible once the markdown is rendered. What stands in the way is not the format but
`cells.list`: everything that executes hangs off it — Run All, the `index` numbering,
statuses under cells, `]c`/`[c`, split/join/move, the text objects — 18 call sites in 8
modules. Let prose into that list and Run All walks over the headings. Making markdown a
cell therefore means **splitting the list by kind, not widening it**: a code-only list for
whatever runs, and a full one for the snapshot, the agent and the outline.

### 7.2.1. Sorting a table

`order_by` is a list of `{column, desc}` in order of importance. The sidecar does the
sorting, before slicing the page: otherwise page 2 would be sorted separately from page 1
and paging would stop being consistent. Reading the whole file is not needed for that —
`scan_parquet().sort().slice()` stays lazy.

The accumulation is done on the Lua side: the chosen column goes to the top of the stack,
and the previous keys stay behind it as tie-breakers. Choosing the same column again lifts
it back to the top and flips the direction instead of adding a duplicate. Changing the order
returns you to the first page: looking at the middle of a different order makes no sense.

The column under the cursor is determined from the layout the formatter returns together
with the rows: for every column it is known where it starts and ends in screen cells, and
which one it is by count. The index is what copying a cell (`<CR>`) needs: the value is taken
out of the page's data, because in the buffer it has been clipped to `max_col`. The row is
counted from the position in the buffer — `rows` lies in exactly the order it was drawn in,
after sorting as well, since the sorting happens in the sidecar before the page is sliced.

### 7.3. Honesty about the output on screen

One drawer per notebook means the window easily ends up holding output that no longer
relates to the text on screen. Hence three marks, all of them cheap:

- **the time of the run** — `из истории · 03.09 12:46` ("from history");
- **`⚠ код изменился`** ("the code changed") — the sha of the cell's code does not match
  the run's `code_sha`. This is the strongest sign: it says not "the output is old" but
  "the output did not come from this code". Redrawing hangs on `TextChanged`, and the
  answer is cached by `changedtick`;
- **`⏳ ещё N`** ("N more") — other runs are going on somewhere.

Errors are stored alongside successful runs: `status: error` plus `ename` in the index and
the traceback in the `.txt`. That is why "why did it fail yesterday" is answered without a
re-run, and paging through runs lets you walk from a failed attempt back to the last good
result.

### 7.4. The snapshot for an outside reader

`.jupyter-out` makes outputs available from outside, but only by cell id, and the id itself
lives in the document's text. So an outside tool, to get from "the second cell" to a
parquet, has to repeat our parsing: cell boundaries, `jncell` out of the fence, the
directory layout, the sha for freshness. That is a second copy of the rules, and it
diverges from the first exactly where the rules are non-trivial — that is, in the edge
cases they were written for.

Hence `snapshot.build`: one structure where the cells are already matched with the last run
of each. The boundary is hard — **the snapshot computes nothing anew and writes nothing**.
Freshness comes from the same sha comparison as the mark in the drawer; the id is taken
read-only (`exec.cell_id`, not `cellid.ensure`), otherwise viewing a notebook would edit the
document. There are still two sources of truth: the buffer and `index.jsonl`.

A run in progress is reported by two fields, not one. `running` says the cell is busy;
`live.status` says what it is busy with — waiting in the kernel's queue or being computed.
While a single flag answered both questions, "run all" looked from outside like a kernel
computing sixteen cells at once, and the reader drew the conclusion the flag invited: that
nothing was moving. `live` also carries the size and the last line of the output collected
so far — the record in `index.jsonl` appears only when the run ends, so until then there is
nothing else to tell a moving run from a stuck one.

The cells' text is not part of the snapshot: the reader has it already — the buffer is
taken whole in one call, and the boundaries come from the snapshot. Duplicating it would
mean handing out the same thing two ways and inviting the question "which one is right"
when the buffer is edited while it is being read.

### 7.4.1. The draft of an unsaved buffer

The task is not the one `:w` solves. The buffer is markdown from jupytext, the file on disk
is an `.ipynb`: a real write runs an external converter and passes through the
`BufWritePre` of every other plugin. On a timer, while you are typing, that is
unacceptable. So the draft writes the buffer's text as it is — no conversion, past the
notebook file and past other people's autocommands.

Decisions, each of them paid for by a specific breakage:

- **Not a `<name>.md` next to the notebook.** That is precisely the file jupytext.nvim
  considers its own cache and starts reading instead of the notebook, without comparing
  dates (the "Known issues" section of the README). A draft with such a name would turn
  insurance into quiet data corruption. Its place is `.jupyter-out/<name>/drafts/`, the
  same directory as the history, and it is in `.gitignore` already.
- **Named by `<pid>-<open counter>`, not one per notebook.** Two nvims on one file is a
  legitimate case; a shared draft would mean the second overwriting the first one's unsaved
  work. The counter grows on every opening of the buffer inside the process: without it, a
  new life of the same notebook would write over the draft it had just found.
- **A candidate for recovery is either our own pid or a dead one.** Someone else's live
  process is typing into that draft right now and must not be touched. Our own may be:
  `:bd!` loses work just as a crash does. The check goes through `orphans.alive`, that is,
  signal 0.
- **Atomicity through `rename`.** A crash in the middle of a write would otherwise leave a
  stump. The text first, the metadata after: the text is what it is all for, and the
  metadata carries the sha that shows it belongs to that text. If they disagree, we believe
  the text and not the story about it.
- **The notebook's `mtime` in the metadata.** It tells "nobody touched the file" from "it
  was rewritten from Jupyter Lab". In the second case the draft must not be slipped in
  silently. The same field answers "may the draft be dropped": **not by the `modified`
  flag**. That flag is set by more than nvim — jupytext.nvim clears it in its
  `BufWriteCmd` before the external converter has run, and regardless of whether it runs at
  all. Verified on a live session: the buffer "saved", the `.ipynb` half an hour old, the
  draft dropped. We drop it only once the notebook file has changed since the draft was
  written. Milliseconds as a whole number, not seconds: `getftime` cannot tell two writes
  within the same second apart, and a fractional value through `vim.json` loses its last
  digits and reads back slightly smaller.
- **Only buffers with a real file.** otter.nvim keeps a copy of the cells' code in a
  `<notebook>.otter.py` buffer with `ft=python` — there is no such file on disk,
  `cells.list` sees a cell in it (the percent representation counts a whole file with no
  markers as one cell), and `:t:r` gives it a directory of its own in `.jupyter-out`.
  Drafts were being written there instead of the notebook's.
- **Matching the buffer is not a reason to drop the draft.** Removing it silently is only
  allowed when the buffer has no edits, that is, matches the file. With unsaved edits, "the
  draft equals the buffer" means exactly the opposite — the draft is fresh and the work is
  nowhere else. This cost a whole session: on exit the buffer managed to detach and
  immediately attach again, the new draft found the old one, saw that it matched the
  unsaved buffer and deleted it (`detach` → `attach` → `check.same` → `drop` within one
  second by the journal).
- **A final write when the buffer is unloaded, not on `VimLeavePre`.** On `:qa!` the buffer
  is unloaded before `VimLeavePre` arrives, and by then it is no longer in the list —
  everything typed during the last seconds of the debounce was lost.
- **The `drafts/trace.log` journal.** Everything interesting about a draft happens on exit
  and after a crash, when neither `:JupyterLog` nor `:messages` can be asked any more. It is
  appended immediately, one line per event, and trimmed by size. Both losses above were
  found by it.
- **Recovery puts the text into the buffer and stops.** The plugin does not write to the
  file: the user has not yet seen what came back. Undo is broken on both sides, as in
  `agent.lua` — otherwise one `u` would take away both the recovery and whatever was typed
  before it.

The module's boundary: `draft.lua` knows nothing about the kernel or about runs, and writes
nothing into the document except on an explicit command from the user. That is why it
attaches to the buffer on `FileType`, before any session: the text needs protecting even
when python has never been started.

`autosave.write_on_run` is a separate story and a second layer. It is a real `:w`, and
specifically `:w` rather than `noautocmd write`: the markdown → `.ipynb` conversion is done
by jupytext through `BufWriteCmd`, and with autocommands off, raw markdown would go into
the file. The moment is chosen in domain terms: the code that ran is on disk, and
`code_sha` in the index refers to it. Off by default, because `:w` drags other people's
`BufWritePre` along with it.

### 7.5. Editing from outside

Reading a notebook from outside is safe, writing is not: tens of seconds pass between an
outside reader taking a cell and returning an answer, and the document is alive all that
time. By the moment of writing, line numbers mean nothing any more, and an edit by them
lands in a neighbouring cell or in the middle of somebody's paragraph. Hence two phases:
`agent.begin` puts down an anchor, `agent.apply` writes by that anchor.

There are two anchors, and that is not belt and braces but two different kinds of shift.
`jncell` survives a whole cell being moved — an extmark in that case would stay where it
was, that is, point at foreign text. An extmark survives edits above and below — while a
cell may have no id at all (§7.2). On top of both there is the sha of the body: the anchor
answers **where** the cell is, the sha answers **whether it is the same one**. Without the
second question an edit silently overwrites whatever the user typed inside the cell while
the agent was thinking; a `changed` refusal is more expensive for the agent but cheaper for
the document. 99 ([ThePrimeagen/99](https://github.com/ThePrimeagen/99)), where the idea of
using marks comes from, has no such check: it only holds the boundaries of a region.

Two smaller decisions, both of which cost debugging:

- **undo is broken on both sides of the write** (`let &undolevels = &undolevels`).
  Otherwise the edit is glued to the user's insert session into a single block, and their
  `u` takes away both — verified headless. The break goes through `nvim_buf_call`:
  `&undolevels` is read from the current buffer, while the agent edits the one it named —
  and the user may be looking at another document at that moment.
- **Its own namespace, not shared with the statuses.** `ui.status` clears its own namespace
  entirely on every redraw, and the claim's mark would disappear at the first keystroke.

The mark in the buffer is not decoration: a claim lives for as long as the agent is
thinking, and without it the user does not know that someone has this cell in their sights.
That is why it appears in `begin` and not at the moment of writing.

**What the claim looks like is part of the mechanism, not decoration.** The piece is fenced
off by two virtual lines, above and below, each carrying a spinner, the agent's name, the
verb and the age; the body between them is highlighted and every line of it gets a `✎` in
the signcolumn. Three channels, and each answers a different question: the fence — *where*
the edit will land, including when the body is longer than the screen and neither edge is
in view; the signcolumn — *that* something is happening, in the column the eye already scans
for diagnostics and git; the spinner and the age — *whether it is still going*. Virtual
lines and not text: they cannot be typed into, `:w` does not save them and jupytext never
sees them, so the document underneath stays exactly what it was. The spinner is ten braille
frames on a 250 ms tick, straight from 99; the buffer is only redrawn while it is on screen,
because a wheel spins for an eye and there is none behind a hidden buffer.

**Where the label hangs was decided by two facts about other people's rendering.** The first:
render-markdown hides a cell's fences whole (`conceal_lines`), and a `virt_lines` on a hidden
line is not drawn at all — the label appeared only when the cursor landed on that line and
conceal let go of it. So the anchor is never the fence: the frame goes through
`common.virt_line_below`, the same helper the cell statuses use, and an insert claim at the
very end of the buffer gets one blank line appended to hang from — the only case where a
claim touches the document, and `forget` takes the line back if it is still empty. Whether
the fence is *actually* hidden we do not ask: `conceal_lines` is placed per visible region,
so the same document answers differently depending on where it is scrolled.

The second: several virtual lines on one buffer line are drawn in the order of their
extmarks, and `priority` does not govern it — verified on a live buffer, a label at
`priority = 5000` still swapped places with a status the moment that status was redrawn, and
statuses are redrawn on every keystroke. Hence two measures. An insert claim hangs its label
*below* the blank line that separates cells, while the status of the cell above hangs above
it: different slots, nothing to argue about — and the label ends up exactly in the gap where
the new cell will appear. For everything that still shares a line, `agent.reanchor` re-places
the labels right after the statuses are drawn, so the order is restored rather than left to
chance.

**A claimed cell does not run.** `exec` asks a predicate before every execution — the plugin
answers "an agent is rewriting this one" — and skips it, saying so once per second rather
than once per cell, because Run All would otherwise fire a volley of identical messages. The
reason is not politeness: the code is about to be replaced, so the output would belong to a
version that will not exist a second later, and `index.jsonl` would record it as a real run
of the current code. The question is asked *before* `cellid.ensure`, so a refused run leaves
no freshly written id behind. Insert claims block nothing — there is no cell yet.

**And a claim is mortal.** `begin` has a counterpart in time, not only in `apply`: the agent
may crash, run out of its limit, or stop to ask a question and never come back — none of
which sends a `cancel`. The mark that stays behind is worse than no mark at all, because it
says a cell is taken while nobody is working on it, and the user steers around it. So a
claim carries a deadline (`ttl_ms`, five minutes), a timer ticks while claims exist and
stops when the last one is gone, and the label shows its own age — `✎ Claude · 2м10с`. The
age is what separates "thinking" from "gone": a pause looks the same either way, a stopped
counter does not. Whoever thinks longer than the deadline says `touch`, which restarts it;
that is deliberately an action, not a setting, because the only honest evidence that an
agent is alive is the agent doing something. A token dropped by time is remembered, so
`apply` can answer `expired` ("open a new claim") rather than `no_request` ("you got the
token wrong") — two different problems for whoever is on the other end.

### 7.6. A prompt from the notebook

§7.5 is the agent's half of the protocol: it takes a cell, thinks, writes back. This is the
other half — the user's. Without it the place has to be described in words ("the cell where
I read the parquet, the second one from the bottom"), and the agent spends turns looking for
what the user is already looking at.

**The transport is tmux, not a process of ours.** The session lives in its own pane, opened
by a person: it survives a restart of nvim, it is where permission prompts are answered and
questions asked, and a crash in it is visible rather than silent. Three commands put a
prompt into it — `load-buffer` from a file, `paste-buffer -d -p`, `send-keys Enter`. Through
a file and a tmux buffer rather than `send-keys -l "text"` because a prompt is arbitrary
text: quotes, `$`, backslashes. And worse — for `send-keys` a newline is indistinguishable
from Enter, so a multi-line prompt would be submitted a line at a time, the first line
arriving as a whole question. `paste-buffer -p` wraps the paste in bracketed paste, where
newlines stay newlines; the only Enter is ours, sent separately.

Finding the pane is a ladder, from exact to general: the one remembered in `agent.json` →
the one next to nvim in the same window → the only one in the same tmux session → by the
notebook's directory → ask the user (`:JupyterAgentAttach`). It is a ladder rather than a
question because asking "where is your agent" on every prompt is unusable, and guessing
silently is worse than that: a prompt that went to the wrong pane looks like a prompt that
vanished. "Next to nvim" sits above "by directory" deliberately — the agent a person keeps
beside their editor is the one they are working with, while matching directories is only a
guess.

**The claim is opened by the plugin, before sending, not by the agent after reading.** This
is the point of the whole thing, and it is the one part §7.5 could not provide. An edit
protocol makes a claim *impossible to skip* — `apply` takes a token and only `begin` issues
one — but it cannot make it *early*: an agent is free to think for a minute in silence, open
a claim and apply it in the same second. Formally honest, and it tells the user nothing. A
claim opened at keypress cannot be late, and it does not depend on the agent's discipline at
all.

What the plugin cannot know is what kind of edit it will be: "add a check after this" and
"rewrite this" point at the same cell. So the claim is opened as `pending` — it holds the
cell (and blocks running it, like any claim) but commits to nothing, `apply` on it refuses
with `not_adopted`, and the agent settles the question with `edit_adopt(token)` or
`edit_adopt(token, {after = true})`. The sha is taken at that moment rather than at send
time: otherwise anything the user typed while the prompt was in flight would come back as a
`changed` refusal of our own making.

The claim is dropped the instant sending fails. A mark with nobody behind it lies worse than
no mark at all — the same reason the deadline exists in §7.5.

One thing does get written into the document: `cellid.ensure` gives the cell under the
cursor a `jncell` if it has none. Without an id there is nothing to name to the agent and
nothing for a claim to anchor to — a fallback ordinal id belongs to a different cell as soon
as a neighbour is inserted. The plugin does this at the first run anyway (§7.2).

## 8. What is not supported

ipywidgets, interactive widgets and HTML tables; exporting output back into the `.ipynb`
and saving a session; a remote Jupyter server over HTTP; image providers other than
image.nvim; non-Python kernels.

**Editing prose from outside.** A markdown cell is not a cell in this model (§7.2.2), so it
has no id to name, nothing for a claim to anchor to and no sha to check. Inserting one is
not supported either — `cells.insert` writes a code fence, and markdown put there lands
inside ```` ``` ```` and breaks the next Run All. There is no fallback: writing to the
`.ipynb` or to the jupytext `.md` while the notebook is open in nvim is the one thing that
reliably breaks the document, so an outside reader hands the prose back in its reply and the
user places it.

`text/html` in v1: if the bundle has a `text/plain`, we take it; if it is HTML only, we
save a file and show it in the status.

## 9. Testing

**The sidecar is headless pytest against a real `ipykernel`**, with no nvim. That is the
very reason JSON-lines was chosen. Covered: routing with two cells in the queue, output
from a background thread after `idle`, `\r`/`\b`/ANSI, an interrupt with a queue, the death
and restart of a kernel, `input()`, readiness, an image as a file, `env` reaching the
kernel, cleanup of the connection file, a dataframe result, reading output without nvim,
trimming history, a table of 100k rows.

**Lua is plenary in headless nvim**, `tests/run.sh`. Some of the tests bring up a real
sidecar and kernel: that is a side benefit of the choice of transport — the whole async
class of problems (stdout callbacks arrive in a fast event context, where the API must not
be touched) is checked with no human involved. A dedicated test calls `nvim_buf_set_lines`
from inside an event handler.

The `.ipynb` → markdown → `.ipynb` round trip with real jupytext is the only automatic
protection against corrupting other people's documents, and it has to be there.

A rake in the harness that cost time: **`--noplugin` breaks plenary.** With that flag
`plugin/plenary.vim` is not loaded, the `:PlenaryBusted*` commands do not exist, and
headless nvim simply hangs waiting for input — without a single line of output. For the
same reason `runtimepath` in `minimal_init` is **set** rather than appended to: otherwise
the tests execute the user's config with all of its plugins, and any blocking prompt from
there hangs the run.

### What the flakes taught

Each of them reproduced roughly once in five runs, and all but the last turned out to be
real bugs rather than noise from the tests:

| symptom | what it really was |
|---|---|
| the first cell with no output | a premature `ready`: iopub not subscribed yet (§6.2) |
| `input()` sometimes hangs forever | the `input_request` is lost, the ROUTER does not know the identity (§6.2) |
| an `orphan` on a clean run | output of the kernel itself with no parent, not an anomaly (§4.5) |
| the kernel does not come up, `KeyboardInterrupt` in the imports | our own probe was interrupting the kernel before its loop came alive |
| a rare failure only under load | the only real noise: a tight waiting budget |
| `integration_spec` never reached the end, exit code 1 with no summary | not a flake: plenary's default timeout (50 s) and an interpreter without polars |

Not a single `sleep` in the tests — waiting is always on an event or on a state. That is
exactly why these bugs failed loudly instead of hiding.

**Flakes are not noise by default.** A test with a live kernel that fails one time in five
is treated as a bug in the code first and as a bug in the test second. Of the five cases
above, four were the code.

**A green test is not the same thing as a working feature.** An IPython traceback arrives as
a list with `\n` inside its elements, and `nvim_buf_set_lines` does not accept that. The
test for an error in a cell passed all the same: it was checking a structure in memory,
while the crash happened asynchronously, in an event handler. If a feature ends in drawing,
what has to be checked is the buffer's contents.

## 10. State

Done: the protocol and the sidecar, running cells, output into a buffer, paged tables,
stable ids and run history, the status under a cell, images, `:checkhealth`, text objects,
restructuring cells (§5, `edit.lua`), magic arguments, finding kernels with no owner and
attaching to a live kernel (§6.5).

A "cell navigation mode" is no longer in the plans, and that is a decision rather than
forgetfulness: an input shell would be wrapping emptiness, because nvim already has a
command mode — it is called normal mode. The value was in the operations themselves, and
those have been made.

Further work depends on actual use: cancelling an individual run, a pool of kernels for
parallel queries. The work queue with estimates is in CONTRIBUTING.md.

Not closed:

- ~~why the notebook's buffer kept losing its markdown `filetype`~~ — **found on
  10.09.2026, by a tripwire**. The journal held `представление fence при filetype=json
  (маркеров 0, фенсов 7)` ("fence representation with filetype=json; 0 markers, 7 fences"):
  the content was converted, the filetype json. The cause is neither in the plugin nor in
  jupytext — it is in nvim. `jupytext.nvim` sets `ft=markdown` once, in its own
  `BufReadCmd`, while `runtime/filetype.lua` re-decides the filetype on **every** `BufRead`
  from the file name, and `*.ipynb` is detected as `json` by default. The event fires on
  more than opening: netrw on `:Ex` triggers `BufRead` on the buffer that is in the window
  at that moment. The full scenario: open an `.ipynb` → `:Ex` → come back to the notebook
  (with harpoon, with `:e`, whatever) — and cells stop being recognised. It is cured on the
  configuration side with a single line,
  `vim.filetype.add({ extension = { ipynb = "markdown" } })`: the repeated detection then
  yields the same markdown. The plugin did everything it could on its side:
  `M.representation` also looks at the text, so the whole document no longer goes to the
  kernel as one cell, and the `cells.explain` tripwire named the culprit on the very first
  occurrence — which is what it was put there for;
- the user-visible problems are listed in the README ("Known issues") and are not
  duplicated here;
- protection against accidentally joining cells has not been made, and when it is, it will
  not be a prohibition. A miss by a couple of lines (`3dd` across a boundary) joins two
  cells silently: verified — 25 cells and 21 outputs turn into 24 and 20, and the code of
  the vanished cell cannot be restored from the history, which holds only a `code_sha`.
  Forbidding the edit is not an option: a guard that reverts changes cannot tell a slip
  from an intention and sooner or later will eat something needed. The idea is to notice:
  an id backed by history has disappeared from the document, so say so and remind about
  `u`. The signal is narrow, cells with no runs stay silent.

## 11. What it costs

Measured on 07–09.09.2026 on a real notebook: 823 lines, 27 cells, history on disk. The
numbers are not here for decoration — two decisions rest on them.

| | |
|---|---|
| nvim startup | 0: the plugin is lazy, it is absent from the `--startuptime` log |
| opening a notebook, end to end | 285 ms |
| of that, the jupytext conversion | 137–141 ms — not ours, and independent of the notebook's size: it is Python starting |
| of that, our attach (keys, window, reading history) | 3 ms |
| redrawing the statuses | 0.8 ms |
| a keystroke in insert mode | 1.1 ms |
| quitting nvim with a live kernel | 87 ms |

**The first decision — do not wait for the sidecar on exit.** Waiting cost 1868 ms on every
exit, and exactly the same on closing a buffer. The guarantee comes not from waiting but
from the sidecar itself: it puts the kernel out with a one-second deadline, and if it does
not live that long, a trace remains by which the kernel can be found (§6.5).

**The second — do not cache the conversion next to the notebook.** A cache saves 137 ms
(reading a ready file takes 0.02 ms), but a cache with no validity check shows yesterday's
document, and saving overwrites the real one with it. A proper cache lives outside the
working directory and is keyed by mtime; until there is one, we pay 137 ms for seeing the
real file.
