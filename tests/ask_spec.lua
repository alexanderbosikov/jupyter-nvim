-- Промпт агенту из ноутбука.
--
-- Главное здесь — порядок: заявка открывается ДО отправки и снимается, если отправить не
-- удалось. Метка, за которой никого нет, врёт хуже, чем её отсутствие, — поэтому tmux
-- подменён так, чтобы отказ можно было устроить нарочно.

local agent = require("jupyter.agent")
local ask = require("jupyter.ask")
local pane = require("jupyter.pane")

local LINES = {
    "# Отчёт", -- 1
    "", -- 2
    '```python jncell="a3f9"', -- 3
    "df = read()", -- 4
    "```", -- 5
    "", -- 6
    "```python", -- 7  ячейка без id: его ещё не проставляли
    "y = 2", -- 8
    "```", -- 9
}

local dir, nb, buf, sent, real_find, real_send

---Лавка вместо настоящего .jupyter-out: ask.lua зовёт у истории ровно три метода.
local function fake_store(record)
    return {
        base = dir,
        notebook = nb,
        load = function() end,
        last_record = function()
            return record
        end,
        path_of = function(_, r)
            return r and (dir .. "/runs/" .. r.run_id .. ".parquet") or nil
        end,
    }
end

local function make_buf()
    buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, LINES)
    vim.api.nvim_buf_set_name(buf, nb)
    -- имя обратно из буфера: на macOS /var — симлинк на /private/var, и nvim отдаёт
    -- разрешённый путь. Сверять адрес с тем, что мы задумали, а не с тем, что он видит,
    -- значило бы проверять симлинки
    nb = vim.api.nvim_buf_get_name(buf)
    vim.bo[buf].filetype = "markdown"
    return buf
end

local function enter()
    agent._reset()
    dir = vim.fn.tempname()
    vim.fn.mkdir(dir, "p")
    nb = dir .. "/01_eda.ipynb"
    make_buf()
    sent = nil
    real_find, real_send = pane.find, pane.send
    pane.find = function()
        return "%19", "рядом в окне", {}
    end
    pane.send = function(_, text)
        sent = text
        return true, nil
    end
end

local function leave()
    pane.find, pane.send = real_find, real_send
    pcall(vim.fn.delete, dir, "rf")
end

describe("адрес промпта", function()
    before_each(enter)
    after_each(leave)

    it("называет ноутбук, сокет и ячейку под курсором", function()
        local addr = ask.address(buf, { row = 4 })
        assert.equals(nb, addr.notebook)
        assert.equals("a3f9", addr.cell_id)
        assert.equals("python", addr.lang)
        assert.equals(4, addr.start_row)
        assert.equals(4, addr.end_row)
    end)

    it("ячейке без jncell проставляет его: иначе её нечем назвать", function()
        local addr = ask.address(buf, { row = 8 })
        assert.is_truthy(addr.cell_id)
        local marker = vim.api.nvim_buf_get_lines(buf, 6, 7, false)[1]
        assert.is_truthy(marker:match('jncell="' .. addr.cell_id .. '"'), "id уехал в документ")
        -- а раз уехал — заявка эту ячейку теперь находит
        assert.is_true(agent.begin(buf, { cell = addr.cell_id }).ok)
    end)

    it("в прозе ячейки нет — и это не ошибка", function()
        local addr = ask.address(buf, { row = 1 })
        assert.is_nil(addr.cell_id)
        assert.equals(nb, addr.notebook)
    end)

    it("вопрос про весь ноутбук ячейку под курсором не трогает", function()
        local addr = ask.address(buf, { row = 4, scope = "notebook" })
        assert.is_nil(addr.cell_id)
    end)

    it("вывод ячейки берёт из истории и говорит, что он устарел", function()
        local addr = ask.address(buf, {
            row = 4,
            store = fake_store({ run_id = 7, kind = "table", rows = 1204, cols = 8, code_sha = "деадбиф" }),
        })
        assert.equals("table", addr.output.kind)
        assert.equals(1204, addr.output.rows)
        assert.is_true(addr.output.stale, "код правили после прогона")
    end)
end)

describe("шапка промпта", function()
    before_each(enter)
    after_each(leave)

    it("несёт всё, что агенту иначе пришлось бы искать", function()
        local text = table.concat(ask.header(ask.address(buf, { row = 4 }), 7), "\n")
        assert.is_truthy(text:match("jupyter%-nvim"), "назван скилл")
        assert.is_truthy(text:find(nb, 1, true))
        assert.is_truthy(text:match("ячейка: a3f9"))
    end)

    it("велит забрать заявку, а не открывать свою", function()
        local text = table.concat(ask.header(ask.address(buf, { row = 4 }), 7), "\n")
        assert.is_truthy(text:match("edit_adopt%(7%)"))
        assert.is_truthy(text:match("edit_adopt%(7, {after = true}%)"))
        assert.is_truthy(text:match("edit_begin не зови"))
    end)

    it("без заявки говорит об этом прямо", function()
        local text = table.concat(ask.header(ask.address(buf, { row = 1 }), nil), "\n")
        assert.is_truthy(text:match("заявки нет"))
        assert.is_nil(text:match("edit_adopt"))
    end)

    it("выделение внутри ячейки передаёт строками", function()
        local addr = ask.address(buf, { row = 4, selection = { from = 4, to = 4 } })
        local text = table.concat(ask.header(addr, 1), "\n")
        assert.is_truthy(text:match("выделено: строки 4–4"))
    end)
end)

