-- .ipynb ↔ markdown-буфер своими BufReadCmd/BufWriteCmd (lua/jupyter/ipynb.lua).
--
-- Что тут держится: на диске нет ничего, кроме ноутбука; выводы переживают `:w`; сбой
-- конвертации не оставляет ни пустого буфера, ни испорченного файла. Нужен настоящий
-- jupytext — без него тест пропускается.

local ipynb = require("jupyter.ipynb")

local available = vim.fn.exepath("jupytext") ~= ""

-- В изолированном rtp нет парсера markdown, и штатный ftplugin на FileType падает.
-- Само событие тут не проверяется — проверяется filetype.
vim.o.eventignore = "FileType"
vim.cmd("runtime! ftdetect/jupyter.lua")

local function notebook(path, cells)
    local nb = {
        nbformat = 4,
        nbformat_minor = 5,
        metadata = { kernelspec = { display_name = "Python 3", language = "python", name = "python3" } },
        cells = cells or {
            { cell_type = "markdown", id = "m1", metadata = vim.empty_dict(), source = { "# Заголовок" } },
            {
                cell_type = "code",
                id = "c1",
                execution_count = 3,
                metadata = vim.empty_dict(),
                outputs = { { output_type = "stream", name = "stdout", text = { "привет\n" } } },
                source = { "print('привет')" },
            },
        },
    }
    vim.fn.writefile({ vim.json.encode(nb) }, path)
end

local function decode(path)
    return vim.json.decode(table.concat(vim.fn.readfile(path), "\n"), { luanil = { object = true, array = true } })
end

local function lines()
    return vim.api.nvim_buf_get_lines(0, 0, -1, false)
end

