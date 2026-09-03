-- Минимальный init для headless-тестов.
--
-- runtimepath именно ЗАДАЁТСЯ, а не дополняется: по умолчанию в нём есть ~/.config/nvim,
-- то есть тесты исполняли бы пользовательский конфиг вместе со всеми его плагинами.
-- Любой блокирующий промпт оттуда ("Press ENTER or type command to continue" от lazy
-- при обновлении плагинов) в headless означает вис навсегда и без единой строки вывода.
-- Заодно тесты перестают зависеть от того, что творится в конфиге пользователя.

local this = debug.getinfo(1, "S").source:sub(2)
local root = vim.fn.fnamemodify(this, ":h:h")

vim.opt.runtimepath = vim.env.VIMRUNTIME
vim.opt.packpath = vim.env.VIMRUNTIME
vim.opt.runtimepath:append(root)
vim.opt.runtimepath:append(vim.fn.expand("~/.local/share/nvim/lazy/plenary.nvim"))

vim.opt.swapfile = false
vim.opt.shadafile = "NONE"

-- Сайдкару нужен python с jupyter_client и polars; в тестах это venv jupyter-utils.
vim.g.jupyter_python = vim.env.JUPYTER_NVIM_PYTHON
    or vim.fn.expand("~/work/jupyter-utils/.venv/bin/python")
