-- Постраничный просмотр результата-таблицы (ARCHITECTURE.md §4.2, шаг 4 в §10).
--
-- Данные лежат в parquet рядом с ноутбуком, страницу нарезает сайдкар через
-- scan_parquet().slice() — файл целиком не читается никогда. Поллинга нет:
-- сайдкар присылает готовую страницу ответом на запрос.
--
-- Выравнивание колонок делает Lua, а не сайдкар: только она знает ширину окна (§3).
-- Ширина считается через strdisplaywidth, а не по байтам, иначе кириллица разъезжается.

local common = require("jupyter.ui.common")
local hl = require("jupyter.highlight")

local M = {}

M.DEFAULT_KEYS = {
    { mode = "n", key = "s", action = "sort_asc" },
    { mode = "n", key = "S", action = "sort_desc" },
    { mode = "n", key = "c", action = "sort_clear" },
    { mode = "n", key = "L", action = "page_next" },
    { mode = "n", key = "H", action = "page_prev" },
    { mode = "n", key = "]]", action = "page_last" },
    { mode = "n", key = "[[", action = "page_first" },
    { mode = "n", key = "R", action = "refresh" },
    { mode = "n", key = "y", action = "yank_page" },
    { mode = "n", key = "Y", action = "yank_all" },
    { mode = "n", key = "q", action = "close" },
}

local GAP = "  "
local RULE = "─"

-- Порог для «скопировать целиком»: регистр — не файл, и миллион строк в нём не нужен
-- никому. Выше порога спрашиваем, а не собираем молча.
M.YANK_LIMIT = 50000

local clip = common.clip

---Значение в одну строку.
---
---Перевод строки внутри клетки разложил бы её по строкам буфера: колонки разъехались бы,
---а нумерация строк начала врать. Сайдкар такое уже экранирует при чтении parquet, но
---раскладку держит эта функция — и держать она обязана независимо от источника.
---@param text any
---@return string
local function oneline(text)
    return (tostring(text or ""):gsub("[\r\n]+", " "))
end

