-- Круг .ipynb → markdown → .ipynb с настоящим jupytext.
--
-- Главная проверка того, что id ячейки живёт в тексте документа: если он не переживает
-- конвертацию, привязка выводов рассыпается, а ноутбук получает мусор. Ноутбук для теста
-- собирается здесь же, чтобы проверка не зависела от чужих файлов.
--
-- Тест пропускается там, где нет jupytext.

local cells = require("jupyter.cells")
local cellid = require("jupyter.cellid")

local JUPYTEXT = vim.fn.exepath("jupytext")

local function available()
    return JUPYTEXT ~= ""
end

---Ноутбук с обычными ячейками и ячейкой с магикой языка.
local function sample_notebook(path)
    local function cell(source)
        return { cell_type = "code", execution_count = vim.NIL, metadata = vim.empty_dict(), outputs = {}, source = source }
    end
    local nb = {
        nbformat = 4,
        nbformat_minor = 5,
        metadata = {
            kernelspec = { display_name = "Python 3", language = "python", name = "python3" },
            language_info = { name = "python", version = "3.11.0" },
        },
        cells = {
            cell({ "import polars as pl\n" }),
            cell({ "%%sql df_name=orders limit=0\n", "select 1\n" }),
            cell({ 'print("привет")\n' }),
            cell({ "%%sql\n", "select 2\n" }),
            cell({ "x = 1\n", "y = 2\n" }),
        },
    }
    vim.fn.writefile(vim.split(vim.json.encode(nb), "\n"), path)
end

describe("круг через jupytext", function()
    local dir

    before_each(function()
        if not available() then
            return
        end
        dir = vim.fn.tempname()
        vim.fn.mkdir(dir, "p")
        sample_notebook(dir .. "/nb.ipynb")
    end)

    local function to_md(ipynb, md)
        vim.fn.system({ JUPYTEXT, "--to", "markdown", "--output", md, ipynb })
    end

    local function to_nb(md, ipynb)
        vim.fn.system({ JUPYTEXT, "--to", "notebook", "--output", ipynb, md })
    end

    ---Буфер таким, каким его видит nvim. Без :edit — в изолированном rtp нет парсера
    ---markdown, и штатный ftplugin падает.
    local function open_md(path)
        local buf = vim.api.nvim_create_buf(false, true)
        vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.fn.readfile(path))
        local save = vim.o.eventignore
        vim.o.eventignore = "FileType"
        vim.bo[buf].filetype = "markdown"
        vim.o.eventignore = save
        return buf
    end

    local function ids_of(buf)
        return vim.tbl_map(function(cell)
            return cellid.of(buf, cell) or "—"
        end, cells.list(buf))
    end

    it("id всех ячеек переживают markdown → ipynb → markdown", function()
        if not available() then
            return
        end

        to_md(dir .. "/nb.ipynb", dir .. "/a.md")
        local buf = open_md(dir .. "/a.md")
        assert.is_true(#cells.list(buf) >= 4, "ожидали код-ячейки, нашли " .. #cells.list(buf))

        for _, cell in ipairs(cells.list(buf)) do
            cellid.ensure(buf, cell)
        end
        local before = ids_of(buf)
        assert.is_false(vim.tbl_contains(before, "—"), "id должны быть у всех ячеек")
        vim.fn.writefile(vim.api.nvim_buf_get_lines(buf, 0, -1, false), dir .. "/a.md")

        to_nb(dir .. "/a.md", dir .. "/b.ipynb")
        to_md(dir .. "/b.ipynb", dir .. "/c.md")

        assert.same(before, ids_of(open_md(dir .. "/c.md")))
    end)

    it("id не попадает в тело ячейки и не ломает магику", function()
        if not available() then
            return
        end

        to_md(dir .. "/nb.ipynb", dir .. "/a.md")
        local buf = open_md(dir .. "/a.md")
        for _, cell in ipairs(cells.list(buf)) do
            cellid.ensure(buf, cell)
        end
        vim.fn.writefile(vim.api.nvim_buf_get_lines(buf, 0, -1, false), dir .. "/a.md")
        to_nb(dir .. "/a.md", dir .. "/b.ipynb")

        local nb = vim.json.decode(table.concat(vim.fn.readfile(dir .. "/b.ipynb"), "\n"),
            { luanil = { object = true, array = true } })
        local leaked, with_meta, magic_first = 0, 0, 0
        for _, cell in ipairs(nb.cells) do
            local src = table.concat(cell.source or {}, "")
            if src:find(cellid.KEY, 1, true) then
                leaked = leaked + 1
            end
            if cell.metadata and cell.metadata[cellid.KEY] then
                with_meta = with_meta + 1
            end
            if src:match("^%%%%sql") then
                magic_first = magic_first + 1
            end
        end

        assert.equals(0, leaked, "id в теле ячейки уехал бы в ядро частью кода")
        assert.is_true(with_meta >= 4, "id должен лежать в cell metadata")
        assert.is_true(magic_first > 0, "магика должна остаться первой строкой тела")
    end)
end)