describe("ipynb: свои BufReadCmd и BufWriteCmd", function()
    local dir, path

    before_each(function()
        dir = vim.fn.tempname()
        vim.fn.mkdir(dir, "p")
        path = dir .. "/nb.ipynb"
    end)

    after_each(function()
        vim.cmd("silent! %bwipeout!")
        vim.fn.delete(dir, "rf")
    end)

    it("открывает ноутбук markdown-ом и не кладёт рядом ничего", function()
        if not available then
            return
        end
        notebook(path)

        vim.cmd.edit(path)

        assert.equals("markdown", vim.bo.filetype)
        assert.is_false(vim.bo.modified)
        assert.is_true(vim.tbl_contains(lines(), "print('привет')"))
        assert.same({ "nb.ipynb" }, vim.fn.readdir(dir))
        -- `u` сразу после открытия не должен стирать ноутбук
        assert.equals(0, vim.fn.undotree().seq_last)
    end)

    it(":w сохраняет выводы, правку и не оставляет временных файлов", function()
        if not available then
            return
        end
        notebook(path)
        vim.cmd.edit(path)
        local row = vim.fn.index(lines(), "print('привет')")
        vim.api.nvim_buf_set_lines(0, row, row + 1, false, { "print('пока')" })
        local posted = false
        vim.api.nvim_create_autocmd("BufWritePost", { buffer = 0, once = true, callback = function() posted = true end })

        vim.cmd("silent write")

        assert.is_false(vim.bo.modified)
        assert.is_true(posted, "BufWritePost нужен черновику и чужим плагинам")
        assert.same({ "nb.ipynb" }, vim.fn.readdir(dir))
        local nb = decode(path)
        assert.equals(2, #nb.cells)
        assert.equals("print('пока')", table.concat(nb.cells[2].source, ""))
        assert.equals("привет\n", table.concat(nb.cells[2].outputs[1].text, ""))
        assert.equals("python3", nb.metadata.kernelspec.name)
    end)

    it("пустые строки в конце буфера не становятся лишней ячейкой", function()
        if not available then
            return
        end
        notebook(path)
        vim.cmd.edit(path)
        vim.api.nvim_buf_set_lines(0, -1, -1, false, { "", "  ", "" })

        vim.cmd("silent write")

        assert.equals(2, #decode(path).cells)
    end)

    it("сбой конвертации на записи не трогает файл и оставляет буфер изменённым", function()
        if not available then
            return
        end
        notebook(path)
        local before = vim.fn.readfile(path)
        vim.cmd.edit(path)
        vim.api.nvim_buf_set_lines(0, 0, 0, false, { "правка" })
        local real = ipynb.command
        ipynb.command = function()
            return { "false" }
        end
        local notify = vim.notify
        local said
        vim.notify = function(msg)
            said = msg
        end

        local ok = pcall(vim.cmd, "silent write")

        ipynb.command, vim.notify = real, notify
        assert.is_true(ok)
        assert.is_true(vim.bo.modified, "иначе :wq закрыл бы nvim с потерянной правкой")
        assert.same(before, vim.fn.readfile(path))
        assert.same({ "nb.ipynb" }, vim.fn.readdir(dir))
        assert.is_truthy(said and said:find("не записан", 1, true))
    end)

    it("битый json открывается как есть и так же пишется", function()
        notebook(path)
        vim.fn.writefile({ '{"cells": [', "oops" }, path)
        local notify = vim.notify
        vim.notify = function() end

        vim.cmd.edit(path)
        vim.wait(50) -- сообщение уходит через vim.schedule

        vim.notify = notify
        assert.equals("json", vim.bo.filetype)
        assert.same({ '{"cells": [', "oops" }, lines(), "пустой буфер стёр бы ноутбук первым же :w")

        vim.api.nvim_buf_set_lines(0, -1, -1, false, { "]}" })
        vim.cmd("silent write")
        assert.same({ '{"cells": [', "oops", "]}" }, vim.fn.readfile(path))
    end)

    it("новый ноутбук получает kernelspec из opts.kernel_name", function()
        if not available then
            return
        end
        local data = dir .. "/data"
        vim.fn.mkdir(data .. "/kernels/proba", "p")
        vim.fn.writefile({ vim.json.encode({ display_name = "Проба", language = "python", argv = {} }) },
            data .. "/kernels/proba/kernel.json")
        local saved_env, saved_mod = vim.env.JUPYTER_DATA_DIR, package.loaded["jupyter"]
        vim.env.JUPYTER_DATA_DIR = data
        package.loaded["jupyter"] = { config = { kernel_name = "proba" } }

        vim.cmd.edit(path)
        assert.same({ "" }, lines())
        assert.equals("markdown", vim.bo.filetype)
        vim.api.nvim_buf_set_lines(0, 0, -1, false, { "```python", "x = 1", "```" })
        vim.cmd("silent write")

        vim.env.JUPYTER_DATA_DIR, package.loaded["jupyter"] = saved_env, saved_mod
        local nb = decode(path)
        assert.same({ name = "proba", display_name = "Проба", language = "python" }, nb.metadata.kernelspec)
        assert.equals("x = 1", table.concat(nb.cells[1].source, ""))
    end)

    it("повторный BufRead (netrw на :Ex) не делает из ноутбука json", function()
        if not available then
            return
        end
        notebook(path)
        vim.cmd.edit(path)

        vim.cmd("doautocmd filetypedetect BufRead " .. vim.fn.fnameescape(path))

        assert.equals("markdown", vim.bo.filetype)
    end)

    it("пишет в файл под симлинком, а не на место ссылки", function()
        if not available then
            return
        end
        notebook(path)
        local link = dir .. "/link.ipynb"
        vim.uv.fs_symlink(path, link)
        vim.cmd.edit(link)
        vim.api.nvim_buf_set_lines(0, -1, -1, false, { "", "```python", "y = 2", "```" })

        vim.cmd("silent write")

        assert.equals("link", vim.uv.fs_lstat(link).type)
        assert.equals(3, #decode(path).cells)
    end)
end)

describe("ipynb.trim", function()
    it("срезает только хвост из пустых строк", function()
        assert.same({ "a", "", "b" }, ipynb.trim({ "a", "", "b", "", " ", "\t" }))
        assert.same({}, ipynb.trim({ "", "" }))
        assert.same({ "a" }, ipynb.trim({ "a" }))
    end)
end)
