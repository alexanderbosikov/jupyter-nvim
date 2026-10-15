-- Запуск ячейки агентом (jupyter.agent_run). Агент приходит через --remote-expr, и текущим
-- буфером nvim в этот момент может быть что угодно. Проверяем, что запуск ищет ноутбук по
-- пути, а не по текущему буферу, и что отказ возвращается причиной, а не молчит.

local jupyter = require("jupyter")
local agent = require("jupyter.agent")

local function notebook(lines)
    local path = vim.fn.tempname() .. ".py"
    vim.fn.writefile(lines, path)
    vim.cmd.edit(path)
    vim.bo.filetype = "python"
    return vim.api.nvim_get_current_buf(), path
end

describe("запуск ячейки агентом", function()
    local buf, path, s, sent

    before_each(function()
        agent._reset()
        jupyter.setup({})
        buf, path = notebook({ '# %% jncell="aa01"', "a = 1", '# %% jncell="bb02"', "b = 2", '# %% jncell="cc03"', "" })
        s = jupyter.session(buf)
        -- ядро не поднимаем: started — чтобы ensure_started не стартовал сайдкар
        s.started = true
        sent = {}
        s.kernel.execute = function(_, args)
            table.insert(sent, args)
        end
        -- курсор уходит в посторонний буфер, как это бывает, когда агент шлёт запуск
        vim.cmd("enew")
    end)

    after_each(function()
        jupyter.detach(buf)
        vim.cmd("silent! %bwipeout!")
    end)

    it("запускает ячейку ноутбука по id, хотя текущий буфер другой", function()
        local other = vim.api.nvim_get_current_buf()
        local res = jupyter.agent_run({ notebook = path, cell = "bb02" })
        assert.is_true(res.ok, res.msg)
        assert.equals("bb02", res.cell_id)
        assert.equals(1, #sent)
        assert.equals("b = 2", sent[1].code)
        assert.equals(other, vim.api.nvim_get_current_buf(), "текущий буфер не меняется")
    end)

    it("запускает по строке", function()
        local res = jupyter.agent_run({ notebook = path, row = 2 })
        assert.is_true(res.ok, res.msg)
        assert.equals("aa01", res.cell_id)
    end)

    it("нет ячейки — причина, а не молчание", function()
        local res = jupyter.agent_run({ notebook = path, cell = "zz99" })
        assert.is_false(res.ok)
        assert.equals("no_cell", res.reason)
        assert.equals(0, #sent)
    end)

    it("пустая ячейка — empty", function()
        local res = jupyter.agent_run({ notebook = path, cell = "cc03" })
        assert.equals("empty", res.reason)
    end)

    it("ноутбук не открыт — no_buffer", function()
        local res = jupyter.agent_run({ notebook = "/нет/такого.ipynb", cell = "bb02" })
        assert.equals("no_buffer", res.reason)
    end)

    it("снимок по пути — того ноутбука, а не текущего буфера", function()
        local snap = jupyter.snapshot(path)
        assert.equals(buf, snap.buf)
        assert.equals(3, #snap.cells)
        local missing = jupyter.snapshot("/нет/такого.ipynb")
        assert.is_false(missing.ok)
        assert.equals("no_buffer", missing.reason)
    end)

    it("ячейка под заявкой — claimed с номером заявки", function()
        local claim = agent.claim(buf, { text = "b = 2", label = "Claude" })
        assert.is_true(claim.ok, claim.msg)
        local res = jupyter.agent_run({ notebook = path, cell = "bb02" })
        assert.equals("claimed", res.reason)
        assert.equals(claim.token, res.token)
        assert.equals(0, #sent)
    end)
end)