describe("отправка", function()
    before_each(enter)
    after_each(leave)

    it("открывает заявку до отправки: её номер уже в тексте промпта", function()
        local res = ask.send(buf, "перепиши на polars", { row = 4, store = fake_store() })

        assert.is_truthy(res.token)
        assert.equals("a3f9", res.cell_id)
        assert.is_truthy(sent:match("заявка: " .. res.token))
        assert.is_truthy(sent:match("перепиши на polars"), "сам промпт на месте")
        assert.equals(1, #agent.list(buf), "метка стоит в буфере")
    end)

    it("промпт не ушёл — заявка снимается, метка не остаётся врать", function()
        pane.send = function()
            return false, "панели больше нет"
        end
        local res, err = ask.send(buf, "перепиши", { row = 4, store = fake_store() })

        assert.is_nil(res)
        assert.is_truthy(err:match("панели больше нет"))
        assert.equals(0, #agent.list(buf))
    end)

    it("панель не нашлась — заявка не открывается вовсе", function()
        pane.find = function()
            return nil, "сессии агента нет ни в одной панели tmux", {}
        end
        local res, err = ask.send(buf, "перепиши", { row = 4, store = fake_store() })

        assert.is_nil(res)
        assert.is_truthy(err:match("ни в одной панели"))
        assert.equals(0, #agent.list(buf))
        assert.is_nil(sent)
    end)

    it("запоминает панель и пишет промпт в журнал", function()
        local store = fake_store()
        ask.send(buf, "проверь полноту", { row = 4, store = store })

        assert.equals("%19", ask.load_state(store).pane)
        local log = vim.fn.readfile(dir .. "/" .. ask.PROMPTS)
        local entry = vim.json.decode(log[#log])
        assert.equals("проверь полноту", entry.prompt)
        assert.equals("a3f9", entry.cell_id)
    end)

    it("вопрос про весь ноутбук уходит без заявки", function()
        local res = ask.send(buf, "напиши выводы", { row = 4, scope = "notebook", store = fake_store() })

        assert.is_nil(res.token)
        assert.equals(0, #agent.list(buf), "метить нечего: вопрос не про ячейку")
        assert.is_truthy(sent:match("заявки нет"))
    end)

    it("несохранённому буферу отказывает: адресовать нечего", function()
        local blank = vim.api.nvim_create_buf(false, true)
        vim.api.nvim_buf_set_lines(blank, 0, -1, false, LINES)
        local res, err = ask.send(blank, "поправь", { row = 4 })
        assert.is_nil(res)
        assert.is_truthy(err:match("не сохранён"))
    end)

    it("пустой промпт не отправляет", function()
        local res, err = ask.send(buf, "   \n  ", { row = 4, store = fake_store() })
        assert.is_nil(res)
        assert.is_truthy(err:match("пустой"))
        assert.is_nil(sent)
    end)
end)

describe("окно промпта", function()
    before_each(enter)
    after_each(leave)

    it("набранное отправляется, окно закрывается", function()
        local win = ask.open(buf, { row = 4, store = fake_store(), insert = false })
        local prompt_buf = vim.api.nvim_win_get_buf(win)
        vim.api.nvim_buf_set_lines(prompt_buf, 0, -1, false, { "перепиши на polars", "и добавь окно по дате" })

        vim.api.nvim_set_current_win(win)
        vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<CR>", true, false, true), "x", false)

        assert.is_false(vim.api.nvim_win_is_valid(win), "окно закрылось")
        assert.is_truthy(sent:match("перепиши на polars"))
        assert.is_truthy(sent:match("и добавь окно по дате"), "многострочный промпт цел")
    end)

    it("пустой промпт окно не закрывает: человек ещё не дописал", function()
        local win = ask.open(buf, { row = 4, store = fake_store(), insert = false })
        vim.api.nvim_set_current_win(win)
        vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<CR>", true, false, true), "x", false)

        assert.is_true(vim.api.nvim_win_is_valid(win))
        assert.is_nil(sent)
        pcall(vim.api.nvim_win_close, win, true)
    end)

    it("q закрывает, ничего не отправив", function()
        local win = ask.open(buf, { row = 4, store = fake_store(), insert = false })
        local prompt_buf = vim.api.nvim_win_get_buf(win)
        vim.api.nvim_buf_set_lines(prompt_buf, 0, -1, false, { "передумал" })

        vim.api.nvim_set_current_win(win)
        vim.api.nvim_feedkeys("q", "x", false)

        assert.is_false(vim.api.nvim_win_is_valid(win))
        assert.is_nil(sent)
        assert.equals(0, #agent.list(buf), "заявку не открывали")
    end)
end)
