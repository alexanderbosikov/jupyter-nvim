-- Перестройка ячеек: разрезать, склеить, переставить, сменить тип.
--
-- Отдельно от cells.lua намеренно: тот отвечает за вопрос «где границы ячеек», этот — за
-- правку документа. Модели ноутбука у нас нет и не будет: документ и есть модель, поэтому
-- каждая операция — это правка строк буфера, а не перестановка узлов в дереве.
--
-- Три правила, из которых следует остальное:
--
-- 1. **Id живёт в маркере.** Разрез оставляет id первой половине (её код изменился, значит
--    под ней честно появится «⚠ код правили»), вторая получит свой при первом запуске.
--    Склейка уносит id второй ячейки вместе с её маркером: история на диске останется, но
--    станет недостижимой — это цена операции, и она названа вслух.
-- 2. **Через прозу не склеиваем и не переставляем молча.** Между двумя код-ячейками может
--    лежать markdown-текст или markdown-ячейка. Склеить «сквозь» них — потерять текст,
--    поэтому в таком случае отказываемся и говорим почему.
-- 3. **Одна операция — одна правка буфера.** Иначе откат стоил бы двух нажатий `u`, и
--    пользователь узнавал бы об этом в самый неподходящий момент. Поэтому каждая функция
--    собирает новый кусок целиком и ставит его одним `nvim_buf_set_lines`.
-- 4. **Перестановка меняет местами только код-ячейки.** Проза между ними остаётся на месте:
--    так документ не разъезжается, а правило легко объяснить одной фразой.

local cells = require("jupyter.cells")

local M = {}

local PERCENT_MARKER = "^#%s*%%%%"

---@param buf integer
---@param from integer 1-based, включительно
---@param to integer 1-based, включительно
---@return string[]
local function lines(buf, from, to)
    return vim.api.nvim_buf_get_lines(buf, from - 1, to, false)
end

---Только пробелы между этими строками (границы не входят)?
---@return boolean
local function blank_between(buf, from, to)
    if to < from then
        return true
    end
    for _, line in ipairs(lines(buf, from, to)) do
        if line:match("%S") then
            return false
        end
    end
    return true
end

---Язык открывающего фенса ячейки вместе с его хвостом (magic_args, id).
---@param buf integer
---@param cell jupyter.Cell
---@return string маркер для новой половины
local function fence_of(buf, cell)
    local line = lines(buf, cell.marker_row, cell.marker_row)[1] or "```python"
    -- хвост не переносим: magic_args и id принадлежат первой половине
    return line:match("^(```+%S+)") or "```python"
end

---Разрезать ячейку по строке: всё с неё и ниже уезжает в новую ячейку.
---
---Резать перед первой строкой тела бессмысленно — получилась бы пустая ячейка, поэтому
---в этом случае отказываемся.
---@param buf integer
---@param row integer
---@return integer|nil row строка, на которую ставить курсор
function M.split(buf, row)
    local cell = cells.at(buf, row)
    if not cell or row <= cell.start_row or row > cell.end_row then
        return nil
    end

    if cells.representation(buf) == "fence" then
        vim.api.nvim_buf_set_lines(buf, row - 1, row - 1, false, { "```", "", fence_of(buf, cell) })
        return row + 3
    end
    vim.api.nvim_buf_set_lines(buf, row - 1, row - 1, false, { "# %%" })
    return row + 1
end

---Склеить ячейку со следующей код-ячейкой.
---@param buf integer
---@param cell jupyter.Cell
---@return boolean ok, string|nil почему нет
function M.merge(buf, cell)
    local next_cell = cells.next(buf, cell.span_end)
    if not next_cell then
        return false, "следующей ячейки нет"
    end
    if not blank_between(buf, cell.span_end + 1, next_cell.span_start - 1) then
        return false, "между ячейками текст — склейка его потеряет"
    end

    if cells.representation(buf) == "fence" then
        if cell.lang ~= next_cell.lang then
            return false, ("разные языки: %s и %s"):format(cell.lang, next_cell.lang)
        end
        -- закрывающий фенс, пустые строки между и открывающий фенс следующей — долой
        vim.api.nvim_buf_set_lines(buf, cell.span_end - 1, next_cell.marker_row, false, {})
        return true
    end
    vim.api.nvim_buf_set_lines(buf, next_cell.marker_row - 1, next_cell.marker_row, false, {})
    return true
