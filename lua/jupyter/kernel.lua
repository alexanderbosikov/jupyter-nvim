-- Автомат состояний ядра и очередь запусков до его готовности.
--
-- Гард из §12 п.1 идеи здесь не «не давать выполнять», а «подождать и выполнить»: сайдкар
-- сам отклонит запрос в состоянии starting (ARCHITECTURE.md §6.2), поэтому нажатие на
-- запуск сразу после старта не должно ни падать, ни теряться — ячейка становится в очередь
-- и уезжает, когда ядро ответит.
--
-- Состояние приходит событиями kernel.state, своей копии правды здесь нет.

local sidecar = require("jupyter.sidecar")

local M = {}

-- Состояния, в которых сайдкар примет execute: busy значит «ядро работает, но занято»,
-- очередь дальше держит уже само ядро.
local USABLE = { ready = true, busy = true }

---@class jupyter.Kernel
local Kernel = {}
Kernel.__index = Kernel

---@param opts? table sidecar, kernel_name, env, on_state, on_event
function M.new(opts)
    opts = opts or {}
    local self = setmetatable({
        sidecar = opts.sidecar or sidecar.new(),
        kernel_name = opts.kernel_name or "python3",
        -- переменные окружения ядра: сюда удобно класть флаги, которые библиотеки
        -- на стороне ядра читают при импорте
        env = opts.env or {},
        on_state = opts.on_state,
        _state = "none",
        _reason = nil,
        _queue = {},
        _info = {},
    }, Kernel)

    self.sidecar:on("kernel.state", function(msg)
        self:_set_state(msg.data.state, msg.data)
    end)
    if opts.on_event then
        self.sidecar:on("*", opts.on_event)
    end
    return self
end

function Kernel:state()
    return self._state
end

function Kernel:info()
    return self._info
end

function Kernel:is_usable()
    return USABLE[self._state] == true
end

function Kernel:_set_state(state, data)
    if state == self._state then
        return
    end
    self._state = state
    self._reason = data and data.reason
    if data and data.language_version then
        self._info = data
    end

    if USABLE[state] then
        self:_flush()
    elseif state == "dead" then
        self:_drop_queue({
            code = "kernel_dead",
            msg = self._reason or "ядро умерло, запуск отменён",
        })
    end
    if self.on_state then
        self.on_state(state, data)
    end
end

-- --- жизненный цикл ---

---@param opts? table notebook, cwd, kernel_name, out_dir, history_limit
---@param cb? fun(err: table|nil, started: table|nil)
function Kernel:start(opts, cb)
    opts = opts or {}
    local function boot()
        self.sidecar:request("kernel.start", {
            kernel_name = opts.kernel_name or self.kernel_name,
            cwd = opts.cwd,
            env = self.env,
            notebook = opts.notebook,
            out_dir = opts.out_dir,
            history_limit = opts.history_limit,
        }, function(err, data)
            if err then
                self:_drop_queue(err)
            end
            if cb then cb(err, data) end
        end)
    end

    if self.sidecar:is_running() then
        boot()
        return
    end
    self.sidecar:start(function(err)
        if err then
            self:_drop_queue(err)
            if cb then cb(err) end
            return
        end
        boot()
    end)
end

---@param cb? fun(err: table|nil, data: table|nil)
function Kernel:restart(cb)
    self:_drop_queue({ code = "kernel_restart", msg = "рестарт ядра, запуск отменён" })
    self.sidecar:request("kernel.restart", {}, cb)
end

function Kernel:interrupt(cb)
    self:_drop_queue({ code = "interrupted", msg = "прерывание, очередь запусков сброшена" })
    self.sidecar:request("interrupt", {}, cb)
end

function Kernel:shutdown(cb)
    self:_drop_queue({ code = "kernel_shutdown", msg = "ядро гасится, запуск отменён" })
    self.sidecar:request("kernel.shutdown", {}, cb)
end

function Kernel:stop()
    self.sidecar:stop()
end

-- --- выполнение ---

---Выполнить код. До готовности ядра запрос ждёт в очереди, а не падает.
---@param args table cell_id, run_id, code, result_expr
---@param cb? fun(err: table|nil, data: table|nil)
function Kernel:execute(args, cb)
    if self._state == "dead" then
        if cb then cb({ code = "kernel_dead", msg = self._reason or "ядро умерло" }) end
        return
    end
    if self:is_usable() then
        self.sidecar:request("execute", args, cb)
        return
    end
    table.insert(self._queue, { args = args, cb = cb })
end

function Kernel:queued()
    return #self._queue
end

function Kernel:_flush()
    local queue = self._queue
    self._queue = {}
    for _, item in ipairs(queue) do
        self.sidecar:request("execute", item.args, item.cb)
    end
end

function Kernel:_drop_queue(err)
    local queue = self._queue
    self._queue = {}
    for _, item in ipairs(queue) do
        if item.cb then
            pcall(item.cb, err)
        end
    end
end

return M
