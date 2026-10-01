-- Статус в сайдбаре herdr: чем кончается прогон и что об этом видно из соседнего воркспейса.
--
-- Первая половина — чистая сводка по прогонам. Вторая — настоящее ядро: каждый способ,
-- которым прогон может закончиться, проверен вживую, потому что статус залипает в
-- working именно на краях — на прерывании, рестарте, смерти ядра, упавшем сайдкаре.

local cells = require("jupyter.cells")
local exec = require("jupyter.exec")
local jupyter = require("jupyter")
local sidebar = require("jupyter.sidebar")

local function run(id, run_id, status, code, extra)
    local r = { cell_id = id, run_id = run_id, status = status, lines = {} }
    if code then
        r.error = { code = code }
    end
    return vim.tbl_extend("force", r, extra or {})
end

local function runs(list)
    local out = {}
    for _, r in ipairs(list) do
        out[r.cell_id] = r
    end
    return out
end

describe("сводка ноутбука", function()
    it("пока идут ячейки — working и N/M по волне", function()
        local s = sidebar.summarize({
            kernel_state = "busy",
            runs = runs({ run("a", 1, "ok"), run("b", 2, "running"), run("c", 3, "queued") }),
        })
        assert.same({ state = "working", done = 1, total = 3 }, s)
    end)

    it("всё досчиталось — idle: done herdr выведет сам", function()
        local s = sidebar.summarize({ kernel_state = "ready", runs = runs({ run("a", 1, "ok"), run("b", 2, "ok") }) })
        assert.equals("idle", s.state)
        assert.is_nil(s.message)
    end)

    it("ошибка в коде — blocked с ячейкой и исключением", function()
        local s = sidebar.summarize({
            kernel_state = "ready",
            runs = runs({ run("a", 1, "ok"), run("b", 2, "error", "ZeroDivisionError"), run("c", 3, "aborted") }),
        })
        assert.equals("blocked", s.state)
        assert.equals("ошибка в b: ZeroDivisionError", s.message)
    end)

    it("ручная остановка — idle, хотя прогоны кончились ошибкой и отменой", function()
        for _, code in ipairs({ "KeyboardInterrupt", "interrupted", "kernel_restart", "kernel_shutdown" }) do
            local s = sidebar.summarize({
                kernel_state = "ready",
                runs = runs({ run("a", 1, "error", code), run("b", 2, "aborted") }),
            })
            assert.equals("idle", s.state, code)
        end
    end)

    it("смерть ядра — blocked, даже если прогонов в волне нет", function()
        local s = sidebar.summarize({ kernel_state = "dead", runs = {} })
        assert.equals("blocked", s.state)
        assert.equals("ядро умерло", s.message)
        assert.equals("blocked", sidebar.summarize({ kernel_state = "stuck", runs = {} }).state)
    end)

    it("упавший сайдкар — blocked", function()
        local s = sidebar.summarize({ kernel_state = "busy", runs = runs({ run("a", 1, "error", "sidecar_exited") }) })
        assert.equals("blocked", s.state)
    end)

    it("input() — blocked, пока ячейка ждёт ввода", function()
        local s = sidebar.summarize({
            kernel_state = "busy",
            runs = runs({ run("a", 1, "running", nil, { input_prompt = "имя?" }) }),
        })
        assert.equals("blocked", s.state)
        assert.equals("ждёт ввода: имя?", s.message)
    end)

    it("прогоны до начала волны не считаются", function()
        local s = sidebar.summarize({
            kernel_state = "ready",
            base = 2,
            runs = runs({ run("a", 1, "error", "NameError"), run("b", 2, "ok"), run("c", 3, "ok") }),
        })
        assert.same({ state = "idle", done = 1, total = 1 }, s)
    end)

    it("ядро ни разу не поднимали — показывать нечего", function()
        assert.is_nil(sidebar.summarize({ kernel_state = "none", runs = {} }))
    end)
end)

describe("сводка нескольких ноутбуков", function()
    it("главный — самый тревожный, прогресс складывается по занятым", function()
        local got = sidebar.combine({
            { name = "a.ipynb", summary = { state = "working", done = 1, total = 4 } },
            { name = "b.ipynb", summary = { state = "blocked", done = 2, total = 2, message = "ядро умерло" } },
            { name = "c.ipynb", summary = { state = "working", done = 2, total = 3 } },
        })
        assert.same({ state = "blocked", label = "3/7", name = "b.ipynb +2", message = "ядро умерло" }, got)
    end)

    it("один ноутбук — его имя без хвоста, у idle нет метки", function()
        local got = sidebar.combine({ { name = "a.ipynb", summary = { state = "idle", done = 3, total = 3 } } })
        assert.same({ state = "idle", name = "a.ipynb" }, got)
    end)

    it("ноутбуки без ядра не показываются, и если других нет — nil", function()
        assert.is_nil(sidebar.combine({ { name = "a.ipynb" } }))
    end)
end)

