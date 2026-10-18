-- Чтение истории прогонов с диска. Индекс пишет сайдкар, здесь проверяется обратное чтение.

local store = require("jupyter.store")

local function fixture(records, extra)
    local dir = vim.fn.tempname()
    local base = dir .. "/.jupyter-out/отчёт"
    vim.fn.mkdir(base, "p")
    local lines = vim.tbl_map(function(r) return vim.json.encode(r) end, records)
    vim.list_extend(lines, extra or {})
    vim.fn.writefile(lines, base .. "/index.jsonl")
    return store.new({ notebook = dir .. "/отчёт.md" }), base
end

local function record(over)
    return vim.tbl_extend("force", {
        cell_id = "a3f9",
        run_id = 1,
        started_at = "2026-09-03T10:12:04+00:00",
        duration_ms = 120,
        status = "ok",
        kind = "text",
        path = "a3f9/1.txt",
        code_sha = "9c1f2a",
    }, over or {})
end

describe("хранилище", function()
    it("без ноутбука не падает и истории не имеет", function()
        local s = store.new({})

        assert.equals(0, s:load())
        assert.same({}, s:records_of("a3f9"))
        assert.is_nil(s:last_run("a3f9"))
    end)

    it("считает путь до индекса рядом с ноутбуком", function()
        local s = store.new({ notebook = "/tmp/дир/отчёт.md" })

        assert.equals("/tmp/дир/.jupyter-out/отчёт", s.base)
        assert.equals("/tmp/дир/.jupyter-out/отчёт/index.jsonl", s:index_path())
    end)

    it("читает прогоны в порядке выполнения", function()
        local s = fixture({
            record({ run_id = 1 }),
            record({ cell_id = "b7e1", run_id = 2 }),
            record({ run_id = 3, duration_ms = 999 }),
        })

        local runs = s:records_of("a3f9")

        assert.equals(3, select(2, s:size()))
        assert.equals(2, select(1, s:size()))
        assert.same({ 1, 3 }, { runs[1].run_id, runs[2].run_id })
        assert.equals(999, s:last_record("a3f9").duration_ms)
    end)

    it("обрезанную строку пропускает, остальные читает", function()
        local s = fixture({ record({ run_id = 1 }) }, { '{"cell_id": "a3f9", "run_i' , "", vim.json.encode(record({ run_id = 5 })) })

        assert.same({ 1, 5 }, vim.tbl_map(function(r) return r.run_id end, s:records_of("a3f9")))
    end)

    it("текстовый прогон собирается со строками из файла", function()
        local s, base = fixture({ record({ run_id = 7, path = "a3f9/7.txt" }) })
        vim.fn.mkdir(base .. "/a3f9", "p")
        vim.fn.writefile({ "строка один", "строка два" }, base .. "/a3f9/7.txt")

        local run = s:last_run("a3f9")

        assert.equals("a3f9", run.cell_id)
        assert.equals(7, run.run_id)
        assert.equals("ok", run.status)
        assert.is_true(run.historical)
        assert.same({ "строка один", "строка два" }, run.lines)
    end)

    it("таблица восстанавливается со путём и размером", function()
        local s, base = fixture({
            record({ run_id = 2, kind = "table", path = "a3f9/2.parquet", rows = 1240, cols = 7 }),
        })

        local run = s:last_run("a3f9")

        assert.equals(base .. "/a3f9/2.parquet", run.table.path)
        assert.equals(1240, run.table.rows)
        assert.is_truthy(run.lines[1]:find("1240"))
    end)

    it("несколько выводов: текст, обе картинки под своими маркерами, таблица", function()
        local s, base = fixture({
            record({
                run_id = 3, kind = "table", path = "a3f9/3.parquet", rows = 15, cols = 4,
                outputs = {
                    { kind = "text", path = "a3f9/3.txt" },
                    { kind = "image", path = "a3f9/3.png" },
                    { kind = "image", path = "a3f9/3-2.png" },
                    { kind = "table", path = "a3f9/3.parquet", rows = 15, cols = 4 },
                },
            }),
        })
        vim.fn.mkdir(base .. "/a3f9", "p")
        vim.fn.writefile({ "mape 0.12" }, base .. "/a3f9/3.txt")

        local run = s:last_run("a3f9")

        assert.equals("mape 0.12", run.lines[1])
        assert.same({
            { path = base .. "/a3f9/3.png", line = 2 },
            { path = base .. "/a3f9/3-2.png", line = 3 },
        }, run.images)
        assert.equals(base .. "/a3f9/3.parquet", run.table.path)
        assert.is_truthy(run.lines[4]:find("15 строк"))
    end)

    it("запись с полем text: сначала напечатанное, потом таблица", function()
        local s, base = fixture({
            record({ run_id = 5, kind = "table", path = "a3f9/5.parquet", rows = 3, cols = 1, text = "a3f9/5.out.txt" }),
        })
        vim.fn.mkdir(base .. "/a3f9", "p")
        vim.fn.writefile({ "строк всего: 3" }, base .. "/a3f9/5.out.txt")

        local run = s:last_run("a3f9")

        assert.equals("строк всего: 3", run.lines[1])
        assert.equals(base .. "/a3f9/5.parquet", run.table.path)
    end)

    it("старая запись с картинкой — одна картинка под маркером", function()
        local s, base = fixture({ record({ run_id = 4, kind = "image", path = "a3f9/4.png" }) })

        local run = s:last_run("a3f9")

        assert.same({ { path = base .. "/a3f9/4.png", line = 1 } }, run.images)
    end)

    it("ошибка сохраняет имя исключения", function()
        local s = fixture({ record({ status = "error", ename = "ZeroDivisionError", path = nil }) })

        local run = s:last_run("a3f9")

        assert.equals("error", run.status)
        assert.equals("ZeroDivisionError", run.error.code)
        assert.same({ "ZeroDivisionError" }, run.lines)
    end)

    it("пропавший файл вывода не ломает сборку прогона", function()
        local s = fixture({ record({ path = "a3f9/нет.txt" }) })

        local run = s:last_run("a3f9")

        assert.is_truthy(run)
        assert.same({}, run.lines)
    end)
end)

