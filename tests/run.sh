#!/bin/sh
# Прогон headless-тестов Lua. Сайдкар отдельно, через pytest в sidecar/.
#
# Без --noplugin: он не даёт загрузиться plugin/plenary.vim, команды :PlenaryBusted*
# тогда не существует, и headless nvim просто висит в ожидании ввода.
cd "$(dirname "$0")/.." || exit 1

# Проверка интерпретатора до запуска: без polars integration_spec умирает на третьем
# тесте, унося с собой остальные сорок с лишним. Молча — падение приходит из ядра.
PY="${JUPYTER_NVIM_PYTHON:-python3}"
for mod in jupyter_client ipykernel polars; do
    if ! "$PY" -c "import $mod" 2>/dev/null; then
        echo "jupyter.nvim: в $PY нет модуля $mod — тесты с живым ядром не пройдут." >&2
        echo "  JUPYTER_NVIM_PYTHON=/path/to/venv/bin/python $0" >&2
        exit 1
    fi
done

# timeout задан явно: дефолт plenary — 50 с на файл, а integration_spec поднимает
# настоящие ядра и идёт дольше. При дефолте родитель бросал ребёнка на полпути, и это
# выглядело как флак прогонщика: код возврата 1, ни сводки, ни списка падений, а в
# системе оставался повисший nvim с сайдкаром и ядром.
exec nvim --headless -u tests/minimal_init.lua \
    -c "PlenaryBustedDirectory ${1:-tests/} { minimal_init = 'tests/minimal_init.lua', timeout = 400000 }"
