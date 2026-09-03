# jupyter.nvim

Notebook-workflow для nvim: ячейки в тексте, ядро в отдельном процессе, выводы вне документа.

Конструкция и границы модулей — `ARCHITECTURE.md`. Мотивация и тест-лист —
`~/work/ideas/nvim-notebook-plugin.md`.

## Состояние

Шаги 1 и 2 из `ARCHITECTURE.md` §10 сделаны: сайдкар работает целиком, без nvim.
`rpc`, `router`, `stream`, `outdir`, `kernel`, `mime`, `frames`, CLI. 85 тестов, из них 23 против
живого `ipykernel`.

Дальше — шаг 3: Lua-минимум (`sidecar`, `kernel`, `cells`, `exec`, `ui/output`).

## Тесты

Зависимости не ставятся — берётся venv `jupyter-utils`:

```sh
cd sidecar && PYTHONPATH=. ~/work/jupyter-utils/.venv/bin/python -m pytest -q
```
