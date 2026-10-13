-- Подсветка строк-магик IPython в python-ячейках: `%connect rs`, `%%time`, `!ls`.
--
-- Для treesitter-python это не код: `%connect rs` разбирается в ERROR с `%` оператором и
-- `connect` переменной, и строка выглядит сломанной. Чинить грамматику незачем — поверх
-- кладём свою группу эфемерными extmark'ами с приоритетом выше treesitter (100) и
-- семантических токенов (125). Только на видимых строках и только на тех, что похожи на
-- магику, — ячейки считаются лишь тогда, когда такая строка нашлась.

local cells = require("jupyter.cells")

local M = {}

-- группы определяются в highlight.lua, там же переживают смену темы
M.GROUP = "JupyterMagic" -- имя: `%connect`
M.ARGS = "JupyterMagicArgs" -- остальное: `rs` — обычный текст, а не «оператор и переменная»
M.PRIORITY = 200

local ns = vim.api.nvim_create_namespace("jupyter.magic")

---Похожа ли строка на магику: `%name`, `%%name` или `!команда` в начале строки.
---@param line string
---@return boolean
function M.match(line)
    return line:match("^%s*%%%%?[%a_]") ~= nil or line:match("^%s*!%S") ~= nil
end

---Где в строке-магике её имя: `%connect`, `%%time`, `!pip`. 0-based, конец не включён.
---@param line string
---@return integer first
---@return integer last
function M.name_range(line)
    local indent, name = line:match("^(%s*)([%%!]+[^%s]*)")
    if not indent then
        return 0, 0
    end
    return #indent, #indent + #name
end

-- Ячейки текущего прохода отрисовки: окно → список, считается по первой магике.
local pass = {}

function M.attach()
    vim.api.nvim_set_decoration_provider(ns, {
        on_win = function(_, win, buf)
            if vim.b[buf].jupyter_ipynb ~= true then
                return false
            end
            pass[win] = nil
        end,
        on_line = function(_, win, buf, row)
            local line = vim.api.nvim_buf_get_lines(buf, row, row + 1, false)[1]
            if not line or not M.match(line) then
                return
            end
            pass[win] = pass[win] or cells.list(buf)
            for _, cell in ipairs(pass[win]) do
                if row + 1 >= cell.start_row and row + 1 <= cell.end_row then
                    if cell.lang == nil or cell.lang == "python" then
                        local first, last = M.name_range(line)
                        local function mark(from, to, group)
                            if to > from then
                                vim.api.nvim_buf_set_extmark(buf, ns, row, from, {
                                    end_col = to,
                                    hl_group = group,
                                    priority = M.PRIORITY,
                                    ephemeral = true,
                                })
                            end
                        end
                        mark(first, last, M.GROUP)
                        mark(last, #line, M.ARGS)
                    end
                    return
                end
            end
        end,
    })
end

return M
