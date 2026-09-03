-- Статус строкой под ячейкой: текст компактный, позиции пересчитываются, ничего не хранится.

local status_ui = require("jupyter.ui.status")

local function run(over)
    return vim.tbl_extend("force", { cell_id = "a3f9", run_id = 1, status = "ok", lines = {} }, over or {})
end

describe("текст статуса", function()
    it("выполняется", function()
        local text, group = status_ui.text_of(run({ status = "running" }))

        assert.equals("⏳ выполняется", text)
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
