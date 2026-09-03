-- Постраничный просмотр результата-таблицы (ARCHITECTURE.md §4.2, шаг 4 в §10).
--
-- Данные лежат в parquet рядом с ноутбуком, страницу нарезает сайдкар через
-- scan_parquet().slice() — файл целиком не читается никогда. Таймера с filereadable,
-- как в molten_table.lua, здесь нет: сайдкар присылает готовую страницу ответом.
--
-- Выравнивание колонок делает Lua, а не сайдкар: только она знает ширину окна (§3).
-- Ширина считается через strdisplaywidth, а не по байтам, иначе кириллица разъезжается.

local common = require("jupyter.ui.common")
local hl = require("jupyter.highlight")

local M = {}

M.DEFAULT_KEYS = {
    { mode = "n", key = "L", action = "page_next" },
    { mode = "n", key = "H", action = "page_prev" },
    { mode = "n", key = "]]", action = "page_last" },
    { mode = "n", key = "[[", action = "page_first" },
    { mode = "n", key = "R", action = "refresh" },
    { mode = "n", key = "q", action = "close" },
}

local GAP = "  "
local RULE = "─"
local ELLIPSIS = "…"

---Обрезать по ширине отображения, а не по байтам.
---@param text string
---@param width integer
---@return string
local function clip(text, width)
    if vim.fn.strdisplaywidth(text) <= width then
        return text
    end
    local out = ""
    for _, char in ipairs(vim.fn.str2list(text)) do
        local candidate = out .. vim.fn.nr2char(char)
        if vim.fn.strdisplaywidth(candidate) > width - 1 then
            break
        end
        out = candidate
    end
    return out .. ELLIPSIS
end

local function pad(text, width)
    return text .. string.rep(" ", math.max(0, width - vim.fn.strdisplaywidth(text)))
end

---Свернуть страницу в строки буфера с выровненными колонками.
---@param header string[]
---@param rows string[][]
---@param opts? table max_col
---@return string[]
function M.format(header, rows, opts)
    opts = opts or {}
    local max_col = opts.max_col or 40
    if #header == 0 then
        return { "(нет колонок)" }
    end

    local widths = {}
    for i, name in ipairs(header) do
        widths[i] = math.min(math.max(vim.fn.strdisplaywidth(name), 3), max_col)
    end
    for _, row in ipairs(rows) do
        for i, cell in ipairs(row) do
            local w = math.min(vim.fn.strdisplaywidth(cell), max_col)
            if w > (widths[i] or 0) then
                widths[i] = w
            end
        end
    end

    local function line(cells)
        local parts = {}
        for i = 1, #header do
            table.insert(parts, pad(clip(cells[i] or "", widths[i]), widths[i]))
        end
        return " " .. vim.trim(table.concat(parts, GAP), " ")
    end

    local out = { line(header) }
    local rule = {}
    for i = 1, #header do
        rule[i] = string.rep(RULE, widths[i])
    end
    table.insert(out, line(rule))
    for _, row in ipairs(rows) do
        table.insert(out, line(row))
    end
    if #rows == 0 then
        table.insert(out, " (пусто)")
    end
    return out
end

---@class jupyter.TableView
local View = {}
View.__index = View

---@param opts table sidecar, page_size, keys, max_col
function M.new(opts)
    return setmetatable({
        sidecar = opts.sidecar,
        page_size = opts.page_size or 50,
        max_col = opts.max_col or 40,
        keys = opts.keys or M.DEFAULT_KEYS,
        buf = nil,
        win = nil,
        tab = nil,
        path = nil,
        label = nil,
        offset = 0,
        total = 0,
    }, View)
end

function View:is_open()
    return self.win ~= nil and vim.api.nvim_win_is_valid(self.win)
end

function View:_ensure_buf()
    if self.buf and vim.api.nvim_buf_is_valid(self.buf) then
        return self.buf
    end
    self.buf = common.scratch_buf("jupyter://table", "jupyter-table")
    common.apply_keys(self.buf, self:get_actions(), self.keys)
    return self.buf
end

---Открыть таблицу. Отдельная вкладка: широкие таблицы требуют всей ширины,
---а q закрывает вкладку и возвращает ноутбук нетронутым.
---@param path string путь к parquet
---@param label? string что показать в winbar
function View:open(path, label)
    self.path = path
    self.label = label or vim.fn.fnamemodify(path, ":t")
    self.offset = 0

    local buf = self:_ensure_buf()
    if not self:is_open() then
        vim.cmd("tab split") -- не tabnew: иначе плодятся пустые [No Name]
        self.tab = vim.api.nvim_get_current_tabpage()
        self.win = vim.api.nvim_get_current_win()
        vim.api.nvim_win_set_buf(self.win, buf)
        vim.wo[self.win].wrap = false -- широкие таблицы листаются по горизонтали
        vim.wo[self.win].number = false
        vim.wo[self.win].relativenumber = false
        vim.wo[self.win].signcolumn = "no"
        vim.wo[self.win].cursorline = true
    end
    self:page(0)
end

function View:close()
    if self:is_open() then
        local win = self.win
        self.win = nil
        pcall(vim.api.nvim_win_close, win, true)
    end
    self.win = nil
end

---@param offset integer|nil nil — перечитать текущую страницу
function View:page(offset)
    if not self.path then
        return
    end
    local want = math.max(0, math.floor(offset or self.offset))
    self.sidecar:request("table.page", {
        path = self.path,
        offset = want,
        limit = self.page_size,
    }, function(err, page)
        if err then
            common.set_lines(self:_ensure_buf(), {
                " не удалось прочитать таблицу",
                " " .. (err.code or "?") .. ": " .. (err.msg or ""),
            })
            return
        end
        self.offset = page.offset
        self.total = page.total_rows
        common.set_lines(self:_ensure_buf(), M.format(page.header, page.rows, { max_col = self.max_col }))
        self:_render_winbar()
        if self:is_open() then
            pcall(vim.api.nvim_win_set_cursor, self.win, { 1, 0 })
        end
    end)
end

---Строка статуса. Отдельным методом — её удобно проверять тестом.
---@return string
function View:status()
    if self.total == 0 then
        return "пусто"
    end
    local from = self.offset + 1
    local to = math.min(self.offset + self.page_size, self.total)
    local page = math.floor(self.offset / self.page_size) + 1
    local pages = math.max(1, math.ceil(self.total / self.page_size))
    return ("строки %d–%d из %d · страница %d/%d"):format(from, to, self.total, page, pages)
end

function View:_render_winbar()
    if not self:is_open() then
        return
    end
    vim.wo[self.win].winbar = table.concat({
        hl.wrap("JupyterWinBar", " " .. common.escape_status(self.label or "таблица")),
        "%=",
        hl.wrap("JupyterWinBarInfo", common.escape_status(self:status())),
        hl.wrap("JupyterWinBar", " "),
    })
end

---@return table<string, fun()>
function View:get_actions()
    return {
        page_next = function() self:page(self.offset + self.page_size) end,
        page_prev = function() self:page(self.offset - self.page_size) end,
        page_first = function() self:page(0) end,
        page_last = function()
            self:page(math.floor(math.max(0, self.total - 1) / self.page_size) * self.page_size)
        end,
        refresh = function() self:page(self.offset) end,
        close = function() self:close() end,
    }
end

return M
