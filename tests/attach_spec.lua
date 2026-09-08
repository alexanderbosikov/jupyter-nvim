-- Подключение к ядру, пережившему редактор.
--
-- Смысл фичи проверяется единственным способом: убить сайдкар, поднять всё заново и
-- увидеть в новой сессии переменную, объявленную в прошлой. Всё остальное — детали.

local jupyter = require("jupyter")
local cells = require("jupyter.cells")
local exec = require("jupyter.exec")
local orphans = require("jupyter.orphans")

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

---Дождаться успешного прогона ячейки на строке row.
local function run_and_wait(buf, row, session)
    vim.api.nvim_win_set_cursor(0, { row, 0 })
    jupyter.run_cell()
    local id = cid(buf, row)
    wait(function()
        local r = session.exec:run_for(id)
        return r and r.status == "ok"
    end, 60000, "прогон строки " .. row)
    return session.exec:run_for(id)
end

describe("подключение к живому ядру", function()
    local buf, kernel_pid

    before_each(function()
        jupyter.setup({})
    end)

    after_each(function()
        if buf then
            jupyter.detach(buf)
            buf = nil
        end
        if kernel_pid and orphans.alive(kernel_pid) then
            pcall(vim.uv.kill, kernel_pid, "sigkill")
            kernel_pid = nil
        end
        vim.cmd("silent! %bwipeout!")
    end)

    it("память ядра переживает смерть редактора", function()
        local path, b = notebook({ "# %%", "сокровище = 42", "# %%", "print(сокровище)" })
        buf = b
        local session = jupyter.session(buf)
        run_and_wait(buf, 2, session)

        -- редактор «упал»: сайдкар убит, ядро осталось жить сиротой
        local sidecar_pid = session.kernel.sidecar._proc.pid
        vim.uv.kill(sidecar_pid, "sigkill")
        wait(function() return not orphans.alive(sidecar_pid) end, 10000, "смерти сайдкара")
        jupyter.detach(buf)

        -- след указывает на живое ядро без хозяина — к нему и подключаемся
        local found = orphans.check(orphans.record_for(path))
        assert.is_truthy(found, "след должен остаться")
        assert.is_false(found.stale, "ядро обязано быть живым")
        kernel_pid = found.kernel_pid

        local fresh = jupyter.session(buf)
        assert.is_true(jupyter.attach(buf))
        wait(function() return fresh.kernel:is_usable() end, 60000, "готовности подключённого ядра")

        local run = run_and_wait(buf, 4, fresh)

        assert.is_truthy(
            table.concat(run.lines or {}, "\n"):find("42", 1, true),
            "переменная из прошлой сессии должна быть на месте: " .. vim.inspect(run.lines)
        )
    end)

    it("подключаться не к чему — говорим об этом, а не молчим", function()
        local _, b = notebook({ "# %%", "x = 1" })
        buf = b
        jupyter.session(buf)

        local notes = {}
        local notify = vim.notify
        vim.notify = function(msg) table.insert(notes, msg) end
        local started = jupyter.attach(buf)
        vim.notify = notify

        assert.is_false(started)
        assert.equals(1, #notes)
        assert.is_truthy(notes[1]:find("не к чему", 1, true), notes[1])
    end)

    it("своё ядро не подменяем чужим", function()
        local _, b = notebook({ "# %%", "x = 1" })
        buf = b
        local session = jupyter.session(buf)
        run_and_wait(buf, 2, session)

        local notes = {}
        local notify = vim.notify
        vim.notify = function(msg) table.insert(notes, msg) end
        local started = jupyter.attach(buf)
        vim.notify = notify

        assert.is_false(started)
        assert.is_truthy(notes[1]:find("уже своё ядро", 1, true), notes[1])
    end)
end)
