-- Границы ячеек в двух представлениях одного и того же ноутбука.
--
--   percent — python-файл с маркерами "# %%"; ячейки "[markdown]" пропускаются,
--             код до первого маркера — тоже ячейка, файл без маркеров — одна ячейка;
--   fence   — markdown после jupytext; код-ячейка это ТОЛЬКО ```python-фенс.
--
-- Нюанс про fence: фенсы с другим языком отдавать ядру нельзя. Это либо примеры кода
-- внутри markdown-ячейки, либо магика, которую не нормализовал ipynb_magics (jupytext
-- уносит "%%sql" в info-строку фенса). К моменту, когда мы смотрим буфер, магика уже
-- возвращена в тело, поэтому здесь про неё знать не нужно.
--
-- Детектор представления вынесен в M.representation: по §1 ARCHITECTURE.md переход на
-- treesitter — это замена одного модуля, а не правки по всему плагину.

local M = {}

local PERCENT_MARKER = "^#%s*%%%%"
local FENCE_OPEN = "^```(%S+)"
local FENCE_CLOSE = "^```%s*$"
local CODE_LANG = "python"

---Языки магик, которые jupytext выносит в info-строку фенса.
---
---Такая ячейка в markdown выглядит как ```sql magic_args="df_name=orders", а строка `%%sql`
---из тела удалена. Мы принимаем эту форму как есть и собираем магику обратно только в момент
---отправки ядру (M.text). Разворачивать её в буфере не нужно: тогда работает родная подсветка
---SQL, а jupytext пишет .ipynb без промежуточных преобразований.
M.MAGIC_LANGS = { sql = true }

---@param lang string|nil
---@return boolean
local function is_code_lang(lang)
    return lang == CODE_LANG or (lang ~= nil and M.MAGIC_LANGS[lang] == true)
end

---@class jupyter.Cell
---@field index integer номер среди код-ячеек, 1-based
---@field start_row integer первая строка тела, 1-based
---@field end_row integer последняя строка тела, включительно
---@field span_start integer первая строка ячейки вместе с маркером
---@field span_end integer последняя строка ячейки вместе с закрывающим фенсом
---@field marker_row integer|nil строка маркера или открывающего фенса

---@return "fence"|"percent"
function M.representation(buf)
    return vim.bo[buf or 0].filetype == "markdown" and "fence" or "percent"
end

local function lines(buf)
    return vim.api.nvim_buf_get_lines(buf, 0, -1, false)
end

local function add(cells, cell)
    if cell.end_row < cell.start_row then
        return -- ячейка без тела: ядру отправлять нечего
    end
    cell.index = #cells + 1
    table.insert(cells, cell)
end

local function fence_cells(buf)
    local cells, open, lang, magic_args = {}, nil, nil, nil
    for row, line in ipairs(lines(buf)) do
        if not open then
            local found = line:match(FENCE_OPEN)
            if is_code_lang(found) then
                open, lang = row, found
                magic_args = line:match('magic_args="(.-)"')
            end
        elseif line:match(FENCE_CLOSE) then
            add(cells, {
                start_row = open + 1,
                end_row = row - 1,
                span_start = open,
                span_end = row,
                marker_row = open,
                lang = lang,
                magic_args = magic_args,
            })
            open, lang, magic_args = nil, nil, nil
        end
    end
    return cells -- незакрытый фенс в конце файла ячейкой не считается
end

local function percent_cells(buf)
    local all = lines(buf)
    local total = #all
    local marks = {}
    for row, line in ipairs(all) do
        if line:match(PERCENT_MARKER) then
            table.insert(marks, { row = row, markdown = line:match("%[markdown%]") ~= nil })
        end
    end

    if #marks == 0 then
        local cells = {}
        add(cells, { start_row = 1, end_row = total, span_start = 1, span_end = total })
        return cells
    end

    local cells = {}
    if marks[1].row > 1 then
        add(cells, {
            start_row = 1,
            end_row = marks[1].row - 1,
            span_start = 1,
            span_end = marks[1].row - 1,
        })
    end
    for i, mark in ipairs(marks) do
        local last = (marks[i + 1] and marks[i + 1].row or total + 1) - 1
        if not mark.markdown then
            add(cells, {
                start_row = mark.row + 1,
                end_row = last,
                span_start = mark.row,
                span_end = last,
                marker_row = mark.row,
            })
        end
    end
    return cells
end

---Все код-ячейки буфера по порядку.
---@param buf? integer
---@return jupyter.Cell[]
function M.list(buf)
    buf = buf or 0
    return M.representation(buf) == "fence" and fence_cells(buf) or percent_cells(buf)
end

---Ячейка, которой принадлежит строка. Маркер и закрывающий фенс считаются частью ячейки.
---@param buf? integer
---@param row integer 1-based
---@return jupyter.Cell|nil
function M.at(buf, row)
    for _, cell in ipairs(M.list(buf)) do
        if row >= cell.span_start and row <= cell.span_end then
            return cell
        end
    end
end

---@return jupyter.Cell|nil
function M.next(buf, row)
    for _, cell in ipairs(M.list(buf)) do
        if cell.span_start > row then
            return cell
        end
    end
end

---@return jupyter.Cell|nil
function M.prev(buf, row)
    local current = M.at(buf, row)
    local limit = current and current.span_start or row
    local found
    for _, cell in ipairs(M.list(buf)) do
        if cell.span_start < limit then
            found = cell
        end
    end
    return found
end

---Тело ячейки без хвостовых пустых строк.
---@return integer start_row, integer end_row
function M.body(buf, cell)
    buf = buf or 0
    local all = vim.api.nvim_buf_get_lines(buf, cell.start_row - 1, cell.end_row, false)
    local last = #all
    while last > 1 and all[last]:match("^%s*$") do
        last = last - 1
    end
    return cell.start_row, cell.start_row + last - 1
end

---Код ячейки одной строкой, готовый к отправке ядру.
---
---Для ячейки с магикой языка (```sql в markdown-представлении) строка `%%sql` собирается
---обратно: в буфере её нет, jupytext держит язык и аргументы в info-строке фенса. Если
---магика уже стоит в теле — например буфер прошёл через ipynb_magics — второй раз не добавляем.
---
---NUL-байты вырезаются: python всё равно откажется компилировать такой исходник
---("source code string cannot contain null bytes"), а по пути они успевают наделать
---беды — NUL в коде ячейки молча убивал дочерний nvim в тестах. В буфер NUL попадает
---легко: например `writefile` так записывает перевод строки внутри элемента списка.
---@return string
function M.text(buf, cell)
    local first, last = M.body(buf, cell)
    local text = table.concat(vim.api.nvim_buf_get_lines(buf, first - 1, last, false), "\n")
    text = text:gsub("%z", "")

    if cell.lang and cell.lang ~= CODE_LANG and not text:match("^%%%%") then
        local magic = "%%" .. cell.lang
        if cell.magic_args and cell.magic_args ~= "" then
            magic = magic .. " " .. cell.magic_args
        end
        text = magic .. "\n" .. text
    end
    return text
end

---Вставить пустую ячейку выше или ниже ячейки под строкой.
---@param buf? integer
---@param row integer
---@param where "above"|"below"
---@return integer row строка, на которую ставить курсор
function M.insert(buf, row, where)
    buf = buf or 0
    local cell = M.at(buf, row)
    local fence = M.representation(buf) == "fence"
    local at, body_offset

    if where == "above" then
        at = cell and cell.span_start - 1 or row - 1
        body_offset = 2 -- маркер занимает первую вставленную строку
    else
        at = cell and cell.span_end or row
        body_offset = 3 -- перед маркером стоит пустая строка-разделитель
    end

    local text
    if fence then
        text = where == "above" and { "```" .. CODE_LANG, "", "```", "" }
            or { "", "```" .. CODE_LANG, "", "```" }
    else
        text = where == "above" and { "# %%", "", "" } or { "", "# %%", "" }
    end

    vim.api.nvim_buf_set_lines(buf, at, at, false, text)
    return at + body_offset
end

return M
