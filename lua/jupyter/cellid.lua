-- Стабильный идентификатор ячейки, живущий в тексте документа (ARCHITECTURE.md §4.6).
--
-- Почему не нативный id nbformat 4.5: он есть у каждой ячейки в .ipynb, но jupytext
-- **регенерирует все id** при обратной конвертации md → ipynb. Проверено на настоящем
-- ноутбуке: из 65 id не совпал ни один. То есть для персистентности он бесполезен.
--
-- Где живёт наш: в info-строке фенса (`jncell="a3f9"`), в percent — на строке маркера.
-- Проверено экспериментом, что именно такая форма доживает до .ipynb честной cell metadata
-- и возвращается обратно дословно. Дефис в ключе (`cell-id=`) jupytext не принимает и кладёт
-- значение в `incorrectly_encoded_metadata` — поэтому ключ без дефиса.
--
-- Главное следствие места: id НЕ попадает в тело ячейки, а значит не уезжает в ядро.
-- Комментарием в теле его держать нельзя: в ячейке с магикой языка `#` — не комментарий,
-- а часть кода на этом языке, и он бы его сломал.

local cells = require("jupyter.cells")

local M = {}

M.KEY = "jncell"

local PATTERN = M.KEY .. '="([0-9a-f]+)"'

---Достать id из строки маркера или фенса.
---@param line string
---@return string|nil
function M.parse(line)
    return line and line:match(PATTERN) or nil
end

---Все занятые в буфере id.
---@param buf integer
---@return table<string, boolean>
function M.used(buf)
    local seen = {}
    for _, line in ipairs(vim.api.nvim_buf_get_lines(buf, 0, -1, false)) do
        local id = M.parse(line)
        if id then
            seen[id] = true
        end
    end
    return seen
end

---Id ячейки, если он уже записан в тексте.
---@param buf integer
---@param cell jupyter.Cell
---@return string|nil
function M.of(buf, cell)
    if not cell.marker_row then
        return nil -- ячейке без маркера id записать некуда
    end
    local line = vim.api.nvim_buf_get_lines(buf, cell.marker_row - 1, cell.marker_row, false)[1]
    return M.parse(line)
end

---Сгенерировать id, которого нет среди занятых.
---Детерминированно от содержимого: копипаст ячейки даёт коллизию, она разводится солью.
---@param seed string
---@param used table<string, boolean>
---@return string
function M.generate(seed, used)
    for salt = 0, 4096 do
        local id = vim.fn.sha256(seed .. ":" .. salt):sub(1, 4)
        if not used[id] then
            return id
        end
    end
    error("не удалось подобрать свободный cell-id")
end

---Вернуть id ячейки, записав его в текст, если его там нет.
---
---Это единственное место плагина, которое правит документ пользователя. Правка одна,
---в конец строки маркера, и отменяется обычным undo.
---@param buf integer
---@param cell jupyter.Cell
---@return string|nil id, boolean written
function M.ensure(buf, cell)
    local existing = M.of(buf, cell)
    if existing then
        return existing, false
    end
    if not cell.marker_row then
        return nil, false
    end

    local id = M.generate(cells.text(buf, cell) .. ":" .. cell.marker_row, M.used(buf))
    local row = cell.marker_row
    local line = vim.api.nvim_buf_get_lines(buf, row - 1, row, false)[1]
    local suffix = (' %s="%s"'):format(M.KEY, id)
    vim.api.nvim_buf_set_lines(buf, row - 1, row, false, { line .. suffix })
    return id, true
end

---Ячейка с этим id, если она есть в буфере.
---@param buf integer
---@param id string
---@return jupyter.Cell|nil
function M.find(buf, id)
    for _, cell in ipairs(cells.list(buf)) do
        if M.of(buf, cell) == id then
            return cell
        end
    end
end

return M
