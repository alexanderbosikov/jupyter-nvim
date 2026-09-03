-- Канал к сайдкару: дочерний процесс и JSON-lines в обе стороны (ARCHITECTURE.md §4.1).
-- Запросы уходят с монотонным id, ответ на запрос ровно один и несёт тот же id; всё
-- остальное — события, на которые подписываются обработчики.
--
-- Нюанс, определяющий устройство модуля: колбэки stdout у vim.system зовутся в fast event
-- context, где трогать API нельзя. Поэтому разбор строк идёт прямо в колбэке (это чистый
-- Lua и потому безопасно), а доставка обработчикам — через vim.schedule, с сохранением
-- порядка сообщений. Обработчики выполняются под pcall: упавший обработчик не должен
-- ронять канал, иначе плагин молча перестанет получать вывод.

local M = {}

M.PROTOCOL_V = 1

---@class jupyter.Sidecar
---@field python string путь к интерпретатору с jupyter_client
---@field root string корень плагина: оттуда берётся PYTHONPATH сайдкара
local Sidecar = {}
Sidecar.__index = Sidecar

local function plugin_root()
    local this = debug.getinfo(1, "S").source:sub(2)
    return vim.fn.fnamemodify(this, ":h:h:h")
end

---@param opts? table python, root, on_exit
---@return jupyter.Sidecar
function M.new(opts)
    opts = opts or {}
    return setmetatable({
        python = opts.python or vim.g.jupyter_python or "python3",
        root = opts.root or plugin_root(),
        on_exit = opts.on_exit,
        _proc = nil,
        _next_id = 0,
        _pending = {},
        _handlers = {},
        _tail = "",
        _queue = {},
        _draining = false,
        _exited = nil,
    }, Sidecar)
end

-- --- подписка ---

---Подписаться на событие. `"*"` — на все.
---@param ev string
---@param fn fun(msg: table)
function Sidecar:on(ev, fn)
    self._handlers[ev] = self._handlers[ev] or {}
    table.insert(self._handlers[ev], fn)
end

-- --- запуск и остановка ---

---@param cb? fun(err: table|nil, hello: table|nil)
function Sidecar:start(cb)
    if self._proc then
        if cb then cb({ code = "already_running", msg = "сайдкар уже запущен" }) end
        return
    end

    self._exited = nil
    self._proc = vim.system({ self.python, "-m", "jupyter_nvim" }, {
        stdin = true,
        text = true,
        env = { PYTHONPATH = self.root .. "/sidecar" },
        stdout = function(err, data)
            if err or not data then return end
            self:_feed(data)
        end,
        stderr = function(err, data)
            if err or not data or not data:match("%S") then return end
            self:_emit_local("log", { level = "stderr", msg = data })
        end,
    }, function(res)
        self._exited = res
        self._proc = nil
        vim.schedule(function()
            self:_fail_pending({ code = "sidecar_exited", msg = "сайдкар завершился", code_exit = res.code })
            if self.on_exit then self.on_exit(res) end
        end)
    end)

    self:request("hello", { v = M.PROTOCOL_V }, function(err, data)
        if err then
            if cb then cb(err) end
            return
        end
        if data.v ~= M.PROTOCOL_V then
            self:stop()
            err = {
                code = "protocol_version",
                msg = ("сайдкар говорит на версии %s, плагин на %d"):format(
                    tostring(data.v), M.PROTOCOL_V
                ),
            }
            if cb then cb(err) end
            return
        end
        if cb then cb(nil, data) end
    end)
end

function Sidecar:is_running()
    return self._proc ~= nil
end

---Закрывает stdin: сайдкар сам гасит ядро и выходит (см. App.serve).
function Sidecar:stop()
    if not self._proc then return end
    pcall(function() self._proc:write(nil) end)
end

---Ждать завершения процесса, прокручивая event loop.
---Именно vim.wait, а не proc:wait(): второй блокирует loop, а нам в нём нужен колбэк выхода.
---@param timeout_ms? integer
function Sidecar:wait(timeout_ms)
    vim.wait(timeout_ms or 5000, function() return self._exited ~= nil end, 10)
    return self._exited
end

-- --- запросы ---

---@param op string
---@param args? table
---@param cb? fun(err: table|nil, data: table|nil)
function Sidecar:request(op, args, cb)
    if not self._proc then
        if cb then cb({ code = "not_running", msg = "сайдкар не запущен" }) end
        return
    end

    self._next_id = self._next_id + 1
    local id = self._next_id
    if cb then self._pending[id] = cb end

    local line = vim.json.encode({ v = M.PROTOCOL_V, id = id, op = op, args = args or vim.empty_dict() })
    local ok, err = pcall(function() self._proc:write(line .. "\n") end)
    if not ok then
        self._pending[id] = nil
        if cb then cb({ code = "write_failed", msg = tostring(err) }) end
    end
    return id
end

-- --- приём ---

---Разбор чанка stdout. Зовётся в fast event context: только чистый Lua, никакого API.
function Sidecar:_feed(chunk)
    self._tail = self._tail .. chunk
    while true do
        local nl = self._tail:find("\n", 1, true)
        if not nl then break end
        local line = self._tail:sub(1, nl - 1)
        self._tail = self._tail:sub(nl + 1)
        if line:match("%S") then
            local ok, msg = pcall(vim.json.decode, line)
            if ok and type(msg) == "table" then
                table.insert(self._queue, msg)
            else
                table.insert(self._queue, {
                    ev = "log",
                    data = { level = "error", msg = "нераспознанная строка от сайдкара: " .. line },
                })
            end
        end
    end
    self:_drain_later()
end

function Sidecar:_drain_later()
    if self._draining or #self._queue == 0 then return end
    self._draining = true
    vim.schedule(function()
        self._draining = false
        local batch = self._queue
        self._queue = {}
        for _, msg in ipairs(batch) do
            self:_dispatch(msg)
        end
        self:_drain_later()
    end)
end

function Sidecar:_dispatch(msg)
    if msg.id ~= nil then
        local cb = self._pending[msg.id]
        self._pending[msg.id] = nil
        if not cb then
            return self:_emit_local("log", {
                level = "warn",
                msg = "ответ на неизвестный запрос id=" .. tostring(msg.id),
            })
        end
        local ok, err
        if msg.ev == "ok" then
            ok, err = pcall(cb, nil, msg.data or {})
        else
            ok, err = pcall(cb, msg.data or { code = "unknown", msg = "ответ без данных" })
        end
        if not ok then self:_handler_crashed(err) end
        return
    end

    for _, ev in ipairs({ msg.ev, "*" }) do
        for _, fn in ipairs(self._handlers[ev] or {}) do
            local ok, err = pcall(fn, msg)
            if not ok then self:_handler_crashed(err) end
        end
    end
end

---Локальное событие от самого канала: доставляется теми же обработчиками, что и события сайдкара.
function Sidecar:_emit_local(ev, data)
    table.insert(self._queue, { v = M.PROTOCOL_V, ev = ev, data = data, local_ = true })
    self:_drain_later()
end

function Sidecar:_handler_crashed(err)
    vim.notify("jupyter.nvim: обработчик события упал: " .. tostring(err), vim.log.levels.ERROR)
end

function Sidecar:_fail_pending(err)
    local pending = self._pending
    self._pending = {}
    for _, cb in pairs(pending) do
        pcall(cb, err)
    end
end

return M