describe("время прогона", function()
    it("ISO из индекса переводится в локальное", function()
        local formatted = store.local_time("2026-09-03T12:46:19.742508+00:00")

        assert.is_truthy(formatted:match("^%d%d%.%d%d %d%d:%d%d$"), "получили: " .. tostring(formatted))
    end)

    it("мусор не ломает", function()
        assert.is_nil(store.local_time(nil))
        assert.is_nil(store.local_time("не дата"))
        assert.is_nil(store.local_time(42))
    end)

    it("прогон из индекса несёт время и sha кода", function()
        local dir = vim.fn.tempname()
        vim.fn.mkdir(dir .. "/.jupyter-out/отчёт", "p")
        vim.fn.writefile({
            vim.json.encode({
                cell_id = "a3f9", run_id = 1, status = "ok", kind = "text",
                started_at = "2026-09-03T12:46:19+00:00", code_sha = "9c1f2a",
            }),
        }, dir .. "/.jupyter-out/отчёт/index.jsonl")

        local run = store.new({ notebook = dir .. "/отчёт.md" }):last_run("a3f9")

        assert.equals("9c1f2a", run.code_sha)
        assert.is_truthy(run.at)
    end)
end)

describe("null в индексе", function()
    it("запись без файла вывода не роняет чтение", function()
        -- сайдкар пишет "path": null для прогонов без файла; vim.json.decode без luanil
        -- превращает его в vim.NIL, и vim.fs.joinpath падает на userdata
        local dir = vim.fn.tempname()
        vim.fn.mkdir(dir .. "/.jupyter-out/отчёт", "p")
        vim.fn.writefile({
            '{"cell_id":"a3f9","run_id":1,"status":"ok","kind":"none","path":null,"ename":null,'
                .. '"started_at":"2026-09-04T09:00:00+00:00","duration_ms":5,"code_sha":"abc12345"}',
        }, dir .. "/.jupyter-out/отчёт/index.jsonl")
        local s = store.new({ notebook = dir .. "/отчёт.md" })

        local run = s:last_run("a3f9")

        assert.is_truthy(run)
        assert.is_nil(s:path_of(s:last_record("a3f9")))
        assert.same({}, run.lines)
        assert.is_nil(run.error, "ename = null это отсутствие ошибки")
    end)
end)
