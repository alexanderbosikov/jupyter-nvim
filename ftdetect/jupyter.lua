-- .ipynb открывается markdown-буфером, на диск уходит json (lua/jupyter/ipynb.lua).
--
-- Здесь, а не в setup(): `BufReadCmd` должен стоять до того, как откроется первый ноутбук,
-- а плагин грузится лениво. ftdetect читается при старте — встроенными пакетами и lazy.nvim
-- (для плагина с `ft`), — и стоит это трёх автокоманд: сам модуль подтягивается первым
-- ноутбуком.
--
-- Выключается `vim.g.jupyter_ipynb = false` до старта. Если стоит jupytext.nvim, ноутбуки
-- остаются за ним: два конвертера на одном буфере — это два `:w` разными путями.

if vim.g.jupyter_ipynb == false then
    return
end

-- jupytext.nvim регистрирует BufReadCmd глобально, а свой BufWriteCmd — на буфер
local function jupytext_nvim(event, buf)
    local ok, found = pcall(vim.api.nvim_get_autocmds, { group = "jupytext-nvim", event = event, buffer = buf })
    return ok and #found > 0
end

-- nvim на каждый `BufRead` заново решает filetype по имени, а `*.ipynb` у него json. Событие
-- шлёт не только открытие: netrw на `:Ex` дёргает `BufRead` у буфера в окне, и ноутбук молча
-- становился json (ARCHITECTURE.md §10). Чужой буфер (nil) детект не трогает.
vim.filetype.add({
    extension = {
        ipynb = function(_, buf)
            local mine = vim.b[buf].jupyter_ipynb
            if mine == nil then
                return nil
            end
            return mine and "markdown" or "json"
        end,
    },
})

local group = vim.api.nvim_create_augroup("jupyter.ipynb", { clear = true })

vim.api.nvim_create_autocmd("BufReadCmd", {
    group = group,
    pattern = "*.ipynb",
    callback = function(ev)
        if jupytext_nvim("BufReadCmd") then
            return
        end
        require("jupyter.ipynb").read(ev.buf, vim.fn.fnamemodify(ev.match, ":p"))
    end,
})

vim.api.nvim_create_autocmd({ "BufWriteCmd", "FileWriteCmd" }, {
    group = group,
    pattern = "*.ipynb",
    callback = function(ev)
        if vim.b[ev.buf].jupyter_ipynb == nil and jupytext_nvim(ev.event, ev.buf) then
            return
        end
        local range
        if ev.event == "FileWriteCmd" then
            range = { vim.api.nvim_buf_get_mark(ev.buf, "[")[1], vim.api.nvim_buf_get_mark(ev.buf, "]")[1] }
        end
        require("jupyter.ipynb").write(ev.buf, vim.fn.fnamemodify(ev.match, ":p"), range)
    end,
})
