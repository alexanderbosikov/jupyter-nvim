-- Кто ещё держит этот ноутбук открытым.
--
-- Один .ipynb, открытый в двух nvim, — это два независимых буфера: правка в одном не видна
-- в другом, а `:wa` в забытом перезапишет файл. Swap-файл тут не помощник: ноутбук читается
-- через BufReadCmd, а swapfile у многих выключен. Поэтому свой реестр: каждый nvim, открыв
-- ноутбук, кладёт файл `<хеш пути>-<pid>.json` с pid и сокетом и убирает его при закрытии
-- буфера и при выходе. Запись от умершего nvim (SIGKILL) узнаётся по pid и стирается при
-- следующем чтении.

local M = {}

---`nil` — `stdpath("state")/jupyter/open`; задаётся в тестах.
M.DIR = nil

---Жив ли процесс; подменяется в тестах.
M.alive = function(pid)
    return type(pid) == "number" and pid > 0 and vim.uv.kill(pid, 0) == 0
end

local function dir()
    return M.DIR or vim.fs.joinpath(vim.fn.stdpath("state"), "jupyter", "open")
end

local function key(path)
    return vim.fn.sha256(vim.fn.resolve(vim.fn.fnamemodify(path, ":p"))):sub(1, 16)
end

local function own_file(path)
    return vim.fs.joinpath(dir(), ("%s-%d.json"):format(key(path), vim.fn.getpid()))
end

---Отметить, что этот nvim держит ноутбук открытым.
---@param path string
function M.claim(path)
    vim.fn.mkdir(dir(), "p")
    local record = {
        pid = vim.fn.getpid(),
        socket = vim.v.servername ~= "" and vim.v.servername or nil,
        notebook = vim.fn.fnamemodify(path, ":p"),
        at = os.date("%Y-%m-%dT%H:%M:%S"),
    }
    pcall(vim.fn.writefile, { vim.json.encode(record) }, own_file(path))
end

---Снять свою отметку.
---@param path string
function M.release(path)
    pcall(vim.fn.delete, own_file(path))
end

---Другие живые nvim с этим ноутбуком: `{ pid, socket, at }`.
---@param path string
---@return table[]
function M.others(path)
    local me = vim.fn.getpid()
    local found = {}
    for _, file in ipairs(vim.fn.glob(vim.fs.joinpath(dir(), key(path) .. "-*.json"), false, true)) do
        local ok, lines = pcall(vim.fn.readfile, file)
        local decoded, record = false, nil
        if ok and #lines > 0 then
            decoded, record = pcall(vim.json.decode, table.concat(lines, "\n"))
        end
        if decoded and type(record) == "table" and record.pid ~= me then
            if M.alive(record.pid) then
                table.insert(found, { pid = record.pid, socket = record.socket, at = record.at })
            else
                pcall(vim.fn.delete, file) -- nvim умер, не успев убрать за собой
            end
        end
    end
    return found
end

---Строка для предупреждения.
---@param others table[]
---@return string
function M.describe(others)
    local parts = {}
    for _, o in ipairs(others) do
        table.insert(parts, ("pid %d%s"):format(o.pid, o.socket and (", " .. o.socket) or ""))
    end
    return table.concat(parts, "; ")
end

return M
