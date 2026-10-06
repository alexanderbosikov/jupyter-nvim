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
    ask.PANES_DIR = dir .. "/panes"
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
    ask.PANES_DIR = nil
    pcall(vim.fn.delete, dir, "rf")
end

describe("адрес промпта", function()
    before_each(enter)
    after_each(leave)

    it("курсор в ячейке — кусок это она, с фенсами", function()
        local addr = ask.address(buf, { row = 4 })
        assert.equals(nb, addr.notebook)
        assert.equals(3, addr.from)
        assert.equals(5, addr.to)
        assert.equals(1, #addr.cells)
        assert.equals("a3f9", addr.cells[1].id)
        assert.equals("python", addr.cells[1].lang)
        assert.equals(4, addr.cells[1].start_row)
        assert.is_false(addr.prose)
        assert.equals("a3f9", ask.cell_of(addr))
    end)

    it("ячейке без jncell проставляет его: иначе её нечем назвать", function()
        local addr = ask.address(buf, { row = 8 })
        local id = addr.cells[1].id
        assert.is_truthy(id)
        local marker = vim.api.nvim_buf_get_lines(buf, 6, 7, false)[1]
        assert.is_truthy(marker:match('jncell="' .. id .. '"'), "id уехал в документ")
        assert.is_true(agent.begin(buf, { cell = id }).ok)
    end)

    it("курсор в прозе — кусок это абзац под ним", function()
        local addr = ask.address(buf, { row = 1 })
        assert.equals(1, addr.from)
        assert.equals(1, addr.to)
        assert.is_true(addr.prose)
        assert.equals(0, #addr.cells)
    end)

    it("курсор на пустой строке — куска нет, вопрос про весь ноутбук", function()
        local addr = ask.address(buf, { row = 6 })
        assert.is_nil(addr.from)
    end)

    it("выделение прозы и ячейки расширяется до ячейки целиком", function()
        local addr = ask.address(buf, { selection = { from = 1, to = 4 } })
        assert.equals(1, addr.from)
        assert.equals(5, addr.to, "до закрывающего фенса")
        assert.is_true(addr.prose)
        assert.equals("a3f9", addr.cells[1].id)
        assert.is_nil(ask.cell_of(addr), "это не одна ячейка")
    end)

    it("вопрос про весь ноутбук куска не берёт", function()
        local addr = ask.address(buf, { row = 4, scope = "notebook" })
        assert.is_nil(addr.from)
        assert.equals(0, #addr.cells)
    end)

    it("вывод ячейки берёт из истории и говорит, что он устарел", function()
        local addr = ask.address(buf, {
            row = 4,
            store = fake_store({ run_id = 7, kind = "table", rows = 1204, cols = 8, code_sha = "деадбиф" }),
        })
        local output = addr.cells[1].output
        assert.equals("table", output.kind)
        assert.equals(1204, output.rows)
        assert.is_true(output.stale, "код правили после прогона")
    end)
end)

describe("шапка промпта", function()
    before_each(enter)
    after_each(leave)

    local function header(addr, token, opts)
        return table.concat(ask.header(addr, token, opts), "\n")
    end
    local function dirname()
        return vim.fn.fnamemodify(dir, ":t")
    end

    it("одна ячейка — её id, язык и строки тела", function()
        local first = ask.header(ask.address(buf, { row = 4 }), 7, { remembered = true })[1]
        assert.equals("[jupyter.nvim] " .. dirname() .. "/01_eda.ipynb · ячейка a3f9 · python · строки 4–4", first)
    end)

    it("проза и ячейка — строки куска и что в нём", function()
        local first = ask.header(ask.address(buf, { selection = { from = 1, to = 4 } }), 7, { remembered = true })[1]
        assert.equals("[jupyter.nvim] " .. dirname() .. "/01_eda.ipynb · строки 1–5: проза и ячейка a3f9", first)
    end)

    it("без куска — весь ноутбук, и ни слова о заявке", function()
        local text = header(ask.address(buf, { row = 4, scope = "notebook" }), nil, { remembered = true })
        assert.is_truthy(text:find("весь ноутбук", 1, true))
        assert.is_nil(text:find("заявк", 1, true))
    end)

    it("адрес в файле панели — ни пути, ни сокета, ни номера заявки в шапке", function()
        local addr = ask.address(buf, { row = 4 })
        addr.socket = "/tmp/nvim.1.0"
        local lines = ask.header(addr, 7, { remembered = true })
        assert.equals(1, #lines)
    end)

    it("файл панели не записался — путь, сокет и заявка едут в шапке", function()
        local addr = ask.address(buf, { row = 4 })
        addr.socket = "/tmp/nvim.1.0"
        local text = header(addr, 7, { remembered = false })
        assert.is_truthy(text:find("ноутбук: " .. nb, 1, true))
        assert.is_truthy(text:find("сокет nvim: /tmp/nvim.1.0", 1, true))
        assert.is_truthy(text:find("заявка: 7", 1, true))
    end)

    it("выделение части ячейки называет, выделение всей — нет", function()
        local addr = { notebook = nb, from = 9, to = 21, prose = false, cells = {
            { id = "a3f9", lang = "python", start_row = 10, end_row = 20 },
        } }
        addr.selection = { from = 12, to = 14 }
        assert.is_truthy(header(addr, 1, { remembered = true }):match("выделено 12–14"))
        addr.selection = { from = 10, to = 20 }
        assert.is_nil(header(addr, 1, { remembered = true }):match("выделено"))
    end)

    it("путь к выводу — от каталога ноутбука", function()
        local addr = ask.address(buf, {
            row = 4,
            store = fake_store({ run_id = 7, kind = "table", rows = 42, cols = 10 }),
        })
        assert.is_truthy(header(addr, 1, { remembered = true }):find("вывод: runs/7.parquet · table · 42×10", 1, true))
    end)

    it("выводов много — называет три, остальные отсылает в снимок", function()
        local addr = { notebook = nb, from = 1, to = 50, prose = true, cells = {} }
        for i = 1, 5 do
            table.insert(addr.cells, { id = "c" .. i, lang = "python", start_row = i * 10, end_row = i * 10 + 1,
                output = { path = dir .. "/o" .. i .. ".parquet", kind = "table" } })
        end
        local text = header(addr, 1, { remembered = true })
        assert.is_truthy(text:find("вывод c3: o3.parquet", 1, true))
        assert.is_nil(text:find("вывод c4", 1, true))
        assert.is_truthy(text:find("ещё 2 выводов", 1, true))
    end)
end)

describe("файл панели", function()
    before_each(enter)
    after_each(leave)

    local function read(id)
        return vim.json.decode(table.concat(vim.fn.readfile(ask.PANES_DIR .. "/" .. id .. ".json"), "\n"))
    end

    ---Сокет, который «жив»: файл на диске. remember проверяет только, что он есть.
    local function live_socket(name)
        local path = dir .. "/" .. name
        vim.fn.writefile({}, path)
        return path
    end

    it("кладёт адрес ноутбука под id панели", function()
        local sock = live_socket("nvim.1.0")
        assert.is_true(ask.remember("%19", { notebook = nb, socket = sock }, 1000))
        assert.same({ [nb] = { socket = sock, at = 1000 } }, read("%19"))
    end)

    it("второй ноутбук в ту же панель не затирает первый", function()
        local a, b = live_socket("nvim.1.0"), live_socket("nvim.2.0")
        ask.remember("w4:p2", { notebook = nb, socket = a }, 1000)
        ask.remember("w4:p2", { notebook = dir .. "/02_funnel.ipynb", socket = b }, 1010)
        local entries = read("w4:p2")
        assert.equals(a, entries[nb].socket)
        assert.equals(b, entries[dir .. "/02_funnel.ipynb"].socket)
    end)

    it("выбрасывает записи закрытых nvim и слишком старые", function()
        local sock = live_socket("nvim.1.0")
        ask.remember("%19", { notebook = dir .. "/closed.ipynb", socket = dir .. "/нет.0" }, 1000)
        ask.remember("%19", { notebook = dir .. "/old.ipynb", socket = sock }, 1000)
        ask.remember("%19", { notebook = nb, socket = sock }, 1000 + ask.PANE_TTL + 1)
        local entries = read("%19")
        assert.is_nil(entries[dir .. "/closed.ipynb"], "сокета нет — nvim закрыт")
        assert.is_nil(entries[dir .. "/old.ipynb"], "старше недели")
        assert.is_truthy(entries[nb])
    end)

    it("без сокета не пишет ничего: адрес без него бесполезен", function()
        assert.is_false(ask.remember("%19", { notebook = nb }))
        assert.equals(0, vim.fn.filereadable(ask.PANES_DIR .. "/%19.json"))
    end)
end)

describe("отправка", function()
    before_each(enter)
    after_each(leave)

    it("открывает заявку до отправки: её номер уже в тексте промпта", function()
        local res = ask.send(buf, "перепиши на polars", { row = 4, store = fake_store() })

        assert.is_truthy(res.token)
        assert.equals("a3f9", res.cell_id)
        assert.is_nil(sent:find("заявка", 1, true), "номер заявки — в файле панели, не в шапке")
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

    it("оставляет адрес в файле панели, и шапка обходится без пути и сокета", function()
        ask.send(buf, "проверь полноту", { row = 4, store = fake_store() })

        local file = ask.PANES_DIR .. "/%19.json"
        local entries = vim.json.decode(table.concat(vim.fn.readfile(file), "\n"))
        assert.equals(vim.v.servername, entries[nb].socket)
        assert.equals(agent.list(buf)[1].token, entries[nb].claim, "агенту — номер заявки, чтобы её снять")
        assert.is_nil(sent:find("сокет", 1, true))
        assert.is_nil(sent:find("ноутбук: ", 1, true))
    end)

    it("вопрос про весь ноутбук уходит без заявки", function()
        local res = ask.send(buf, "напиши выводы", { row = 4, scope = "notebook", store = fake_store() })

        assert.is_nil(res.token)
        assert.equals(0, #agent.list(buf), "метить нечего: вопрос не про ячейку")
        assert.is_truthy(sent:find("весь ноутбук", 1, true))
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
