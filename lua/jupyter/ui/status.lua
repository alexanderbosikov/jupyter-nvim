-- Однострочный статус под ячейкой (ARCHITECTURE.md §4.3).
--
-- Зачем, если есть drawer: drawer показывает одну ячейку, а состояние нужно видеть у всех
-- сразу — какая выполняется, какая упала, у какой вывод получен из другого кода. Это же
-- снимает главную путаницу одного окна: под ячейкой сразу видно, свежий у неё вывод или нет.
--
-- Позиции не хранятся: на каждую перерисовку namespace очищается и extmark'и ставятся заново
-- по актуальным границам ячеек. Поэтому переживать правки нечему — состояние живёт в тексте
-- (cellid) и в exec, а не в позициях.

local hl = require("jupyter.highlight")

local M = {}

M.NS = vim.api.nvim_create_namespace("jupyter.status")

---Компактный текст статуса: под ячейкой места мало.
---@param run jupyter.Run
---@param stale boolean|nil
---@return string text, string group
function M.text_of(run, stale)
    local mark = run.historical and "⟲ " or ""
    local group = hl.for_status(run.status)

    if run.status == "running" then
        return mark .. "⏳ выполняется", group
    end
    if run.status == "error" then
        local name = run.error and run.error.code or "ошибка"
        return ("%s✗ %s%s"):format(mark, name, stale and " ⚠" or ""), group
    end
    if run.status == "aborted" then
        return mark .. "⊘ прервано", group
    end

    local parts = {}
    if run.duration_ms then
        table.insert(parts, ("%.1f с"):format(run.duration_ms / 1000))
    end
    if run.table then
        table.insert(parts, ("%s × %s"):format(run.table.rows, run.table.cols))
    elseif run.lines and #run.lines > 0 then
        table.insert(parts, ("%d строк"):format(#run.lines))
    end
    if run.historical and run.at then
        table.insert(parts, run.at)
    end

    local text = ("%s✓ %s"):format(mark, table.concat(parts, " · "))
    return stale and (text .. " ⚠") or text, group
end

---@class jupyter.Status
local Status = {}
Status.__index = Status

---@param opts? table position ("below"|"eol"), enabled
function M.new(opts)
    opts = opts or {}
    return setmetatable({
        position = opts.position or "below",
        enabled = opts.enabled ~= false,
    }, Status)
end

function Status:clear(buf)
    if vim.api.nvim_buf_is_valid(buf) then
        vim.api.nvim_buf_clear_namespace(buf, M.NS, 0, -1)
    end
end

---Нарисовать статусы.
---@param buf integer
---@param entries table[] список { row, text, group } — row это последняя строка тела ячейки
function Status:render(buf, entries)
    if not vim.api.nvim_buf_is_valid(buf) then
        return 0
    end
    self:clear(buf)
    if not self.enabled then
        return 0
    end

    local drawn = 0
    for _, entry in ipairs(entries) do
        local row = math.max(0, math.min(entry.row - 1, vim.api.nvim_buf_line_count(buf) - 1))
        local chunk = { { entry.text, entry.group } }
        local ok = pcall(vim.api.nvim_buf_set_extmark, buf, M.NS, row, 0, self.position == "eol"
                and { virt_text = chunk, virt_text_pos = "eol", hl_mode = "combine" }
            or { virt_lines = { chunk }, virt_lines_above = false })
        if ok then
            drawn = drawn + 1
        end
    end
    return drawn
end

---Сколько статусов сейчас нарисовано. Для тестов и checkhealth.
---@param buf integer
---@return integer
function M.count(buf)
    if not vim.api.nvim_buf_is_valid(buf) then
        return 0
    end
    return #vim.api.nvim_buf_get_extmarks(buf, M.NS, 0, -1, {})
end

return M
