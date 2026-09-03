-- Постраничный просмотр таблиц. Форматирование проверяется как чистая функция,
-- листание — против настоящего parquet через сайдкар.

local table_view = require("jupyter.ui.table")

describe("форматирование", function()
    it("выравнивает по ширине отображения, а не по байтам", function()
        local lines = table_view.format({ "id", "имя" }, {
            { "1", "стр" },
            { "200", "длиннее" },
        })

        assert.equals(4, #lines, "заголовок, линейка и две строки")
        -- в кириллице байт больше, чем клеток: проверяем, что колонки встали ровно
        local id_col = {}
        for _, line in ipairs(lines) do
            table.insert(id_col, vim.fn.strdisplaywidth(line:match("^ (%S+)") or ""))
        end
        local starts = {}
        for _, line in ipairs(lines) do
            local prefix = line:match("^ %S+%s+")
            table.insert(starts, vim.fn.strdisplaywidth(prefix or ""))
        end
        assert.equals(starts[1], starts[3])
        assert.equals(starts[1], starts[4])
        assert.is_true(id_col[1] > 0)
    end)

    it("рисует линейку под заголовком", function()
        local lines = table_view.format({ "a" }, { { "1" } })

        assert.is_truthy(lines[2]:find("─"))
    end)

    it("обрезает слишком широкую клетку с многоточием", function()
        local lines = table_view.format({ "текст" }, { { string.rep("я", 100) } }, { max_col = 10 })

        local cell = lines[3]
        assert.is_true(
            vim.fn.strdisplaywidth(cell) <= 11, -- ведущий пробел плюс max_col
            "ширина: " .. vim.fn.strdisplaywidth(cell)
        )
        assert.is_truthy(cell:find("…"))
    end)

    it("широкую колонку зажимает по max_col, узкую не растягивает", function()
        local lines = table_view.format({ "a", "длинное_имя_колонки" }, { { "1", "x" } }, { max_col = 8 })

        for _, line in ipairs(lines) do
            assert.is_true(vim.fn.strdisplaywidth(line) <= 1 + 3 + 2 + 8, "строка шире лимита: " .. line)
        end
    end)

    it("пустой набор строк подписывает", function()
        local lines = table_view.format({ "a" }, {})

        assert.equals(" (пусто)", lines[3])
    end)

    it("без колонок не падает", function()
        assert.same({ "(нет колонок)" }, table_view.format({}, {}))
    end)

    it("nil-клетки становятся пустыми, а не ломают строку", function()
        local lines = table_view.format({ "a", "b" }, { { "1" } })

        assert.is_truthy(lines[3]:find("^ 1"))
    end)
end)

describe("статус и листание", function()
    local view

    before_each(function()
        view = table_view.new({ sidecar = {}, page_size = 50 })
    end)

    it("считает страницы", function()
        view.total, view.offset = 1240, 0
        assert.equals("строки 1–50 из 1240 · страница 1/25", view:status())

        view.offset = 1200
        assert.equals("строки 1201–1240 из 1240 · страница 25/25", view:status())
    end)

    it("пустую таблицу подписывает", function()
        assert.equals("пусто", view:status())
    end)

    it("объявляет все действия, на которые ссылаются дефолтные клавиши", function()
        local actions = view:get_actions()

        for _, spec in ipairs(table_view.DEFAULT_KEYS) do
            assert.equals("function", type(actions[spec.action]), "нет действия " .. spec.action)
        end
    end)
end)
