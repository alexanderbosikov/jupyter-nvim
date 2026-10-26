-- Вход для `jn` (sidecar/jupyter_nvim/jn.py): агентский API одним вызовом через файл.
--
-- Без него каждый вызов агента — `--remote-expr "luaeval('…')"` с аргументами прямо в
-- строке: кавычки в трёх слоях (shell, vimscript, Lua), а текст правки с переводами строк
-- туда не влезает вовсе. Здесь аргументы лежат в JSON-файле, а в выражении — только его
-- путь: экранировать нечего.

local M = {}

---Что можно позвать. Не весь `jupyter`: только то, что описано агенту в скилле.
local CALLS = {
    agent_open = true,
    snapshot = true,
    agent_run = true,
    edit_replace = true,
    edit_insert = true,
    edit_claim = true,
    edit_done = true,
    edit_touch = true,
}

---Текст ноутбука целиком, с несохранённым: буфер, а не файл.
---@param notebook string
---@return table
local function text(notebook)
    local snap = require("jupyter").snapshot(notebook)
    if not snap.buf then
        return snap
    end
    return { ok = true, text = table.concat(vim.api.nvim_buf_get_lines(snap.buf, 0, -1, false), "\n") }
end

---@param path string JSON `{fn, args}`
---@return string JSON ответа
function M.call(path)
    local ok, req = pcall(function()
        return vim.json.decode(table.concat(vim.fn.readfile(path), "\n"), { luanil = { object = true, array = true } })
    end)
    if not ok or type(req) ~= "table" then
        return vim.json.encode({ ok = false, reason = "bad_request", msg = "не читается запрос " .. path })
    end
    local args = req.args or {}
    local res
    if req.fn == "text" then
        res = text(args[1])
    elseif CALLS[req.fn] then
        res = require("jupyter")[req.fn](unpack(args, 1, req.argc or #args))
    else
        res = { ok = false, reason = "bad_request", msg = "нет такого вызова: " .. tostring(req.fn) }
    end
    return vim.json.encode(res)
end

return M
