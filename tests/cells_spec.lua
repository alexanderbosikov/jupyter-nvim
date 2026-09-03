-- Границы ячеек в обоих представлениях. Все ожидания заданы точными номерами строк:
-- краевые случаи (маркер без тела, чужой язык фенса, незакрытый фенс) здесь и живут.

local cells = require("jupyter.cells")

local PERCENT = {
    "import polars as pl", -- 1  ячейка до первого маркера
    "x = 1", -- 2
    "", -- 3
    "# %%", -- 4  маркер второй ячейки
    'print("вторая")', -- 5
    "y = 2", -- 6
    "", -- 7
    "# %% [markdown]", -- 8  пропускается целиком
    "# заголовок", -- 9
    "", -- 10
    "# %%", -- 11
    'print("третья")', -- 12
    "", -- 13
    "# %%", -- 14 маркер без тела
}

local FENCE = {
    "# Отчёт", -- 1
    "", -- 2
    "```python", -- 3
    "import polars as pl", -- 4
    "```", -- 5
    "", -- 6
    "Текст между ячейками.", -- 7
    "", -- 8
    "```sql", -- 9  чужой язык: ядру не отдаём
    "select 1", -- 10
    "```", -- 11
    "", -- 12
    "```python", -- 13
    'print("вторая")', -- 14
    "", -- 15
    "```", -- 16
    "", -- 17
    "```python", -- 18 незакрытый фенс
    "незакрытый", -- 19
}

local function make(lines, filetype)
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.bo[buf].filetype = filetype
    return buf
end

describe("percent", function()
    local buf

    before_each(function()
        buf = make(PERCENT, "python")
    end)

    it("определяет представление по filetype", function()
        assert.equals("percent", cells.representation(buf))
    end)

    it("собирает код до первого маркера, пропускает [markdown] и маркер без тела", function()
        local list = cells.list(buf)

        assert.equals(3, #list)
        assert.same({ 1, 3, 1, 3 }, { list[1].span_start, list[1].span_end, list[1].start_row, list[1].end_row })
        assert.same({ 4, 7, 5, 7 }, { list[2].span_start, list[2].span_end, list[2].start_row, list[2].end_row })
        assert.same({ 11, 13, 12, 13 }, { list[3].span_start, list[3].span_end, list[3].start_row, list[3].end_row })
        assert.same({ 1, 2, 3 }, { list[1].index, list[2].index, list[3].index })
    end)

    it("файл без маркеров — одна ячейка", function()
        local plain = make({ "a = 1", "b = 2" }, "python")

        local list = cells.list(plain)

        assert.equals(1, #list)
        assert.same({ 1, 2 }, { list[1].start_row, list[1].end_row })
    end)

    it("маркер принадлежит своей ячейке", function()
        assert.equals(2, cells.at(buf, 4).index)
        assert.equals(2, cells.at(buf, 5).index)
    end)

    it("внутри [markdown] и у маркера без тела ячейки нет", function()
        assert.is_nil(cells.at(buf, 9))
        assert.is_nil(cells.at(buf, 14))
    end)

    it("прыжки идут по код-ячейкам, минуя markdown", function()
        assert.equals(3, cells.next(buf, 4).index)
        assert.is_nil(cells.next(buf, 13))
        assert.equals(2, cells.prev(buf, 12).index)
        assert.is_nil(cells.prev(buf, 1))
    end)

    it("тело обрезает хвостовые пустые строки", function()
        local first, last = cells.body(buf, cells.at(buf, 5))

        assert.same({ 5, 6 }, { first, last })
        assert.equals('print("вторая")\ny = 2', cells.text(buf, cells.at(buf, 5)))
    end)

    it("вставка ниже даёт новую ячейку и ставит курсор в её тело", function()
        local before = #cells.list(buf)

        local row = cells.insert(buf, 5, "below")

        assert.equals(before + 1, #cells.list(buf))
        assert.equals("# %%", vim.api.nvim_buf_get_lines(buf, row - 2, row - 1, false)[1])
        assert.equals("", vim.api.nvim_buf_get_lines(buf, row - 1, row, false)[1])
    end)

    it("вставка выше не задевает тело текущей ячейки", function()
        local before = cells.text(buf, cells.at(buf, 5))

        local row = cells.insert(buf, 5, "above")

        assert.equals("# %%", vim.api.nvim_buf_get_lines(buf, row - 2, row - 1, false)[1])
        assert.equals("", cells.text(buf, cells.at(buf, row)), "новая ячейка пустая")
        local moved = cells.next(buf, row)
        assert.equals(before, cells.text(buf, moved), "прежняя ячейка уехала вниз целиком")
    end)
end)

describe("fence", function()
    local buf

    before_each(function()
        buf = make(FENCE, "markdown")
    end)

    it("определяет представление по filetype", function()
        assert.equals("fence", cells.representation(buf))
    end)

    it("код-ячейка это только ```python", function()
        local list = cells.list(buf)

        assert.equals(2, #list)
        assert.same({ 3, 5, 4, 4 }, { list[1].span_start, list[1].span_end, list[1].start_row, list[1].end_row })
        assert.same({ 13, 16, 14, 15 }, { list[2].span_start, list[2].span_end, list[2].start_row, list[2].end_row })
    end)

    it("незакрытый фенс ячейкой не считается", function()
        assert.is_nil(cells.at(buf, 19))
    end)

    it("в тексте между ячейками и в чужом фенсе ячейки нет", function()
        assert.is_nil(cells.at(buf, 7))
        assert.is_nil(cells.at(buf, 10))
    end)

    it("оба фенса принадлежат ячейке", function()
        assert.equals(1, cells.at(buf, 3).index)
        assert.equals(1, cells.at(buf, 5).index)
    end)

    it("пустой фенс пропускается", function()
        local empty = make({ "```python", "```", "" }, "markdown")

        assert.equals(0, #cells.list(empty))
    end)

    it("тело обрезает хвостовую пустую строку", function()
        assert.equals('print("вторая")', cells.text(buf, cells.at(buf, 14)))
    end)

    it("вставка ниже создаёт закрытый фенс", function()
        local before = #cells.list(buf)

        local row = cells.insert(buf, 4, "below")

        assert.equals(before + 1, #cells.list(buf))
        assert.equals("```python", vim.api.nvim_buf_get_lines(buf, row - 2, row - 1, false)[1])
        assert.equals("```", vim.api.nvim_buf_get_lines(buf, row, row + 1, false)[1])
    end)

    it("вставка выше создаёт закрытый фенс", function()
        local before = #cells.list(buf)

        cells.insert(buf, 4, "above")

        assert.equals(before + 1, #cells.list(buf))
    end)
end)

describe("устойчивость к NUL", function()
    it("NUL-байт не доезжает до ядра", function()
        -- в буфер NUL попадает легко: writefile так пишет перевод строки внутри элемента
        local buf = vim.api.nvim_create_buf(false, true)
        vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "# %%", "x = 1" .. string.char(0) .. "y = 2" })
        vim.bo[buf].filetype = "python"

        local text = cells.text(buf, cells.at(buf, 2))

        assert.is_nil(text:find("%z"), "NUL должен быть вырезан")
        assert.equals("x = 1y = 2", text)
    end)
end)