end

---Поменять ячейку местами с соседней код-ячейкой.
---@param buf integer
---@param cell jupyter.Cell
---@param dir "up"|"down"
---@return integer|nil row первая строка тела на новом месте
function M.move(buf, cell, dir)
    local other = dir == "up" and cells.prev(buf, cell.span_start) or cells.next(buf, cell.span_end)
    if not other then
        return nil
    end
    local first = dir == "up" and other or cell
    local second = dir == "up" and cell or other

    local head = lines(buf, first.span_start, first.span_end)
    local middle = lines(buf, first.span_end + 1, second.span_start - 1)
    local tail = lines(buf, second.span_start, second.span_end)

    local swapped = {}
    vim.list_extend(swapped, tail)
    vim.list_extend(swapped, middle)
    vim.list_extend(swapped, head)
    vim.api.nvim_buf_set_lines(buf, first.span_start - 1, second.span_end, false, swapped)

    -- курсор ведём за ячейкой: смещение тела внутри её собственного куска не меняется
    local offset = cell.start_row - cell.span_start
    if dir == "up" then
        return first.span_start + offset
    end
    return first.span_start + #tail + #middle + offset
end

---Превратить код-ячейку в markdown.
---@param buf integer
---@param cell jupyter.Cell
---@return boolean ok, string|nil почему нет
function M.to_markdown(buf, cell)
    local body = lines(buf, cell.start_row, cell.end_row)
    if cells.representation(buf) == "fence" then
        -- markdown-ячейка в этом представлении — просто текст без фенсов
        vim.api.nvim_buf_set_lines(buf, cell.span_start - 1, cell.span_end, false, body)
        return true
    end
    for i, line in ipairs(body) do
        body[i] = line == "" and "#" or ("# " .. line)
    end
    vim.api.nvim_buf_set_lines(buf, cell.span_start - 1, cell.span_end, false,
        vim.list_extend({ "# %% [markdown]" }, body))
    return true
end

---Границы абзаца вокруг строки: непустые строки до пустой строки или фенса.
---@param buf integer
---@param row integer
---@return integer|nil from, integer|nil to
local function paragraph(buf, row)
    local total = vim.api.nvim_buf_line_count(buf)
    local function stop(n)
        local line = lines(buf, n, n)[1]
        return line == nil or not line:match("%S") or line:match("^```")
    end
    if stop(row) then
        return nil, nil
    end
    local from, to = row, row
    while from > 1 and not stop(from - 1) do
        from = from - 1
    end
    while to < total and not stop(to + 1) do
        to = to + 1
    end
    return from, to
end

---Превратить markdown под курсором в код-ячейку.
---@param buf integer
---@param row integer
---@return integer|nil row первая строка тела новой ячейки
function M.to_code(buf, row)
    if cells.representation(buf) == "fence" then
        if cells.at(buf, row) then
            return nil -- это уже код-ячейка
        end
        local from, to = paragraph(buf, row)
        if not from then
            return nil
        end
        local body = vim.list_extend({ "```python" }, lines(buf, from, to))
        table.insert(body, "```")
        vim.api.nvim_buf_set_lines(buf, from - 1, to, false, body)
        return from + 1
    end

    -- percent: ищем свой маркер вверх от курсора, он и скажет тип ячейки
    local marker
    for n = row, 1, -1 do
        if (lines(buf, n, n)[1] or ""):match(PERCENT_MARKER) then
            marker = n
            break
        end
    end
    if not marker or not (lines(buf, marker, marker)[1]):match("%[markdown%]") then
        return nil
    end
    local total = vim.api.nvim_buf_line_count(buf)
    local last = total
    for n = marker + 1, total do
        if (lines(buf, n, n)[1] or ""):match(PERCENT_MARKER) then
            last = n - 1
            break
        end
    end
    local body = lines(buf, marker + 1, last)
    for i, line in ipairs(body) do
        body[i] = line:gsub("^#%s?", "")
    end
    vim.api.nvim_buf_set_lines(buf, marker - 1, last, false, vim.list_extend({ "# %%" }, body))
    return marker + 1
end

return M
