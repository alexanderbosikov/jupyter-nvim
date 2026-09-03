# jupyter.nvim

Notebook-workflow для nvim: ячейки в тексте, ядро в отдельном процессе, выводы вне документа.

Конструкция и границы модулей — `ARCHITECTURE.md`. Мотивация и тест-лист —
`~/work/ideas/nvim-notebook-plugin.md`.

## Состояние

Шаги 1–2 из `ARCHITECTURE.md` §10 сделаны целиком: сайдкар работает без nvim.
Шаг 3 наполовину: есть `sidecar`, `cells`, `kernel`; осталось `exec` и `ui/output`.

Дальше — первый момент, когда `%%sql` даёт текст в буфере.

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
