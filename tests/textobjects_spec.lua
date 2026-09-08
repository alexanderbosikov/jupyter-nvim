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

    it("yac кладёт ячейку целиком в регистр", function()
        local buf = buffer(LINES, "markdown", 4)

        vim.cmd("normal yac")

        assert.same(LINES, text(buf), "yank ничего не меняет")
        assert.equals("```python\nimport polars as pl\nx = 1\n```\n", vim.fn.getreg('"'))
    end)
end)

-- Живой сбой: в visual выделялась половина ячейки. Нажатое `v` уже ставит якорь, и одно
-- движение курсора его не двигает — выделение шло от якоря до конца ячейки. В
-- operator-pending якоря нет, поэтому dic и yac работали, и тесты на них этого не ловили:
-- проверять надо было именно тот режим, в котором ошибка возможна.
describe("выделение из visual", function()
    local CELL = { "# %%", "первая", "вторая", "третья", "четвёртая", "", "# %%", "чужая" }

    ---Границы выделения после команды: метки ставятся при выходе из visual.
    local function selection(row, key)
        buffer(CELL, "python", row)
        vim.cmd("normal " .. key)
        vim.cmd("normal! \27")
        return vim.fn.line("'<"), vim.fn.line("'>")
    end

    it("vic берёт всё тело, откуда бы ни начали", function()
        for _, row in ipairs({ 2, 4, 5 }) do
            local from, to = selection(row, "vic")
            assert.equals(2, from, "начало выделения при курсоре на " .. row)
            assert.equals(6, to, "конец выделения при курсоре на " .. row)
        end
    end)

    it("vac добирает маркер", function()
        local from, to = selection(4, "vac")

        assert.equals(1, from)
        assert.equals(6, to)
    end)

    it("из visual-line и блочного выделения тоже целиком", function()
        for _, key in ipairs({ "Vic", "\22ic" }) do
            local from, to = selection(4, key)
            assert.equals(2, from, "начало для " .. vim.inspect(key))
            assert.equals(6, to, "конец для " .. vim.inspect(key))
        end
    end)
end)
