-- Подсветка winbar'ов плагина.
--
-- Штатный WinBar в большинстве тем приглушён до неразличимости, а в нём у нас живёт всё
-- состояние: номер ячейки, время, «код изменился». Поэтому берём контраст от Normal,
-- а смысловые цвета — от Diagnostic*: они есть в любой теме и подобраны читаемыми,
-- но не кричащими. Свои значения задавать не будем — иначе плагин начнёт спорить с темой.
--
-- Группы переопределяются на ColorScheme: у пользователя горячая перезагрузка темы,
-- и без этого после смены темы подсветка осталась бы от прежней.

local M = {}

M.GROUPS = {
    JupyterWinBar = { from = "Normal" }, -- основной текст: номер ячейки
    JupyterWinBarOk = { from = "DiagnosticOk", fallback = "String" },
    JupyterWinBarError = { from = "DiagnosticError", fallback = "ErrorMsg" },
    JupyterWinBarWarn = { from = "DiagnosticWarn", fallback = "WarningMsg" },
    JupyterWinBarInfo = { from = "DiagnosticInfo", fallback = "Special" },
}

local function fg_of(name)
    if not name then
        return nil
    end
    local ok, hl = pcall(vim.api.nvim_get_hl, 0, { name = name, link = false })
    if not ok then
        return nil
    end
    return hl.fg
end

-- Что мы сами выставили в прошлый раз. Нужно, чтобы после смены темы обновить свои
-- цвета, но не затереть то, что пользователь задал руками.
local ours = {}

local function untouched(name)
    local remembered = ours[name]
    if remembered == nil then
        return true -- мы эту группу ещё не ставили
    end
    local ok, hl = pcall(vim.api.nvim_get_hl, 0, { name = name, link = false })
    if not ok then
        return true
    end
    return hl.fg == remembered.fg and hl.bg == remembered.bg
end

---Определить группы. Уже настроенные пользователем не трогаем: ни при первом вызове
---(там работает default = true), ни при смене темы — там сверяемся с тем, что ставили сами.
function M.setup()
    local bar = {}
    local ok, hl = pcall(vim.api.nvim_get_hl, 0, { name = "WinBar", link = false })
    if ok then
        bar = hl
    end

    for name, spec in pairs(M.GROUPS) do
        if untouched(name) then
            local value = { fg = fg_of(spec.from) or fg_of(spec.fallback), bg = bar.bg, bold = spec.bold }
            pcall(vim.api.nvim_set_hl, 0, name, {})
            vim.api.nvim_set_hl(0, name, vim.tbl_extend("force", value, { default = true }))
            ours[name] = value
        end
    end
end

---Повесить переопределение на смену темы: без этого после переключения темы подсветка
---осталась бы от прежней, а у пользователя тема перезагружается горячо.
---@param group integer augroup
function M.attach(group)
    M.setup()
    vim.api.nvim_create_autocmd("ColorScheme", {
        group = group,
        callback = function()
            M.setup()
        end,
    })
end

---Забыть, что мы ставили. Только для тестов.
function M._forget()
    ours = {}
end

---Обернуть текст в группу для winbar/statusline.
---@param group string
---@param text string
---@return string
function M.wrap(group, text)
    if text == "" then
        return ""
    end
    return ("%%#%s#%s"):format(group, text)
end

---Группа под статус прогона.
---@param status string|nil
---@return string
function M.for_status(status)
    if status == "error" then
        return "JupyterWinBarError"
    end
    if status == "running" then
        return "JupyterWinBarInfo"
    end
    if status == "aborted" then
        return "JupyterWinBarWarn"
    end
    return "JupyterWinBarOk"
end

return M
