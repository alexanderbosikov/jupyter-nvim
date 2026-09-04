# jupyter.nvim

Работа с Jupyter-ноутбуками в nvim: ячейки — обычный текст, ядро живёт в отдельном
процессе, выводы хранятся вне документа.

Три решения, из которых следует всё остальное:

- **Вывод — текст в буфере, а не виртуальный текст.** Его можно копировать, искать и
  скроллить штатными средствами редактора.
- **Документ остаётся кодом.** В `.ipynb` не попадают ни выводы, ни картинки: они лежат
  рядом, в `.jupyter-out/`. Диффы читаемые, файл не разрастается.
- **Результат-датафрейм сохраняется в parquet.** Таблица на сотни тысяч строк не
  превращается в мегабайты HTML и листается постранично, не читаясь целиком.

## Требования

- Neovim 0.10+
- Python с `jupyter_client`, `ipykernel` и (для таблиц) `polars`
- [image.nvim](https://github.com/3rd/image.nvim) — опционально, для картинок
- [jupytext.nvim](https://github.com/GCBallesteros/jupytext.nvim) — если работаешь с `.ipynb`

## Установка

```lua
{
    "alexanderbosikov/jupyter-nvim",
    ft = { "python", "markdown" },
    main = "jupyter",
    init = function()
        -- интерпретатор, которым запускается сайдкар
        vim.g.jupyter_python = vim.fn.expand("~/.venvs/jupyter/bin/python")
    end,
    opts = {
        kernel_name = "python3",
        output = { position = "right", size = 0.5 },
    },
}
```

Проверить окружение: `:checkhealth jupyter` — интерпретатор, версии библиотек,
рукопожатие с сайдкаром, наличие kernelspec и image.nvim.

## Клавиши и команды

Дефолтные мапы ставятся буфер-локально и заменяются целиком через `opts.keys`
(значением может быть строка или список клавиш); `keys = false` отключает их совсем.

| действие | по умолчанию |
|---|---|
| выполнить ячейку | `<leader>jc` |
| выполнить все / с текущей и ниже | `<leader>jA` / `<leader>jB` |
| ячейка выше / ниже | `<leader>ja` / `<leader>jb` |
| следующая / предыдущая ячейка | `]c` / `[c` |
| окно вывода | `<leader>jo` |
| таблица постранично | `<leader>jt` |
| предыдущий / следующий прогон ячейки | `[r` / `]r` |
| прервать / перезапустить ядро | `<leader>ji` / `<leader>jR` |

Команды: `:JupyterRun`, `:JupyterRunAll`, `:JupyterRunBelow`, `:JupyterOutput`,
`:JupyterTable`, `:JupyterRunPrev`, `:JupyterRunNext`, `:JupyterInterrupt`,
`:JupyterRestart`, `:JupyterHistory`, `:JupyterRepaint`, `:JupyterClearImages`,
`:JupyterLog`, `:JupyterStatus`, `:JupyterStop`.

В окне вывода: `t` — таблица постранично, `y` — скопировать вывод, `c` — очистить,
`q` — закрыть. В окне таблицы: `H`/`L` — страницы, `[[`/`]]` — края, `R` — перечитать,
`q` — закрыть вкладку.

## Ячейки

Понимаются два представления одного ноутбука:

- **percent** — `.py` с маркерами `# %%`; ячейки `# %% [markdown]` пропускаются;
- **fenced** — markdown после jupytext; код-ячейка это ```` ```python ````, а также фенс
  с языком магики (```` ```sql ````) — такую ячейку jupytext хранит с `magic_args`
  в info-строке, и строка `%%sql` собирается обратно в момент отправки ядру.

## Что плагин пишет в документ

При первом запуске ячейки к её маркеру дописывается идентификатор:

```
```python jncell="a3f9"      # в markdown-представлении
# %% jncell="a3f9"           # в percent-файлах
```

Это единственная правка документа, и она отменяется обычным undo. В `.ipynb` id попадает
в cell metadata и переживает конвертацию в обе стороны. В тело ячейки id не попадает
никогда — иначе он уехал бы в ядро частью кода.

По этому id находится история прогонов, в том числе снаружи редактора.

## Где лежат выводы

```
<каталог ноутбука>/.jupyter-out/<имя>/
    index.jsonl          по строке на прогон: статус, время, размер, sha кода
    a3f9/12.parquet      результат-датафрейм
    a3f9/13.txt          текстовый вывод
    b7e1/3.png           картинка
    kernel.log           собственный лог ядра
```

Каталог стоит добавить в `.gitignore`: он восстановим прогоном.

Прочитать вывод снаружи nvim:

```sh
python -m jupyter_nvim.cli notebook.ipynb a3f9          # текст
python -m jupyter_nvim.cli notebook.ipynb a3f9 --json   # запись индекса
python -c "import polars as pl; print(pl.read_parquet('.jupyter-out/notebook/a3f9/12.parquet'))"
```

## Свежий вывод и старый

Окно вывода следует за курсором и показывает прогон той ячейки, на которой он стоит,
включая прогоны из истории — то есть вывод вчерашней ячейки виден сразу при открытии
файла, без запуска ядра. Чтобы старый вывод не выдавал себя за свежий, в строке статуса
появляются пометки: время прогона (`из истории · 03.09 12:46`), `⚠ код изменился`, если
код ячейки правили после прогона, и `⏳ ещё N`, если где-то ещё идут вычисления.

Под каждой выполнявшейся ячейкой рисуется строка состояния: время, размер таблицы, имя
исключения, `⟲` для прогона из истории.

## Настройки

```lua
opts = {
    kernel_name = "python3",
    python = nil,                    -- по умолчанию vim.g.jupyter_python
    env = {},                        -- переменные окружения ядра
    filetypes = { "python", "markdown" },
    out_dir = ".jupyter-out",
    images = true,
    highlight = true,                -- свои группы подсветки для winbar
    output = {
        position = "bottom",         -- или "right"
        size = 15,                   -- меньше единицы — доля экрана
        follow_cursor = true,
        preview_rows = 30,           -- строк таблицы прямо в окне вывода
        open_on_attach = false,      -- открыть окно при открытии ноутбука
    },
    table = { page_size = 100, max_col = 40 },
    status = { enabled = true, position = "below" },
}
```

## Тесты

Сайдкар — pytest; интерпретатор задаётся переменной окружения:

```sh
cd sidecar && PYTHONPATH=. python -m pytest -q
```

Lua — plenary в headless nvim; часть тестов поднимает настоящий сайдкар и ядро:

```sh
JUPYTER_NVIM_PYTHON=~/.venvs/jupyter/bin/python ./tests/run.sh
./tests/run.sh tests/cells_spec.lua    # один файл
```

Устройство и принятые решения — в [ARCHITECTURE.md](ARCHITECTURE.md).
