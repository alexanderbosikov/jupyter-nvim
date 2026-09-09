-- Перестройка ячеек. Проверяется результат в буфере: у операций нет промежуточной
-- структуры, документ и есть модель, поэтому единственная честная проверка — текст.

local edit = require("jupyter.edit")
local cells = require("jupyter.cells")

local function make(lines, filetype)
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.bo[buf].filetype = filetype
    return buf
end

local function text(buf)
    return vim.api.nvim_buf_get_lines(buf, 0, -1, false)
end

describe("разрезание", function()
    it("percent: маркер встаёт перед строкой курсора", function()
        local buf = make({ "# %%", "первая", "вторая", "третья" }, "python")

        local row = edit.split(buf, 3)

        assert.same({ "# %%", "первая", "# %%", "вторая", "третья" }, text(buf))
        assert.equals(4, row, "курсор — на первой строке новой ячейки")
    end)

    it("фенсы: половины разъезжаются, язык сохраняется", function()
        local buf = make({ "```sql", "select 1", "select 2", "```" }, "markdown")

        edit.split(buf, 3)

        assert.same({ "```sql", "select 1", "```", "", "```sql", "select 2", "```" }, text(buf))
        assert.equals(2, #cells.list(buf))
    end)

    it("id и параметры остаются у первой половины", function()
        local buf = make({ '```sql magic_args="df_name=a" jncell="a3f9"', "select 1", "select 2", "```" }, "markdown")

        edit.split(buf, 3)

        local list = cells.list(buf)
        assert.equals("df_name=a", list[1].magic_args)
        assert.is_nil(list[2].magic_args, "вторая половина — своя ячейка, чужие параметры ей ни к чему")
        assert.equals("a3f9", require("jupyter.cellid").of(buf, list[1]))
        assert.is_nil(require("jupyter.cellid").of(buf, list[2]))
    end)

    it("перед первой строкой тела резать нечего", function()
        local buf = make({ "# %%", "первая" }, "python")

        assert.is_nil(edit.split(buf, 2), "получилась бы пустая ячейка")
        assert.is_nil(edit.split(buf, 1), "курсор на маркере")
    end)
end)

describe("склейка", function()
    it("percent: маркер второй ячейки исчезает", function()
        local buf = make({ "# %%", "первая", "# %%", "вторая" }, "python")

        assert.is_true(edit.merge(buf, cells.list(buf)[1]))

        assert.same({ "# %%", "первая", "вторая" }, text(buf))
        assert.equals(1, #cells.list(buf))
    end)

    it("фенсы: тела становятся одним", function()
        local buf = make({ "```python", "x = 1", "```", "", "```python", "y = 2", "```" }, "markdown")

        assert.is_true(edit.merge(buf, cells.list(buf)[1]))

        assert.same({ "```python", "x = 1", "y = 2", "```" }, text(buf))
    end)

    it("текст между ячейками не теряем — отказываемся", function()
        local buf = make({ "```python", "x = 1", "```", "", "Важная проза.", "", "```python", "y = 2", "```" }, "markdown")
        local before = text(buf)

        local ok, why = edit.merge(buf, cells.list(buf)[1])

        assert.is_false(ok)
        assert.is_truthy(why:find("текст"))
        assert.same(before, text(buf))
    end)

    it("разные языки не склеиваем", function()
        local buf = make({ "```python", "x = 1", "```", "", "```sql", "select 1", "```" }, "markdown")

        local ok, why = edit.merge(buf, cells.list(buf)[1])

        assert.is_false(ok)
        assert.is_truthy(why:find("языки"))
    end)

    it("последней ячейке склеиваться не с чем", function()
        local buf = make({ "# %%", "первая" }, "python")

        local ok, why = edit.merge(buf, cells.list(buf)[1])

        assert.is_false(ok)
        assert.is_truthy(why:find("нет"))
    end)
end)

describe("перестановка", function()
    it("percent: ячейки меняются местами целиком", function()
        local buf = make({ "# %%", "первая", "# %%", "вторая", "вторая-2" }, "python")

        local row = edit.move(buf, cells.list(buf)[1], "down")

        assert.same({ "# %%", "вторая", "вторая-2", "# %%", "первая" }, text(buf))
        assert.equals(5, row, "курсор идёт за ячейкой")
    end)

    it("вверх — то же самое в обратную сторону", function()
        local buf = make({ "# %%", "первая", "# %%", "вторая" }, "python")

        local row = edit.move(buf, cells.list(buf)[2], "up")

        assert.same({ "# %%", "вторая", "# %%", "первая" }, text(buf))
        assert.equals(2, row)
    end)

    it("проза между ячейками остаётся на месте", function()
        local buf = make({
            "```python", "первая", "```",
            "", "Проза.", "",
            "```python", "вторая", "```",
        }, "markdown")

        edit.move(buf, cells.list(buf)[1], "down")

        assert.same({
            "```python", "вторая", "```",
            "", "Проза.", "",
            "```python", "первая", "```",
        }, text(buf))
    end)

    it("крайним двигаться некуда", function()
        local buf = make({ "# %%", "одна" }, "python")

        assert.is_nil(edit.move(buf, cells.list(buf)[1], "up"))
        assert.is_nil(edit.move(buf, cells.list(buf)[1], "down"))
    end)
end)

describe("смена типа ячейки", function()
    it("фенсы: код становится прозой", function()
        local buf = make({ "```python", "заметка", "```", "", "```python", "x = 1", "```" }, "markdown")

        assert.is_true(edit.to_markdown(buf, cells.list(buf)[1]))

        assert.same({ "заметка", "", "```python", "x = 1", "```" }, text(buf))
        assert.equals(1, #cells.list(buf), "код-ячейка осталась одна")
    end)

    it("фенсы: абзац под курсором становится кодом", function()
        local buf = make({ "первая строка", "вторая строка", "", "чужой абзац" }, "markdown")

        local row = edit.to_code(buf, 2)

        assert.same({ "```python", "первая строка", "вторая строка", "```", "", "чужой абзац" }, text(buf))
        assert.equals(2, row)
        assert.equals(1, #cells.list(buf))
    end)

    it("percent: тело комментируется и раскомментируется обратно", function()
        local buf = make({ "# %%", "x = 1", "", "y = 2" }, "python")

        edit.to_markdown(buf, cells.list(buf)[1])
        assert.same({ "# %% [markdown]", "# x = 1", "#", "# y = 2" }, text(buf))
        assert.equals(0, #cells.list(buf), "markdown-ячейка кодом не считается")

        local row = edit.to_code(buf, 2)
        assert.same({ "# %%", "x = 1", "", "y = 2" }, text(buf))
        assert.equals(2, row)
    end)

    it("код кодом обратно не делаем", function()
        local buf = make({ "```python", "x = 1", "```" }, "markdown")

        assert.is_nil(edit.to_code(buf, 2))
    end)

    it("на пустой строке абзаца нет", function()
        local buf = make({ "текст", "", "ещё" }, "markdown")

        assert.is_nil(edit.to_code(buf, 2))
    end)
end)

-- Откат: каждая операция должна отменяться одним `u`. Две правки подряд означали бы два
-- нажатия, и узнал бы об этом пользователь в самый неподходящий момент.
describe("откат одним нажатием", function()
    local function undoable(lines, filetype, act)
        local buf = vim.api.nvim_create_buf(false, true)
        vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
        vim.bo[buf].filetype = filetype
        vim.api.nvim_win_set_buf(0, buf)
        vim.bo[buf].undolevels = 1000 -- у scratch-буфера истории по умолчанию нет
        local before = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
        act(buf)
        assert.are_not.same(before, vim.api.nvim_buf_get_lines(buf, 0, -1, false), "операция ничего не сделала")
        vim.cmd("silent! undo")
        return before, vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    end

    it("разрез", function()
        local before, after = undoable({ "# %%", "первая", "вторая" }, "python", function(buf)
            edit.split(buf, 3)
        end)
        assert.same(before, after)
    end)

    it("склейка", function()
        local before, after = undoable({ "# %%", "первая", "# %%", "вторая" }, "python", function(buf)
            edit.merge(buf, cells.list(buf)[1])
        end)
        assert.same(before, after)
    end)

    it("перестановка", function()
        local before, after = undoable({ "# %%", "первая", "# %%", "вторая" }, "python", function(buf)
            edit.move(buf, cells.list(buf)[1], "down")
        end)
        assert.same(before, after)
    end)

    it("в markdown и обратно", function()
        local before, after = undoable({ "```python", "x = 1", "```" }, "markdown", function(buf)
            edit.to_markdown(buf, cells.list(buf)[1])
        end)
        assert.same(before, after)

        local was, now = undoable({ "просто текст" }, "markdown", function(buf)
            edit.to_code(buf, 1)
        end)
        assert.same(was, now)
    end)

    it("percent: в markdown", function()
        local before, after = undoable({ "# %%", "x = 1" }, "python", function(buf)
            edit.to_markdown(buf, cells.list(buf)[1])
        end)
        assert.same(before, after)
    end)
end)