describe("волна", function()
    local list
    before_each(function()
        sidebar._reset()
        list = {}
        sidebar.attach("nb", {
            name = "a.ipynb",
            runs = function() return list end,
            kernel_state = function() return "ready" end,
        })
    end)

    local function start(id, run_id)
        list[id] = run(id, run_id, "queued")
        sidebar.update("nb", list[id], true)
    end

    it("новая волна начинается, когда ничего не идёт, и забывает прошлую ошибку", function()
        start("a", 1)
        list.a.status, list.a.error = "error", { code = "NameError" }
        sidebar.update("nb", list.a, false)
        assert.equals("blocked", sidebar.current().state)

        start("b", 2)
        list.b.status = "ok"
        sidebar.update("nb", list.b, false)
        assert.same({ state = "idle", name = "a.ipynb" }, sidebar.current())
    end)

    it("ячейка, брошенная посреди волны, её увеличивает", function()
        start("a", 1)
        start("b", 2)
        list.a.status = "ok"
        start("c", 3)
        assert.equals("1/3", sidebar.current().label)
    end)

    it("взгляд в nvim снимает ошибку закрытой волны, но не идущую", function()
        start("a", 1)
        list.a.status, list.a.error = "error", { code = "NameError" }
        sidebar.seen()
        assert.equals("idle", sidebar.current().state)

        start("b", 2)
        sidebar.seen()
        assert.equals("working", sidebar.current().state)
    end)
end)

