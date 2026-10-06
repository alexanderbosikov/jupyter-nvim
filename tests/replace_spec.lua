-- Правка по тексту и заявка на кусок текста (agent.replace / agent.claim).
--
-- Главное здесь — что правка ложится только туда, где `old` встречается ровно один раз, и
-- что документ после неё остаётся документом: фенсы закрыты, id не задвоены и не потеряны
-- у ячеек, которые остались. Всё проверяется по содержимому буфера.

local agent = require("jupyter.agent")
local cellid = require("jupyter.cellid")

local LINES = {
    "# Отчёт", -- 1
    "Первый абзац.", -- 2
    "", -- 3
    '```python jncell="a3f9"', -- 4
    "x = 1", -- 5
    "```", -- 6
    "", -- 7
    "Вывод: всё сходится.", -- 8
    "", -- 9
    '```sql jncell="b7e1"', -- 10
    "select 1", -- 11
    "```", -- 12
}

local buf

local function make_buf()
    buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, LINES)
    vim.bo[buf].filetype = "markdown"
    return buf
end

local function lines_of()
    return vim.api.nvim_buf_get_lines(buf, 0, -1, false)
end

describe("правка по тексту", function()
    before_each(function()
        agent._reset()
        make_buf()
    end)

    it("правит прозу", function()
        local res = agent.replace(buf, "всё сходится", "расходится на 3%")
        assert.is_true(res.ok)
        assert.equals("Вывод: расходится на 3%.", lines_of()[8])
        assert.equals(8, res.start_row)
    end)

    it("правит код и прозу одной правкой", function()
        local res = agent.replace(buf, "x = 1\n```\n\nВывод: всё сходится.", "x = 2\n```\n\nВывод: теперь два.")
        assert.is_true(res.ok)
        assert.equals("x = 2", lines_of()[5])
        assert.equals("Вывод: теперь два.", lines_of()[8])
    end)

    it("текста нет — отказ, буфер не тронут", function()
        local res = agent.replace(buf, "такого нет", "что-то")
        assert.is_false(res.ok)
        assert.equals("not_found", res.reason)
        assert.same(LINES, lines_of())
    end)

    it("текст встречается дважды — отказ: не угадываем, какой из двух", function()
        local res = agent.replace(buf, "```", "")
        assert.is_false(res.ok)
        assert.equals("ambiguous", res.reason)
        assert.same(LINES, lines_of())
    end)

    it("незакрытый фенс — отказ: весь текст ниже стал бы кодом", function()
        local res = agent.replace(buf, "x = 1\n```", "x = 1")
        assert.is_false(res.ok)
        assert.equals("fences", res.reason)
        assert.same(LINES, lines_of())
    end)

    it("скопированная строка фенса с id — отказ: две ячейки делили бы историю", function()
        local res = agent.replace(buf, "Вывод: всё сходится.", '```python jncell="a3f9"\ny = 2\n```')
        assert.is_false(res.ok)
        assert.equals("duplicate_id", res.reason)
    end)

    it("id пропал, а ячейка осталась — отказ", function()
        local res = agent.replace(buf, '```python jncell="a3f9"', "```python")
        assert.is_false(res.ok)
        assert.equals("id_lost", res.reason)
        assert.same(LINES, lines_of())
    end)

    it("удалить ячейку целиком можно: её id уходит вместе с ней", function()
        local res = agent.replace(buf, '```python jncell="a3f9"\nx = 1\n```\n\n', "")
        assert.is_true(res.ok)
        assert.is_nil(cellid.find(buf, "a3f9"))
        assert.equals("Вывод: всё сходится.", lines_of()[4])
    end)

    it("новая ячейка сразу получает id", function()
        local res = agent.replace(buf, "Вывод: всё сходится.", "Вывод: всё сходится.\n\n```python\ny = 2\n```")
        assert.is_true(res.ok)
        local fence = lines_of()[10]
        assert.is_truthy(cellid.parse(fence), "у новой ячейки есть jncell: " .. fence)
    end)

    it("одна правка — один шаг undo, вместе с проставленным id", function()
        vim.api.nvim_buf_call(buf, function()
            vim.cmd("let &undolevels = &undolevels")
        end)
        agent.replace(buf, "Вывод: всё сходится.", "Вывод.\n\n```python\ny = 2\n```")
        vim.api.nvim_buf_call(buf, function()
            vim.cmd("silent undo")
        end)
        assert.same(LINES, lines_of())
    end)

    it("правка в заявке продлевает её и снимает «отправлено»", function()
        local claim = agent.claim(buf, { from = 8, to = 8, pending = true, title = "перепиши вывод" })
        local before = agent.list(buf)[1]
        vim.wait(20)
        agent.replace(buf, "всё сходится", "нет")
        local after = agent.list(buf)[1]
        assert.equals(claim.token, after.token)
        assert.is_true(after.left_ms >= before.left_ms - 5, "срок продлён")
        assert.equals(agent.LABEL, after.label)
    end)
end)

