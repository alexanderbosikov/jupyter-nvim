-- Оглавление: заголовки, ячейки и их состояние в одном списке.

local toc = require("jupyter.toc")

local function md(lines)
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.bo[buf].filetype = "markdown"
    return buf
end

local function py(lines)
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.bo[buf].filetype = "python"
    return buf
end

local FENCE = {
    "# Загрузка данных", -- 1
    "", -- 2
    "```python", -- 3
    "import polars as pl", -- 4
    "```", -- 5
    "", -- 6
    "## Проверки", -- 7
    "", -- 8
    "```sql", -- 9
    "select 1", -- 10
    "```", -- 11
    "", -- 12
    "# Выгрузка", -- 13
}

describe("сбор", function()
    it("заголовки и ячейки идут в порядке документа", function()
        local entries = toc.collect(md(FENCE))

        assert.same(
            { "header", "cell", "header", "cell", "header" },
            vim.tbl_map(function(e) return e.kind end, entries)
        )
        assert.same(
            { "Загрузка данных", "Проверки", "Выгрузка" },
            vim.tbl_map(function(e) return e.text end, vim.tbl_filter(function(e)
                return e.kind == "header"
            end, entries))
        )
    end)

    it("уровень заголовка сохраняется", function()
        local entries = toc.collect(md(FENCE))

        assert.equals(1, entries[1].level)
        assert.equals(2, entries[3].level)
    end)

    it("прыжок ведёт в тело ячейки, а не на фенс", function()
        local entries = toc.collect(md(FENCE))

        assert.equals(4, entries[2].row)
        assert.equals(10, entries[4].row)
    end)

    it("комментарий внутри кода заголовком не считается", function()
        local buf = md({ "```python", "# это комментарий, а не раздел", "x = 1", "```" })

        local entries = toc.collect(buf)

        assert.equals(1, #entries)
        assert.equals("cell", entries[1].kind)
    end)

    it("percent: заголовок закомментирован и всё равно находится", function()
        local buf = py({
            "# %% [markdown]",
            "# # Раздел",
            "# пояснение",
            "# %%",
            "x = 1",
        })

        local entries = toc.collect(buf)

        local header = vim.tbl_filter(function(e) return e.kind == "header" end, entries)[1]
        assert.is_truthy(header, "заголовок в markdown-ячейке percent должен находиться")
        assert.equals("Раздел", header.text)
        assert.equals(1, header.level)
    end)

    it("состояние ячейки берётся из переданной функции", function()
        local entries = toc.collect(md(FENCE), {
            run_of = function(cell)
                if cell.index == 1 then
                    return { status = "ok", duration_ms = 700, lines = { "x" } }
                end
                return nil
            end,
        })

        assert.is_truthy(entries[2].text:find("0.7 с", 1, true))
        assert.equals("не запускалась", entries[4].text)
    end)

    it("превью берёт первую содержательную строку", function()
        local buf = md({ "```python", "", "   ", "df = load()", "print(df)", "```" })

        local entries = toc.collect(buf)

        assert.equals("df = load()", entries[1].preview)
    end)

    it("длинное превью обрезается", function()
        local buf = md({ "```python", "x = " .. string.rep("ы", 80), "```" })

        assert.is_true(vim.fn.strdisplaywidth(toc.collect(buf)[1].preview) <= 48)
        assert.is_truthy(toc.collect(buf)[1].preview:find("…"))
    end)

    it("у ячейки с магикой показывается запрос, а не строка магики", function()
        -- иначе в ноутбуке из одних %%sql-ячеек все записи одинаковые
        local buf = md({ "```python", "%%sql df_name=orders", "select count(*) from t", "```" })

        assert.equals("sql: select count(*) from t", toc.collect(buf)[1].preview)
    end)

    it("родная форма фенса тоже показывает запрос", function()
        local buf = md({ '```sql magic_args="df_name=orders"', "select 1", "```" })

        assert.equals("select 1", toc.collect(buf)[1].preview)
    end)

    it("ячейка из одной магики показывает саму магику", function()
        local buf = md({ "```python", "%%sql", "```" })

        assert.equals("sql", toc.collect(buf)[1].preview)
    end)

    it("пустой буфер даёт пустое оглавление", function()
        assert.same({}, toc.collect(md({ "", "просто текст" })))
    end)
end)

describe("оформление", function()
    it("заголовки отступают по уровню", function()
        assert.equals("# Раздел", toc.format({ kind = "header", level = 1, text = "Раздел" }))
        assert.equals("  ## Подраздел", toc.format({ kind = "header", level = 2, text = "Подраздел" }))
    end)

    it("у ячейки сначала код, потом состояние", function()
        local line = toc.format({ kind = "cell", level = 0, text = "✓ 0.7 с", preview = "df = run(...)" })

        assert.equals("    df = run(...)  ✓ 0.7 с", line)
    end)
end)

describe("текущая позиция", function()
    it("находит запись, в которой стоит курсор", function()
        local entries = toc.collect(md(FENCE))

        assert.equals(1, toc.at(entries, 1))
        assert.equals(2, toc.at(entries, 4), "внутри первой ячейки")
        assert.equals(3, toc.at(entries, 7))
        assert.equals(5, toc.at(entries, 13))
    end)

    it("до первой записи ничего не выбрано", function()
        assert.is_nil(toc.at(toc.collect(md(FENCE)), 0))
    end)
end)

describe("выбор списка", function()
    local picker = require("jupyter.ui.picker")

    it("без telescope падает обратно на vim.ui.select", function()
        local shown, chosen
        local original = vim.ui.select
        vim.ui.select = function(items, opts, cb)
            shown = { items = items, prompt = opts.prompt, formatted = opts.format_item(items[1]) }
            cb(items[2])
        end
        local saved = package.loaded["telescope.pickers"]
        package.loaded["telescope.pickers"] = nil
        package.preload["telescope.pickers"] = function() error("нет telescope") end

        picker.select(
            { { text = "раз" }, { text = "два" } },
            { prompt = "Оглавление", format = function(e) return e.text end },
            function(entry) chosen = entry end
        )

        vim.ui.select = original
        package.preload["telescope.pickers"] = nil
        package.loaded["telescope.pickers"] = saved

        assert.equals("Оглавление", shown.prompt)
        assert.equals("раз", shown.formatted)
        assert.same({ text = "два" }, chosen)
    end)

    it("отказ от выбора ничего не вызывает", function()
        local called = false
        local original = vim.ui.select
        vim.ui.select = function(_, _, cb) cb(nil) end
        package.preload["telescope.pickers"] = function() error("нет telescope") end
        local saved = package.loaded["telescope.pickers"]
        package.loaded["telescope.pickers"] = nil

        picker.select({ { text = "раз" } }, { format = function(e) return e.text end }, function()
            called = true
        end)

        vim.ui.select = original
        package.preload["telescope.pickers"] = nil
        package.loaded["telescope.pickers"] = saved

        assert.is_false(called)
    end)
end)

describe("фильтрация списка", function()
    local picker = require("jupyter.ui.picker")

    it("пустой запрос пропускает всё", function()
        assert.is_true(picker.matches("любая строка", ""))
        assert.is_true(picker.matches("любая строка", nil))
    end)

    it("регистр не важен", function()
        assert.is_true(picker.matches("SELECT count(*)", "select"))
        assert.is_true(picker.matches("Загрузка данных", "ЗАГРУЗКА"))
    end)

    it("все слова запроса должны встретиться", function()
        assert.is_true(picker.matches("sql: select count(*) from t  ✓ 0.7 с", "sql count"))
        assert.is_false(picker.matches("sql: select count(*) from t", "sql orders"))
    end)

    it("слова могут идти в любом порядке", function()
        assert.is_true(picker.matches("df = load()  ✗ KeyError", "keyerror df"))
    end)

    it("ищется и по состоянию, не только по коду", function()
        assert.is_true(picker.matches("plt.plot(x)  не запускалась", "не запускалась"))
    end)
end)

describe("ширина превью", function()
    it("двойные по ширине символы не выходят за отведённые клетки", function()
        local toc = require("jupyter.toc")
        local buf = vim.api.nvim_create_buf(false, true)
        vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "# %%", ('print("%s")'):format(("日"):rep(60)) })
        vim.bo[buf].filetype = "python"

        local entry = toc.collect(buf)[1]
        local width = vim.fn.strdisplaywidth(entry.preview)

        assert.is_true(width <= 48, ("превью заняло %d клеток: %s"):format(width, entry.preview))
    end)
end)
