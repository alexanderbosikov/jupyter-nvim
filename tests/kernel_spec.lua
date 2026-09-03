-- Автомат состояний и очередь до готовности — против живого ядра.
-- Главная проверка: execute сразу после start не теряется и не падает.

local kernel = require("jupyter.kernel")

local function wait(pred, timeout, what)
    assert.is_true(vim.wait(timeout or 60000, pred, 10), "не дождались " .. (what or "условия"))
end

describe("ядро", function()
    local k, events

    before_each(function()
        events = {}
        k = kernel.new({ on_event = function(msg) table.insert(events, msg) end })
    end)

    after_each(function()
        if k then
            k:stop()
            k.sidecar:wait(10000)
            k = nil
        end
    end)

    local function seen(ev, pred)
        for _, msg in ipairs(events) do
            if msg.ev == ev and (not pred or pred(msg)) then return msg end
        end
    end

    it("проходит none → starting → ready", function()
        local seq = {}
        k.on_state = function(state) table.insert(seq, state) end
        assert.equals("none", k:state())

        k:start()
        wait(function() return k:state() == "ready" end, 60000, "ready")

        assert.equals("starting", seq[1])
        assert.equals("ready", seq[#seq])
        assert.is_true(k:is_usable())
        assert.is_truthy(k:info().language_version)
    end)

    it("запуск до готовности ждёт в очереди, а не падает", function()
        local err, data
        k:start()
        -- сразу, не дожидаясь ready: ровно то нажатие, которое ломалось в molten
        k:execute({ cell_id = "a3f9", run_id = 1, code = "print('из очереди')" }, function(e, d)
            err, data = e, d
        end)

        assert.equals(1, k:queued(), "запрос должен встать в очередь")
        assert.is_false(k:is_usable())

        wait(function() return err ~= nil or data ~= nil end, 60000, "ответ на execute")

        assert.is_nil(err)
        assert.is_truthy(data.msg_id)
        assert.equals(0, k:queued())
        wait(function() return seen("exec.done") ~= nil end, 30000, "exec.done")
        assert.equals("из очереди", seen("stream").data.ops[1].text)
    end)

    it("очередь сохраняет порядок ячеек", function()
        k:start()
        for i = 1, 3 do
            k:execute({ cell_id = "c" .. i, run_id = i, code = ("print(%d)"):format(i) })
        end
        assert.equals(3, k:queued())

        wait(function()
            local done = 0
            for _, msg in ipairs(events) do
                if msg.ev == "exec.done" then done = done + 1 end
            end
            return done == 3
        end, 60000, "три exec.done")

        local order = {}
        for _, msg in ipairs(events) do
            if msg.ev == "exec.started" then table.insert(order, msg.cell_id) end
        end
        assert.same({ "c1", "c2", "c3" }, order)
    end)

    it("после смерти ядра запуск отклоняется сразу", function()
        k:start()
        wait(function() return k:state() == "ready" end, 60000, "ready")

        k:execute({ cell_id = "a3f9", run_id = 1, code = "import os, signal\nos.kill(os.getpid(), signal.SIGKILL)" })
        wait(function() return k:state() == "dead" end, 30000, "dead")

        local err
        k:execute({ cell_id = "b7e1", run_id = 2, code = "1" }, function(e) err = e end)

        assert.equals("kernel_dead", err.code)
        assert.equals(0, k:queued())
    end)

    it("смерть ядра сбрасывает очередь с ошибкой", function()
        k:start()
        wait(function() return k:state() == "ready" end, 60000, "ready")
        k._state = "starting" -- имитируем окно, в котором ядро ещё не готово

        local err
        k:execute({ cell_id = "a3f9", run_id = 1, code = "1" }, function(e) err = e end)
        assert.equals(1, k:queued())

        k:_set_state("dead", { reason = "тест" })

        assert.equals("kernel_dead", err.code)
        assert.equals("тест", err.msg)
        assert.equals(0, k:queued())
    end)

    it("рестарт очищает очередь и возвращает ядро в строй", function()
        k:start()
        wait(function() return k:state() == "ready" end, 60000, "ready")
        k:execute({ cell_id = "a3f9", run_id = 1, code = "x = 41" })
        wait(function() return seen("exec.done") ~= nil end, 30000, "exec.done")

        local restarted
        k:restart(function(err) restarted = err == nil end)
        wait(function() return restarted end, 60000, "ответ на restart")
        wait(function() return k:state() == "ready" end, 60000, "ready после рестарта")

        events = {}
        k:execute({ cell_id = "b7e1", run_id = 2, code = "print(globals().get('x'))" })
        wait(function() return seen("exec.done") ~= nil end, 30000, "exec.done после рестарта")

        assert.equals("None", seen("stream").data.ops[1].text)
    end)
end)
