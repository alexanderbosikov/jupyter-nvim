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
