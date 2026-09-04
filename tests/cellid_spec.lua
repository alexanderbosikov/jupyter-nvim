-- Стабильные id ячеек. Здесь же зафиксированы факты про jupytext, полученные замером:
-- нативный id ячейки не переживает круг md → ipynb, а ключ jncell="..." переживает.

local cellid = require("jupyter.cellid")
local cells = require("jupyter.cells")

local function make(lines, filetype)
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.bo[buf].filetype = filetype or "python"
    return buf
end

describe("разбор", function()
    it("достаёт id из фенса и из маркера", function()
        assert.equals("a3f9", cellid.parse('```python jncell="a3f9"'))
        assert.equals("b7e1", cellid.parse('# %% jncell="b7e1"'))
        assert.equals("00ff", cellid.parse('```sql magic_args="df <<" jncell="00ff"'))
    end)

    it("не путает с чужими ключами и мусором", function()
        assert.is_nil(cellid.parse("```python"))
        assert.is_nil(cellid.parse('```python tags=["x"]'))
        assert.is_nil(cellid.parse('```python jncell=a3f9'), "значение обязано быть в кавычках")
        assert.is_nil(cellid.parse('```python jncell="ЫЫЫ"'), "только hex")
        assert.is_nil(cellid.parse(nil))
    end)
end)

describe("генерация", function()
    it("детерминирована по содержимому", function()
        local a = cellid.generate("x = 1", {})
        local b = cellid.generate("x = 1", {})

        assert.equals(a, b)
        assert.equals(4, #a)
        assert.is_truthy(a:match("^[0-9a-f]+$"))
    end)

    it("разводит коллизию солью", function()
        local first = cellid.generate("одинаково", {})
        local second = cellid.generate("одинаково", { [first] = true })

        assert.are_not.equals(first, second)
    end)

    it("подходит под проверку сайдкара", function()
        -- outdir.check_cell_id принимает ^[0-9a-f]{4,8}$: id идёт в путь на диске
        for _, seed in ipairs({ "a", "%%sql\nselect 1", "кириллица", "" }) do
            assert.is_truthy(cellid.generate(seed, {}):match("^[0-9a-f]{4}$") ~= nil
                or cellid.generate(seed, {}):match("^%x%x%x%x$"))
        end
    end)
end)

describe("percent", function()
    local buf

    before_each(function()
        buf = make({ "# %%", "x = 1", "# %%", 'print("два")' })
    end)

    it("дописывает id к маркеру и возвращает его", function()
        local cell = cells.at(buf, 2)

        local id, written = cellid.ensure(buf, cell)

        assert.is_truthy(id)
        assert.is_true(written)
        assert.equals(('# %%%% jncell="%s"'):format(id), vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1])
    end)

    it("второй раз не пишет и отдаёт тот же id", function()
        local first = cellid.ensure(buf, cells.at(buf, 2))

        local again, written = cellid.ensure(buf, cells.at(buf, 2))

        assert.equals(first, again)
        assert.is_false(written)
        assert.equals(1, #vim.tbl_keys(cellid.used(buf)))
    end)

    it("не ломает границы ячейки", function()
        local before = cells.text(buf, cells.at(buf, 2))

        cellid.ensure(buf, cells.at(buf, 2))

        assert.equals(2, #cells.list(buf))
        assert.equals(before, cells.text(buf, cells.at(buf, 2)), "тело не тронуто")
    end)

    it("id уникальны в пределах файла даже у одинаковых ячеек", function()
        local same = make({ "# %%", "x = 1", "# %%", "x = 1" })

        local a = cellid.ensure(same, cells.list(same)[1])
        local b = cellid.ensure(same, cells.list(same)[2])

        assert.are_not.equals(a, b)
    end)

    it("ячейке без маркера id не пишет", function()
        local no_marker = make({ "x = 1", "y = 2" })

        local id, written = cellid.ensure(no_marker, cells.list(no_marker)[1])

        assert.is_nil(id)
        assert.is_false(written)
    end)

    it("правка отменяется обычным undo", function()
        local file = make({ "# %%", "x = 1" })
        vim.api.nvim_set_current_buf(file)
        vim.bo[file].undolevels = 1000
        local before = vim.api.nvim_buf_get_lines(file, 0, -1, false)

        cellid.ensure(file, cells.at(file, 2))
        vim.cmd("undo")

        assert.same(before, vim.api.nvim_buf_get_lines(file, 0, -1, false))
    end)
end)

describe("fence", function()
    local buf

    before_each(function()
        buf = make({ "# Отчёт", "", "```python", "x = 1", "```" }, "markdown")
    end)

    it("дописывает id в info-строку фенса, а не в тело", function()
        local id = cellid.ensure(buf, cells.at(buf, 4))

        assert.equals(('```python jncell="%s"'):format(id), vim.api.nvim_buf_get_lines(buf, 2, 3, false)[1])
        assert.equals("x = 1", cells.text(buf, cells.at(buf, 4)), "тело ячейки не тронуто")
    end)

    it("сохраняет чужие ключи на фенсе", function()
        local with_meta = make({ '```python tags=["важное"]', "x = 1", "```" }, "markdown")

        local id = cellid.ensure(with_meta, cells.list(with_meta)[1])
        local line = vim.api.nvim_buf_get_lines(with_meta, 0, 1, false)[1]

        assert.is_truthy(line:find('tags=["важное"]', 1, true), "чужая метадата должна остаться")
        assert.equals(id, cellid.parse(line))
    end)

    it("магика в теле остаётся первой строкой", function()
        -- id обязан жить на фенсе: в теле он уехал бы в ядро частью кода ячейки
        local sql = make({ "```python", "%%sql df_name=orders", "select 1", "```" }, "markdown")

        cellid.ensure(sql, cells.list(sql)[1])

        assert.equals("%%sql df_name=orders", vim.api.nvim_buf_get_lines(sql, 1, 2, false)[1])
        assert.is_truthy(cells.text(sql, cells.list(sql)[1]):match("^%%%%sql"))
    end)

    it("находит ячейку по id", function()
        local id = cellid.ensure(buf, cells.at(buf, 4))

        local found = cellid.find(buf, id)

        assert.is_truthy(found)
        assert.equals(4, found.start_row)
        assert.is_nil(cellid.find(buf, "ffff"))
    end)
end)
