-- Drawer вывода: обычный буфер, статус в winbar, действия без хардкода клавиш.

local output = require("jupyter.ui.output")

local function run(fields)
    return vim.tbl_extend("force", {
        cell_id = "0001",
        run_id = 1,
        lines = {},
        status = "running",
    }, fields or {})
end

describe("drawer", function()
    local out

    before_each(function()
        out = output.new({ size = 8 })
    end)

    after_each(function()
        out:close()
    end)

    it("открывается, не забирая фокус", function()
        local before = vim.api.nvim_get_current_win()

        out:open()

        assert.is_true(out:is_open())
        assert.equals(before, vim.api.nvim_get_current_win(), "фокус должен остаться в ноутбуке")
        assert.are_not.equals(before, out.win)
    end)

    it("open и close идемпотентны", function()
        out:open()
        local win = out.win
        out:open()
        assert.equals(win, out.win)

        out:close()
        out:close()
        assert.is_false(out:is_open())
    end)

    it("toggle переключает окно", function()
        out:toggle()
        assert.is_true(out:is_open())
        out:toggle()
        assert.is_false(out:is_open())
    end)

    it("показывает строки прогона", function()
        out:show(run({ lines = { "раз", "два" } }))

        assert.same({ "раз", "два" }, vim.api.nvim_buf_get_lines(out.buf, 0, -1, false))
    end)

    it("буфер не редактируется пользователем", function()
        out:show(run({ lines = { "вывод" } }))

        assert.is_false(vim.bo[out.buf].modifiable)
        assert.equals("nofile", vim.bo[out.buf].buftype)
    end)

    it("update применяется только к показываемой ячейке", function()
        local shown = run({ cell_id = "0001", lines = { "моё" } })
        out:show(shown)

        assert.is_false(out:update(run({ cell_id = "0002", lines = { "чужое" } })))
        assert.same({ "моё" }, vim.api.nvim_buf_get_lines(out.buf, 0, -1, false))

        shown.lines = { "моё", "и ещё" }
        assert.is_true(out:update(shown))
        assert.same({ "моё", "и ещё" }, vim.api.nvim_buf_get_lines(out.buf, 0, -1, false))
    end)

    describe("статус", function()
        it("без прогона", function()
            assert.equals("нет вывода", out:status())
        end)

        it("выполняется", function()
            out.run = run()
            assert.equals("⏳ выполняется", out:status())
        end)

        it("успех показывает время и число строк", function()
            out.run = run({ status = "ok", duration_ms = 12300, lines = { "a", "b" } })
            assert.equals("✓ 12.3 с · 2 строк", out:status())
        end)

        it("успех с таблицей показывает размер, а не строки вывода", function()
            out.run = run({
                status = "ok",
                duration_ms = 500,
                lines = { "сводка" },
                table = { rows = 1240, cols = 7 },
            })
            assert.equals("✓ 0.5 с · 1240 × 7", out:status())
        end)

        it("ошибка показывает имя исключения", function()
            out.run = run({ status = "error", error = { code = "ZeroDivisionError" } })
            assert.equals("✗ ZeroDivisionError", out:status())
        end)

        it("прерывание", function()
            out.run = run({ status = "aborted" })
            assert.equals("⊘ прервано", out:status())
        end)
    end)

    it("процент в статусе экранируется для winbar", function()
        -- иначе winbar съест "%s" как элемент формата и покажет мусор
        out:show(run({ status = "error", error = { code = "Err%or" } }))

        local winbar = vim.wo[out.win].winbar
        assert.is_truthy(winbar:find("Err%%%%or", 1, false), "ожидали удвоенный процент: " .. winbar)
        assert.is_truthy(winbar:find("ячейка 0001", 1, true))
        assert.is_truthy(winbar:find("%=", 1, true), "правая часть выравнивается через %=")
    end)

    it("действия объявлены, клавиши задаются извне", function()
        local actions = out:get_actions()

        for _, name in ipairs({ "close", "clear", "yank", "top", "bottom" }) do
            assert.equals("function", type(actions[name]), "нет действия " .. name)
        end
        for _, spec in ipairs(output.DEFAULT_KEYS) do
            assert.is_truthy(actions[spec.action], "дефолтная клавиша ссылается на " .. spec.action)
        end
    end)

    it("clear чистит вывод, но прогон остаётся", function()
        local r = run({ lines = { "мусор" } })
        out:show(r)

        out:get_actions().clear()

        assert.same({}, r.lines)
        assert.same({ "" }, vim.api.nvim_buf_get_lines(out.buf, 0, -1, false))
        assert.equals(r, out.run)
    end)

    it("yank копирует весь вывод в безымянный регистр", function()
        out:show(run({ lines = { "первая", "вторая" } }))
        vim.fn.setreg('"', "")

        out:get_actions().yank()

        assert.equals("первая\nвторая", vim.fn.getreg('"'))
    end)

    it("клавиши ставятся буфер-локально", function()
        out:open()

        local maps = vim.api.nvim_buf_get_keymap(out.buf, "n")
        local lhs = {}
        for _, map in ipairs(maps) do
            lhs[map.lhs] = true
        end
        assert.is_true(lhs["q"], "дефолтная q должна быть на буфере drawer'а")
    end)
end)

