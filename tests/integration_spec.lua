-- Сквозная проверка шага 3: настоящий файл в буфере, настоящее ядро, вывод в drawer.
-- Это тот самый момент «%%sql даёт текст в буфере», только без человека.

local jupyter = require("jupyter")

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
            local run = session.exec:run_for("0001")
            return run and run.status == "ok"
        end, 60000, "успешное завершение ячейки")

        assert.is_true(session.output:is_open())
        local shown = vim.api.nvim_buf_get_lines(session.output.buf, 0, -1, false)
        assert.same({ "привет из буфера" }, shown)
        assert.is_truthy(session.output:status():find("✓"))
        assert.is_truthy(vim.wo[session.output.win].winbar:find("ячейка 0001", 1, true))
    end)

    it("вторая ячейка не смешивается с первой", function()
        local _, b = notebook({ "# %%", 'print("первая")', "# %%", 'print("вторая")' })
        buf = b

        vim.api.nvim_win_set_cursor(0, { 2, 0 })
        jupyter.run_cell()
        local session = jupyter.session(buf)
        wait(function()
            local run = session.exec:run_for("0001")
            return run and run.status == "ok"
        end, 60000, "первая ячейка")

        vim.api.nvim_win_set_cursor(0, { 4, 0 })
        jupyter.run_cell()
        wait(function()
            local run = session.exec:run_for("0002")
            return run and run.status == "ok"
        end, 30000, "вторая ячейка")

        assert.same({ "первая" }, session.exec:run_for("0001").lines)
        assert.same({ "вторая" }, session.exec:run_for("0002").lines)
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
            local run = session.exec:run_for("0001")
            return run and run.table ~= nil and run.status == "ok"
        end, 60000, "результат-таблицу и завершение прогона")

        local run = session.exec:run_for("0001")
        assert.equals(3, run.table.rows)
        assert.equals(2, run.table.cols)
        assert.equals(1, vim.fn.filereadable(run.table.path))

        -- имя буфера, а не tempname(): на macOS nvim разрешает /var -> /private/var,
        -- и сайдкар получает уже разрешённый путь
        local opened = vim.api.nvim_buf_get_name(buf)
        local expected = vim.fn.fnamemodify(opened, ":h")
            .. "/.jupyter-out/"
            .. vim.fn.fnamemodify(opened, ":t:r")
            .. "/0001/1.parquet"
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
            local run = session.exec:run_for("0001")
            return run and run.status == "error"
        end, 60000, "ошибку")

        assert.equals("ZeroDivisionError", session.exec:run_for("0001").error.code)
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
            local run = session.exec:run_for("0002")
            return run and run.status == "ok"
        end, 30000, "ячейку после ошибки")

        assert.same({ "после ошибки" }, session.exec:run_for("0002").lines)
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
            local run = session.exec:run_for("0001")
            return run and run.status == "ok"
        end, 60000, "выполнение из очереди")

        assert.same({ "без ожидания" }, session.exec:run_for("0001").lines)
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
            local run = session.exec:run_for("0001")
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

    it("detach дожидается выхода сайдкара, не оставляя процесс", function()
        local _, b = notebook({ "# %%", "x = 1" })
        jupyter.ensure_started()
        local session = jupyter.session(b)
        wait(function() return session.kernel:state() == "ready" end, 60000, "ready")

        jupyter.detach(b)

        assert.is_false(session.kernel.sidecar:is_running(), "сайдкар должен был выйти")
    end)

    it("мёртвое ядро не задерживает гашение", function()
        local _, b = notebook({ "# %%", "import os, signal", "os.kill(os.getpid(), signal.SIGKILL)" })
        vim.api.nvim_win_set_cursor(0, { 2, 0 })
        jupyter.run_cell()
        local session = jupyter.session(b)
        wait(function() return session.kernel:state() == "dead" end, 60000, "смерть ядра")

        local started = vim.uv.now()
        jupyter.detach(b)
        local spent = vim.uv.now() - started

        assert.is_false(session.kernel.sidecar:is_running())
        assert.is_true(spent < 3000, ("гашение заняло %d мс"):format(spent))
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
            local run = session.exec:run_for("0001")
            return run and run.status == "ok"
        end, 60000, "первый прогон")
        assert.is_true(session.output:is_open())

        session.output:close()
        assert.is_false(session.output:is_open())

        -- та же ячейка: раньше update() молча писал в буфер и окно не появлялось
        jupyter.run_cell()
        assert.is_true(session.output:is_open(), "окно должно подняться на новый прогон")

        wait(function()
            local run = session.exec:run_for("0001")
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

    local function run_cell_at(row, cell_id)
        vim.api.nvim_win_set_cursor(0, { row, 0 })
        jupyter.run_cell()
        session = session or jupyter.session(buf)
        wait(function()
            local r = session.exec:run_for(cell_id)
            return r and r.status == "ok"
        end, 60000, "прогон " .. cell_id)
    end

    it("переключается на вывод ячейки под курсором", function()
        local _, b = notebook({ "# %%", 'print("первая")', "# %%", 'print("вторая")' })
        buf, session = b, nil

        run_cell_at(2, "0001")
        run_cell_at(4, "0002")
        assert.same({ "вторая" }, vim.api.nvim_buf_get_lines(session.output.buf, 0, -1, false))

        vim.api.nvim_win_set_cursor(0, { 2, 0 })
        jupyter.follow_cursor(buf)

        assert.equals("0001", session.output.run.cell_id)
        assert.same({ "первая" }, vim.api.nvim_buf_get_lines(session.output.buf, 0, -1, false))
    end)

    it("во время долгого запроса можно смотреть вывод другой ячейки", function()
        local _, b = notebook({ "# %%", 'print("готово")', "# %%", "import time", "time.sleep(3)" })
        buf, session = b, nil

        run_cell_at(2, "0001")

        vim.api.nvim_win_set_cursor(0, { 4, 0 })
        jupyter.run_cell()
        assert.equals("0002", session.output.run.cell_id)

        -- уходим читать первую ячейку, вторая ещё выполняется
        vim.api.nvim_win_set_cursor(0, { 2, 0 })
        jupyter.follow_cursor(buf)

        assert.equals("0001", session.output.run.cell_id, "окно должно переключиться")
        assert.same({ "готово" }, vim.api.nvim_buf_get_lines(session.output.buf, 0, -1, false))
        assert.is_truthy(
            vim.wo[session.output.win].winbar:find("ещё 1", 1, true),
            "в winbar должен быть счётчик идущих прогонов: " .. vim.wo[session.output.win].winbar
        )

        wait(function()
            local r = session.exec:run_for("0002")
            return r and r.status == "ok"
        end, 60000, "вторая ячейка")

        assert.equals("0001", session.output.run.cell_id, "завершение чужого прогона окно не забирает")
        assert.is_nil(vim.wo[session.output.win].winbar:find("ещё", 1, true), "счётчик должен исчезнуть")
    end)

    it("ячейка без прогона окно не трогает", function()
        local _, b = notebook({ "# %%", 'print("есть вывод")', "# %%", "x = 1" })
        buf, session = b, nil

        run_cell_at(2, "0001")

        vim.api.nvim_win_set_cursor(0, { 4, 0 })
        jupyter.follow_cursor(buf)

        assert.equals("0001", session.output.run.cell_id)
    end)

    it("при закрытом окне ничего не делает", function()
        local _, b = notebook({ "# %%", 'print("вывод")' })
        buf, session = b, nil

        run_cell_at(2, "0001")
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
