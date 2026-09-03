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

---`%` в winbar/statusline — начало элемента формата, литерал экранируется удвоением (§9 идеи).
---@param text string
---@return string
function M.escape_status(text)
    return (text:gsub("%%", "%%%%"))
end

return M