describe("многострочный элемент", function()
    local common = require("jupyter.ui.common")

    it("раскладывается на строки буфера", function()
        assert.same({ "раз", "два", "три" }, common.flatten({ "раз\nдва", "три" }))
    end)

    it("теряет каретку возврата", function()
        assert.same({ "чисто" }, common.flatten({ "чисто\r" }))
    end)

    it("обрезка считает клетки экрана, а не байты и не символы", function()
        -- кириллица: два байта на символ, одна клетка
        assert.equals("привет", common.clip("привет", 10))
        assert.equals(6, vim.fn.strdisplaywidth(common.clip("привет мир", 6)))
        -- эмодзи и CJK: один символ, две клетки — по символам обрезка промахнулась бы вдвое
        for _, text in ipairs({ ("🌍"):rep(20), ("日"):rep(20) }) do
            local got = common.clip(text, 8)
            assert.is_true(
                vim.fn.strdisplaywidth(got) <= 8,
                ("вышли за 8 клеток: %d в %s"):format(vim.fn.strdisplaywidth(got), got)
            )
        end
        -- обрезанное помечается многоточием, целое — нет
        assert.is_truthy(common.clip("длинная строка", 6):find("…", 1, true))
        assert.is_nil(common.clip("коротко", 20):find("…", 1, true))
    end)

    it("drawer отрисовывает трейсбек, а не падает", function()
        local out = output.new({ size = 8 })
        out:show({
            cell_id = "0001",
            run_id = 1,
            status = "error",
            error = { code = "ZeroDivisionError" },
            lines = { "Traceback (most recent call last)\n  Cell In[1], line 1\n", "ZeroDivisionError" },
        })

        local shown = vim.api.nvim_buf_get_lines(out.buf, 0, -1, false)
        assert.is_true(#shown >= 3)
        for _, line in ipairs(shown) do
            assert.is_nil(line:find("\n", 1, true))
        end
        out:close()
    end)
end)

describe("закрытое окно", function()
    it("update не поднимает окно, но пишет в буфер", function()
        local out = output.new({ size = 8 })
        local r = run({ lines = { "первое" } })
        out:show(r)
        out:close()

        r.lines = { "первое", "второе" }
        assert.is_true(out:update(r))

        assert.is_false(out:is_open(), "обновление не должно поднимать закрытое окно")
        assert.same({ "первое", "второе" }, vim.api.nvim_buf_get_lines(out.buf, 0, -1, false))
    end)

    it("show поднимает окно заново", function()
        local out = output.new({ size = 8 })
        out:show(run({ lines = { "раз" } }))
        out:close()

        out:show(run({ cell_id = "0001", run_id = 2, lines = { "два" } }))

        assert.is_true(out:is_open())
        assert.same({ "два" }, vim.api.nvim_buf_get_lines(out.buf, 0, -1, false))
        out:close()
    end)
end)

describe("счётчик идущих прогонов", function()
    it("появляется в winbar и исчезает", function()
        local pending = 0
        local out = output.new({ size = 8, pending = function() return pending end })
        out:show(run({ status = "ok", duration_ms = 100 }))
        assert.is_nil(vim.wo[out.win].winbar:find("ещё", 1, true))

        pending = 2
        out:refresh_status()
        assert.is_truthy(vim.wo[out.win].winbar:find("ещё 2", 1, true))

        pending = 0
        out:refresh_status()
        assert.is_nil(vim.wo[out.win].winbar:find("ещё", 1, true))
        out:close()
    end)

    it("refresh_status не трогает содержимое буфера", function()
        local out = output.new({ size = 8, pending = function() return 1 end })
        out:show(run({ lines = { "не менять" }, status = "ok" }))

        out:refresh_status()

        assert.same({ "не менять" }, vim.api.nvim_buf_get_lines(out.buf, 0, -1, false))
        out:close()
    end)
end)

describe("устаревший вывод", function()
    it("код изменился — в winbar предупреждение", function()
        local stale = false
        local out = output.new({ size = 8, stale = function() return stale end })
        out:show(run({ status = "ok", duration_ms = 10, code_sha = "9c1f2a" }))
        assert.is_false(out:is_stale())
        assert.is_nil(vim.wo[out.win].winbar:find("код изменился", 1, true))

        stale = true
        out:refresh_status()

        assert.is_true(out:is_stale())
        assert.is_truthy(vim.wo[out.win].winbar:find("код изменился", 1, true))
        out:close()
    end)

    it("прогон из истории подписан временем", function()
        local out = output.new({ size = 8 })
        out:show(run({ status = "ok", duration_ms = 500, historical = true, at = "03.09 12:46" }))

        assert.is_truthy(out:status():find("из истории · 03.09 12:46", 1, true))
        out:close()
    end)

    it("ошибка из истории тоже помечена", function()
        local out = output.new({ size = 8 })
        out:show(run({ status = "error", error = { code = "KeyError" }, historical = true }))

        assert.equals("✗ KeyError · из истории", out:status())
        out:close()
    end)
end)

describe("предпросмотр таблицы", function()
    local function table_run()
        return run({
            status = "ok",
            duration_ms = 700,
            lines = { "[таблица] 1240 строк × 2 колонок" },
            table = { path = "/tmp/df.parquet", rows = 1240, cols = 2 },
        })
    end

    it("запрашивается один раз и дописывается к выводу", function()
        local asked = 0
        local out = output.new({
            size = 8,
            preview_rows = 3,
            preview = function(_, limit, cb)
                asked = asked + 1
                cb({ (" id  имя"), (" ──  ───"), (" 1   раз"), (" … ещё %d строк"):format(1237) })
            end,
        })

        out:show(table_run())
        out:render()
        out:render()

        assert.equals(1, asked, "предпросмотр должен запрашиваться один раз на прогон")
        local shown = vim.api.nvim_buf_get_lines(out.buf, 0, -1, false)
        assert.equals("[таблица] 1240 строк × 2 колонок", shown[1])
        assert.equals("", shown[2], "пустая строка отделяет сводку от таблицы")
        assert.is_truthy(shown[3]:find("имя", 1, true))
        assert.is_truthy(shown[#shown]:find("ещё 1237", 1, true))
        out:close()
    end)

    it("preview_rows = 0 выключает предпросмотр", function()
        local asked = false
        local out = output.new({
            size = 8,
            preview_rows = 0,
            preview = function() asked = true end,
        })

        out:show(table_run())

        assert.is_false(asked)
        assert.same({ "[таблица] 1240 строк × 2 колонок" }, vim.api.nvim_buf_get_lines(out.buf, 0, -1, false))
        out:close()
    end)

    it("прогон без таблицы предпросмотр не запрашивает", function()
        local asked = false
        local out = output.new({ size = 8, preview = function() asked = true end })

        out:show(run({ status = "ok", lines = { "просто текст" } }))

        assert.is_false(asked)
        out:close()
    end)

    it("ошибка чтения показывается вместо таблицы, а не роняет окно", function()
        local out = output.new({
            size = 8,
            preview = function(_, _, cb) cb({ "(не удалось прочитать таблицу: нет файла)" }) end,
        })

        out:show(table_run())

        local shown = vim.api.nvim_buf_get_lines(out.buf, 0, -1, false)
        assert.is_truthy(shown[#shown]:find("не удалось", 1, true))
        out:close()
    end)
end)

describe("размер и ориентация", function()
    it("целое значение — строки или колонки как есть", function()
        assert.equals(15, output.new({ size = 15 }):computed_size())
        assert.equals(60, output.new({ size = 60, position = "right" }):computed_size())
    end)

    it("дробное — доля экрана по нужной оси", function()
        local right = output.new({ size = 0.5, position = "right" })
        local bottom = output.new({ size = 0.25 })

        assert.equals(math.floor(vim.o.columns * 0.5), right:computed_size())
        assert.equals(math.floor(vim.o.lines * 0.25), bottom:computed_size())
    end)

    it("вправо открывается вертикальным сплитом в половину ширины", function()
        local out = output.new({ size = 0.5, position = "right" })

        out:open()

        local width = vim.api.nvim_win_get_width(out.win)
        assert.is_true(math.abs(width - math.floor(vim.o.columns * 0.5)) <= 1, "ширина: " .. width)
        assert.is_true(vim.wo[out.win].winfixwidth, "у вертикального фиксируется ширина")
        assert.is_false(vim.wo[out.win].winfixheight)
        out:close()
    end)

    it("вниз открывается горизонтальным и фиксирует высоту", function()
        local out = output.new({ size = 8 })

        out:open()

        assert.equals(8, vim.api.nvim_win_get_height(out.win))
        assert.is_true(vim.wo[out.win].winfixheight)
        assert.is_false(vim.wo[out.win].winfixwidth)
        out:close()
    end)

    it("resize пересчитывает под текущий экран", function()
        local out = output.new({ size = 0.5, position = "right" })
        out:open()
        vim.api.nvim_win_set_width(out.win, 10)

        out:resize()

        assert.is_true(vim.api.nvim_win_get_width(out.win) > 10)
        out:close()
    end)

    it("закрытое окно resize не трогает", function()
        local out = output.new({ size = 0.5, position = "right" })

        out:resize() -- не должно падать

        assert.is_false(out:is_open())
    end)
end)