describe("отправка в herdr", function()
    local calls, env
    local spawn = sidebar.spawn

    before_each(function()
        sidebar._reset()
        calls = {}
        env = { HERDR_ENV = vim.env.HERDR_ENV, HERDR_PANE_ID = vim.env.HERDR_PANE_ID }
        vim.env.HERDR_ENV, vim.env.HERDR_PANE_ID = "1", "w1:p1"
        sidebar.enabled = true
        sidebar.spawn = function(args, wait_ms)
            table.insert(calls, { args = args, wait = wait_ms })
        end
    end)

    after_each(function()
        vim.env.HERDR_ENV, vim.env.HERDR_PANE_ID = env.HERDR_ENV, env.HERDR_PANE_ID
        sidebar.spawn = spawn
        sidebar._reset()
    end)

    local function arg(call, name)
        for i, a in ipairs(call.args) do
            if a == name then return call.args[i + 1] end
        end
    end

    it("статус и метаданные, с растущим seq; повтор того же статуса не шлётся", function()
        local list = { a = run("a", 1, "running") }
        sidebar.attach("nb", { name = "a.ipynb", runs = function() return list end, kernel_state = function() return "busy" end })

        sidebar.flush()
        sidebar.flush()

        assert.equals(2, #calls)
        assert.equals("report-agent", calls[1].args[2])
        assert.equals("w1:p1", calls[1].args[3])
        assert.equals("working", arg(calls[1], "--state"))
        assert.equals("report-metadata", calls[2].args[2])
        assert.equals("a.ipynb", arg(calls[2], "--display-agent"))
        assert.equals("working=0/1", arg(calls[2], "--state-label"))
        assert.is_true(tonumber(arg(calls[2], "--seq")) > tonumber(arg(calls[1], "--seq")))
        -- herdr помнит seq и после release: номер должен быть больше, чем у прошлого nvim
        assert.is_truthy(arg(calls[1], "--seq"):match("^%d+$"), "целое без экспоненты")
        assert.is_true(tonumber(arg(calls[1], "--seq")) > 1e15)
    end)

    it("закрыли последний ноутбук — release; выход из редактора ждёт herdr", function()
        local list = { a = run("a", 1, "ok") }
        sidebar.attach("nb", { name = "a.ipynb", runs = function() return list end, kernel_state = function() return "ready" end })
        sidebar.flush()
        calls = {}

        sidebar.release()

        assert.equals(1, #calls)
        assert.equals("release-agent", calls[1].args[2])
        assert.equals(sidebar.RELEASE_TIMEOUT_MS, calls[1].wait)
    end)

    it("вне herdr не зовёт ничего", function()
        vim.env.HERDR_ENV = nil
        sidebar.attach("nb", { name = "a", runs = function() return { a = run("a", 1, "running") } end, kernel_state = function() return "busy" end })
        sidebar.flush()
        sidebar.release()
        assert.equals(0, #calls)
    end)
end)

-- --- вживую ---

local function wait(pred, timeout, what)
    assert.is_true(vim.wait(timeout or 60000, pred, 20), "не дождались " .. (what or "условия"))
end

local function notebook(lines)
    local path = vim.fn.tempname() .. ".py"
    vim.fn.writefile(lines, path)
    vim.cmd.edit(path)
    vim.bo.filetype = "python"
    return vim.api.nvim_get_current_buf()
end

local function cid(buf, row)
    return exec.cell_id(buf, cells.at(buf, row))
end

describe("как кончается прогон — на настоящем ядре", function()
    local buf

    before_each(function()
        sidebar._reset()
        jupyter.setup({})
    end)

    after_each(function()
        if buf then
            jupyter.detach(buf)
            buf = nil
        end
        vim.cmd("silent! %bwipeout!")
    end)

    local function settled(session)
        wait(function()
            for _, r in pairs(session.exec.runs) do
                if exec.is_busy(r) then return false end
            end
            return next(session.exec.runs) ~= nil
        end, 60000, "конца волны")
    end

    it("идёт — working с прогрессом, досчиталось — idle", function()
        buf = notebook({ "# %%", "import time; time.sleep(1)", "# %%", "x = 2" })
        jupyter.run_all()
        local session = jupyter.session(buf)
        wait(function() local c = sidebar.current(); return c and c.state == "working" end, 60000, "working")
        assert.equals("0/2", sidebar.current().label)

        settled(session)
        assert.same({ state = "idle", name = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(buf), ":t") }, sidebar.current())
    end)

    it("ошибка в коде — blocked, оставшиеся отменены", function()
        buf = notebook({ "# %%", "1 / 0", "# %%", "x = 2" })
        jupyter.run_all()
        local session = jupyter.session(buf)
        settled(session)

        local c = sidebar.current()
        assert.equals("blocked", c.state)
        assert.equals(("ошибка в %s: ZeroDivisionError"):format(cid(buf, 2)), c.message)
        assert.equals("aborted", session.exec:run_for(cid(buf, 4)).status)
    end)

    it("ручное прерывание — idle", function()
        buf = notebook({ "# %%", "import time; time.sleep(30)", "# %%", "x = 2" })
        jupyter.run_all()
        local session = jupyter.session(buf)
        wait(function() return session.exec:run_for(cid(buf, 2)).status == "running" end, 60000, "running")

        jupyter.interrupt()
        settled(session)

        assert.equals("KeyboardInterrupt", session.exec:run_for(cid(buf, 2)).error.code)
        assert.equals("idle", sidebar.current().state)
    end)

    it("рестарт посреди прогона — idle", function()
        buf = notebook({ "# %%", "import time; time.sleep(30)", "# %%", "x = 2" })
        jupyter.run_all()
        local session = jupyter.session(buf)
        wait(function() return session.exec:run_for(cid(buf, 2)).status == "running" end, 60000, "running")

        jupyter.restart()
        settled(session)
        wait(function() return session.kernel:state() == "ready" end, 60000, "ready после рестарта")

        assert.equals("idle", sidebar.current().state)
    end)

    it("смерть ядра — blocked, после рестарта снова idle", function()
        buf = notebook({ "# %%", "import os, signal", "os.kill(os.getpid(), signal.SIGKILL)", "# %%", "x = 2" })
        jupyter.run_all()
        local session = jupyter.session(buf)
        wait(function() return session.kernel:state() == "dead" end, 60000, "смерть ядра")
        settled(session)

        assert.same("blocked", sidebar.current().state)
        assert.equals("ядро умерло", sidebar.current().message)

        jupyter.restart()
        wait(function() return session.kernel:state() == "ready" end, 60000, "ready после рестарта")
        sidebar.seen() -- ошибку волны снимает взгляд в nvim, смерть ядра — его новое состояние
        assert.equals("idle", sidebar.current().state)
    end)

    it("input() — blocked, пока ждёт; прерывание снимает", function()
        buf = notebook({ "# %%", "name = input('имя? ')" })
        jupyter.run_all()
        local session = jupyter.session(buf)
        wait(function() local c = sidebar.current(); return c and c.state == "blocked" end, 60000, "blocked на input")
        assert.equals("ждёт ввода: имя? ", sidebar.current().message)

        jupyter.interrupt()
        settled(session)
        assert.equals("idle", sidebar.current().state)
    end)

    it("упал сайдкар — прогоны закрыты, blocked", function()
        buf = notebook({ "# %%", "import time; time.sleep(30)" })
        jupyter.run_all()
        local session = jupyter.session(buf)
        wait(function() return session.exec:run_for(cid(buf, 2)).status == "running" end, 60000, "running")

        vim.uv.kill(session.sidecar._proc.pid, "sigkill")
        settled(session)

        assert.equals("sidecar_exited", session.exec:run_for(cid(buf, 2)).error.code)
        assert.equals("blocked", sidebar.current().state)
    end)

    it(":JupyterStop посреди прогона — ноутбук уходит из сайдбара", function()
        buf = notebook({ "# %%", "import time; time.sleep(30)" })
        jupyter.run_all()
        local session = jupyter.session(buf)
        wait(function() return session.exec:run_for(cid(buf, 2)).status == "running" end, 60000, "running")

        vim.cmd("JupyterStop")
        buf = nil

        assert.is_nil(sidebar.current())
    end)
end)
