-- Вход для `jn` (lua/jupyter/cli.lua): запрос — JSON-файл, ответ — JSON-строка.

local jupyter = require("jupyter")
local cli = require("jupyter.cli")

local function request(tbl)
    local path = vim.fn.tempname() .. ".json"
    vim.fn.writefile({ vim.json.encode(tbl) }, path)
    return path
end

describe("jupyter.cli", function()
    local buf, path

    before_each(function()
        jupyter.setup({})
        path = vim.fn.tempname() .. ".py"
        vim.fn.writefile({ '# %% jncell="aa01"', 'x = "it\'s"', "" }, path)
        vim.cmd.edit(path)
        vim.bo.filetype = "python"
        buf = vim.api.nvim_get_current_buf()
        vim.cmd("enew")
    end)

    after_each(function()
        jupyter.detach(buf)
        vim.cmd("silent! %bwipeout!")
    end)

    it("текст правки с кавычками и переводами строк доходит как есть", function()
        local res = vim.json.decode(cli.call(request({
            fn = "edit_replace",
            args = { 'x = "it\'s"', 'x = "it\'s"\ny = "\\\\n"', { notebook = path } },
            argc = 3,
        })))
        assert.is_true(res.ok, res.msg)
        assert.same({ 'x = "it\'s"', 'y = "\\\\n"' }, vim.api.nvim_buf_get_lines(buf, 1, 3, false))
    end)

    it("text — буфер целиком, с несохранённым", function()
        vim.api.nvim_buf_set_lines(buf, 2, 3, false, { "z = 1" })
        local res = vim.json.decode(cli.call(request({ fn = "text", args = { path } })))
        assert.is_truthy(res.text:find("z = 1", 1, true))
    end)

    it("modified — изменён ли буфер ноутбука", function()
        local ask = function()
            return vim.json.decode(cli.call(request({ fn = "modified", args = { path } })))
        end
        assert.is_false(ask().modified)
        vim.api.nvim_buf_set_lines(buf, 2, 3, false, { "z = 1" })
        assert.is_true(ask().modified)
        assert.equals("no_buffer", vim.json.decode(cli.call(request({ fn = "modified", args = { "/nope.ipynb" } }))).reason)
    end)

    it("чужие функции не зовутся", function()
        local res = vim.json.decode(cli.call(request({ fn = "restart", args = {} })))
        assert.equals("bad_request", res.reason)
    end)

    it("битый запрос — отказ, а не исключение", function()
        local bad = vim.fn.tempname()
        vim.fn.writefile({ "{" }, bad)
        assert.equals("bad_request", vim.json.decode(cli.call(bad)).reason)
    end)
end)
