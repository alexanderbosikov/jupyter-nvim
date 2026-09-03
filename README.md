# jupyter.nvim

Notebook-workflow для nvim: ячейки в тексте, ядро в отдельном процессе, выводы вне документа.

Конструкция и границы модулей — `ARCHITECTURE.md`. Мотивация и тест-лист —
`~/work/ideas/nvim-notebook-plugin.md`.

## Состояние

Шаги 1–3 из `ARCHITECTURE.md` §10 сделаны: ячейка выполняется в ядре, вывод приезжает
в scratch-буфер. 169 тестов (88 на сайдкар, 81 на Lua).

Пока нет: постраничного просмотра таблиц (шаг 4), стабильных id ячеек и истории прогонов
(шаг 5), статуса под ячейкой и картинок (шаг 6).

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
`:JupyterInterrupt`, `:JupyterRestart`, `:JupyterStatus`, `:JupyterStop`.

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
