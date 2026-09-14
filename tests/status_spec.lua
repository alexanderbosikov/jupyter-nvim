-- Статус строкой под ячейкой: текст компактный, позиции пересчитываются, ничего не хранится.

local status_ui = require("jupyter.ui.status")

local function run(over)
    return vim.tbl_extend("force", { cell_id = "a3f9", run_id = 1, status = "ok", lines = {} }, over or {})
end

describe("текст статуса", function()
    it("выполняется", function()
        local text, group = status_ui.text_of(run({ status = "running" }))

        assert.equals("[*] ⏳ выполняется", text, "номера у незаконченного прогона ещё нет — звёздочка, как в Lab")
        assert.equals("JupyterWinBarInfo", group)
    end)

    it("успех с временем и числом строк", function()
        local text = status_ui.text_of(run({ duration_ms = 12300, lines = { "a", "b" } }))

        assert.equals("✓ 12.3 с · 2 строк", text)
    end)

    it("успех с таблицей показывает размер", function()
        local text = status_ui.text_of(run({ duration_ms = 500, table = { rows = 1240, cols = 7 } }))

        assert.equals("✓ 0.5 с · 1240 × 7", text)
    end)

    it("ошибка красная и с именем исключения", function()
        local text, group = status_ui.text_of(run({ status = "error", error = { code = "KeyError" } }))

        assert.equals("✗ KeyError", text)
        assert.equals("JupyterWinBarError", group)
    end)

    it("прогон из истории помечен знаком и временем", function()
        local text = status_ui.text_of(run({ duration_ms = 100, historical = true, at = "03.09 12:46" }))

        assert.equals("⟲ ✓ 0.1 с · 03.09 12:46", text)
    end)

    it("устаревший код добавляет предупреждение", function()
        assert.is_truthy(status_ui.text_of(run({ duration_ms = 100 }), true):find("⚠"))
        assert.is_truthy(
            status_ui.text_of(run({ status = "error", error = { code = "E" } }), true):find("⚠")
        )
    end)
end)

describe("номер прогона ядра", function()
    it("законченный прогон показывает счётчик ядра, как In [12] в Lab", function()
        assert.equals("[12] ✓ 0.1 с", status_ui.text_of(run({ duration_ms = 100, execution_count = 12 })))
    end)

    it("пока прогон не закончен, номера нет — звёздочка", function()
        assert.equals("[*] ⏳ в очереди", status_ui.text_of(run({ status = "queued" })))
        assert.equals("[*] ⏳ выполняется", status_ui.text_of(run({ status = "running" })))
    end)

    it("у прогона из истории номер идёт после знака истории", function()
        local text = status_ui.text_of(run({ duration_ms = 100, historical = true, at = "10.09 09:53", execution_count = 7 }))

        assert.equals("⟲ [7] ✓ 0.1 с · 10.09 09:53", text)
    end)
end)

describe("отрисовка", function()
    local buf

    before_each(function()
        buf = vim.api.nvim_create_buf(false, true)
        vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "# %%", "x = 1", "# %%", "y = 2" })
        vim.bo[buf].filetype = "python"
    end)

    it("ставит по extmark'у на запись", function()
        local st = status_ui.new({})

        local drawn = st:render(buf, {
            { row = 2, text = "✓ ок", group = "JupyterWinBarOk" },
            { row = 4, text = "⏳", group = "JupyterWinBarInfo" },
        })

        assert.equals(2, drawn)
        assert.equals(2, status_ui.count(buf))
    end)

    it("перерисовка не копит extmark'и", function()
        local st = status_ui.new({})
        st:render(buf, { { row = 2, text = "раз", group = "JupyterWinBarOk" } })

        st:render(buf, { { row = 2, text = "два", group = "JupyterWinBarOk" } })

        assert.equals(1, status_ui.count(buf))
    end)

    it("clear убирает всё", function()
        local st = status_ui.new({})
        st:render(buf, { { row = 2, text = "x", group = "JupyterWinBarOk" } })

        st:clear(buf)

        assert.equals(0, status_ui.count(buf))
    end)

    it("выключенный статус ничего не рисует", function()
        local st = status_ui.new({ enabled = false })

        assert.equals(0, st:render(buf, { { row = 2, text = "x", group = "JupyterWinBarOk" } }))
        assert.equals(0, status_ui.count(buf))
    end)

    it("строка за концом буфера не ломает отрисовку", function()
        local st = status_ui.new({})

        assert.equals(1, st:render(buf, { { row = 9999, text = "x", group = "JupyterWinBarOk" } }))
    end)

    it("режим eol тоже рисует", function()
        local st = status_ui.new({ position = "eol" })

        assert.equals(1, st:render(buf, { { row = 2, text = "x", group = "JupyterWinBarOk" } }))
        local marks = vim.api.nvim_buf_get_extmarks(buf, status_ui.NS, 0, -1, { details = true })
        assert.is_truthy(marks[1][4].virt_text, "в режиме eol ожидается virt_text, а не virt_lines")
    end)
