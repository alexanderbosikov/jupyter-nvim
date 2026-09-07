-- Сквозная проверка шага 3: настоящий файл в буфере, настоящее ядро, вывод в drawer.
-- Это тот самый момент «%%sql даёт текст в буфере», только без человека.

local cells = require("jupyter.cells")
local exec = require("jupyter.exec")
local jupyter = require("jupyter")

---Стабильный id ячейки под строкой. После первого запуска он записан в маркер,
---поэтому тесты сверяются с тем, что реально лежит в тексте, а не с номером ячейки.
local function cid(buf, row)
    return exec.cell_id(buf, cells.at(buf, row))
end

local function wait(pred, timeout, what)
    assert.is_true(vim.wait(timeout or 60000, pred, 20), "не дождались " .. (what or "условия"))
end

local function notebook(lines)
    local path = vim.fn.tempname() .. ".py"
    vim.fn.writefile(lines, path)
    vim.cmd.edit(path)
    vim.bo.filetype = "python"
    return path, vim.api.nvim_get_current_buf()
end

describe("шаг 3 целиком", function()
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

    it("выполняет ячейку под курсором и показывает вывод в drawer", function()
        local _, b = notebook({ "# %%", 'print("привет из буфера")', "# %%", 'print("вторая")' })
        buf = b
        vim.api.nvim_win_set_cursor(0, { 2, 0 })

        jupyter.run_cell()
        local session = jupyter.session(buf)

        wait(function()
            local run = session.exec:run_for(cid(buf, 2))
            return run and run.status == "ok"
        end, 60000, "успешное завершение ячейки")

        assert.is_true(session.output:is_open())
        local shown = vim.api.nvim_buf_get_lines(session.output.buf, 0, -1, false)
        assert.same({ "привет из буфера" }, shown)
        assert.is_truthy(session.output:status():find("✓"))
        assert.is_truthy(vim.wo[session.output.win].winbar:find(("ячейка " .. cid(buf, 2)), 1, true))
    end)

    it("вторая ячейка не смешивается с первой", function()
        local _, b = notebook({ "# %%", 'print("первая")', "# %%", 'print("вторая")' })
        buf = b

        vim.api.nvim_win_set_cursor(0, { 2, 0 })
        jupyter.run_cell()
        local session = jupyter.session(buf)
        wait(function()
            local run = session.exec:run_for(cid(buf, 2))
            return run and run.status == "ok"
        end, 60000, "первая ячейка")

        vim.api.nvim_win_set_cursor(0, { 4, 0 })
        jupyter.run_cell()
        wait(function()
            local run = session.exec:run_for(cid(buf, 4))
            return run and run.status == "ok"
        end, 30000, "вторая ячейка")

        assert.same({ "первая" }, session.exec:run_for(cid(buf, 2)).lines)
        assert.same({ "вторая" }, session.exec:run_for(cid(buf, 4)).lines)
        assert.same({ "вторая" }, vim.api.nvim_buf_get_lines(session.output.buf, 0, -1, false))
    end)

    it("датафрейм превращается в parquet рядом с ноутбуком", function()
        local path, b = notebook({
            "# %%",
            "import polars as pl",
            "pl.DataFrame({'a': [1, 2, 3], 'b': ['x', 'y', 'z']})",
        })
        buf = b
        vim.api.nvim_win_set_cursor(0, { 2, 0 })

        jupyter.run_cell()
        local session = jupyter.session(buf)
        wait(function()
            local run = session.exec:run_for(cid(buf, 2))
            return run and run.table ~= nil and run.status == "ok"
        end, 60000, "результат-таблицу и завершение прогона")

        local run = session.exec:run_for(cid(buf, 2))
        assert.equals(3, run.table.rows)
        assert.equals(2, run.table.cols)
        assert.equals(1, vim.fn.filereadable(run.table.path))

        -- имя буфера, а не tempname(): на macOS nvim разрешает /var -> /private/var,
        -- и сайдкар получает уже разрешённый путь
        local opened = vim.api.nvim_buf_get_name(buf)
        local expected = vim.fn.fnamemodify(opened, ":h")
            .. "/.jupyter-out/"
            .. vim.fn.fnamemodify(opened, ":t:r")
            .. "/"
            .. cid(buf, 2)
            .. "/1.parquet"
        assert.equals(expected, run.table.path)
        assert.is_truthy(session.output:status():find("3 × 2", 1, true))
    end)

    it("ошибка в ячейке приезжает трейсбеком, ядро остаётся живым", function()
        local _, b = notebook({ "# %%", "1 / 0", "# %%", 'print("после ошибки")' })
        buf = b

        vim.api.nvim_win_set_cursor(0, { 2, 0 })
        jupyter.run_cell()
        local session = jupyter.session(buf)
        wait(function()
            local run = session.exec:run_for(cid(buf, 2))
            return run and run.status == "error"
        end, 60000, "ошибку")

        assert.equals("ZeroDivisionError", session.exec:run_for(cid(buf, 2)).error.code)
        assert.is_truthy(session.output:status():find("ZeroDivisionError", 1, true))

        -- именно эта проверка ловит трейсбек с "\n" внутри элемента: без неё падение
        -- случалось в обработчике события, а тест оставался зелёным
        local shown = vim.api.nvim_buf_get_lines(session.output.buf, 0, -1, false)
        assert.is_true(#shown > 1, "трейсбек должен быть отрисован строками")
        assert.is_truthy(
            table.concat(shown, "\n"):find("ZeroDivisionError", 1, true),
            "в drawer'е нет имени исключения"
        )
        for _, line in ipairs(shown) do
            assert.is_nil(line:find("\n", 1, true), "в строке буфера не должно быть перевода строки")
        end

        vim.api.nvim_win_set_cursor(0, { 4, 0 })
        jupyter.run_cell()
        wait(function()
            local run = session.exec:run_for(cid(buf, 4))
            return run and run.status == "ok"
        end, 30000, "ячейку после ошибки")

        assert.same({ "после ошибки" }, session.exec:run_for(cid(buf, 4)).lines)
    end)

    it("запуск сразу после открытия файла не теряется", function()
        -- ядро в этот момент ещё стартует: запрос должен подождать в очереди (kernel.lua)
        local _, b = notebook({ "# %%", 'print("без ожидания")' })
        buf = b
        vim.api.nvim_win_set_cursor(0, { 2, 0 })

        jupyter.run_cell()
        local session = jupyter.session(buf)
        assert.is_false(session.kernel:is_usable(), "ядро ещё не готово")
        assert.equals(1, session.kernel:queued())

        wait(function()
            local run = session.exec:run_for(cid(buf, 2))
            return run and run.status == "ok"
        end, 60000, "выполнение из очереди")

        assert.same({ "без ожидания" }, session.exec:run_for(cid(buf, 2)).lines)
    end)

    it("status рассказывает про ядро и ячейки", function()
        local _, b = notebook({ "# %%", "x = 1", "# %%", "y = 2" })
        buf = b

        local before = jupyter.status()
        assert.equals("none", before.state)
        assert.equals(2, before.cells)

        jupyter.ensure_started()
        wait(function() return jupyter.status().state == "ready" end, 60000, "ready")

        assert.is_truthy(jupyter.status().info.language_version)
    end)

    it("команды зарегистрированы", function()
        local commands = vim.api.nvim_get_commands({})

        for _, name in ipairs({
            "JupyterStart", "JupyterRun", "JupyterRunAll", "JupyterRunBelow",
            "JupyterInterrupt", "JupyterRestart", "JupyterOutput", "JupyterStop", "JupyterStatus",
        }) do
            assert.is_truthy(commands[name], "нет команды " .. name)
        end
    end)
end)

describe("конфиг", function()
    after_each(function()
        jupyter.setup({})
    end)

    it("keys заменяется целиком, а не сливается с дефолтами", function()
        jupyter.setup({ keys = { run_cell = "<leader>nc" } })

        assert.same({ run_cell = "<leader>nc" }, jupyter.config.keys)
    end)

    it("keys = false выключает мапы совсем", function()
        jupyter.setup({ keys = false })

        assert.is_false(jupyter.config.keys)
    end)

    it("остальные опции по-прежнему сливаются", function()
        jupyter.setup({ output = { size = 30 } })

        assert.equals(30, jupyter.config.output.size)
        assert.equals("bottom", jupyter.config.output.position, "не заданное берётся из дефолтов")
    end)
end)

describe("диагностика", function()
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

    it("журнал копит переходы состояний и вывод ядра", function()
        local _, b = notebook({ "# %%", 'print("для журнала")' })
        buf = b
        vim.api.nvim_win_set_cursor(0, { 2, 0 })

        jupyter.run_cell()
        local session = jupyter.session(buf)
        wait(function()
            local run = session.exec:run_for(cid(buf, 2))
            return run and run.status == "ok"
        end, 60000, "выполнение")

        local levels = {}
        for _, entry in ipairs(jupyter.log(buf)) do
            levels[entry.level] = (levels[entry.level] or 0) + 1
            assert.is_truthy(entry.at:match("^%d%d:%d%d:%d%d$"), "время записи: " .. entry.at)
        end
        assert.is_truthy(levels.state, "переходы состояний должны попадать в журнал")
        assert.is_truthy(vim.tbl_count(levels) > 0)
    end)

    it("смерть ядра попадает в журнал", function()
        local _, b = notebook({ "# %%", "import os, signal", "os.kill(os.getpid(), signal.SIGKILL)" })
        buf = b
        vim.api.nvim_win_set_cursor(0, { 2, 0 })

        jupyter.run_cell()
        local session = jupyter.session(buf)
        wait(function() return session.kernel:state() == "dead" end, 60000, "смерть ядра")

        local found = false
        for _, entry in ipairs(jupyter.log(buf)) do
            if entry.level == "state" and entry.msg == "dead" then found = true end
        end
        assert.is_true(found)
    end)

    it("журнал показывается в буфере и закрывается по q", function()
        local _, b = notebook({ "# %%", "x = 1" })
        buf = b
        jupyter.ensure_started()

        jupyter.show_log()

        local shown = vim.api.nvim_buf_get_lines(0, 0, -1, false)
        assert.is_true(#shown >= 1)
        assert.is_truthy(vim.api.nvim_buf_get_name(0):find("jupyter://log", 1, true))
        vim.cmd("close")
    end)
end)

describe("гашение", function()
    before_each(function()
        jupyter.setup({})
    end)

    it("detach возвращается сразу, а сайдкар уходит сам", function()
        local _, b = notebook({ "# %%", "x = 1" })
        jupyter.ensure_started()
        local session = jupyter.session(b)
        wait(function() return session.kernel:state() == "ready" end, 60000, "ready")
        local sidecar = session.kernel.sidecar

        local started = vim.uv.now()
        jupyter.detach(b)
        local spent = vim.uv.now() - started

        -- ждать вежливого гашения ядра — это те самые 1.9 с на выходе из редактора
        assert.is_true(spent < 200, ("гашение заняло %d мс, а не должно ждать вовсе"):format(spent))
        -- гарантию даёт сайдкар: stdin закрыт, дальше он гасит ядро и выходит без нас
        wait(function() return not sidecar:is_running() end, 10000, "выход сайдкара")
    end)

    it("с явным таймаутом detach всё-таки ждёт: это нужно тестам", function()
        local _, b = notebook({ "# %%", "x = 1" })
        jupyter.ensure_started()
        local session = jupyter.session(b)
        wait(function() return session.kernel:state() == "ready" end, 60000, "ready")

        jupyter.detach(b, 10000)

        assert.is_false(session.kernel.sidecar:is_running(), "с таймаутом ждём до конца")
    end)

    it("мёртвое ядро не задерживает гашение", function()
        local _, b = notebook({ "# %%", "import os, signal", "os.kill(os.getpid(), signal.SIGKILL)" })
        vim.api.nvim_win_set_cursor(0, { 2, 0 })
        jupyter.run_cell()
        local session = jupyter.session(b)
        wait(function() return session.kernel:state() == "dead" end, 60000, "смерть ядра")

        local started = vim.uv.now()
        jupyter.detach(b, 10000) -- даже с таймаутом: гасить нечего, ждать нечего
        local spent = vim.uv.now() - started

        assert.is_false(session.kernel.sidecar:is_running())
        assert.is_true(spent < 3000, ("гашение заняло %d мс"):format(spent))
    end)

    it("след ядра убирается при гашении", function()
        local orphans = require("jupyter.orphans")
        local path, b = notebook({ "# %%", "x = 1" })
        jupyter.ensure_started()
        local session = jupyter.session(b)
        wait(function() return session.kernel:state() == "ready" end, 60000, "ready")

        local record = orphans.record_for(path)
        wait(function() return vim.fn.filereadable(record) == 1 end, 5000, "запись следа")
        assert.is_nil(orphans.check(record), "живая сессия сиротой быть не может")

        jupyter.detach(b, 10000)

        assert.equals(0, vim.fn.filereadable(record), "след должен быть убран вместе с ядром")
    end)
end)

describe("повторный запуск при закрытом окне", function()
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

    it("окно вывода поднимается снова для той же ячейки", function()
        local _, b = notebook({ "# %%", 'print("первый прогон")' })
        buf = b
        vim.api.nvim_win_set_cursor(0, { 2, 0 })

        jupyter.run_cell()
        local session = jupyter.session(buf)
        wait(function()
            local run = session.exec:run_for(cid(buf, 2))
            return run and run.status == "ok"
        end, 60000, "первый прогон")
        assert.is_true(session.output:is_open())

        session.output:close()
        assert.is_false(session.output:is_open())

        -- та же ячейка: раньше update() молча писал в буфер и окно не появлялось
        jupyter.run_cell()
        assert.is_true(session.output:is_open(), "окно должно подняться на новый прогон")

        wait(function()
            local run = session.exec:run_for(cid(buf, 2))
            return run and run.run_id == 2 and run.status == "ok"
        end, 60000, "второй прогон")
        assert.same({ "первый прогон" }, vim.api.nvim_buf_get_lines(session.output.buf, 0, -1, false))
    end)
end)

describe("окно следует за курсором", function()
    local buf, session

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

    local function run_cell_at(row)
        vim.api.nvim_win_set_cursor(0, { row, 0 })
        jupyter.run_cell()
        session = session or jupyter.session(buf)
        wait(function()
            local r = session.exec:run_for(cid(buf, row))
            return r and r.status == "ok"
        end, 60000, "прогон в строке " .. row)
    end

    it("переключается на вывод ячейки под курсором", function()
        local _, b = notebook({ "# %%", 'print("первая")', "# %%", 'print("вторая")' })
        buf, session = b, nil

        run_cell_at(2)
        run_cell_at(4)
        assert.same({ "вторая" }, vim.api.nvim_buf_get_lines(session.output.buf, 0, -1, false))

        vim.api.nvim_win_set_cursor(0, { 2, 0 })
        jupyter.follow_cursor(buf)

        assert.equals(cid(buf, 2), session.output.run.cell_id)
        assert.same({ "первая" }, vim.api.nvim_buf_get_lines(session.output.buf, 0, -1, false))
    end)

    it("во время долгого запроса можно смотреть вывод другой ячейки", function()
        local _, b = notebook({ "# %%", 'print("готово")', "# %%", "import time", "time.sleep(3)" })
        buf, session = b, nil

        run_cell_at(2)

        vim.api.nvim_win_set_cursor(0, { 4, 0 })
        jupyter.run_cell()
        assert.equals(cid(buf, 4), session.output.run.cell_id)

        -- уходим читать первую ячейку, вторая ещё выполняется
        vim.api.nvim_win_set_cursor(0, { 2, 0 })
        jupyter.follow_cursor(buf)

        assert.equals(cid(buf, 2), session.output.run.cell_id, "окно должно переключиться")
        assert.same({ "готово" }, vim.api.nvim_buf_get_lines(session.output.buf, 0, -1, false))
        assert.is_truthy(
            vim.wo[session.output.win].winbar:find("ещё 1", 1, true),
            "в winbar должен быть счётчик идущих прогонов: " .. vim.wo[session.output.win].winbar
        )

        wait(function()
            local r = session.exec:run_for(cid(buf, 4))
            return r and r.status == "ok"
        end, 60000, "вторая ячейка")

        assert.equals(cid(buf, 2), session.output.run.cell_id, "завершение чужого прогона окно не забирает")
        assert.is_nil(vim.wo[session.output.win].winbar:find("ещё", 1, true), "счётчик должен исчезнуть")
    end)

    it("ячейка без прогона окно не трогает", function()
        local _, b = notebook({ "# %%", 'print("есть вывод")', "# %%", "x = 1" })
        buf, session = b, nil

        run_cell_at(2)

        vim.api.nvim_win_set_cursor(0, { 4, 0 })
        jupyter.follow_cursor(buf)

        assert.equals(cid(buf, 2), session.output.run.cell_id)
    end)

    it("при закрытом окне ничего не делает", function()
        local _, b = notebook({ "# %%", 'print("вывод")' })
        buf, session = b, nil

        run_cell_at(2)
        session.output:close()

        jupyter.follow_cursor(buf)

        assert.is_false(session.output:is_open())
    end)
end)

describe("клавиши", function()
    local function lhs_of(buf)
        local set = {}
        for _, map in ipairs(vim.api.nvim_buf_get_keymap(buf, "n")) do
            set[map.lhs] = map.desc
        end
        return set
    end

    after_each(function()
        jupyter.setup({})
        vim.cmd("silent! %bwipeout!")
    end)

    it("на одно действие можно повесить несколько клавиш", function()
        jupyter.setup({ keys = { next_cell = { "<C-j>", "]n" }, prev_cell = "<C-k>" } })
        local buf = vim.api.nvim_create_buf(false, true)

        jupyter.set_keys(buf)
        local maps = lhs_of(buf)

        assert.equals("jupyter: next_cell", maps["<C-J>"] or maps["<C-j>"])
        assert.equals("jupyter: next_cell", maps["]n"])
        assert.equals("jupyter: prev_cell", maps["<C-K>"] or maps["<C-k>"])
    end)

    it("неизвестное действие в keys игнорируется, а не падает", function()
        jupyter.setup({ keys = { нет_такого = "<C-x>" } })
        local buf = vim.api.nvim_create_buf(false, true)

        jupyter.set_keys(buf)

        assert.is_nil(lhs_of(buf)["<C-X>"])
    end)
end)

describe("таблица", function()
    local buf, session

    before_each(function()
        -- размер страницы фиксируем: проверки ниже про клампинг и края,
        -- а не про текущее значение по умолчанию
        jupyter.setup({ table = { page_size = 50 } })
    end)

    after_each(function()
        if buf then
            jupyter.detach(buf)
            buf = nil
            session = nil
        end
        vim.cmd("silent! %bwipeout!")
    end)

    local function table_lines()
        return vim.api.nvim_buf_get_lines(session.table.buf, 0, -1, false)
    end

    it("листается постранично и не читает файл целиком", function()
        local _, b = notebook({
            "# %%",
            "import polars as pl",
            "pl.DataFrame({'n': range(200), 'имя': [f'стр-{i}' for i in range(200)]})",
        })
        buf, session = b, nil
        vim.api.nvim_win_set_cursor(0, { 2, 0 })

        jupyter.run_cell()
        session = jupyter.session(buf)
        wait(function()
            local r = session.exec:run_for(cid(buf, 2))
            return r and r.status == "ok" and r.table ~= nil
        end, 60000, "таблицу")

        jupyter.open_table()
        wait(function() return session.table.total == 200 end, 30000, "первую страницу")

        local lines = table_lines()
        assert.equals(52, #lines, "заголовок, линейка и 50 строк")
        assert.is_truthy(lines[1]:find("имя", 1, true))
        assert.is_truthy(lines[3]:find("стр%-0"))
        assert.is_truthy(session.table:status():find("строки 1–50 из 200", 1, true))
        assert.is_truthy(vim.wo[session.table.win].winbar:find(("ячейка " .. cid(buf, 2)), 1, true))

        session.table:get_actions().page_next()
        wait(function() return session.table.offset == 50 end, 30000, "вторую страницу")
        assert.is_truthy(table_lines()[3]:find("стр%-50"))

        session.table:get_actions().page_last()
        wait(function() return session.table.offset == 150 end, 30000, "последнюю страницу")
        assert.is_truthy(session.table:status():find("страница 4/4", 1, true))

        session.table:get_actions().page_next()
        wait(function() return session.table.offset == 150 end, 5000, "клампинг за концом")
        assert.equals(52, #table_lines())

        session.table:get_actions().close()
        assert.is_false(session.table:is_open())
    end)

    it("у ячейки без таблицы предупреждает, а не открывает пустое окно", function()
        local _, b = notebook({ "# %%", 'print("просто текст")' })
        buf, session = b, nil
        vim.api.nvim_win_set_cursor(0, { 2, 0 })

        jupyter.run_cell()
        session = jupyter.session(buf)
        wait(function()
            local r = session.exec:run_for(cid(buf, 2))
            return r and r.status == "ok"
        end, 60000, "прогон")

        local said
        local notify = vim.notify
        vim.notify = function(msg) said = msg end
        jupyter.open_table()
        vim.notify = notify

        assert.is_truthy(said and said:find("нет результата%-таблицы"))
        assert.is_false(session.table:is_open())
    end)
end)

describe("история переживает перезагрузку", function()
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

    it("вывод вчерашней ячейки виден без ядра и без перезапуска", function()
        local path, b = notebook({ "# %%", 'print("это было раньше")', "# %%", "x = 1" })
        buf = b
        vim.api.nvim_win_set_cursor(0, { 2, 0 })

        jupyter.run_cell()
        local session = jupyter.session(buf)
        wait(function()
            local r = session.exec:run_for(cid(buf, 2))
            return r and r.status == "ok"
        end, 60000, "прогон")

        local id = cid(buf, 2)
        assert.is_truthy(id:match("^%x%x%x%x$"), "id должен быть записан в маркер")
        vim.cmd("silent write")

        -- закрываем всё: ядра нет, состояние в памяти потеряно
        jupyter.detach(buf)
        buf = nil
        vim.cmd("silent! %bwipeout!")

        vim.cmd.edit(path)
        vim.bo.filetype = "python"
        buf = vim.api.nvim_get_current_buf()
        local reopened = jupyter.session(buf)

        assert.equals(id, cid(buf, 2), "id прочитался из текста")
        assert.equals("none", reopened.kernel:state(), "ядро подниматься не должно")

        local from_disk = reopened.store:last_run(id)
        assert.is_truthy(from_disk, "история должна найтись по id")
        assert.same({ "это было раньше" }, from_disk.lines)
        assert.is_true(from_disk.historical)

        -- и то же самое через движение курсора
        reopened.output:open()
        vim.api.nvim_win_set_cursor(0, { 2, 0 })
        jupyter.follow_cursor(buf)

        assert.same({ "это было раньше" }, vim.api.nvim_buf_get_lines(reopened.output.buf, 0, -1, false))
        assert.is_truthy(reopened.output:status():find("из истории", 1, true))
    end)

    it("status рассказывает про историю", function()
        local _, b = notebook({ "# %%", 'print("для истории")' })
        buf = b
        vim.api.nvim_win_set_cursor(0, { 2, 0 })

        jupyter.run_cell()
        local session = jupyter.session(buf)
        wait(function()
            local r = session.exec:run_for(cid(buf, 2))
            return r and r.status == "ok"
        end, 60000, "прогон")

        session.store:load()
        local st = jupyter.status()

        assert.equals(1, st.history_cells)
        assert.is_true(st.history_runs >= 1)
    end)
end)

describe("устаревший и исторический вывод", function()
    local buf, session

    before_each(function()
        jupyter.setup({})
    end)

    after_each(function()
        if buf then
            jupyter.detach(buf)
            buf = nil
            session = nil
        end
        vim.cmd("silent! %bwipeout!")
    end)

    local function run_and_wait(row)
        vim.api.nvim_win_set_cursor(0, { row, 0 })
        jupyter.run_cell()
        session = session or jupyter.session(buf)
        local want = session.exec._next_run
        wait(function()
            local r = session.exec:run_for(cid(buf, row))
            return r and r.run_id == want and r.status ~= "running"
        end, 60000, "прогон в строке " .. row)
    end

    it("правка ячейки помечает показанный вывод как устаревший", function()
        local _, b = notebook({ "# %%", 'print("старый результат")' })
        buf, session = b, nil

        run_and_wait(2)
        assert.is_false(session.output:is_stale(), "свежий вывод устаревшим быть не должен")

        vim.api.nvim_buf_set_lines(buf, 1, 2, false, { 'print("уже другой код")' })
        session.output:refresh_status()

        assert.is_true(session.output:is_stale())
        assert.is_truthy(vim.wo[session.output.win].winbar:find("код изменился", 1, true))
    end)

    it("листание истории показывает предыдущие прогоны и не сбивается курсором", function()
        local _, b = notebook({ "# %%", 'print("прогон А")' })
        buf, session = b, nil

        run_and_wait(2)
        vim.api.nvim_buf_set_lines(buf, 1, 2, false, { 'print("прогон Б")' })
        run_and_wait(2)
        assert.same({ "прогон Б" }, vim.api.nvim_buf_get_lines(session.output.buf, 0, -1, false))

        local older = jupyter.prev_run()

        assert.is_truthy(older)
        assert.is_true(older.historical)
        assert.same({ "прогон А" }, vim.api.nvim_buf_get_lines(session.output.buf, 0, -1, false))

        -- движение курсора не должно возвращать к последнему прогону
        jupyter.follow_cursor(buf)
        assert.same({ "прогон А" }, vim.api.nvim_buf_get_lines(session.output.buf, 0, -1, false))

        jupyter.next_run()
        assert.same({ "прогон Б" }, vim.api.nvim_buf_get_lines(session.output.buf, 0, -1, false))

        -- новый запуск снимает просмотр истории
        run_and_wait(2)
        assert.is_nil(session.browse[cid(buf, 2)])
    end)

    it("ошибки сохраняются и находятся в истории", function()
        local _, b = notebook({ "# %%", "1 / 0" })
        buf, session = b, nil

        run_and_wait(2)
        session.store:load()

        local record = session.store:last_record(cid(buf, 2))
        assert.equals("error", record.status)
        assert.equals("ZeroDivisionError", record.ename)

        local from_disk = session.store:last_run(cid(buf, 2))
        assert.equals("ZeroDivisionError", from_disk.error.code)
        assert.is_true(#from_disk.lines > 0, "трейсбек должен быть на диске")
    end)
end)

describe("статус под ячейками", function()
    local buf, session
    local status_ui = require("jupyter.ui.status")

    before_each(function()
        jupyter.setup({})
    end)

    after_each(function()
        if buf then
            jupyter.detach(buf)
            buf = nil
            session = nil
        end
        vim.cmd("silent! %bwipeout!")
    end)

    it("появляется у выполненной ячейки и не у остальных", function()
        local _, b = notebook({ "# %%", 'print("раз")', "# %%", 'print("два")' })
        buf, session = b, nil
        vim.api.nvim_win_set_cursor(0, { 2, 0 })

        jupyter.run_cell()
        session = jupyter.session(buf)
        wait(function()
            local r = session.exec:run_for(cid(buf, 2))
            return r and r.status == "ok"
        end, 60000, "прогон")

        assert.equals(1, status_ui.count(buf), "статус только у выполненной ячейки")

        vim.api.nvim_win_set_cursor(0, { 4, 0 })
        jupyter.run_cell()
        wait(function()
            local r = session.exec:run_for(cid(buf, 4))
            return r and r.status == "ok"
        end, 60000, "второй прогон")

        assert.equals(2, status_ui.count(buf))
    end)

    it("правка ячейки сразу помечает её статус, без сохранения", function()
        local _, b = notebook({ "# %%", 'print("исходный")' })
        buf, session = b, nil
        vim.api.nvim_win_set_cursor(0, { 2, 0 })

        jupyter.run_cell()
        session = jupyter.session(buf)
        wait(function()
            local r = session.exec:run_for(cid(buf, 2))
            return r and r.status == "ok"
        end, 60000, "прогон")

        local function status_text()
            local marks = vim.api.nvim_buf_get_extmarks(buf, status_ui.NS, 0, -1, { details = true })
            local chunks = marks[1] and (marks[1][4].virt_lines and marks[1][4].virt_lines[1] or marks[1][4].virt_text)
            return chunks and chunks[1][1] or ""
        end

        assert.is_nil(status_text():find("⚠"), "свежий вывод предупреждения не несёт")

        -- правим и НЕ сохраняем: автокоманда TextChanged должна перерисовать статус
        vim.api.nvim_buf_set_lines(buf, 1, 2, false, { 'print("другой код")' })
        vim.api.nvim_exec_autocmds("TextChanged", { buffer = buf })

        assert.is_truthy(status_text():find("⚠"), "после правки ожидается ⚠, статус: " .. status_text())
        assert.is_true(vim.bo[buf].modified, "файл при этом не сохранён")
        assert.is_true(session.output:is_stale())
    end)

    it("история рисует статус сразу при открытии, без ядра", function()
        local path, b = notebook({ "# %%", 'print("вчерашний")' })
        buf, session = b, nil
        vim.api.nvim_win_set_cursor(0, { 2, 0 })
        jupyter.run_cell()
        session = jupyter.session(buf)
        wait(function()
            local r = session.exec:run_for(cid(buf, 2))
            return r and r.status == "ok"
        end, 60000, "прогон")
        vim.cmd("silent write")

        jupyter.detach(buf)
        buf = nil
        vim.cmd("silent! %bwipeout!")

        vim.cmd.edit(path)
        vim.bo.filetype = "python"
        buf = vim.api.nvim_get_current_buf()
        session = jupyter.session(buf)

        local drawn = jupyter.repaint(buf)

        assert.equals(1, drawn)
        assert.equals("none", session.kernel:state(), "ядро подниматься не должно")
        local marks = vim.api.nvim_buf_get_extmarks(buf, status_ui.NS, 0, -1, { details = true })
        local text = marks[1][4].virt_lines[1][1][1]
        assert.is_truthy(text:find("⟲"), "статус из истории помечается знаком: " .. text)
    end)
end)

describe("таблица в окне вывода", function()
    local buf, session

    before_each(function()
        jupyter.setup({})
    end)

    after_each(function()
        if buf then
            jupyter.detach(buf)
            buf = nil
            session = nil
        end
        vim.cmd("silent! %bwipeout!")
    end)

    it("repr от polars заменяется нашей таблицей", function()
        -- polars печатает свой repr с рамками ┌───┬───┐: в узком окне он разъезжается
        -- на несколько строк на ячейку. Раз parquet есть, рисуем сами
        local _, b = notebook({
            "# %%",
            "import polars as pl",
            "pl.DataFrame({'n': range(50), 'имя': [f'стр-{i}' for i in range(50)]})",
        })
        buf, session = b, nil
        vim.api.nvim_win_set_cursor(0, { 2, 0 })

        jupyter.run_cell()
        session = jupyter.session(buf)
        wait(function()
            local r = session.exec:run_for(cid(buf, 2))
            return r and r.status == "ok" and r._preview ~= nil
        end, 60000, "предпросмотр таблицы")

        local text = table.concat(vim.api.nvim_buf_get_lines(session.output.buf, 0, -1, false), "\n")

        assert.is_falsy(text:find("┌", 1, true), "рамок polars быть не должно: " .. text:sub(1, 200))
        assert.is_falsy(text:find("│", 1, true), "и вертикальных линеек тоже")
        assert.is_truthy(text:find("%[таблица%] 50 строк"), "сводка на месте")
        assert.is_truthy(text:find("стр%-0"), "первая строка данных видна")
        assert.is_truthy(text:find("─"), "линейка под заголовком — наша")
        assert.is_falsy(text:find("стр%-49"), "хвост датафрейма в окно не грузится")
    end)

    it("ячейка без своего repr получает предпросмотр из parquet", function()
        -- это форма %%sql: результат кладётся в переменную, текстового вывода нет
        local _, b = notebook({
            "# %%",
            "import polars as pl",
            "df = pl.DataFrame({'n': range(50), 'имя': [f'стр-{i}' for i in range(50)]})",
            "print('готово')",
        })
        buf, session = b, nil
        vim.api.nvim_win_set_cursor(0, { 2, 0 })

        session = jupyter.ensure_started(buf)
        wait(function() return session.kernel:is_usable() end, 60000, "готовность ядра")
        local cell = require("jupyter.cells").at(buf, 2)
        session.exec:run(buf, cell, { result_expr = "df" })
        wait(function()
            local r = session.exec:run_for(cid(buf, 2))
            return r and r.status == "ok" and r._preview ~= nil
        end, 60000, "предпросмотр таблицы")

        local text = table.concat(vim.api.nvim_buf_get_lines(session.output.buf, 0, -1, false), "\n")

        assert.is_truthy(text:find("%[таблица%] 50 строк"), "сводка остаётся")
        assert.is_truthy(text:find("имя", 1, true), "заголовок колонки виден")
        assert.is_truthy(text:find("стр%-0"), "первая строка данных видна")
        assert.is_truthy(text:find("… ещё %d+ строк"), "подсказка про остаток: " .. text:sub(-80))
        assert.is_falsy(text:find("стр%-49"), "весь датафрейм в окно не грузится")
    end)

    it("таблица из истории тоже показывается в окне", function()
        local _, b = notebook({ "# %%", "import polars as pl", "pl.DataFrame({'a': [1, 2, 3]})" })
        buf, session = b, nil
        vim.api.nvim_win_set_cursor(0, { 2, 0 })

        jupyter.run_cell()
        session = jupyter.session(buf)
        wait(function()
            local r = session.exec:run_for(cid(buf, 2))
            return r and r.status == "ok"
        end, 60000, "прогон")
        session.store:load()

        local from_disk = session.store:last_run(cid(buf, 2))
        session.output:show(from_disk)
        wait(function() return from_disk._preview ~= nil end, 30000, "предпросмотр из истории")

        local text = table.concat(vim.api.nvim_buf_get_lines(session.output.buf, 0, -1, false), "\n")
        assert.is_truthy(text:find(" a"), "заголовок колонки: " .. text)
    end)
end)

describe("таблица из окна вывода", function()
    local buf, session

    before_each(function()
        jupyter.setup({})
    end)

    after_each(function()
        if buf then
            jupyter.detach(buf)
            buf = nil
            session = nil
        end
        vim.cmd("silent! %bwipeout!")
    end)

    it("открывается, когда курсор стоит в drawer'е", function()
        local _, b = notebook({ "# %%", "import polars as pl", "pl.DataFrame({'n': range(80)})" })
        buf, session = b, nil
        vim.api.nvim_win_set_cursor(0, { 2, 0 })

        jupyter.run_cell()
        session = jupyter.session(buf)
        wait(function()
            local r = session.exec:run_for(cid(buf, 2))
            return r and r.status == "ok" and r.table ~= nil
        end, 60000, "таблицу")

        -- уходим курсором в окно вывода
        vim.api.nvim_set_current_win(session.output.win)
        assert.are_not.equals(buf, vim.api.nvim_get_current_buf())

        assert.equals(session, jupyter.session(), "сессия ищется по буферу нашего окна")
        jupyter.open_table()
        wait(function() return session.table.total == 80 end, 30000, "страницу таблицы")

        assert.is_true(session.table:is_open())
        assert.is_truthy(vim.wo[session.table.win].winbar:find("прогон", 1, true))
        session.table:get_actions().close()
    end)

    it("действие drawer'а открывает ту же таблицу", function()
        local _, b = notebook({ "# %%", "import polars as pl", "pl.DataFrame({'n': range(5)})" })
        buf, session = b, nil
        vim.api.nvim_win_set_cursor(0, { 2, 0 })

        jupyter.run_cell()
        session = jupyter.session(buf)
        wait(function()
            local r = session.exec:run_for(cid(buf, 2))
            return r and r.table ~= nil
        end, 60000, "таблицу")

        session.output:get_actions().open_table()
        wait(function() return session.table.total == 5 end, 30000, "страницу таблицы")

        assert.is_true(session.table:is_open())
        session.table:get_actions().close()
    end)

    it("клавиша t есть в drawer'е", function()
        local _, b = notebook({ "# %%", "x = 1" })
        buf, session = b, nil
        session = jupyter.session(buf)
        session.output:open()

        local lhs = {}
        for _, map in ipairs(vim.api.nvim_buf_get_keymap(session.output.buf, "n")) do
            lhs[map.lhs] = map.desc
        end

        assert.equals("jupyter: open_table", lhs["t"])
    end)
end)

describe("аварийная чистка картинок", function()
    it("снимает картинки сессии и сообщает, если сессии нет", function()
        jupyter.setup({})
        local buf = vim.api.nvim_create_buf(false, true)
        vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "# %%", "x = 1" })
        vim.bo[buf].filetype = "python"

        local session = jupyter.session(buf)
        local cleared = false
        session.output.images.clear = function(_, _) cleared = true end

        assert.is_true(jupyter.clear_images(buf))
        assert.is_true(cleared)

        jupyter.detach(buf)
        assert.is_false(jupyter.clear_images(buf), "без сессии — честное false, а не тишина")
    end)
end)

describe("картинки и фокус окна", function()
    local buf, session

    before_each(function()
        jupyter.setup({})
    end)

    after_each(function()
        if buf then
            jupyter.detach(buf)
            buf = nil
            session = nil
        end
        vim.cmd("silent! %bwipeout!")
    end)

    it("потеря фокуса снимает картинку, возврат рисует заново", function()
        local buffer = vim.api.nvim_create_buf(false, true)
        vim.api.nvim_buf_set_lines(buffer, 0, -1, false, { "# %%", "x = 1" })
        vim.bo[buffer].filetype = "python"
        buf = buffer
        session = jupyter.session(buf)

        local cleared, rendered = 0, 0
        session.output.images.clear = function() cleared = cleared + 1 end
        session.output:open()
        session.output.run = { cell_id = "a3f9", run_id = 1, status = "ok", lines = { "x" }, image = "/tmp/x.png" }
        session.output.render = function() rendered = rendered + 1 end

        jupyter.on_focus(false)
        assert.equals(1, cleared, "без фокуса картинок быть не должно")

        jupyter.on_focus(true)
        vim.wait(200, function() return rendered > 0 end, 10)
        assert.equals(1, rendered, "вернули фокус — рисуем заново")
    end)

    it("у прогона без картинки возврат фокуса ничего не рисует", function()
        local buffer = vim.api.nvim_create_buf(false, true)
        vim.api.nvim_buf_set_lines(buffer, 0, -1, false, { "# %%", "x = 1" })
        vim.bo[buffer].filetype = "python"
        buf = buffer
        session = jupyter.session(buf)

        local rendered = 0
        session.output:open()
        session.output.run = { cell_id = "a3f9", run_id = 1, status = "ok", lines = { "текст" } }
        session.output.render = function() rendered = rendered + 1 end

        jupyter.on_focus(true)
        vim.wait(100)

        assert.equals(0, rendered)
    end)
end)

describe("окно вывода при открытии", function()
    after_each(function()
        jupyter.setup({})
        vim.cmd("silent! %bwipeout!")
    end)

    it("без истории окно не открывает, но статусы рисует", function()
        -- пустое окно на пол-экрана хуже, чем никакого: при первом запуске оно откроется само
        jupyter.setup({ output = { open_on_attach = true } })
        local path = vim.fn.tempname() .. ".py"
        vim.fn.writefile({ "# %%", "x = 1" }, path)
        vim.cmd.edit(path)
        vim.bo.filetype = "python"
        local buf = vim.api.nvim_get_current_buf()

        assert.is_false(jupyter.open_for(buf))

        local session = jupyter.session(buf)
        assert.is_false(session.output:is_open())
        assert.equals("none", session.kernel:state(), "ядро при этом не поднимается")
        jupyter.detach(buf)
    end)

    it("с историей открывает и сразу показывает прогон", function()
        jupyter.setup({ output = { open_on_attach = true } })
        local path = vim.fn.tempname() .. ".py"
        vim.fn.writefile({ "# %%", 'print("вчерашнее")' }, path)
        vim.cmd.edit(path)
        vim.bo.filetype = "python"
        local buf = vim.api.nvim_get_current_buf()

        -- кладём историю на диск руками: ядро для этого не нужно
        local session = jupyter.session(buf)
        local id = cid(buf, 2)
        local base = session.store.base
        vim.fn.mkdir(base .. "/" .. id, "p")
        vim.fn.writefile({ "вчерашнее" }, base .. "/" .. id .. "/1.txt")
        vim.fn.writefile({
            vim.json.encode({
                cell_id = id, run_id = 1, status = "ok", kind = "text",
                path = id .. "/1.txt", started_at = "2026-09-04T09:00:00+00:00",
                duration_ms = 7, code_sha = "abc12345",
            }),
        }, base .. "/index.jsonl")
        session.store:load()

        assert.is_true(jupyter.open_for(buf))

        assert.is_true(session.output:is_open())
        assert.same({ "вчерашнее" }, vim.api.nvim_buf_get_lines(session.output.buf, 0, -1, false))
        assert.equals("none", session.kernel:state())
        jupyter.detach(buf)
    end)

    it("обычный python-скрипт без ячеек не трогает", function()
        jupyter.setup({ output = { open_on_attach = true } })
        local buf = vim.api.nvim_create_buf(false, true)
        -- файл без маркеров считается одной ячейкой, поэтому берём пустой
        vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "" })
        vim.bo[buf].filetype = "python"

        assert.is_false(jupyter.open_for(buf))
    end)
end)

describe("сортировка таблицы", function()
    local buf, session

    before_each(function()
        jupyter.setup({ table = { page_size = 50 } })
    end)

    after_each(function()
        if buf then
            jupyter.detach(buf)
            buf = nil
            session = nil
        end
        vim.cmd("silent! %bwipeout!")
    end)

    it("каждая следующая сортировка учитывает предыдущую", function()
        local _, b = notebook({
            "# %%",
            "import polars as pl",
            "pl.DataFrame({'площадка': ['web','ios','web','ios'], 'день': [2,1,1,2]})",
        })
        buf, session = b, nil
        vim.api.nvim_win_set_cursor(0, { 2, 0 })

        jupyter.run_cell()
        session = jupyter.session(buf)
        wait(function()
            local r = session.exec:run_for(cid(buf, 2))
            return r and r.status == "ok" and r.table ~= nil
        end, 60000, "таблицу")

        jupyter.open_table()
        wait(function() return session.table.total == 4 end, 30000, "страницу")

        local function column(index)
            local out = {}
            for i = 3, #vim.api.nvim_buf_get_lines(session.table.buf, 0, -1, false) do
                local line = vim.api.nvim_buf_get_lines(session.table.buf, i - 1, i, false)[1]
                local entry = session.table.layout[index]
                table.insert(out, vim.trim(vim.fn.strcharpart(line, entry.from - 1, entry.to - entry.from + 1)))
            end
            return out
        end

        -- ждём точного порядка, а не первой строки: иначе ожидание проходит мгновенно
        -- на данных, которые совпали случайно
        local function ordered(index, want)
            return function()
                return table.concat(column(index), ",") == want
            end
        end

        -- сначала по площадке
        session.table:sort_by("площадка", false)
        wait(ordered(1, "ios,ios,web,web"), 30000, "порядок по площадке")

        -- теперь по дню: он главный, площадка осталась тай-брейкером
        session.table:sort_by("день", false)
        wait(ordered(2, "1,1,2,2"), 30000, "порядок по дню")

        assert.same({ "1", "1", "2", "2" }, column(2))
        assert.same({ "ios", "web", "ios", "web" }, column(1), "внутри дня сохранился прежний порядок")
        assert.is_truthy(session.table:status():find("сортировка: день ↑ · площадка ↑", 1, true))

        session.table:get_actions().sort_clear()
        wait(function() return #session.table.order == 0 end, 30000, "сброс")
        session.table:get_actions().close()
    end)
end)

describe("повторное открытие ноутбука", function()
    it("окно вывода поднимается один раз на сессию", function()
        -- FileType срабатывает на каждое перечитывание буфера: прыжок из telescope,
        -- :e, смена filetype. Окно не должно возвращаться после того, как его закрыли
        jupyter.setup({ output = { open_on_attach = true } })
        local path = vim.fn.tempname() .. ".py"
        vim.fn.writefile({ "# %%", 'print("вчерашнее")' }, path)
        vim.cmd.edit(path)
        vim.bo.filetype = "python"
        local buf = vim.api.nvim_get_current_buf()

        local session = jupyter.session(buf)
        local id = cid(buf, 2)
        local base = session.store.base
        vim.fn.mkdir(base .. "/" .. id, "p")
        vim.fn.writefile({ "вчерашнее" }, base .. "/" .. id .. "/1.txt")
        vim.fn.writefile({
            vim.json.encode({
                cell_id = id, run_id = 1, status = "ok", kind = "text",
                path = id .. "/1.txt", started_at = "2026-09-04T09:00:00+00:00",
                duration_ms = 7, code_sha = "abc12345",
            }),
        }, base .. "/index.jsonl")
        session.store:load()

        assert.is_true(jupyter.open_for(buf), "первый раз открываем")
        session.output:close()

        assert.is_false(jupyter.open_for(buf), "второй раз — нет")
        assert.is_false(session.output:is_open(), "закрытое руками окно не должно возвращаться")

        jupyter.detach(buf)
        jupyter.setup({})
    end)
end)
