-- Сантехника UI: scratch-буфер, окно, действия → клавиши.
--
-- Плагин не хардкодит ни одной клавиши (практика из §9 идеи и из dbee ui/common):
-- объект публикует таблицу именованных действий, пользователь отдаёт список
-- { mode, key, action }. Дефолты живут в модуле окна, а не здесь.
--
-- Нюанс: клавиши ставятся через langmapper, если он установлен. Иначе в русской
-- раскладке drawer не закроется по q — там будет "й", и это хуже, чем отсутствие мапы.

local M = {}

function M.map(mode, lhs, rhs, opts)
    local ok, lm = pcall(require, "langmapper")
    if ok and type(lm.map) == "function" then
        lm.map(mode, lhs, rhs, opts)
    else
        vim.keymap.set(mode, lhs, rhs, opts)
    end
end

---@param buf integer
---@param actions table<string, fun()>
---@param keys table[] список { mode, key, action }
function M.apply_keys(buf, actions, keys)
    for _, spec in ipairs(keys or {}) do
        local action = actions[spec.action]
        if action then
            M.map(spec.mode or "n", spec.key, action, {
                buffer = buf,
                nowait = true,
                silent = true,
                desc = "jupyter: " .. spec.action,
            })
        else
            vim.notify(
                ("jupyter.nvim: неизвестное действие %q"):format(tostring(spec.action)),
                vim.log.levels.WARN
            )
        end
    end
end

---@param name string
---@param filetype? string
---@return integer buf
function M.scratch_buf(name, filetype)
    local buf = vim.api.nvim_create_buf(false, true)
    pcall(vim.api.nvim_buf_set_name, buf, name) -- имя мог занять ещё не выгруженный буфер
    vim.bo[buf].buftype = "nofile"
    vim.bo[buf].bufhidden = "hide"
    vim.bo[buf].swapfile = false
    vim.bo[buf].modifiable = false
    if filetype then
        vim.bo[buf].filetype = filetype
    end
    return buf
end

---Разложить многострочные элементы на строки буфера.
---nvim_buf_set_lines не принимает "\n" внутри элемента, а из ядра такое приходит: трейсбек
---IPython — это список, в котором один элемент легко содержит несколько строк.
---@param lines string[]
---@return string[]
function M.flatten(lines)
    local out = {}
    for _, line in ipairs(lines or {}) do
        line = tostring(line)
        if line:find("\n", 1, true) then
            for _, part in ipairs(vim.split(line, "\n", { plain = true })) do
                table.insert(out, (part:gsub("\r", "")))
            end
        else
            table.insert(out, (line:gsub("\r", "")))
        end
    end
    return out
end

---Запись в буфер, который для пользователя только для чтения.
function M.set_lines(buf, lines)
    if not vim.api.nvim_buf_is_valid(buf) then
        return
    end
    vim.bo[buf].modifiable = true
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, M.flatten(lines))
    vim.bo[buf].modifiable = false
end

---Обрезать по ширине отображения, а не по байтам и не по символам.
---
---Три единицы легко перепутать, и все три встречались в коде: байты режут кириллицу
---посередине, символы не учитывают, что эмодзи и CJK занимают две клетки. Меряем и режем
---одним и тем же — клетками экрана.
---@param text string
---@param width integer
---@return string
function M.clip(text, width)
    text = tostring(text or "")
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
    return out .. "…"
end

---Виртуальная строка под строкой документа — в обход бага прокрутки nvim.
---
---Казалось бы, это `virt_lines` на самой строке с `virt_lines_above = false`. Так и было,
---пока под ней не оказалась строка, скрытая целиком (`conceal_lines`): так render-markdown
---прячет закрывающий фенс ячейки. На такой паре nvim (0.12.5) при прокрутке пересчитывает
---высоту неверно — строки под курсором двоятся или пропадают до принудительного redraw.
---Воспроизводится на голом `nvim --clean` без единого плагина: 60 строк, `conceal_lines`
---на каждом ``` и `virt_lines` на строке перед ним. Наш вклад — только то, что статус
---ячейки стоит ровно в этом месте, на каждой ячейке сразу.
---
---Поэтому якорь — СЛЕДУЮЩАЯ строка с `virt_lines_above = true`: рисуется там же, а баг
---не трогает. Скрытую строку якорем брать нельзя: `virt_lines` на ней не рисуются вовсе
---(проверено на том же стенде), поэтому зовущий отдаёт строку, за которой ячейка кончилась
---совсем — вместе с фенсом.
---
---На последней строке буфера цепляться не за что, и это не редкость: файл ноутбука
---кончается закрывающим фенсом последней ячейки. Там нужен `edge_row` — строка, которая
---видима наверняка (для ячейки это последняя строка тела). Без него статус последней
---ячейки пропадал: якорем оставался скрытый фенс, а на нём `virt_lines` не рисуются.
---За последней строкой прокручивать нечего, поэтому баг прокрутки тут не грозит.
---`opts.id` переставляет уже стоящий extmark вместо того, чтобы ставить новый. Это не
---экономия вызовов: на одной строке виртуальных строк бывает несколько (статус ячейки и
---подпись агента), и при равном приоритете их порядок определяется порядком extmark'ов.
---Пересоздание на каждый тик означало, что подпись прыгает и меняется со статусом местами
---прямо во время набора текста.
---@param buf integer
---@param ns integer
---@param row integer 1-based строка, ПОД которой встанет виртуальная строка
---@param virt_lines table[] чанки, как в nvim_buf_set_extmark
---@param edge_row? integer 1-based запасной якорь, если row — последняя строка буфера
---@param opts? table id — переставить этот extmark; priority — порядок среди соседей
---@return integer|nil id extmark'а, nil если поставить не удалось
function M.virt_line_below(buf, ns, row, virt_lines, edge_row, opts)
    if not vim.api.nvim_buf_is_valid(buf) then
        return nil
    end
    local total = vim.api.nvim_buf_line_count(buf)
    row = math.max(1, math.min(row, total))
    local anchor, above = row, true -- 0-based: строка row это уже следующая
    if row >= total then
        anchor, above = math.max(1, math.min(edge_row or row, total)) - 1, false
    end
    local ok, id = pcall(vim.api.nvim_buf_set_extmark, buf, ns, anchor, 0, {
        id = opts and opts.id or nil,
        priority = opts and opts.priority or nil,
        virt_lines = virt_lines,
        virt_lines_above = above,
    })
    return ok and id or nil
end

---`%` в winbar/statusline — начало элемента формата, литерал экранируется удвоением (§9 идеи).
---@param text string
---@return string
function M.escape_status(text)
    return (text:gsub("%%", "%%%%"))
end

return M