---Данные как TSV: шапка и строки, разделитель — табуляция.
---
---Табы, а не выравнивание пробелами: именно их Slack, Sheets и Excel превращают при
---вставке в таблицу, а нарисованные рамки и отбивку пришлось бы вычищать руками.
---Значение с табом или переводом строки внутри сплющиваем — иначе колонки разъедутся
---и вставленная таблица окажется врущей.
---@param header string[]
---@param rows string[][]
---@return string
function M.tsv(header, rows)
    local function cell(value)
        return (oneline(value):gsub("\t", " "))
    end
    local out = { table.concat(vim.tbl_map(cell, header or {}), "\t") }
    for _, row in ipairs(rows or {}) do
        out[#out + 1] = table.concat(vim.tbl_map(cell, row), "\t")
    end
    return table.concat(out, "\n")
end

---Положить текст в регистры: безымянный и системный.
---
---Без системного копирование теряет главный смысл — унести таблицу в Slack или Sheets, —
---а `clipboard=unnamedplus` включён далеко не у всех. Провайдера может и не быть, поэтому
---системный регистр под pcall, и об этом мы говорим вслух, а не молчим.
---@param text string
---@return boolean системный регистр удался
local function to_registers(text)
    vim.fn.setreg('"', text)
    return (pcall(vim.fn.setreg, "+", text))
end

---Хвост сообщения о копировании: куда именно легло.
---@param ok boolean
---@return string
local function where(ok)
    return ok and "" or ' (только в ", системного буфера обмена нет)'
end

local function pad(text, width)
    return text .. string.rep(" ", math.max(0, width - vim.fn.strdisplaywidth(text)))
end

---Свернуть страницу в строки буфера с выровненными колонками.
---
---Вторым значением возвращается раскладка: где на экране начинается и кончается каждая
---колонка. По ней сортировка понимает, над какой колонкой стоит курсор.
---
---opts.first_row включает слева колонку номеров. Это номер строки в датасете, а не в
---буфере: он продолжается со страницы на страницу и считается после сортировки, поэтому
---'number' окна тут не годится — тот считал бы ещё шапку с разделителем.
---@param header string[]
---@param rows string[][]
---@param opts? table max_col, first_row
---@return string[] lines, table[] layout
function M.format(header, rows, opts)
    opts = opts or {}
    local max_col = opts.max_col or 40
    local first_row = opts.first_row
    if #header == 0 then
        return { "(нет колонок)" }, {}
    end

    local widths = {}
    for i, name in ipairs(header) do
        widths[i] = math.min(math.max(vim.fn.strdisplaywidth(name), 3), max_col)
    end
    for _, row in ipairs(rows) do
        for i, cell in ipairs(row) do
            local w = math.min(vim.fn.strdisplaywidth(oneline(cell)), max_col)
            if w > (widths[i] or 0) then
                widths[i] = w
            end
        end
    end

    -- ширину колонки номеров задаёт последняя строка страницы: она самая длинная
    local gutter = first_row and #tostring(first_row + math.max(#rows, 1) - 1) or 0

    ---@param cells string[]
    ---@param mark string содержимое колонки номеров, выравнивается вправо
    local function line(cells, mark)
        local parts = {}
        for i = 1, #header do
            table.insert(parts, pad(clip(oneline(cells[i]), widths[i]), widths[i]))
        end
        -- Срезаем только ХВОСТОВЫЕ пробелы. Обоюдный trim съедал левое поле строки,
        -- у которой первое значение пустое: колонка схлопывалась, и число из второй
        -- колонки вставало под заголовок первой — выглядело так, будто значение не то.
        local body = (table.concat(parts, GAP):gsub("%s+$", ""))
        if gutter == 0 then
            return " " .. body
        end
        local width = vim.fn.strdisplaywidth(mark)
        return " " .. string.rep(" ", math.max(0, gutter - width)) .. mark .. GAP .. body
    end

    local out = { line(header, "#") }
    local rule = {}
    for i = 1, #header do
        rule[i] = string.rep(RULE, widths[i])
    end
    table.insert(out, line(rule, string.rep(RULE, gutter)))
    for i, row in ipairs(rows) do
        table.insert(out, line(row, tostring((first_row or 1) + i - 1)))
    end
    if #rows == 0 then
        table.insert(out, " (пусто)")
    end

    -- раскладка в экранных колонках: 1 занимает ведущий пробел, дальше колонка номеров
    local layout, x = {}, 2 + (gutter > 0 and gutter + #GAP or 0)
    for i, name in ipairs(header) do
        table.insert(layout, { name = name, from = x, to = x + widths[i] - 1 })
        x = x + widths[i] + #GAP
    end
    return out, layout
end

---@class jupyter.TableView
local View = {}
View.__index = View

---@param opts table sidecar, page_size, keys, max_col
function M.new(opts)
    return setmetatable({
        sidecar = opts.sidecar,
        page_size = opts.page_size or 100,
        max_col = opts.max_col or 40,
        keys = opts.keys or M.DEFAULT_KEYS,
        buf = nil,
        win = nil,
        tab = nil,
        path = nil,
        label = nil,
        offset = 0,
        total = 0,
        header = {},
        rows = {},
        layout = {},
        -- стек сортировки: первый элемент — главный ключ, остальные разрешают равенство
        order = {},
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
    self.order = {}

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
        order_by = #self.order > 0 and self.order or nil,
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
        -- страницу держим и данными: из нарисованных строк её обратно не собрать,
        -- а копировать надо значения, а не рамки
        self.header, self.rows = page.header, page.rows
        local lines, layout = M.format(page.header, page.rows, {
            max_col = self.max_col,
            first_row = page.offset + 1,
        })
        self.layout = layout
        common.set_lines(self:_ensure_buf(), lines)
        self:_render_winbar()
        if self:is_open() then
            pcall(vim.api.nvim_win_set_cursor, self.win, { 1, 0 })
        end
    end)
end

---Колонка под экранной позицией. Нужна сортировке: клавиша действует на ту колонку,
---над которой стоит курсор.
---@param col integer экранная колонка, 1-based
---@return string|nil
function View:column_at(col)
    if #self.layout == 0 then
        return nil
    end
    for _, entry in ipairs(self.layout) do
        if col >= entry.from and col <= entry.to then
            return entry.name
        end
    end
    -- курсор в промежутке между колонками или за последней: берём ближайшую слева
    local nearest
    for _, entry in ipairs(self.layout) do
        if entry.from <= col then
            nearest = entry.name
        end
    end
    return nearest or self.layout[1].name
end

---Добавить колонку в стек сортировки главным ключом.
---
---Прежние ключи не теряются, а становятся тай-брейкерами: так каждая следующая сортировка
---учитывает предыдущие. Повторный выбор той же колонки поднимает её обратно наверх и меняет
---направление на заданное.
---@param column string
---@param desc boolean
function View:sort_by(column, desc)
    local kept = {}
    for _, item in ipairs(self.order) do
        if item.column ~= column then
            table.insert(kept, item)
        end
    end
    table.insert(kept, 1, { column = column, desc = desc or nil })
    self.order = kept
    self:page(0) -- после смены порядка страница 1: иначе смотришь в середину чужого порядка
end

---Описание сортировки для статуса.
---@return string
function View:sort_label()
    if #self.order == 0 then
        return ""
    end
    local parts = {}
    for _, item in ipairs(self.order) do
        table.insert(parts, ("%s %s"):format(item.column, item.desc and "↓" or "↑"))
    end
    return "сортировка: " .. table.concat(parts, " · ")
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
    local base = ("строки %d–%d из %d · страница %d/%d"):format(from, to, self.total, page, pages)
    local sort = self:sort_label()
    return sort ~= "" and (sort .. " · " .. base) or base
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
    local function sort(desc)
        return function()
            if not self:is_open() then
                return
            end
            local column = self:column_at(vim.fn.virtcol("."))
            if column then
                self:sort_by(column, desc)
            end
        end
    end

    return {
        sort_asc = sort(false),
        sort_desc = sort(true),
        sort_clear = function()
            self.order = {}
            self:page(0)
        end,
        page_next = function() self:page(self.offset + self.page_size) end,
        page_prev = function() self:page(self.offset - self.page_size) end,
        page_first = function() self:page(0) end,
        page_last = function()
            self:page(math.floor(math.max(0, self.total - 1) / self.page_size) * self.page_size)
        end,
        refresh = function() self:page(self.offset) end,
        yank_page = function()
            if not self.header or #self.header == 0 then
                return
            end
            local ok = to_registers(M.tsv(self.header, self.rows))
            vim.notify(("jupyter.nvim: страница скопирована, строк — %d%s"):format(#self.rows, where(ok)))
        end,
        yank_all = function()
            if not self.path or self.total == 0 then
                return
            end
            if self.total > M.YANK_LIMIT then
                local answer = vim.fn.confirm(
                    ("В таблице %d строк. Скопировать целиком?"):format(self.total),
                    "&Да\n&Нет",
                    2
                )
                if answer ~= 1 then
                    return
                end
            end
            -- limit сайдкар сверху не ограничивает, так что отдельная операция протокола
            -- не нужна: та же table.page, только на всю таблицу и в том же порядке
            self.sidecar:request("table.page", {
                path = self.path,
                offset = 0,
                limit = self.total,
                order_by = #self.order > 0 and self.order or nil,
            }, function(err, page)
                if err then
                    vim.notify(
                        "jupyter.nvim: таблицу целиком прочитать не вышло — " .. (err.msg or "?"),
                        vim.log.levels.ERROR
                    )
                    return
                end
                local ok = to_registers(M.tsv(page.header, page.rows))
                vim.notify(("jupyter.nvim: таблица скопирована, строк — %d%s"):format(#page.rows, where(ok)))
            end)
        end,
        close = function() self:close() end,
    }
end

return M
