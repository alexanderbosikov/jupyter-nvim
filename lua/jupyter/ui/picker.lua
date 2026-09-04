-- Показ списка: telescope, если он есть, иначе штатный vim.ui.select.
--
-- Зависимости от telescope у плагина нет — он подхватывается по факту наличия. Так список
-- получает нечёткий поиск и предпросмотр там, где telescope установлен, и продолжает
-- работать там, где его нет.
--
-- Предпросмотр рисуется из БУФЕРА, а не из файла на диске: у ноутбука на диске лежит .ipynb,
-- и файловый previewer показал бы JSON вместо кода.

local M = {}

M.PREVIEW_LINES = 60

---Подходит ли строка под запрос: все слова запроса должны встретиться, регистр не важен.
---@param line string
---@param prompt string
---@return boolean
function M.matches(line, prompt)
    if prompt == nil or prompt == "" then
        return true
    end
    -- vim.fn.tolower, а не string.lower: последний работает побайтово и кириллицу
    -- не приводит, то есть поиск по русским заголовкам стал бы регистрозависимым
    local haystack = vim.fn.tolower(line)
    for word in vim.fn.tolower(prompt):gmatch("%S+") do
        if not haystack:find(word, 1, true) then
            return false
        end
    end
    return true
end

---Сортировщик, который фильтрует, но не переставляет.
---
---Штатный нечёткий сортировщик telescope выстраивает результаты по релевантности, и порядок
---разделов в документе теряется — а для оглавления он и есть главная информация. Здесь всем
---подходящим строкам даётся одинаковый вес, поэтому остаётся исходный порядок.
local function ordered_sorter()
    local sorters = require("telescope.sorters")
    return sorters.Sorter:new({
        scoring_function = function(_, prompt, line)
            return M.matches(line, prompt) and 1 or -1
        end,
    })
end

---@return boolean, table|nil
function M.telescope()
    local ok, telescope = pcall(require, "telescope.pickers")
    if not ok then
        return false, nil
    end
    return true, telescope
end

---Предпросмотр: кусок исходного буфера от выбранной строки до следующей записи.
local function previewer(buf, entries, format)
    local previewers = require("telescope.previewers")
    local filetype = vim.bo[buf].filetype

    local function region(row)
        local last = vim.api.nvim_buf_line_count(buf)
        for _, entry in ipairs(entries) do
            if entry.row > row then
                last = math.min(last, entry.row - 1)
                break
            end
        end
        return math.min(last, row + M.PREVIEW_LINES)
    end

    return previewers.new_buffer_previewer({
        title = "Содержимое",
        define_preview = function(self, entry)
            local row = entry.value.row
            local lines = vim.api.nvim_buf_get_lines(buf, row - 1, region(row), false)
            vim.api.nvim_buf_set_lines(self.state.bufnr, 0, -1, false, lines)
            vim.bo[self.state.bufnr].filetype = filetype
        end,
    })
end

---Показать список и вызвать on_choice для выбранного.
---@param entries table[]
---@param opts table prompt, format, buf
---@param on_choice fun(entry: table)
function M.select(entries, opts, on_choice)
    local ok = M.telescope()
    if not ok then
        vim.ui.select(entries, {
            prompt = opts.prompt,
            format_item = opts.format,
        }, function(choice)
            if choice then
                on_choice(choice)
            end
        end)
        return
    end

    local pickers = require("telescope.pickers")
    local finders = require("telescope.finders")
    local conf = require("telescope.config").values
    local actions = require("telescope.actions")
    local action_state = require("telescope.actions.state")

    pickers
        .new({
            -- сверху вниз: иначе первая запись документа оказывается внизу списка
            sorting_strategy = "ascending",
            layout_config = { prompt_position = "top" },
        }, {
            prompt_title = opts.prompt,
            finder = finders.new_table({
                results = entries,
                entry_maker = function(entry)
                    local display = opts.format(entry)
                    return {
                        value = entry,
                        display = display,
                        -- искать хочется и по коду, и по состоянию
                        ordinal = display,
                        lnum = entry.row,
                    }
                end,
            }),
            sorter = ordered_sorter(),
            previewer = opts.buf and previewer(opts.buf, entries, opts.format) or nil,
            attach_mappings = function(prompt_bufnr)
                actions.select_default:replace(function()
                    local selected = action_state.get_selected_entry()
                    actions.close(prompt_bufnr)
                    if selected then
                        on_choice(selected.value)
                    end
                end)
                return true
            end,
        })
        :find()
end

return M
