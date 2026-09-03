-- Круг .ipynb → markdown → .ipynb с настоящим jupytext.
--
-- Это главная проверка шага 5: id ячейки живёт в тексте документа пользователя, и если он
-- не переживает конвертацию, привязка выводов рассыпается, а ноутбук получает мусор.
-- Проверяется вместе с ipynb_magics.lua из конфига, потому что он тоже правит буфер.
--
-- Тест пропускается там, где нет jupytext или этого конфига.

local cells = require("jupyter.cells")
local cellid = require("jupyter.cellid")

local JUPYTEXT = vim.fn.expand("~/.local/bin/jupytext")
local MAGICS = vim.fn.expand("~/.config/nvim/lua/custom/ipynb_magics.lua")
local SAMPLE = vim.fn.expand("~/work/sandbox/Sandbox.ipynb")

local function available()
    return vim.fn.executable(JUPYTEXT) == 1
        and vim.fn.filereadable(MAGICS) == 1
        and vim.fn.filereadable(SAMPLE) == 1
end

describe("круг через jupytext", function()
    local dir, magics

    before_each(function()
        if not available() then
            return
        end
        magics = loadfile(MAGICS)()
        dir = vim.fn.tempname()
        vim.fn.mkdir(dir, "p")
        vim.fn.system({ "cp", SAMPLE, dir .. "/nb.ipynb" })
    end)

    local function to_md(ipynb, md)
        vim.fn.system({ JUPYTEXT, "--to", "markdown", "--output", md, ipynb })
    end

    local function to_nb(md, ipynb)
        vim.fn.system({ JUPYTEXT, "--to", "notebook", "--output", ipynb, md })
    end

    ---Буфер таким, каким его видит nvim: содержимое md плюс нормализация магик.
    ---Без :edit — в изолированном rtp нет парсера markdown, и штатный ftplugin падает.
    local function open_md(path)
        local buf = vim.api.nvim_create_buf(false, true)
        local lines = vim.fn.readfile(path)
        vim.api.nvim_buf_set_lines(buf, 0, -1, false, magics.normalize(lines) or lines)
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
        assert.is_true(#cells.list(buf) > 10, "в образце должны быть код-ячейки")

        for _, cell in ipairs(cells.list(buf)) do
            cellid.ensure(buf, cell)
        end
        local before = ids_of(buf)
        assert.is_nil(vim.tbl_contains(before, "—") and true or nil, "id должны быть у всех ячеек")
        vim.fn.writefile(vim.api.nvim_buf_get_lines(buf, 0, -1, false), dir .. "/a.md")

        to_nb(dir .. "/a.md", dir .. "/b.ipynb")
        to_md(dir .. "/b.ipynb", dir .. "/c.md")
        local after = ids_of(open_md(dir .. "/c.md"))

        assert.same(before, after)
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

        local nb = vim.json.decode(table.concat(vim.fn.readfile(dir .. "/b.ipynb"), "\n"))
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

        assert.equals(0, leaked, "id в теле ячейки уехал бы в Redshift частью запроса")
        assert.is_true(with_meta > 10, "id должен лежать в cell metadata")
        assert.is_true(magic_first > 0, "%%sql должен остаться первой строкой тела")
    end)
end)
