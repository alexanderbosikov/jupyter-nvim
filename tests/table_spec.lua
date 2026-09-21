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

describe("пустое значение в клетке", function()
    it("пустая первая колонка не схлопывает строку", function()
        local header = { "feature_source", "users" }
        local rows = { { "очень длинное имя колонки для проверки обрезки", "316" }, { "", "253" } }

        local lines, layout = table_view.format(header, rows)

        local users = layout[2]
        assert.equals("253", lines[4]:sub(users.from, users.from + 2),
            "число должно стоять в своей колонке, а не под соседним заголовком: «" .. lines[4] .. "»")
    end)

    it("хвостовые пробелы всё-таки срезаются", function()
        local lines = table_view.format({ "колонка", "x" }, { { "значение", "" } })

        assert.is_nil(lines[3]:find("%s$"), "у строки не должно быть хвоста из пробелов")
    end)
end)

describe("враждебное значение в клетке", function()
    it("перевод строки не разваливает строку таблицы", function()
        local lines = table_view.format({ "id", "текст" }, {
            { "1", "первая\nвторая" },
            { "2", "обычная" },
        })

        assert.equals(4, #lines, "заголовок, линейка и ровно две строки данных")
        for _, line in ipairs(lines) do
            assert.is_nil(line:find("\n", 1, true), "в строке буфера не может быть перевода строки")
        end
    end)

    it("нумерация не сбивается от многострочного значения", function()
        local lines = table_view.format({ "текст" }, {
            { "a\nb" },
            { "c" },
        }, { first_row = 10 })

        assert.equals("10", lines[3]:match("^%s*(%d+)"))
        assert.equals("11", lines[4]:match("^%s*(%d+)"))
    end)
end)

describe("раскладка колонок", function()
    it("возвращается вместе со строками и совпадает с отрисовкой", function()
        local lines, layout = table_view.format({ "id", "имя" }, { { "1", "стр" } })

        assert.equals(2, #layout)
        assert.equals("id", layout[1].name)
        assert.equals("имя", layout[2].name)
        -- колонка начинается там, где в строке стоит её значение
        local header = lines[1]
        assert.equals("i", vim.fn.strcharpart(header, layout[1].from - 1, 1))
        assert.equals("и", vim.fn.strcharpart(header, layout[2].from - 1, 1))
    end)

    it("без колонок раскладка пустая", function()
        local _, layout = table_view.format({}, {})

        assert.same({}, layout)
    end)
end)

describe("нумерация строк", function()
    it("продолжает счёт со страницы на страницу", function()
        local lines = table_view.format({ "id" }, { { "a" }, { "b" } }, { first_row = 101 })

        assert.equals("101", lines[3]:match("^%s*(%d+)"))
        assert.equals("102", lines[4]:match("^%s*(%d+)"))
    end)

    it("ширину колонки задаёт последний номер страницы", function()
        local lines = table_view.format({ "id" }, { { "a" }, { "b" } }, { first_row = 99 })

        -- 99 и 100: обе строки выровнены вправо по ширине большего
        assert.equals(lines[3]:find("9"), lines[4]:find("1") + 1)
    end)

    it("шапка помечена #, линейка не рвётся", function()
        local lines = table_view.format({ "id" }, { { "a" } }, { first_row = 1 })

        assert.equals("#", lines[1]:match("^%s*(%S)"))
        assert.is_truthy(lines[2]:match("^%s*─"))
    end)

    it("раскладка сдвинута на колонку номеров", function()
        local plain = select(2, table_view.format({ "id", "имя" }, { { "1", "стр" } }))
        local lines, layout = table_view.format({ "id", "имя" }, { { "1", "стр" } }, { first_row = 1 })

        assert.equals(plain[1].from + 3, layout[1].from) -- ширина номера плюс отбивка
        assert.equals("i", vim.fn.strcharpart(lines[1], layout[1].from - 1, 1))
        assert.equals("и", vim.fn.strcharpart(lines[1], layout[2].from - 1, 1))
    end)

    it("без first_row всё как было", function()
        local lines = table_view.format({ "id" }, { { "a" } })

        assert.equals(" id", lines[1])
    end)
end)

describe("сортировка", function()
    local view

    local sent

    before_each(function()
        sent = {}
        local sidecar = {
            request = function(_, op, args)
                table.insert(sent, { op = op, args = args })
            end,
        }
        view = table_view.new({ sidecar = sidecar, page_size = 50 })
        view.path = "/tmp/df.parquet"
        local _, layout = table_view.format({ "площадка", "день", "сессии" }, { { "web", "1", "10" } })
        view.layout = layout
    end)

    it("определяет колонку под курсором", function()
        assert.equals("площадка", view:column_at(view.layout[1].from))
        assert.equals("день", view:column_at(view.layout[2].to))
        assert.equals("сессии", view:column_at(view.layout[3].from + 1))
    end)

    it("за последней колонкой берёт ближайшую слева", function()
        assert.equals("сессии", view:column_at(9999))
    end)

    it("каждая следующая сортировка становится главным ключом", function()
        view:sort_by("день", false)
        view:sort_by("площадка", true)

        assert.same({
            { column = "площадка", desc = true },
            { column = "день" },
        }, view.order)
    end)

    it("повторный выбор колонки поднимает её наверх и меняет направление", function()
        view:sort_by("день", false)
        view:sort_by("площадка", false)
        view:sort_by("день", true)

        assert.equals(2, #view.order, "дубля быть не должно")
        assert.same({ column = "день", desc = true }, view.order[1])
        assert.equals("площадка", view.order[2].column)
    end)

    it("смена порядка запрашивает первую страницу с новым ключом", function()
        view.offset = 500

        view:sort_by("день", true)

        assert.equals(1, #sent)
        assert.equals("table.page", sent[1].op)
        assert.equals(0, sent[1].args.offset, "иначе смотришь в середину чужого порядка")
        assert.same({ { column = "день", desc = true } }, sent[1].args.order_by)
    end)

    it("без сортировки order_by не отправляется", function()
        view:page(0)

        assert.is_nil(sent[1].args.order_by)
    end)

    it("листание сохраняет порядок сортировки", function()
        view:sort_by("день", false)
        sent = {}

        view:get_actions().page_next()

        assert.same({ { column = "день" } }, sent[1].args.order_by)
    end)

    it("сортировка видна в статусе", function()
        view.total = 100
        assert.equals("строки 1–50 из 100 · страница 1/2", view:status())

        view:sort_by("день", false)
        view:sort_by("площадка", true)

        assert.is_truthy(view:status():find("сортировка: площадка ↓ · день ↑", 1, true))
    end)

    it("сброс очищает стек", function()
        view:sort_by("день", false)

        view:get_actions().sort_clear()

        assert.same({}, view.order)
        assert.equals("", view:sort_label())
    end)

    it("действия объявлены и привязаны к дефолтным клавишам", function()
        local actions = view:get_actions()

        for _, name in ipairs({ "sort_asc", "sort_desc", "sort_clear" }) do
            assert.equals("function", type(actions[name]), "нет действия " .. name)
        end
        local keys = {}
        for _, spec in ipairs(table_view.DEFAULT_KEYS) do
            keys[spec.action] = spec.key
        end
        assert.equals("s", keys.sort_asc)
        assert.equals("S", keys.sort_desc)
        assert.equals("c", keys.sort_clear)
    end)
end)

-- Копирование результата. Проверяется содержимое регистра: копирование кончается им,
-- а не промежуточной структурой.
describe("копирование", function()
    local view, sent, replies

    before_each(function()
        sent, replies = {}, {}
        local sidecar = {
            request = function(_, op, args, cb)
                table.insert(sent, { op = op, args = args })
                if cb and replies[1] then
                    cb(nil, table.remove(replies, 1))
                end
            end,
        }
        view = table_view.new({ sidecar = sidecar, page_size = 2 })
        view.path = "/tmp/df.parquet"
        vim.fn.setreg('"', "")
    end)

    it("TSV: шапка и строки через табуляцию, без выравнивания", function()
        local text = table_view.tsv({ "event_date", "uids", "users" }, {
            { "2026-09-08", "3181", "2941" },
            { "2026-09-09", "751", "726" },
        })

        assert.equals(
            "event_date\tuids\tusers\n2026-09-08\t3181\t2941\n2026-09-09\t751\t726",
            text
        )
    end)

    it("таб и перевод строки внутри значения не ломают колонки", function()
        local text = table_view.tsv({ "a", "b" }, { { "раз\tдва", "три\nчетыре" } })

        assert.equals("a\tb\nраз два\tтри четыре", text)
        assert.equals(2, #vim.split(text, "\n"), "строк ровно две: шапка и одна запись")
    end)

    it("y копирует показанную страницу", function()
        view.header, view.rows = { "день", "сессии" }, { { "2026-09-01", "10" } }

        view:get_actions().yank_page()

        assert.equals("день\tсессии\n2026-09-01\t10", vim.fn.getreg('"'))
    end)

    it("Y просит всю таблицу в текущем порядке и копирует её", function()
        view.header, view.rows = { "день" }, { { "2026-09-01" } }
        view.total = 3
        view.order = { { column = "день", desc = true } }
        replies[1] = { header = { "день" }, rows = { { "3" }, { "2" }, { "1" } }, offset = 0, total_rows = 3 }

        view:get_actions().yank_all()

        assert.equals("table.page", sent[1].op)
        assert.equals(0, sent[1].args.offset)
        assert.equals(3, sent[1].args.limit, "лимит — вся таблица, а не страница")
        assert.same({ { column = "день", desc = true } }, sent[1].args.order_by)
        assert.equals("день\n3\n2\n1", vim.fn.getreg('"'))
    end)

    it("пустая таблица не копируется и не падает", function()
        view.header, view.rows, view.total = {}, {}, 0

        view:get_actions().yank_page()
        view:get_actions().yank_all()

        assert.equals("", vim.fn.getreg('"'))
        assert.equals(0, #sent)
    end)
end)

-- Клетка под курсором. Проверяется регистр и нарисованная строка рядом: смысл действия
-- именно в разнице между ними — в таблице значение обрезано, в регистре обязано быть целым.
describe("клетка под курсором", function()
    local view

    after_each(function()
        if view then
            view:close()
        end
    end)

    it("копирует значение целиком, хотя в таблице оно обрезано", function()
        local long = string.rep("x", 300)
        view = table_view.new({
            sidecar = {
                request = function(_, _, _, cb)
                    if cb then
                        cb(nil, {
                            header = { "id", "text" },
                            rows = { { "1", long } },
                            offset = 0,
                            total_rows = 1,
                        })
                    end
                end,
            },
            page_size = 50,
            max_col = 20,
        })
        vim.fn.setreg('"', "")

        view:open("/tmp/df.parquet")
        vim.api.nvim_win_set_cursor(view.win, { 3, view.layout[2].from - 1 })
        view:get_actions().yank_cell()

        local shown = vim.api.nvim_buf_get_lines(view.buf, 0, -1, false)[3]
        assert.is_truthy(shown:find("…"), "в таблице клетка обрезана: " .. shown)
        assert.equals(long, vim.fn.getreg('"'), "а в регистре она должна быть целиком")
    end)

    it("номер строки продолжается со страницы, а не с единицы", function()
        view = table_view.new({ sidecar = {}, page_size = 50 })
        view.rows = { { "a" }, { "b" } }
        local _, layout = table_view.format({ "col" }, view.rows, { first_row = 101 })
        view.layout, view.offset = layout, 100

        assert.equals(101, view:cell_at(3, layout[1].from).number)
        assert.equals("b", view:cell_at(4, layout[1].from).value)
    end)

    it("колонку берёт ту, над которой курсор", function()
        view = table_view.new({ sidecar = {}, page_size = 50 })
        view.rows = { { "web", "10" } }
        local _, layout = table_view.format({ "площадка", "сессии" }, view.rows)
        view.layout = layout

        assert.equals("сессии", view:cell_at(3, layout[2].from).column)
        assert.equals("10", view:cell_at(3, layout[2].from).value)
    end)

    it("на шапке, линейке и за последней строкой клетки нет", function()
        view = table_view.new({ sidecar = {}, page_size = 50 })
        view.rows = { { "a" } }
        local _, layout = table_view.format({ "col" }, view.rows)
        view.layout = layout

        assert.is_nil(view:cell_at(1, layout[1].from))
        assert.is_nil(view:cell_at(2, layout[1].from))
        assert.is_nil(view:cell_at(4, layout[1].from))
    end)
end)
