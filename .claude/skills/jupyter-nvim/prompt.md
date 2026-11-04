# jupyter-nvim — a prompt sent from the notebook (`[jupyter.nvim]`)

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
Step 0 in `SKILL.md`.

**The claim is already open — do not open another one.** The plugin put the mark on that
piece the moment the user pressed the key: it has been visible since before you read the
prompt, and the cells inside will not run while it is there. Edit with `jn replace`
(`editing.md`) — edits that land inside the claim keep it alive and turn its label from
`отправлено` to `агент`. **When you are done, `jn done`** — that is what removes
the mark and lets the cells run again. Done includes "nothing to change" and "I answered in
words": the mark goes either way.

```sh
$JN --sock "$SOCK" done "$NB" "$CLAIM"
```

Whether the user wants the cell rewritten, a new cell after it, prose fixed, or nothing
changed at all — that is in the prompt, not in the claim. The claim only says *where*.
