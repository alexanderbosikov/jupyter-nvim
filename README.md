# jupyter.nvim

Notebook-workflow для nvim: ячейки в тексте, ядро в отдельном процессе, выводы вне документа.

Конструкция и границы модулей — `ARCHITECTURE.md`. Мотивация и тест-лист —
`~/work/ideas/nvim-notebook-plugin.md`.

## Состояние

Шаги 1–5 из `ARCHITECTURE.md` §10 сделаны: ячейка выполняется в ядре, вывод приезжает
в scratch-буфер, результат-таблица листается постранично прямо из parquet, а история
прогонов переживает перезагрузку — вывод вчерашней ячейки виден без ядра.
232 теста (91 на сайдкар, 141 на Lua).

Пока нет: статуса под ячейкой и картинок (шаг 6).

## Что плагин пишет в документ

При первом запуске ячейки к её маркеру дописывается идентификатор:

```
```python jncell="a3f9"      # в markdown-представлении jupytext
# %% jncell="a3f9"          # в percent-файлах
```

Это единственная правка документа, и она отменяется обычным undo. В `.ipynb` id попадает
в cell metadata, круг ipynb → md → ipynb проверен тестом на 65 ячейках. В тело ячейки id
не попадает никогда — иначе он уехал бы в Redshift частью `%%sql`-запроса.

Зачем: по этому id находится история прогонов в `.jupyter-out/`, в том числе снаружи nvim.

## Попробовать

Сайдкару нужен python с `jupyter_client` и polars:

```lua
vim.g.jupyter_python = vim.fn.expand("~/work/jupyter-utils/.venv/bin/python")

{
    dir = "~/projects/jupyter.nvim",
    ft = { "python", "markdown" },
    opts = {
        kernel_name = "jupyter-utils",
        keys = false, -- см. предупреждение ниже
    },
}
```

**Осторожно с клавишами.** Дефолты (`<leader>jc`, `<leader>ja`/`jb`, `<leader>jo`, `]c`/`[c`)
совпадают с мапами обвязки к molten. Пока оба плагина стоят рядом, ставь `keys = false` и вешай
свои на другой префикс, либо зови API напрямую: `require("jupyter").run_cell()`.

Команды: `:JupyterRun`, `:JupyterRunAll`, `:JupyterRunBelow`, `:JupyterOutput`,
`:JupyterTable`, `:JupyterInterrupt`, `:JupyterRestart`, `:JupyterLog`, `:JupyterHistory`,
`:JupyterStatus`, `:JupyterStop`.

В окне таблицы: `H`/`L` — страницы, `[[`/`]]` — первая и последняя, `R` — перечитать,
`q` — закрыть вкладку.

Ядро поднимается лениво, на первом запуске ячейки. Нажать запуск можно сразу — запрос
подождёт в очереди.

## Тесты

Зависимости не ставятся — берётся venv `jupyter-utils`:

Сайдкар — pytest, зависимости берутся из venv `jupyter-utils`, ставить ничего не нужно:

```sh
cd sidecar && PYTHONPATH=. ~/work/jupyter-utils/.venv/bin/python -m pytest -q
```

Lua — plenary в headless nvim (часть тестов поднимает настоящий сайдкар):

```sh
./tests/run.sh                       # всё
./tests/run.sh tests/cells_spec.lua  # один файл
```
