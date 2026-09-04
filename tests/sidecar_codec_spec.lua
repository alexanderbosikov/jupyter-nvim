-- Тесты канала к сайдкару. Часть — на кодеке без процесса, часть — против НАСТОЯЩЕГО
-- сайдкара: он обычный процесс, поэтому мок здесь не нужен и только скрыл бы гонки.

local sidecar = require("jupyter.sidecar")

---Ждать условие, прокручивая event loop: vim.schedule иначе не отработает.
local function wait(pred, timeout, what)
    local ok = vim.wait(timeout or 20000, pred, 10)
    assert.is_true(ok, "не дождались " .. (what or "условия"))
end

describe("кодек", function()
    local sc, got

    before_each(function()
        sc = sidecar.new()
        got = {}
        sc:on("*", function(msg) table.insert(got, msg) end)
    end)

    it("разбирает по одному сообщению на строку", function()
        sc:_feed('{"v":1,"ev":"stream","data":{"text":"раз"}}\n')
        sc:_feed('{"v":1,"ev":"stream","data":{"text":"два"}}\n')
        wait(function() return #got == 2 end, 1000, "два события")

        assert.equals("раз", got[1].data.text)
        assert.equals("два", got[2].data.text)
    end)

    it("склеивает строку, разорванную между чанками", function()
        sc:_feed('{"v":1,"ev":"stream","data":{"te')
        sc:_feed('xt":"склеено"}}')
        assert.equals(0, #got, "неполная строка не должна доставляться")

        sc:_feed("\n")
        wait(function() return #got == 1 end, 1000, "склеенное событие")

        assert.equals("склеено", got[1].data.text)
    end)

    it("разбирает несколько сообщений из одного чанка", function()
        sc:_feed('{"v":1,"ev":"a"}\n{"v":1,"ev":"b"}\n{"v":1,"ev":"c"}\n')
        wait(function() return #got == 3 end, 1000, "три события")

        assert.same({ "a", "b", "c" }, { got[1].ev, got[2].ev, got[3].ev })
    end)

    it("сохраняет порядок сообщений", function()
        for i = 1, 50 do
            sc:_feed(('{"v":1,"ev":"stream","data":{"n":%d}}\n'):format(i))
        end
        wait(function() return #got == 50 end, 2000, "пятьдесят событий")

        for i = 1, 50 do
            assert.equals(i, got[i].data.n)
        end
    end)

    it("пустые строки игнорирует", function()
        sc:_feed('\n   \n{"v":1,"ev":"x"}\n\n')
        wait(function() return #got == 1 end, 1000, "одно событие")

        assert.equals("x", got[1].ev)
    end)

    it("мусорную строку превращает в log, а не в исключение", function()
        sc:_feed("{это не json\n")
        wait(function() return #got == 1 end, 1000, "log о мусоре")

        assert.equals("log", got[1].ev)
        assert.equals("error", got[1].data.level)
        assert.is_truthy(got[1].data.msg:find("нераспознанная"))
    end)

    it("ответ по id уходит в колбэк запроса, а не в обработчики событий", function()
        local reply
        sc._pending[7] = function(err, data) reply = { err = err, data = data } end
        sc:_feed('{"v":1,"id":7,"ev":"ok","data":{"msg_id":"m1"}}\n')
        wait(function() return reply ~= nil end, 1000, "ответ")

        assert.is_nil(reply.err)
        assert.equals("m1", reply.data.msg_id)
        assert.equals(0, #got, "ответ на запрос не является событием")
    end)

    it("ошибку отдаёт первым аргументом колбэка", function()
        local reply
        sc._pending[3] = function(err, data) reply = { err = err, data = data } end
        sc:_feed('{"v":1,"id":3,"ev":"error","data":{"code":"kernel_not_ready"}}\n')
        wait(function() return reply ~= nil end, 1000, "ошибку")

        assert.equals("kernel_not_ready", reply.err.code)
        assert.is_nil(reply.data)
    end)

    it("упавший обработчик не мешает остальным", function()
        local reached = false
        sc:on("boom", function() error("нарочно") end)
        sc:on("boom", function() reached = true end)
        sc:_feed('{"v":1,"ev":"boom"}\n')
        wait(function() return reached end, 1000, "второй обработчик")

        assert.is_true(reached)
    end)
end)

describe("null в протоколе", function()
    it("приезжает как отсутствие поля, а не как значение", function()
        local sc = sidecar.new()
        local got
        sc:on("exec.done", function(msg) got = msg end)

        sc:_feed('{"v":1,"ev":"exec.done","cell_id":"a3f9","run_id":1,'
            .. '"data":{"status":"ok","user_expressions":null,"duration_ms":12}}\n')
        vim.wait(1000, function() return got ~= nil end, 10)

        assert.is_nil(got.data.user_expressions, "vim.NIL вёл бы себя как значение")
        assert.equals(12, got.data.duration_ms)
    end)
end)
