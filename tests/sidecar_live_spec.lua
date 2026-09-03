-- Тесты канала к сайдкару. Часть — на кодеке без процесса, часть — против НАСТОЯЩЕГО
-- сайдкара: он обычный процесс, поэтому мок здесь не нужен и только скрыл бы гонки.

local sidecar = require("jupyter.sidecar")

---Ждать условие, прокручивая event loop: vim.schedule иначе не отработает.
local function wait(pred, timeout, what)
    local ok = vim.wait(timeout or 20000, pred, 10)
    assert.is_true(ok, "не дождались " .. (what or "условия"))
end

describe("живой сайдкар", function()
    local sc

    after_each(function()
        if sc and sc:is_running() then
            sc:stop()
            sc:wait(10000)
        end
        sc = nil
    end)

    local function started()
        local hello, fail
        sc = sidecar.new()
        sc:start(function(err, data)
            hello, fail = data, err
        end)
        wait(function() return hello ~= nil or fail ~= nil end, 30000, "hello")
        assert.is_nil(fail)
        return hello
    end

    it("здоровается и объявляет возможности", function()
        local hello = started()

        assert.equals(sidecar.PROTOCOL_V, hello.v)
        assert.is_truthy(vim.tbl_contains(hello.caps, "execute"))
        assert.is_truthy(hello.python:match("^3%."))
    end)

    it("отвечает на ping", function()
        started()
        local done = false
        sc:request("ping", {}, function(err) done = err == nil end)
        wait(function() return done end, 5000, "pong")

        assert.is_true(done)
    end)

    it("неизвестный op возвращает ошибку, а процесс живёт", function()
        started()
        local err
        sc:request("такого-нет", {}, function(e) err = e end)
        wait(function() return err ~= nil end, 5000, "ошибку")

        assert.equals("unknown_op", err.code)
        assert.is_true(sc:is_running())
    end)

    it("доводит ядро до ready и выполняет ячейку", function()
        started()
        local events = {}
        sc:on("*", function(msg) table.insert(events, msg) end)

        local function seen(ev, pred)
            for _, msg in ipairs(events) do
                if msg.ev == ev and (not pred or pred(msg)) then return msg end
            end
        end

        sc:request("kernel.start", { kernel_name = "python3" })
        wait(function()
            return seen("kernel.state", function(m) return m.data.state == "ready" end) ~= nil
        end, 60000, "kernel.state=ready")

        sc:request("execute", { cell_id = "a3f9", run_id = 1, code = "print('из nvim')" })
        wait(function() return seen("exec.done") ~= nil end, 30000, "exec.done")

        local stream = seen("stream")
        assert.equals("a3f9", stream.cell_id)
        assert.equals("из nvim", stream.data.ops[1].text)
        assert.equals("append", stream.data.ops[1].op)
        assert.equals("ok", seen("exec.done").data.status)
    end)

    it("из обработчика события можно трогать API буфера", function()
        -- Главная проверка async-границы: колбэки stdout зовутся в fast event context,
        -- и без vim.schedule этот тест падал бы с E5560 — иногда.
        started()
        local buf = vim.api.nvim_create_buf(false, true)
        local written, crashed = false, nil

        sc:on("kernel.state", function(msg)
            local ok, err = pcall(vim.api.nvim_buf_set_lines, buf, -1, -1, false, { msg.data.state })
            if ok then written = true else crashed = err end
        end)

        sc:request("kernel.start", { kernel_name = "python3" })
        wait(function() return written or crashed end, 60000, "запись в буфер")

        assert.is_nil(crashed)
        assert.is_truthy(vim.tbl_contains(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "starting"))
    end)

    it("закрытие stdin гасит процесс, запросы после этого отклоняются", function()
        started()
        sc:stop()
        sc:wait(10000)
        wait(function() return not sc:is_running() end, 10000, "выход процесса")

        local err
        sc:request("ping", {}, function(e) err = e end)

        assert.equals("not_running", err.code)
    end)
end)
