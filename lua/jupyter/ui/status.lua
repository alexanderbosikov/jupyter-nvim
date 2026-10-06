-- Однострочный статус под ячейкой (ARCHITECTURE.md §4.3).
--
-- Зачем, если есть drawer: drawer показывает одну ячейку, а состояние нужно видеть у всех
-- сразу — какая выполняется, какая упала, у какой вывод получен из другого кода. Это же
-- снимает главную путаницу одного окна: под ячейкой сразу видно, свежий у неё вывод или нет.
--
-- Позиции не хранятся: на каждую перерисовку namespace очищается и extmark'и ставятся заново
-- по актуальным границам ячеек. Поэтому переживать правки нечему — состояние живёт в тексте
-- (cellid) и в exec, а не в позициях.
--
-- Виртуальная строка ставится якорем на СЛЕДУЮЩУЮ строку (`common.virt_line_below`).
-- Это обход бага прокрутки nvim рядом со скрытой строкой; причина расписана в common.lua.

local common = require("jupyter.ui.common")
local hl = require("jupyter.highlight")

local M = {}

M.NS = vim.api.nvim_create_namespace("jupyter.status")

---Компактный текст статуса: под ячейкой места мало.
---@param run jupyter.Run
---@param stale boolean|nil
---@return string text, string group
function M.text_of(run, stale)
    -- Номер прогона ядра — тот самый `In [12]` из Lab. Он не наш счётчик (`run_id`), а
    -- счётчик ядра: по нему видно порядок выполнения и то, что ячейку выше прогнали позже.
    -- Пока прогон не закончен, номера ещё нет — как и в Lab, показываем звёздочку.
    local mark = run.historical and "⟲ " or ""
    if run.execution_count then
        mark = mark .. ("[%d] "):format(run.execution_count)
    elseif run.status == "queued" or run.status == "running" then
        mark = mark .. "[*] "
    end
    local group = hl.for_status(run.status)

    if run.status == "queued" then
        return mark .. "⏳ в очереди", group
    end
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

---Группа статуса в подвале: цвет текста свой, фон — `JupyterStatusFooter`, если он
---задан, иначе `Normal`. Свой фон у групп `JupyterWinBar*` есть (они для winbar), и на
---строке фенса он выглядел бы продолжением код-блока. У прозрачного терминала `Normal`
---без фона — тогда фона нет и у подвала.
---@param group string
---@return string
function M.on_window(group)
    local name = group .. "Footer"
    local spec = vim.api.nvim_get_hl(0, { name = group, link = false })
    local footer = vim.api.nvim_get_hl(0, { name = "JupyterStatusFooter", link = false })
    spec.bg = footer.bg or vim.api.nvim_get_hl(0, { name = "Normal", link = false }).bg
    vim.api.nvim_set_hl(0, name, spec)
    return name
end

---@class jupyter.Status
local Status = {}
Status.__index = Status

---@param opts? table position ("below"|"eol"|"fence"), enabled
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
---
---Строка в записи — последняя строка ЯЧЕЙКИ, вместе с закрывающим фенсом; `body_row` —
---последняя строка её тела. Виртуальную строку ставит `common.virt_line_below`: якорь
---уезжает на следующую строку, и это не косметика, а обход бага прокрутки nvim —
---подробности там же. `body_row` нужен только в конце файла, где цепляться не за что.
---@param buf integer
---@param entries table[] список { row, body_row?, text, group }
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
        local chunk = { { entry.text, entry.group } }
        local ok
        if self.position == "fence" and entry.body_row and entry.body_row < entry.row then
            -- Строка закрывающего фенса становится подвалом ячейки: статус с первой
            -- колонки на фоне окна и до его края — блок кончается последней строкой кода. Поверх черты, которую рисует
            -- render-markdown при `border = "thin"`: прервать её посередине значит
            -- оставить слева обрубок, похожий на срезанный угол. ``` под статусом не
            -- видно и под курсором — у закрывающего фенса там нет ничего, кроме ```.
            -- При `border = "hide"` строка скрыта целиком, там нужен "below".
            local text = " " .. entry.text
            local pad = math.max(0, vim.o.columns - vim.fn.strdisplaywidth(text))
            ok = pcall(vim.api.nvim_buf_set_extmark, buf, M.NS, entry.row - 1, 0, {
                virt_text = { { text .. string.rep(" ", pad), M.on_window(entry.group) } },
                virt_text_win_col = 0,
                priority = 10000, -- выше черты render-markdown, иначе она рисуется поверх
            })
        elseif self.position == "eol" then
            local row = math.max(0, math.min(entry.row - 1, vim.api.nvim_buf_line_count(buf) - 1))
            ok = pcall(vim.api.nvim_buf_set_extmark, buf, M.NS, row, 0, {
                virt_text = chunk,
                virt_text_pos = "eol",
                hl_mode = "combine",
            })
        else
            ok = common.virt_line_below(buf, M.NS, entry.row, { chunk }, entry.body_row) ~= nil
        end
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
