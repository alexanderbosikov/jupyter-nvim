-- Минимальный init для headless-тестов: только плагин и plenary, никаких пользовательских настроек.
local this = debug.getinfo(1, "S").source:sub(2)
local root = vim.fn.fnamemodify(this, ":h:h")

vim.opt.runtimepath:append(root)
vim.opt.runtimepath:append(vim.fn.expand("~/.local/share/nvim/lazy/plenary.nvim"))
vim.opt.swapfile = false

-- Сайдкару нужен python с jupyter_client и polars; в тестах это venv jupyter-utils.
vim.g.jupyter_python = vim.env.JUPYTER_NVIM_PYTHON
    or vim.fn.expand("~/work/jupyter-utils/.venv/bin/python")
