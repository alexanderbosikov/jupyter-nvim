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

    it("ячейки выше, не выполнявшиеся в этом ядре, — в ответе", function()
        local res = jupyter.agent_run({ notebook = path, cell = "bb02" })
        assert.same({ "aa01" }, res.not_run_above)
        assert.is_false(res.kernel.attached)

        jupyter.agent_run({ notebook = path, cell = "aa01" })
        assert.is_nil(jupyter.agent_run({ notebook = path, cell = "bb02" }).not_run_above)

        -- рестарт: всё, что выполнялось, осталось в прошлом ядре
        s.kernel.sidecar.request = function() end
        s.kernel:restart()
        assert.same({ "aa01" }, jupyter.agent_run({ notebook = path, cell = "bb02" }).not_run_above)
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

    it("agent_open: уже открыт — тот же буфер, ничего не грузит", function()
        local res = jupyter.agent_open({ notebook = path, kernel = false })
        assert.is_true(res.ok, res.msg)
        assert.equals(buf, res.buf)
        assert.is_false(res.opened)
    end)
end)

describe("agent_open: ноутбук агента в nvim человека", function()
    local instances = require("jupyter.instances")
    local saved_dir, saved_alive

    before_each(function()
        jupyter.setup({})
        saved_dir, saved_alive = instances.DIR, instances.alive
        instances.DIR = vim.fn.tempname()
    end)

    after_each(function()
        instances.DIR, instances.alive = saved_dir, saved_alive
        vim.cmd("silent! %bwipeout!")
    end)

    it("открывает скрытым буфером: окно и текущий буфер не меняются", function()
        local path = vim.fn.tempname() .. ".py"
        vim.fn.writefile({ '# %% jncell="aa01"', "a = 1" }, path)
        local win, cur = vim.api.nvim_get_current_win(), vim.api.nvim_get_current_buf()
        local res = jupyter.agent_open({ notebook = path, kernel = false })
        assert.is_true(res.ok, res.msg)
        assert.is_true(res.opened)
        assert.equals(win, vim.api.nvim_get_current_win())
        assert.equals(cur, vim.api.nvim_get_current_buf())
        assert.is_true(vim.api.nvim_buf_is_loaded(res.buf))
        assert.is_true(vim.bo[res.buf].buflisted, "виден в :ls")
        assert.equals(-1, vim.fn.bufwinid(res.buf), "ни в одном окне")
        assert.equals("python", vim.bo[res.buf].filetype)
        jupyter.detach(res.buf)
    end)

    it("после agent_open agent_run находит ноутбук", function()
        local path = vim.fn.tempname() .. ".py"
        vim.fn.writefile({ '# %% jncell="aa01"', "a = 1" }, path)
        local res = jupyter.agent_open({ notebook = path, kernel = false })
        local s = jupyter.session(res.buf)
        s.started = true
        local sent = {}
        s.kernel.execute = function(_, args)
            table.insert(sent, args)
        end
        local run = jupyter.agent_run({ notebook = path, cell = "aa01" })
        assert.is_true(run.ok, run.msg)
        assert.equals("a = 1", sent[1].code)
        jupyter.detach(res.buf)
    end)

    it("открыт в другом nvim — отказ с его сокетом, вторую копию не заводит", function()
        local path = vim.fn.tempname() .. ".ipynb"
        vim.fn.mkdir(instances.DIR, "p")
        local key = vim.fn.sha256(vim.fn.resolve(path)):sub(1, 16)
        vim.fn.writefile({ vim.json.encode({ pid = 999999, socket = "/tmp/other.sock", notebook = path }) },
            instances.DIR .. "/" .. key .. "-999999.json")
        instances.alive = function()
            return true
        end
        local res = jupyter.agent_open({ notebook = path, kernel = false })
        assert.is_false(res.ok)
        assert.equals("other_instance", res.reason)
        assert.equals("/tmp/other.sock", res.others[1].socket)
        assert.equals(-1, vim.fn.bufnr(path))
    end)

    it("без пути — no_path", function()
        assert.equals("no_path", jupyter.agent_open({}).reason)
    end)

    if vim.fn.exepath("jupytext") ~= "" then
        it(".ipynb открывается через jupytext markdown-буфером, без окна", function()
            local path = vim.fn.tempname() .. ".ipynb"
            vim.fn.writefile({ vim.json.encode({
                cells = { { cell_type = "code", source = { "x = 1" }, metadata = vim.empty_dict(), outputs = {}, execution_count = vim.NIL } },
                metadata = vim.empty_dict(), nbformat = 4, nbformat_minor = 5,
            }) }, path)
            local cur = vim.api.nvim_get_current_buf()
            -- в изолированном rtp нет парсера markdown, штатный ftplugin падает (как в ipynb_spec)
            vim.o.eventignore = "FileType"
            vim.cmd("runtime! ftdetect/jupyter.lua")
            local res = jupyter.agent_open({ notebook = path, kernel = false })
            vim.o.eventignore = ""
            assert.is_true(res.ok, res.msg)
            assert.equals(cur, vim.api.nvim_get_current_buf())
            assert.equals("markdown", vim.bo[res.buf].filetype)
            assert.is_true(vim.b[res.buf].jupyter_ipynb)
            assert.truthy(table.concat(vim.api.nvim_buf_get_lines(res.buf, 0, -1, false), "\n"):find("x = 1", 1, true))
            jupyter.detach(res.buf)
        end)
    end
end)