end)

-- Позиция статуса при правке. Тест смотрит в extmark'и буфера, а не в промежуточную
-- структуру: строка выбирается в jupyter.repaint, и раньше она бралась из cells.body,
-- то есть от последней НЕПУСТОЙ строки тела. Перевод строки в конце ячейки статус не
-- двигал — он висел над новой строкой до первого непробельного символа в ней.
-- Ядро тут не нужно: статус рисуется и по истории с диска.
describe("позиция под ячейкой", function()
    local jupyter = require("jupyter")
    local buf

    before_each(function()
        jupyter.setup({})
    end)

    after_each(function()
        if buf then
            jupyter.detach(buf)
            buf = nil
        end
        vim.cmd("silent! %bwipeout!")
    end)

    local function notebook_with_history(lines)
        local dir = vim.fn.tempname()
        vim.fn.mkdir(dir, "p")
        local file = vim.fs.joinpath(dir, "nb.py")
        vim.fn.writefile(lines, file)

        local out = vim.fs.joinpath(dir, ".jupyter-out", "nb")
        vim.fn.mkdir(out, "p")
        vim.fn.writefile({
            vim.json.encode({
                cell_id = "a3f9",
                run_id = 1,
                started_at = "2026-09-09T10:00:00Z",
                duration_ms = 100,
                status = "ok",
                code_sha = "0badc0de",
            }),
        }, vim.fs.joinpath(out, "index.jsonl"))

        vim.cmd.edit(file)
        vim.bo.filetype = "python"
        local b = vim.api.nvim_get_current_buf()
        jupyter.session(b) -- сессия создаётся по требованию; ядро при этом не поднимается
        return b
    end

    ---Строка буфера (1-based), под которой нарисован статус.
    local function status_row(b)
        local marks = vim.api.nvim_buf_get_extmarks(b, status_ui.NS, 0, -1, {})
        return marks[1] and marks[1][2] + 1
    end

    it("перевод строки в конце ячейки уводит статус вниз сразу", function()
        buf = notebook_with_history({ '# %% jncell="a3f9"', "x = 1", "# %%", "y = 2" })

        assert.equals(1, jupyter.repaint(buf))
        assert.equals(2, status_row(buf), "статус под единственной строкой тела")

        -- то же, что нажать Enter в конце ячейки: в теле появилась пустая строка
        vim.api.nvim_buf_set_lines(buf, 2, 2, false, { "" })
        jupyter.repaint(buf)

        assert.equals(3, status_row(buf), "статус должен уйти под новую строку, а не остаться над ней")
    end)

    it("строка из одних пробелов тоже часть ячейки", function()
        buf = notebook_with_history({ '# %% jncell="a3f9"', "x = 1", "# %%", "y = 2" })
        vim.api.nvim_buf_set_lines(buf, 2, 2, false, { "    " })

        jupyter.repaint(buf)

        assert.equals(3, status_row(buf))
    end)
end)
