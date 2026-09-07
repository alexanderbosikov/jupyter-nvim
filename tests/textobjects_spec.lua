-- Текстовые объекты ячейки. Проверяется результат оператора, а не выделение: важно,
-- что `dic` удалил ровно тело, а `dac` — ячейку целиком, в обоих представлениях.

local jupyter = require("jupyter")

---Буфер с установленными мапами и курсором на строке row.
---@param lines string[]
---@param filetype string
---@param row integer
---@return integer buf
local function buffer(lines, filetype, row)
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.bo[buf].filetype = filetype
    vim.api.nvim_win_set_buf(0, buf)
    jupyter.set_keys(buf)
    vim.api.nvim_win_set_cursor(0, { row, 0 })
    return buf
end

local function text(buf)
    return vim.api.nvim_buf_get_lines(buf, 0, -1, false)
end

describe("объект ячейки в percent", function()
    local LINES = {
        "import polars as pl", -- 1
        "", -- 2
        "# %%", -- 3
        'print("вторая")', -- 4
        "y = 2", -- 5
        "", -- 6
        "# %%", -- 7
        'print("третья")', -- 8
    }

    it("ic удаляет тело, оставляя маркер", function()
        local buf = buffer(LINES, "python", 4)

        vim.cmd("normal dic")

        assert.same({ "import polars as pl", "", "# %%", "# %%", 'print("третья")' }, text(buf))
    end)

    it("ac удаляет ячейку вместе с маркером", function()
        local buf = buffer(LINES, "python", 4)

        vim.cmd("normal dac")

        assert.same({ "import polars as pl", "", "# %%", 'print("третья")' }, text(buf))
    end)

    it("курсор на самом маркере — та же ячейка", function()
        local buf = buffer(LINES, "python", 3)

        vim.cmd("normal dac")

        assert.same({ "import polars as pl", "", "# %%", 'print("третья")' }, text(buf))
    end)
end)

describe("объект ячейки в фенсах", function()
    local LINES = {
        "# Отчёт", -- 1
        "", -- 2
        "```python", -- 3
        "import polars as pl", -- 4
        "x = 1", -- 5
        "```", -- 6
        "", -- 7
        "Проза между ячейками.", -- 8
    }

    it("ic оставляет фенсы на месте", function()
        local buf = buffer(LINES, "markdown", 5)

        vim.cmd("normal dic")

        assert.same({ "# Отчёт", "", "```python", "```", "", "Проза между ячейками." }, text(buf))
    end)

    it("ac забирает фенсы вместе с телом", function()
        local buf = buffer(LINES, "markdown", 5)

        vim.cmd("normal dac")

        assert.same({ "# Отчёт", "", "", "Проза между ячейками." }, text(buf))
    end)

    it("в прозе объект ничего не трогает", function()
        local buf = buffer(LINES, "markdown", 8)

        vim.cmd("normal dac")

        assert.same(LINES, text(buf), "проза — не ячейка, удалять нечего")
    end)

    it("visual тоже выделяет: yac кладёт ячейку целиком в регистр", function()
        local buf = buffer(LINES, "markdown", 4)

        vim.cmd("normal yac")

        assert.same(LINES, text(buf), "yank ничего не меняет")
        assert.equals("```python\nimport polars as pl\nx = 1\n```\n", vim.fn.getreg('"'))
    end)
end)
