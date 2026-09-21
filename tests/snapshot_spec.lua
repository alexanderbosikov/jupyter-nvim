-- Снимок ноутбука для внешнего читателя. Проверяется именно то, ради чего он есть:
-- ячейки вместе со своими id, последний прогон каждой и честный ответ на вопрос
-- «относится ли этот вывод к нынешнему коду».

local cells = require("jupyter.cells")
local snapshot = require("jupyter.snapshot")
local store = require("jupyter.store")

local LINES = {
    "# Отчёт", -- 1
    "", -- 2
    '```python jncell="a3f9"', -- 3
    "x = 1", -- 4
    "```", -- 5
    "", -- 6
    "```python", -- 7  без id: в снимке будет запасной, от номера ячейки
    "y = 2", -- 8
    "```", -- 9
}

local function make_buf()
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, LINES)
    vim.bo[buf].filetype = "markdown"
    return buf
end

---@return jupyter.Store, string каталог выводов
local function make_store(records)
    local dir = vim.fn.tempname()
    local base = dir .. "/.jupyter-out/отчёт"
    vim.fn.mkdir(base, "p")
    vim.fn.writefile(
        vim.tbl_map(function(r) return vim.json.encode(r) end, records),
        base .. "/index.jsonl"
    )
    return store.new({ notebook = dir .. "/отчёт.md" }), base
end

---sha кода ячейки — тот же, что кладёт в индекс сайдкар
local function sha_of(buf, index)
    return vim.fn.sha256(cells.text(buf, cells.list(buf)[index])):sub(1, 8)
end

local function record(over)
    return vim.tbl_extend("force", {
        cell_id = "a3f9",
        run_id = 7,
        started_at = "2026-09-03T10:12:04+00:00",
        duration_ms = 120,
        status = "ok",
        kind = "table",
        path = "a3f9/7.parquet",
        rows = 1240,
        cols = 7,
        execution_count = 12,
        code_sha = "0000dead",
    }, over or {})
end

describe("снимок ноутбука", function()
    local buf

    before_each(function()
        buf = make_buf()
    end)

    it("перечисляет ячейки с их id и границами", function()
        local snap = snapshot.build(buf)

        assert.equals(2, #snap.cells)
        assert.equals("a3f9", snap.cells[1].id)
        assert.equals("0002", snap.cells[2].id, "id некуда записать — запасной, от номера ячейки")
        assert.same({ 4, 4, 3, 5 }, {
            snap.cells[1].start_row,
            snap.cells[1].end_row,
            snap.cells[1].span_start,
            snap.cells[1].span_end,
        })
        assert.equals("python", snap.cells[1].lang)
        assert.equals("fence", snap.representation)
    end)

    it("без истории ячейки всё равно видны, прогонов нет", function()
        local snap = snapshot.build(buf)

        assert.equals(0, snap.cells[1].runs)
        assert.is_nil(snap.cells[1].last)
        assert.is_nil(snap.cells[1].stale)
    end)

    it("подтягивает последний прогон и делает путь абсолютным", function()
        local st, base = make_store({ record({ run_id = 6 }), record({ run_id = 7 }) })

        local snap = snapshot.build(buf, { store = st })

        local last = snap.cells[1].last
        assert.equals(2, snap.cells[1].runs)
        assert.equals(7, last.run_id, "последний прогон — тот, что дописан в индекс позже")
        assert.equals("table", last.kind)
        assert.equals(base .. "/a3f9/7.parquet", last.path)
        assert.same({ 1240, 7, 12 }, { last.rows, last.cols, last.execution_count })
        assert.equals(base, snap.out_dir)
    end)

    it("устаревший вывод помечен, свежий — нет", function()
        local stale_store = make_store({ record({ code_sha = "0000dead" }) })
        local fresh_store = make_store({ record({ code_sha = sha_of(buf, 1) }) })

        assert.is_true(snapshot.build(buf, { store = stale_store }).cells[1].stale)
        assert.is_false(snapshot.build(buf, { store = fresh_store }).cells[1].stale)
    end)

    it("в очереди и выполняется — разные состояния, а не один признак «занята»", function()
        local runs = {
            a3f9 = { status = "running", run_id = 12, lines = { "Периоды: 0%" } },
            ["0002"] = { status = "queued", run_id = 13, lines = {} },
        }
        local fake_exec = {
            run_for = function(_, cell_id) return runs[cell_id] end,
        }

        local snap = snapshot.build(buf, { exec = fake_exec })

        assert.is_true(snap.cells[1].running, "занята: ядро считает её прямо сейчас")
        assert.is_true(snap.cells[2].running, "занята: стоит в очереди ядра")
        assert.equals("running", snap.cells[1].live.status)
        assert.equals("queued", snap.cells[2].live.status, "«run all» — это очередь, а не работа")
        assert.equals("Периоды: 0%", snap.cells[1].live.tail, "по хвосту видно, движется ли прогон")
        assert.equals(0, snap.cells[2].live.lines)
    end)

    it("завершённый прогон ячейку не занимает", function()
        local fake_exec = {
            run_for = function() return { status = "aborted", run_id = 3, lines = {} } end,
        }

        local snap = snapshot.build(buf, { exec = fake_exec })

        assert.is_false(snap.cells[1].running, "прервано — тоже конец прогона")
        assert.equals("aborted", snap.cells[1].live.status)
    end)

    it("кодируется в JSON: в такой форме его и забирают снаружи", function()
        local st = make_store({ record({ ename = nil }) })

        local json = vim.json.encode(snapshot.build(buf, { store = st }))
        local back = vim.json.decode(json, { luanil = { object = true, array = true } })

        assert.equals(2, #back.cells)
        assert.equals("a3f9", back.cells[1].id)
        assert.equals(7, back.cells[1].last.run_id)
    end)
end)
