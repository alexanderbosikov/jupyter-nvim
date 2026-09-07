-- Ядра, оставшиеся без хозяина.
--
-- Появиться они могут одним путём: сайдкар умер не своей смертью — SIGKILL, падение
-- интерпретатора, закрытый на полуслове терминал, — не успев погасить ядро. При обычном
-- выходе он гасит ядро сам, с дедлайном в секунду, и именно поэтому nvim его не ждёт
-- (см. `M.detach` в jupyter.init). Цена этого решения — необходимость уметь опознать
-- ядро, которое осталось жить.
--
-- Ничего не мониторим и никаких демонов не держим: сайдкар при старте ядра пишет рядом с
-- выводами `runtime.json` с pid'ами и путём к connection-файлу, а при гашении убирает его.
-- Живой файл при мёртвом сайдкаре и живом pid ядра — это сирота. Проверяется по требованию:
-- при открытии ноутбука и в `:checkhealth jupyter`.

local M = {}

M.FILE = "runtime.json"

---Жив ли процесс. Сигнал 0 не делает ничего — только проверяет, что послать его было бы кому.
---@param pid any
---@return boolean
function M.alive(pid)
    return type(pid) == "number" and pid > 0 and vim.uv.kill(pid, 0) == 0
end

---Командная строка процесса.
---
---Нужна против переиспользования pid: номер могли выдать заново, и убивать чужой процесс
---мы не станем. Опознаём по connection-файлу — он уникален и стоит в argv любого ядра.
---@param pid integer
---@return string
function M.command_of(pid)
    local out = vim.fn.system({ "ps", "-o", "command=", "-p", tostring(pid) })
    if vim.v.shell_error ~= 0 then
        return ""
    end
    return vim.trim(out)
end

---@class jupyter.Orphan
---@field path string путь к следу
---@field kernel_pid integer
---@field sidecar_pid integer
---@field kernel_name string|nil
---@field started_at string|nil
---@field stale boolean след остался, а ядра уже нет — можно просто убрать файл

---Прочитать след.
---@param path string
---@return table|nil
local function read_record(path)
    local ok, lines = pcall(vim.fn.readfile, path)
    if not ok or type(lines) ~= "table" or #lines == 0 then
        return nil
    end
    local decoded, record = pcall(vim.json.decode, table.concat(lines, "\n"), { luanil = { object = true, array = true } })
    if not decoded or type(record) ~= "table" then
        return nil
    end
    return record
end

---Что не так с этим следом.
---
---Возвращает описание, только если разбираться есть с чем: либо ядро живёт без хозяина,
---либо след остался от процессов, которых уже нет.
---@param path string
---@param opts? table alive, command_of — подменяются в тестах
---@return jupyter.Orphan|nil
function M.check(path, opts)
    opts = opts or {}
    local alive = opts.alive or M.alive
    local command_of = opts.command_of or M.command_of

    local record = read_record(path)
    if not record or type(record.kernel_pid) ~= "number" then
        return nil
    end
    if alive(record.sidecar_pid) then
        return nil -- хозяин на месте: это живая сессия, а не сирота
    end

    local found = {
        path = path,
        kernel_pid = record.kernel_pid,
        sidecar_pid = record.sidecar_pid,
        kernel_name = record.kernel_name,
        started_at = record.started_at,
        stale = true,
    }
    if not alive(record.kernel_pid) then
        return found -- и сайдкара нет, и ядра: остался только файл
    end
    -- pid жив, но тот ли это процесс
    local connection = record.connection_file
    if type(connection) == "string" and connection ~= "" then
        if not command_of(record.kernel_pid):find(connection, 1, true) then
            return found -- номер переиспользован чужим процессом: трогать нельзя
        end
    end
    found.stale = false
    return found
end

---Путь следа для конкретного ноутбука.
---@param notebook string путь к файлу ноутбука
---@param out_dir? string
---@return string
function M.record_for(notebook, out_dir)
    return vim.fs.joinpath(
        vim.fn.fnamemodify(notebook, ":h"),
        out_dir or ".jupyter-out",
        vim.fn.fnamemodify(notebook, ":t:r"),
        M.FILE
    )
end

---Все следы рядом с ноутбуками в каталоге.
---@param dir string каталог с ноутбуками
---@param out_dir? string имя каталога выводов, по умолчанию .jupyter-out
---@param opts? table пробрасывается в M.check
---@return jupyter.Orphan[]
function M.scan(dir, out_dir, opts)
    local pattern = vim.fs.joinpath(dir, out_dir or ".jupyter-out", "*", M.FILE)
    local found = {}
    for _, path in ipairs(vim.fn.glob(pattern, false, true)) do
        local orphan = M.check(path, opts)
        if orphan then
            table.insert(found, orphan)
        end
    end
    return found
end

---Убрать сироту: погасить ядро и снять след.
---
---Сначала SIGTERM — ядро успеет закрыть файлы и соединения. Через полсекунды SIGKILL:
---сирота по определению уже никем не управляется, и уговаривать её дальше незачем.
---@param orphan jupyter.Orphan
---@return boolean killed
function M.kill(orphan)
    if not orphan.stale then
        pcall(vim.uv.kill, orphan.kernel_pid, "sigterm")
        vim.wait(500, function()
            return not M.alive(orphan.kernel_pid)
        end, 25)
        if M.alive(orphan.kernel_pid) then
            pcall(vim.uv.kill, orphan.kernel_pid, "sigkill")
            vim.wait(500, function()
                return not M.alive(orphan.kernel_pid)
            end, 25)
        end
    end
    pcall(vim.fn.delete, orphan.path)
    return not M.alive(orphan.kernel_pid)
end

---Человекочитаемая строка про сироту.
---@param orphan jupyter.Orphan
---@return string
function M.describe(orphan)
    local notebook = vim.fn.fnamemodify(vim.fn.fnamemodify(orphan.path, ":h"), ":t")
    if orphan.stale then
        return ("%s: след без процессов (ядро %d уже мертво)"):format(notebook, orphan.kernel_pid)
    end
    return ("%s: ядро %d (%s) живёт без сайдкара с %s"):format(
        notebook,
        orphan.kernel_pid,
        orphan.kernel_name or "?",
        orphan.started_at or "?"
    )
end

return M
