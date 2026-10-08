-- Закреплённый вывод: второе окно над основным, держит одну ячейку, пока курсор ходит
-- по остальным. Ядро не нужно — прогоны подкладываем туда же, куда их кладёт exec.

local jupyter = require("jupyter")
local cells = require("jupyter.cells")
local exec = require("jupyter.exec")

local function notebook(lines)
    local path = vim.fn.tempname() .. ".py"
    vim.fn.writefile(lines, path)
    vim.cmd.edit(path)
    vim.bo.filetype = "python"
    return vim.api.nvim_get_current_buf()
end

local function cid(buf, row)
    return exec.cell_id(buf, cells.at(buf, row))
end

---Прогон ячейки на строке row, как будто его только что прислало ядро.
local function fake_run(s, row, text, run_id)
    local cell_id = cid(s.buf, row)
    local run = { cell_id = cell_id, run_id = run_id or 1, status = "ok", lines = { text } }
    s.exec.runs[cell_id] = run
    s.exec.on_update(run, true)
    return run
end

local function lines_of(out)
    return vim.api.nvim_buf_get_lines(out.buf, 0, -1, false)
end

describe("закреплённый вывод", function()
    local buf, s, nb_win

    before_each(function()
        jupyter.setup({ output = { position = "right", size = 40 } })
        buf = notebook({ "# %% jncell=\"aa01\"", "a = 1", "# %% jncell=\"bb02\"", "b = 2", "# %% jncell=\"cc03\"", "c = 3" })
        nb_win = vim.api.nvim_get_current_win()
        s = jupyter.session(buf)
    end)

    after_each(function()
        jupyter.detach(buf)
        vim.cmd("silent! only!")
        vim.cmd("silent! %bwipeout!")
    end)

    it("встаёт над основным окном в той же колонке и не следует за курсором", function()
        vim.api.nvim_win_set_cursor(0, { 2, 0 })
        fake_run(s, 2, "первая")
        vim.api.nvim_win_set_cursor(0, { 4, 0 })
        fake_run(s, 4, "вторая")

        vim.api.nvim_win_set_cursor(0, { 2, 0 })
        jupyter.pin_output()
        assert.is_true(s.pinned:is_open())
        assert.equals(nb_win, vim.api.nvim_get_current_win(), "фокус остаётся в ноутбуке")

        local p = vim.api.nvim_win_get_position(s.pinned.win)
        local o = vim.api.nvim_win_get_position(s.output.win)
        assert.equals(p[2], o[2], "одна колонка")
        assert.is_true(p[1] < o[1], "закреплённое сверху")

        vim.api.nvim_win_set_cursor(0, { 4, 0 })
        jupyter.follow_cursor(buf)
        assert.same({ "первая" }, lines_of(s.pinned))
        assert.same({ "вторая" }, lines_of(s.output))
    end)

    it("обновляется только перезапуском своей ячейки", function()
        vim.api.nvim_win_set_cursor(0, { 2, 0 })
        fake_run(s, 2, "старое")
        jupyter.pin_output()

        fake_run(s, 4, "чужое")
        assert.same({ "старое" }, lines_of(s.pinned))

        fake_run(s, 2, "новое", 2)
        assert.same({ "новое" }, lines_of(s.pinned))
    end)

    it("закрепить можно одну ячейку, повтор снимает", function()
        vim.api.nvim_win_set_cursor(0, { 2, 0 })
        fake_run(s, 2, "a")
        vim.api.nvim_win_set_cursor(0, { 4, 0 })
        fake_run(s, 4, "b")

        vim.api.nvim_win_set_cursor(0, { 2, 0 })
        jupyter.pin_output()
        vim.api.nvim_win_set_cursor(0, { 4, 0 })
        jupyter.pin_output()
        assert.equals(cid(buf, 4), s.pin_cell)
        assert.same({ "b" }, lines_of(s.pinned))

        jupyter.pin_output()
        assert.is_nil(s.pin_cell)
        assert.is_false(s.pinned:is_open())
        assert.is_true(s.output:is_open(), "основное остаётся")
    end)

    it("без вывода закреплять нечего", function()
        vim.api.nvim_win_set_cursor(0, { 6, 0 })
        jupyter.pin_output()
        assert.is_nil(s.pin_cell)
        assert.is_false(s.pinned:is_open())
    end)

    it("основное окно, открытое позже, встаёт под закреплённым", function()
        vim.api.nvim_win_set_cursor(0, { 2, 0 })
        fake_run(s, 2, "a")
        s.output:close()

        jupyter.pin_output()
        s.output:open()
        local p = vim.api.nvim_win_get_position(s.pinned.win)
        local o = vim.api.nvim_win_get_position(s.output.win)
        assert.equals(p[2], o[2])
        assert.is_true(p[1] < o[1])
    end)
end)
