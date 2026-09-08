-- Границы отказов: то, что случается редко и потому никогда не выполнялось.
--
-- Проверяется не «функция вернула правильное», а «плагин пережил»: файл исчез из-под
-- носа, каталог недоступен для записи, сессию погасили посреди потока вывода. Всё это
-- случается на настоящей работе, и каждое из этого раньше не проходило ни разу.

local jupyter = require("jupyter")
local cells = require("jupyter.cells")
local exec = require("jupyter.exec")

---id ячейки под строкой — тот, что реально записан в маркер.
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

---Сколько служебных буферов плагина сейчас в редакторе.
local function scratch_count()
    local n = 0
    for _, b in ipairs(vim.api.nvim_list_bufs()) do
        if vim.api.nvim_buf_is_valid(b) and vim.api.nvim_buf_get_name(b):find("jupyter://", 1, true) then
            n = n + 1
        end
    end
    return n
end

describe("границы отказов", function()
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

    it("исчезнувший parquet — сообщение в окне, а не падение", function()
        local _, b = notebook({ "# %%", "x = 1" })
        buf = b
        local session = jupyter.session(buf)
        jupyter.ensure_started()
        wait(function() return session.kernel:is_usable() end, 60000, "ready")

        session.table:open("/нет/такого/файла.parquet", "выдуманная таблица")
        wait(function()
            local lines = vim.api.nvim_buf_get_lines(session.table.buf or 0, 0, -1, false)
            return (lines[1] or ""):find("не удалось прочитать таблицу") ~= nil
        end, 10000, "сообщение об ошибке")

        assert.is_true(session.kernel:is_usable(), "ядро от этого пострадать не должно")
    end)

    it("каталог выводов недоступен для записи — прогон всё равно доходит", function()
        local dir = vim.fn.tempname()
        vim.fn.mkdir(dir, "p")
        local path = dir .. "/отчёт.py"
        vim.fn.writefile({ "# %%", 'print("вопреки всему")' }, path)
        vim.cmd.edit(path)
        vim.bo.filetype = "python"
        buf = vim.api.nvim_get_current_buf()
        -- запись в каталог ноутбука запрещена: .jupyter-out создать не выйдет
        vim.fn.setfperm(dir, "r-xr-xr-x")

        vim.api.nvim_win_set_cursor(0, { 2, 0 })
        jupyter.run_cell()
        local session = jupyter.session(buf)

        local ok = vim.wait(30000, function()
            local run = session.exec:run_for(cid(buf, 2))
            return run ~= nil and (run.status == "ok" or run.status == "error")
        end, 50)

        vim.fn.setfperm(dir, "rwxr-xr-x") -- вернуть, иначе tmp не почистится
        if not ok then
            local diag = { "состояние ядра: " .. session.kernel:state(), "в очереди: " .. session.kernel:queued() }
            for _, e in ipairs(session.log or {}) do
                table.insert(diag, ("[%s] %s"):format(e.level or "?", (e.msg or ""):sub(1, 200)))
            end
            error(table.concat(diag, "\n"))
        end
        local run = session.exec:run_for(cid(buf, 2))
        assert.equals("ok", run.status)
        assert.is_truthy(table.concat(run.lines or {}, "\n"):find("вопреки всему"), "вывод должен доехать")
    end)

    it("гашение посреди потока не роняет и не плодит буферов", function()
        local _, b = notebook({ "# %%", "for i in range(300):\n    print('строка', i)" })
        buf = b
        vim.api.nvim_win_set_cursor(0, { 2, 0 })
        jupyter.run_cell()
        local session = jupyter.session(buf)
        -- дождаться первых строк, чтобы поток точно шёл
        wait(function()
            local run = session.output.run
            return run and #(run.lines or {}) > 3
        end, 60000, "начало потока")

        local before = scratch_count()
        jupyter.detach(buf)
        buf = nil
        vim.wait(2000, function() return false end, 50) -- прокрутить отложенные колбэки

        assert.is_true(
            scratch_count() <= before,
            ("служебных буферов было %d, стало %d"):format(before, scratch_count())
        )
    end)

    it("буфер ноутбука снесли прямо во время прогона", function()
        local _, b = notebook({ "# %%", "for i in range(300):\n    print('строка', i)" })
        buf = b
        vim.api.nvim_win_set_cursor(0, { 2, 0 })
        jupyter.run_cell()
        local session = jupyter.session(buf)
        wait(function()
            local run = session.output.run
            return run and #(run.lines or {}) > 3
        end, 60000, "начало потока")

        vim.api.nvim_buf_delete(buf, { force = true })
        buf = nil
        vim.wait(2000, function() return false end, 50)

        -- сессия снята автокомандой BufUnload, а не осталась висеть на мёртвом буфере
        assert.is_nil(jupyter.session_for and jupyter.session_for(b) or nil)
    end)
end)
