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

-- Где искать plenary. Захардкоженный путь внутрь lazy работал только на машине автора,
-- а промах стоил дорого: без plenary команды :PlenaryBusted* не существует, и headless
-- nvim виснет в ожидании ввода без единой строки вывода (§9 ARCHITECTURE.md). Поэтому
-- перебираем известные места и, если не нашли, выходим с внятной ошибкой.
local function find_plenary()
    -- список собирается по одному: nil первым элементом оборвал бы ipairs на нулевом шаге
    local candidates = {}
    if vim.env.JUPYTER_NVIM_PLENARY then
        table.insert(candidates, vim.env.JUPYTER_NVIM_PLENARY)
    end
    local data = vim.fn.stdpath("data")
    table.insert(candidates, data .. "/lazy/plenary.nvim")
    for _, dir in ipairs(vim.fn.glob(data .. "/site/pack/*/start/plenary.nvim", false, true)) do
        table.insert(candidates, dir)
    end
    for _, dir in ipairs(candidates) do
        if dir and vim.fn.isdirectory(vim.fn.expand(dir)) == 1 then
            return vim.fn.expand(dir)
        end
    end
    return nil
end

local plenary = find_plenary()
if not plenary then
    io.stderr:write(
        "jupyter.nvim: не найден plenary.nvim, тесты запускать нечем.\n"
            .. "Поставь его любым менеджером плагинов или укажи путь:\n"
            .. "  JUPYTER_NVIM_PLENARY=/path/to/plenary.nvim ./tests/run.sh\n"
    )
    vim.cmd("cquit 1")
end
vim.opt.runtimepath:append(plenary)

vim.opt.swapfile = false
vim.opt.shadafile = "NONE"

-- Сайдкару нужен python с jupyter_client, ipykernel и polars.
-- Задаётся переменной окружения: JUPYTER_NVIM_PYTHON=/path/to/venv/bin/python ./tests/run.sh
vim.g.jupyter_python = vim.env.JUPYTER_NVIM_PYTHON or "python3"
