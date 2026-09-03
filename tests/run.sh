#!/bin/sh
# Прогон headless-тестов Lua. Сайдкар отдельно, через pytest в sidecar/.
#
# Без --noplugin: он не даёт загрузиться plugin/plenary.vim, команды :PlenaryBusted*
# тогда не существует, и headless nvim просто висит в ожидании ввода.
cd "$(dirname "$0")/.." || exit 1
exec nvim --headless -u tests/minimal_init.lua \
    -c "PlenaryBustedDirectory ${1:-tests/} { minimal_init = 'tests/minimal_init.lua' }"
