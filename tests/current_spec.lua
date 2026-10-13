-- Фон ячейки под курсором (lua/jupyter/ui/current.lua).

local current = require("jupyter.ui.current")

local LINES = {
    "# заголовок", -- 1
    "", -- 2
    "```python", -- 3
    "x = 1", -- 4
    "y = 2", -- 5
    "```", -- 6
    "", -- 7
    "проза", -- 8
    "", -- 9
    "```python", -- 10
    "z = 3", -- 11
    "```", -- 12
}

local function marks(buf)
    return vim.tbl_map(function(m)
        return { m[2] + 1, m[4].end_row } -- первая строка тела 1-based, последняя 1-based
    end, vim.api.nvim_buf_get_extmarks(buf, current.NS, 0, -1, { details = true }))
end

describe("current", function()
    local buf

    before_each(function()
        buf = vim.api.nvim_create_buf(true, false)
        vim.api.nvim_buf_set_lines(buf, 0, -1, false, LINES)
        vim.bo[buf].filetype = "markdown"
        vim.api.nvim_set_current_buf(buf)
    end)

    after_each(function()
        vim.api.nvim_buf_delete(buf, { force = true })
    end)

    it("подсвечивает тело ячейки под курсором, без фенсов", function()
        vim.api.nvim_win_set_cursor(0, { 4, 0 })
        current.update(buf)
        assert.same({ { 4, 5 } }, marks(buf))
    end)

    it("курсор на фенсе — тоже эта ячейка", function()
        vim.api.nvim_win_set_cursor(0, { 6, 0 })
        current.update(buf)
        assert.same({ { 4, 5 } }, marks(buf))
    end)

    it("переходит за курсором и снимается в прозе", function()
        vim.api.nvim_win_set_cursor(0, { 4, 0 })
        current.update(buf)
        vim.api.nvim_win_set_cursor(0, { 11, 0 })
        current.update(buf)
        assert.same({ { 11, 11 } }, marks(buf))

        vim.api.nvim_win_set_cursor(0, { 8, 0 })
        current.update(buf)
        assert.same({}, marks(buf))
    end)

    it("пересчитывает границы после правки в той же ячейке", function()
        vim.api.nvim_win_set_cursor(0, { 4, 0 })
        current.update(buf)
        vim.api.nvim_buf_set_lines(buf, 4, 4, false, { "w = 0" })
        current.update(buf)
        assert.same({ { 4, 6 } }, marks(buf))
    end)

    it("ставит фон выше фона render-markdown", function()
        vim.api.nvim_win_set_cursor(0, { 4, 0 })
        current.update(buf)
        local m = vim.api.nvim_buf_get_extmarks(buf, current.NS, 0, -1, { details = true })[1][4]
        assert.equals(current.GROUP, m.hl_group)
        assert.is_true(m.hl_eol)
        assert.is_true(m.priority > 140)
    end)
end)
