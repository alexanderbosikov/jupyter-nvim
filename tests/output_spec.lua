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
