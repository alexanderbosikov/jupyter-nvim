-- Оглавление ноутбука: заголовки вместе с ячейками и их состоянием.
--
-- Чем это отличается от обычного outline: в списке видно не только структуру, но и что
-- уже посчитано, что упало и что ни разу не запускалось. То есть навигация и обзор
-- состояния в одном месте — как панель содержания, но про ноутбук, а не про markdown.
--
-- Заголовки берутся по-разному в двух представлениях. В markdown это обычные строки `#`
-- вне ячеек. В percent весь markdown закомментирован, поэтому заголовок выглядит как
-- `# # Раздел` внутри ячейки `# %% [markdown]`.

local cells = require("jupyter.cells")
local status_ui = require("jupyter.ui.status")

local M = {}

---@class jupyter.TocEntry
---@field kind "header"|"cell"
---@field level integer уровень заголовка, для ячеек 0
---@field text string
---@field row integer строка для прыжка, 1-based
---@field cell jupyter.Cell|nil
---@field run jupyter.Run|nil
---@field preview string|nil первая содержательная строка кода ячейки

local PREVIEW_WIDTH = 48

---Первая содержательная строка ячейки: по статусу не понять, какая это ячейка,
---особенно в ноутбуке без markdown-разделов.
---@param buf integer
---@param cell jupyter.Cell
---@return string
local function preview_of(buf, cell)
    local prefix = ""
    local body = nil
    for _, line in ipairs(vim.api.nvim_buf_get_lines(buf, cell.start_row - 1, cell.end_row, false)) do
        local text = vim.trim(line)
        if text ~= "" then
            -- строка магики сама по себе ничего не говорит: в ноутбуке из одних
            -- %%sql-ячеек все записи выглядели бы одинаково. Берём следующую за ней
            local lang = text:match("^%%%%(%w+)")
            if lang and not body then
                prefix = lang .. ": "
            else
                body = text
                break
            end
        end
    end
    -- ячейка из одной только магики: показываем хотя бы её
    body = body or (prefix ~= "" and prefix:gsub(": $", "") or "(пусто)")
    if prefix ~= "" and body ~= prefix:gsub(": $", "") then
        body = prefix .. body
    end
    if vim.fn.strdisplaywidth(body) > PREVIEW_WIDTH then
        body = vim.fn.strcharpart(body, 0, PREVIEW_WIDTH - 1) .. "…"
    end
    return body
end

local function header_of(line, representation)
    if representation == "percent" then
        -- `# # Раздел` — markdown-ячейка percent-формата
        local hashes, text = line:match("^#%s+(#+)%s+(.*)$")
        if hashes then
            return #hashes, text
        end
        return nil
    end
    local hashes, text = line:match("^(#+)%s+(.*)$")
    if hashes and #hashes <= 6 then
        return #hashes, text
    end
    return nil
end

---Собрать оглавление.
---@param buf integer
---@param opts? table run_of — функция cell → прогон, чтобы показать состояние
---@return jupyter.TocEntry[]
function M.collect(buf, opts)
    opts = opts or {}
    local representation = cells.representation(buf)
    local list = cells.list(buf)

    -- строки, занятые код-ячейками: заголовок внутри кода — это комментарий, не раздел
    local in_cell = {}
    for _, cell in ipairs(list) do
        for row = cell.span_start, cell.span_end do
            in_cell[row] = true
        end
    end

    local entries = {}
    local next_cell = 1
    for row, line in ipairs(vim.api.nvim_buf_get_lines(buf, 0, -1, false)) do
        while next_cell <= #list and list[next_cell].span_start == row do
            local cell = list[next_cell]
            local run = opts.run_of and opts.run_of(cell) or nil
            table.insert(entries, {
                kind = "cell",
                level = 0,
                text = run and status_ui.text_of(run) or "не запускалась",
                preview = preview_of(buf, cell),
                row = cell.start_row,
                cell = cell,
                run = run,
            })
            next_cell = next_cell + 1
        end
        if not in_cell[row] then
            local level, text = header_of(line, representation)
            if level then
                table.insert(entries, { kind = "header", level = level, text = text, row = row })
            end
        end
    end
    return entries
end

---Строка списка. Заголовки отступают по уровню, ячейки — под своим разделом.
---@param entry jupyter.TocEntry
---@return string
function M.format(entry)
    if entry.kind == "header" then
        return ("%s%s %s"):format(("  "):rep(entry.level - 1), ("#"):rep(entry.level), entry.text)
    end
    -- сначала код, потом состояние: ориентируешься по содержимому, а статус подсказка
    return ("    %s  %s"):format(entry.preview or "", entry.text)
end

---Индекс записи, ближайшей к строке: чтобы список открывался на том разделе, где стоишь.
---@param entries jupyter.TocEntry[]
---@param row integer
---@return integer|nil
function M.at(entries, row)
    local found
    for i, entry in ipairs(entries) do
        if entry.row <= row then
            found = i
        end
    end
    return found
end

return M
