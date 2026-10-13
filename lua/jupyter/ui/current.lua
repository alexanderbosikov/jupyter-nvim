-- Фон ячейки под курсором: видно, какую ячейку запустит <CR> и куда пойдёт правка.
--
-- Фон всех ячеек рисует render-markdown (RenderMarkdownCode, приоритет 140). Поверх тела
-- текущей кладём свой extmark с приоритетом выше — тот же hl_eol, только группа другая.
-- Строки фенсов не трогаем: их render-markdown рисует цветом границы (highlight_border),
-- и у текущей ячейки граница должна остаться той же, что у соседей.
--
-- Extmark обычный, а не эфемерный из decoration provider: курсор в другую ячейку
-- перерисовывает только старую и новую строку курсора, и эфемерная подсветка оставалась
-- бы на прежней ячейке до следующей полной перерисовки.

local cells = require("jupyter.cells")

local M = {}

M.GROUP = "JupyterCellCurrent" -- определяется в highlight.lua
M.PRIORITY = 150 -- выше фона render-markdown (140), ниже пометок агента
M.NS = vim.api.nvim_create_namespace("jupyter.current")

-- Что подсвечено сейчас: buf → { start_row, end_row, tick }. Пока курсор ходит внутри
-- той же ячейки и текст не менялся, ячейки не пересчитываем.
local shown = {}

---Тело ячейки под курсором окна, 1-based включительно; nil — курсор не в код-ячейке.
---@param buf integer
---@param win integer
---@return integer|nil, integer|nil
function M.range(buf, win)
    local row = vim.api.nvim_win_get_cursor(win)[1]
    local cell = cells.at(buf, row)
    if not cell or cell.start_row > cell.end_row then
        return nil
    end
    return cell.start_row, cell.end_row
end

---Подсветить ячейку под курсором текущего окна.
---
---При уходе в другое окно подсветка остаётся: из drawer'а видно, чей вывод читаешь.
---@param buf integer
function M.update(buf)
    if not vim.api.nvim_buf_is_valid(buf) then
        return
    end
    local win = vim.api.nvim_get_current_win()
    if vim.api.nvim_win_get_buf(win) ~= buf then
        return
    end
    local tick = vim.api.nvim_buf_get_changedtick(buf)
    local row = vim.api.nvim_win_get_cursor(win)[1]
    local last = shown[buf]
    if last and last.tick == tick and last.start_row and row >= last.start_row and row <= last.end_row then
        return
    end

    local first, final = M.range(buf, win)
    vim.api.nvim_buf_clear_namespace(buf, M.NS, 0, -1)
    shown[buf] = { start_row = first, end_row = final, tick = tick }
    if not first then
        return
    end
    vim.api.nvim_buf_set_extmark(buf, M.NS, first - 1, 0, {
        end_row = final, -- 0-based и не включая: начало строки после тела
        end_col = 0,
        hl_group = M.GROUP,
        hl_eol = true,
        priority = M.PRIORITY,
    })
end

---@param group integer augroup
function M.attach(group)
    local function notebook(buf)
        return vim.b[buf].jupyter_ipynb == true
    end
    vim.api.nvim_create_autocmd(
        { "BufWinEnter", "WinEnter", "CursorMoved", "CursorMovedI", "TextChanged", "TextChangedI", "TextChangedP" },
        {
            group = group,
            callback = function(ev)
                if notebook(ev.buf) then
                    M.update(ev.buf)
                end
            end,
        }
    )
    vim.api.nvim_create_autocmd("BufWipeout", {
        group = group,
        callback = function(ev)
            shown[ev.buf] = nil
        end,
    })
end

return M