describe("заявка на кусок текста", function()
    before_each(function()
        agent._reset()
        make_buf()
    end)

    it("задевшая ячейку расширяется до неё целиком", function()
        local res = agent.claim(buf, { from = 8, to = 11 })
        assert.is_true(res.ok)
        assert.equals(8, res.start_row)
        assert.equals(12, res.end_row)
        assert.same({ "b7e1" }, res.cells)
    end)

    it("ячейки внутри не запускаются", function()
        agent.claim(buf, { from = 2, to = 5 })
        assert.is_truthy(agent.claim_of(buf, "a3f9"))
        assert.is_nil(agent.claim_of(buf, "b7e1"))
    end)

    it("по тексту: ставится туда, где он встречается", function()
        local res = agent.claim(buf, { text = "Вывод: всё" })
        assert.is_true(res.ok)
        assert.equals(8, res.start_row)
        assert.equals(8, res.end_row)
    end)

    it("второй заявки на тот же кусок нет — отказ с номером первой", function()
        local first = agent.claim(buf, { from = 1, to = 2 })
        local second = agent.claim(buf, { from = 2, to = 8 })
        assert.is_false(second.ok)
        assert.equals("claimed", second.reason)
        assert.equals(first.token, second.token)
    end)

    it("кусок ровно в одну ячейку берётся и по-старому, edit_adopt", function()
        local claim = agent.claim(buf, { from = 4, to = 6, pending = true })
        local res = agent.adopt(claim.token, { label = "Claude" })
        assert.is_true(res.ok)
        assert.equals("a3f9", res.cell_id)
        assert.is_true(agent.apply(claim.token, { "x = 42" }).ok)
        assert.equals("x = 42", lines_of()[5])
    end)

    it("кусок из прозы и кода adopt не берёт: его правят replace", function()
        local claim = agent.claim(buf, { from = 2, to = 6 })
        local res = agent.adopt(claim.token)
        assert.is_false(res.ok)
        assert.equals("not_a_cell", res.reason)
    end)

    it("done снимает метку", function()
        local claim = agent.claim(buf, { from = 8, to = 8 })
        assert.is_true(agent.done(claim.token).ok)
        assert.equals(0, #agent.list(buf))
        assert.equals(0, #vim.api.nvim_buf_get_extmarks(buf, agent.NS, 0, -1, {}))
    end)
end)

describe("правка из файлов", function()
    it("old и new читаются из файлов, последний перевод строки не в счёт", function()
        agent._reset()
        make_buf()
        local jn = require("jupyter")
        local dir = vim.fn.tempname()
        vim.fn.mkdir(dir, "p")
        vim.fn.writefile({ "x = 1" }, dir .. "/old")
        vim.fn.writefile({ "x = 2", "y = \"кавычки\"" }, dir .. "/new")
        local res = jn.edit_replace_files(dir .. "/old", dir .. "/new", { buf = buf })
        assert.is_true(res.ok, vim.inspect(res))
        assert.equals("x = 2", lines_of()[5])
        assert.equals('y = "кавычки"', lines_of()[6])
        assert.equals("```", lines_of()[7])
        vim.fn.delete(dir, "rf")
    end)
end)
