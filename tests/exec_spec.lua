-- Логика запуска и накопления вывода. Ядро здесь подменено заглушкой: проверяется
-- ровно то, что решает Lua — result_expr (§7.1) и отбраковка устаревших прогонов (§4.4).

local exec = require("jupyter.exec")
local cells = require("jupyter.cells")

local function stub_kernel()
    local k = { sent = {}, handlers = {} }
    k.sidecar = {
        on = function(_, _, fn) table.insert(k.handlers, fn) end,
    }
    -- у настоящего sidecar:on сигнатура (self, ev, fn); заглушка принимает то же
    k.sidecar.on = function(_, _ev, fn) table.insert(k.handlers, fn) end
    k.execute = function(_, args, cb)
        table.insert(k.sent, args)
        k._last_cb = cb
    end
    k.emit = function(msg)
        for _, fn in ipairs(k.handlers) do fn(msg) end
    end
    return k
end

local function buffer(lines, filetype)
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.bo[buf].filetype = filetype or "python"
    return buf
end

describe("result_expr", function()
    it("обычная ячейка сериализует последнее выражение", function()
        assert.equals("_", exec.result_expr("import polars as pl\npl.DataFrame({})"))
    end)

    it("голый %%sql кладёт результат в df_temp", function()
        assert.equals("df_temp", exec.result_expr("%%sql\nselect 1"))
    end)

    it("df_name= из магики выигрывает", function()
        assert.equals("orders", exec.result_expr("%%sql df_name=orders limit=0\nselect 1"))
        assert.equals("orders", exec.result_expr("%%sql limit=5000 df_name=orders\nselect 1"))
    end)

    it("магика считается только в первой строке", function()
        assert.equals("_", exec.result_expr("x = 1\n%%sql df_name=orders"))
    end)
end)

describe("запуск", function()
    local k, ex, buf, updates

    before_each(function()
        k = stub_kernel()
        updates = {}
        ex = exec.new({ kernel = k, on_update = function(run) table.insert(updates, run) end }):attach()
        buf = buffer({ "# %%", 'print("раз")', "# %%", 'print("два")' })
    end)

    it("отправляет код ячейки с её cell_id и result_expr", function()
        local run = ex:run_at(buf, 2)

        assert.equals(1, #k.sent)
        assert.same({
            cell_id = "0001",
            run_id = 1,
            code = 'print("раз")',
            result_expr = "_",
        }, k.sent[1])
        assert.equals("running", run.status)
    end)

    it("пустую ячейку не отправляет", function()
        local empty = buffer({ "# %%", "", "   " })

        assert.is_nil(ex:run_at(empty, 2))
        assert.equals(0, #k.sent)
    end)

    it("run_all идёт по всем ячейкам, from_row — только с текущей", function()
        ex:run_all(buf)
        assert.same({ "0001", "0002" }, { k.sent[1].cell_id, k.sent[2].cell_id })

        k.sent = {}
        ex:run_all(buf, 4)
        assert.equals(1, #k.sent)
        assert.equals("0002", k.sent[1].cell_id)
    end)

    it("копит поток строками и перерисовывает по replace_last", function()
        local run = ex:run_at(buf, 2)
        k.emit({ ev = "stream", cell_id = run.cell_id, run_id = run.run_id,
                 data = { name = "stdout", ops = { { op = "append", text = "50%" } } } })
        k.emit({ ev = "stream", cell_id = run.cell_id, run_id = run.run_id,
                 data = { name = "stdout", ops = { { op = "replace_last", text = "100%" } } } })

        assert.same({ "100%" }, run.lines)
    end)

    it("replace_last в stdout не трогает строку stderr", function()
        -- на стороне сайдкара это разные потоки со своей нумерацией, а показываем
        -- мы их одним списком: без учёта хвоста по потоку "\r" затёр бы чужую строку
        local run = ex:run_at(buf, 2)
        local function stream(name, op, text)
            k.emit({ ev = "stream", cell_id = run.cell_id, run_id = run.run_id,
                     data = { name = name, ops = { { op = op, text = text } } } })
        end

        stream("stdout", "append", "прогресс 1")
        stream("stderr", "append", "предупреждение")
        stream("stdout", "replace_last", "прогресс 2")

        assert.same({ "прогресс 2", "предупреждение" }, run.lines)
    end)

    it("события устаревшего прогона отбрасываются", function()
        local first = ex:run_at(buf, 2)
        local second = ex:run_at(buf, 2)
        assert.equals(first.cell_id, second.cell_id)

        k.emit({ ev = "stream", cell_id = first.cell_id, run_id = first.run_id,
                 data = { name = "stdout", ops = { { op = "append", text = "от прошлого запуска" } } } })
        k.emit({ ev = "stream", cell_id = second.cell_id, run_id = second.run_id,
                 data = { name = "stdout", ops = { { op = "append", text = "от текущего" } } } })

        assert.same({ "от текущего" }, second.lines)
        assert.equals(second, ex:run_for(first.cell_id))
    end)

    it("таблицу запоминает отдельно от строк", function()
        local run = ex:run_at(buf, 2)
        k.emit({ ev = "result", cell_id = run.cell_id, run_id = run.run_id,
                 data = { kind = "table", path = "/tmp/a.parquet", rows = 1240, cols = 7 } })

        assert.equals("/tmp/a.parquet", run.table.path)
        assert.equals(1240, run.table.rows)
        assert.is_truthy(run.lines[1]:find("1240"))
    end)

    it("ошибку ядра кладёт трейсбеком в вывод", function()
        local run = ex:run_at(buf, 2)
        k.emit({ ev = "exec.error", cell_id = run.cell_id, run_id = run.run_id,
                 data = { ename = "ZeroDivisionError", evalue = "division by zero",
                          traceback = { "Traceback", "ZeroDivisionError" } } })
        k.emit({ ev = "exec.done", cell_id = run.cell_id, run_id = run.run_id,
                 data = { status = "error", duration_ms = 12 } })

        assert.equals("ZeroDivisionError", run.error.code)
        assert.equals("error", run.status)
        assert.same({ "Traceback", "ZeroDivisionError" }, run.lines)
    end)

    it("clear_output очищает накопленное", function()
        local run = ex:run_at(buf, 2)
        k.emit({ ev = "stream", cell_id = run.cell_id, run_id = run.run_id,
                 data = { name = "stdout", ops = { { op = "append", text = "старое" } } } })
        k.emit({ ev = "clear_output", cell_id = run.cell_id, run_id = run.run_id, data = { wait = false } })

        assert.same({}, run.lines)
    end)

    it("отказ на execute превращается в видимую строку вывода", function()
        local run = ex:run_at(buf, 2)
        k._last_cb({ code = "kernel_dead", msg = "ядро умерло" })

        assert.equals("error", run.status)
        assert.is_truthy(run.lines[1]:find("ядро умерло"))
    end)

    it("зовёт on_update на каждое изменение", function()
        local run = ex:run_at(buf, 2)
        local before = #updates
        k.emit({ ev = "exec.done", cell_id = run.cell_id, run_id = run.run_id, data = { status = "ok" } })

        assert.is_true(#updates > before)
    end)
end)
