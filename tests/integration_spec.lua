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
