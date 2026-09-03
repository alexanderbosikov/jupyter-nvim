-- Вывод ячейки в обычном scratch-буфере (ARCHITECTURE.md §4.3).
--
-- Не virt_text: вывод должен нативно копироваться, искаться и скроллиться. Именно из-за
-- virt_text у molten понадобились и свой drawer, и окно вывода, и :MoltenYankOutput.
--
-- Один drawer на ноутбук, показывает сфокусированную ячейку (решение из §1). Статус —
-- в winbar, потому что это свойство окна, а не строка вывода: список строк остаётся
-- ровно тем, что напечатала ячейка, и его можно яркнуть целиком.

local common = require("jupyter.ui.common")

local M = {}

M.DEFAULT_KEYS = {
    { mode = "n", key = "q", action = "close" },
    { mode = "n", key = "c", action = "clear" },
    { mode = "n", key = "y", action = "yank" },
    { mode = "n", key = "gg", action = "top" },
    { mode = "n", key = "G", action = "bottom" },
}

local STATUS = {
    running = "⏳ выполняется",
    ok = "✓",
    error = "✗",
    aborted = "⊘ прервано",
}

---@class jupyter.Output
local Output = {}
Output.__index = Output

---@param opts? table position ("bottom"|"right"), size, keys, follow, pending
function M.new(opts)
    opts = opts or {}
    return setmetatable({
        -- функция-счётчик прогонов, идущих не в этом окне: рисуется в winbar
        pending = opts.pending,
        position = opts.position or "bottom",
        size = opts.size or 15,
        keys = opts.keys or M.DEFAULT_KEYS,
        follow = opts.follow ~= false, -- скроллить к концу вывода по мере поступления
        buf = nil,
        win = nil,
        run = nil,
    }, Output)
end

-- --- окно ---

function Output:_ensure_buf()
    if self.buf and vim.api.nvim_buf_is_valid(self.buf) then
        return self.buf
    end
    self.buf = common.scratch_buf("jupyter://output", "jupyter-output")
    common.apply_keys(self.buf, self:get_actions(), self.keys)
    return self.buf
end

function Output:is_open()
    return self.win ~= nil and vim.api.nvim_win_is_valid(self.win)
end

---Открыть окно, не забирая фокус: пользователь остаётся в ноутбуке.
function Output:open()
    if self:is_open() then
        return self.win
    end
    local from = vim.api.nvim_get_current_win()
    local buf = self:_ensure_buf()

    vim.cmd(self.position == "right" and ("botright %dvsplit"):format(self.size)
        or ("botright %dsplit"):format(self.size))
    self.win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(self.win, buf)

    vim.wo[self.win].number = false
    vim.wo[self.win].relativenumber = false
    vim.wo[self.win].signcolumn = "no"
    vim.wo[self.win].wrap = false
    vim.wo[self.win].winfixheight = true

    self:_render_winbar()
    if vim.api.nvim_win_is_valid(from) then
        vim.api.nvim_set_current_win(from)
    end
    return self.win
end

function Output:close()
    if self:is_open() then
        vim.api.nvim_win_close(self.win, true)
    end
    self.win = nil
end

function Output:toggle()
    if self:is_open() then
        self:close()
    else
        self:open()
    end
end

-- --- содержимое ---

---Показать прогон. Открывает окно, если оно закрыто.
---@param run jupyter.Run
function Output:show(run)
    self.run = run
    self:open()
    self:render()
end

---Обновить содержимое, если показываем именно этот прогон.
---@param run jupyter.Run
function Output:update(run)
    if not self.run or self.run.cell_id ~= run.cell_id then
        return false
    end
    self.run = run
    self:render()
    return true
end

function Output:render()
    local buf = self:_ensure_buf()
    local lines = self.run and self.run.lines or {}
    if #lines == 0 then
        lines = { "" }
    end
    common.set_lines(buf, lines)
    self:_render_winbar()

    if self.follow and self:is_open() then
        local count = vim.api.nvim_buf_line_count(buf)
        pcall(vim.api.nvim_win_set_cursor, self.win, { count, 0 })
    end
end

---Строка статуса для winbar. Отдельным методом, потому что это единственная часть
---UI, которую удобно проверять тестом.
---@return string
function Output:status()
    local run = self.run
    if not run then
        return "нет вывода"
    end
    if run.status == "running" then
        return STATUS.running
    end
    if run.status == "error" then
        local name = run.error and run.error.code or "ошибка"
        return ("%s %s"):format(STATUS.error, name)
    end
    if run.status == "aborted" then
        return STATUS.aborted
    end

    local parts = {}
    if run.duration_ms then
        table.insert(parts, ("%.1f с"):format(run.duration_ms / 1000))
    end
    if run.table then
        table.insert(parts, ("%s × %s"):format(run.table.rows, run.table.cols))
    else
        table.insert(parts, ("%d строк"):format(#run.lines))
    end
    return ("%s %s"):format(STATUS.ok, table.concat(parts, " · "))
end

---Пересобрать только строку статуса. Нужно, когда изменился прогон, который в окне
---не показывается: счётчик «ещё выполняется» иначе останется висеть неверным.
function Output:refresh_status()
    self:_render_winbar()
end

function Output:_render_winbar()
    if not self:is_open() then
        return
    end
    local cell = self.run and self.run.cell_id or "—"
    local pending = self.pending and self.pending() or 0
    vim.wo[self.win].winbar = table.concat({
        " ",
        common.escape_status("ячейка " .. cell),
        "%=",
        common.escape_status(self:status()),
        pending > 0 and common.escape_status((" · ⏳ ещё %d"):format(pending)) or "",
        " ",
    })
end

-- --- действия ---

---@return table<string, fun()>
function Output:get_actions()
    return {
        close = function() self:close() end,
        clear = function()
            if self.run then
                self.run.lines = {}
            end
            self:render()
        end,
        yank = function()
            local buf = self:_ensure_buf()
            local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
            vim.fn.setreg('"', table.concat(lines, "\n"))
            vim.notify(("jupyter.nvim: скопировано строк — %d"):format(#lines))
        end,
        top = function()
            if self:is_open() then
                pcall(vim.api.nvim_win_set_cursor, self.win, { 1, 0 })
            end
        end,
        bottom = function()
            if self:is_open() then
                local count = vim.api.nvim_buf_line_count(self:_ensure_buf())
                pcall(vim.api.nvim_win_set_cursor, self.win, { count, 0 })
            end
        end,
    }
end

return M
