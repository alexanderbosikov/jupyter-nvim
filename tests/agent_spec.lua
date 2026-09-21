-- Правка ноутбука внешним агентом. Главное здесь — не запись строк, а то, что документ
-- живёт между заявкой и применением: проверяется поведение при сдвиге, перестановке и
-- чужой правке той же ячейки. Всё проверяется по содержимому буфера, а не по структурам.

local agent = require("jupyter.agent")

local LINES = {
    "# Отчёт", -- 1
    "", -- 2
    '```python jncell="a3f9"', -- 3
    "x = 1", -- 4
    "```", -- 5
    "", -- 6
    '```sql jncell="b7e1"', -- 7
    "select 1", -- 8
    "```", -- 9
}

local function make_buf()
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, LINES)
    vim.bo[buf].filetype = "markdown"
    return buf
end

local function lines_of(buf)
    return vim.api.nvim_buf_get_lines(buf, 0, -1, false)
end

local function marks_of(buf)
    return vim.api.nvim_buf_get_extmarks(buf, agent.NS, 0, -1, { details = true })
end

local function signs_of(buf)
    return vim.api.nvim_buf_get_extmarks(buf, agent.NS_SIGN, 0, -1, { details = true })
end

---Виртуальные строки рамки: их текст и на какой строке буфера каждая висит.
local function frame_of(buf)
    local out = {}
    for _, m in ipairs(vim.api.nvim_buf_get_extmarks(buf, agent.NS_FRAME, 0, -1, { details = true })) do
        table.insert(out, {
            row = m[2] + 1,
            above = m[4].virt_lines_above == true,
            text = m[4].virt_lines[1][1][1],
            group = m[4].virt_lines[1][1][2],
        })
    end
    -- у однострочной ячейки обе рамки сидят на одной строке, и порядок выдачи extmark'ов
    -- об их смысле ничего не говорит: раскладываем сами — сверху, потом снизу
    table.sort(out, function(a, b)
        if a.row ~= b.row then
            return a.row < b.row
        end
        return a.above and not b.above
    end)
    return out
end

describe("заявка на правку", function()
    local buf

    before_each(function()
        agent._reset()
        buf = make_buf()
    end)

    it("пишет по якорю, а не по номерам строк из заявки", function()
        local req = agent.begin(buf, { cell = "a3f9" })
        assert.equals(4, req.start_row)

        -- пока агент думал, пользователь дописал три строки выше
        vim.api.nvim_buf_set_lines(buf, 0, 0, false, { "проза", "ещё", "и ещё" })
        local res = agent.apply(req.token, { "x = 2" })

        assert.is_true(res.ok)
        assert.equals(7, res.start_row, "ячейка уехала на три строки вниз — туда и пишем")
        assert.same("x = 2", lines_of(buf)[7])
    end)

    it("находит ячейку после перестановки: extmark остался бы на соседе", function()
        local req = agent.begin(buf, { cell = "a3f9" })

        local moved = vim.api.nvim_buf_get_lines(buf, 2, 5, false) -- ячейку целиком
        vim.api.nvim_buf_set_lines(buf, 2, 5, false, {})
        vim.api.nvim_buf_set_lines(buf, -1, -1, false, moved)
        local res = agent.apply(req.token, { "x = 3" })

        assert.is_true(res.ok)
        local text = lines_of(buf)
        assert.equals("x = 3", text[#text - 1], "ячейка теперь в конце — там и правка")
        assert.equals("select 1", text[5], "соседнюю ячейку не тронули")
    end)

    it("отказывается писать, если ячейку правили после заявки", function()
        local req = agent.begin(buf, { cell = "a3f9" })
        vim.api.nvim_buf_set_lines(buf, 3, 4, false, { "x = 1  # правка руками" })

        local res = agent.apply(req.token, { "x = 999" })

        assert.is_false(res.ok)
        assert.equals("changed", res.reason)
        assert.equals("x = 1  # правка руками", lines_of(buf)[4], "чужой текст остался на месте")
    end)

    it("отказывается писать, если ячейка исчезла", function()
        local req = agent.begin(buf, { cell = "a3f9" })
        vim.api.nvim_buf_set_lines(buf, 2, 5, false, {})

        local res = agent.apply(req.token, { "x = 999" })

        assert.is_false(res.ok)
        assert.equals("cell_gone", res.reason)
    end)

    it("вставляет ячейку после названной, наследуя её язык", function()
        local req = agent.begin(buf, { after = "b7e1" })

        local res = agent.apply(req.token, { "select 2" })

        assert.is_true(res.ok)
        local text = lines_of(buf)
        assert.equals("```sql", text[11], "за sql-ячейкой появляется sql-ячейка")
        assert.equals("select 2", text[12])
        assert.equals("```", text[13])
    end)

    it("многострочный элемент не разваливает запись", function()
        local req = agent.begin(buf, { cell = "a3f9" })

        agent.apply(req.token, { "x = 1\ny = 2" })

        assert.same({ "x = 1", "y = 2" }, vim.api.nvim_buf_get_lines(buf, 3, 5, false))
    end)
end)

describe("пометка в буфере", function()
    local buf

    before_each(function()
        agent._reset()
        buf = make_buf()
    end)

    it("держится, пока заявка открыта, и уходит после применения", function()
        local req = agent.begin(buf, { cell = "a3f9", label = "Claude" })

        local marks = marks_of(buf)
        assert.equals(1, #marks)
        local details = marks[1][4]
        assert.equals("JupyterAgentPending", details.hl_group)
        assert.equals(3, marks[1][2], "область — тело ячейки: 4-я строка, 0-based 3")

        local frame = frame_of(buf)
        assert.equals(2, #frame, "кусок обведён сверху и снизу")
        assert.is_truthy(frame[1].text:find("Claude правит"), "подпись: " .. frame[1].text)
        assert.equals(frame[1].text, frame[2].text, "снизу та же подпись, что сверху")
        -- обе цепляются за строку НИЖЕ той, под которой рисуются: строка закрывающего
        -- фенса скрыта render-markdown, а на скрытой строке virt_lines не рисуются
        assert.same({ 4, 6 }, { frame[1].row, frame[2].row }, "якоря: тело и строка за фенсом")
        assert.is_true(frame[1].above and frame[2].above)
        for _, line in ipairs(frame) do
            assert.are_not.equals(5, line.row, "фенс — скрытая строка, якорем быть не может")
        end

        agent.apply(req.token, { "x = 2" })
        assert.equals(0, #marks_of(buf))
        assert.equals(0, #frame_of(buf), "рамка уходит вместе с заявкой")
    end)

    it("уходит и при отмене, и при отказе", function()
        local cancelled = agent.begin(buf, { cell = "a3f9" })
        agent.cancel(cancelled.token)
        assert.equals(0, #marks_of(buf))

        local refused = agent.begin(buf, { cell = "a3f9" })
        vim.api.nvim_buf_set_lines(buf, 3, 4, false, { "x = 7" })
        agent.apply(refused.token, { "x = 8" })
        assert.equals(0, #marks_of(buf))
    end)

    it("перерисовка статусов её не сносит: namespace свой", function()
        local status = require("jupyter.ui.status")
        agent.begin(buf, { cell = "a3f9" })

        status.new({}):render(buf, { { row = 4, text = "✓ 0.1 с", group = "JupyterWinBar" } })

        assert.equals(1, #marks_of(buf), "статусы чистят свой namespace целиком")
    end)

    it("вставка помечает место призраком будущей ячейки", function()
        agent.begin(buf, { after = "a3f9", label = "Claude" })

        local ghost = frame_of(buf)
        assert.equals(1, #ghost, "обводить нечего: ячейки ещё нет, есть место под неё")
        assert.is_truthy(ghost[1].text:find("пишет новую ячейку"))
        -- строка 6 — пустая между ячейками; статус предыдущей висит над ней, подпись под
        assert.equals(6, ghost[1].row, "подпись за фенсом, а не на нём")
        assert.is_false(ghost[1].above, "и снизу пустой строки, чтобы не спорить со статусом")

        local anchor = marks_of(buf)[1]
        assert.equals(4, anchor[2], "якорь записи остался на конце ячейки (0-based 4)")
        assert.is_nil(anchor[4].virt_lines, "якорь ничего не рисует: он только место вставки")
    end)
end)

describe("undo", function()
    it("правка агента откатывается одна, не унося ввод пользователя", function()
        agent._reset()
        local buf = make_buf()
        vim.api.nvim_set_current_buf(buf)

        vim.api.nvim_buf_set_lines(buf, 0, 1, false, { "# Отчёт правленый" }) -- правка руками
        local req = agent.begin(buf, { cell = "a3f9" })
        agent.apply(req.token, { "x = 42" })
        assert.equals("x = 42", lines_of(buf)[4])

        vim.cmd("undo")

        assert.equals("x = 1", lines_of(buf)[4], "откатилась правка агента")
        assert.equals("# Отчёт правленый", lines_of(buf)[1], "правка пользователя осталась")
    end)
end)

describe("список заявок", function()
    it("показывает открытые и снимается разом", function()
        agent._reset()
        local buf = make_buf()
        agent.begin(buf, { cell = "a3f9" })
        agent.begin(buf, { after = "b7e1" })

        local list = agent.list(buf)
        assert.equals(2, #list)
        assert.same({ "replace", "insert" }, { list[1].kind, list[2].kind })

        assert.equals(2, agent.cancel_all(buf))
        assert.equals(0, #agent.list(buf))
        assert.equals(0, #marks_of(buf))
    end)
end)

describe("срок жизни заявки", function()
    local buf

    before_each(function()
        agent._reset()
        buf = make_buf()
        -- буфер должен быть на экране: скрытый плагин не перерисовывает намеренно
        vim.api.nvim_set_current_buf(buf)
    end)

    ---Перехватить vim.notify на время вызова: заявка снимается не молча.
    local function with_notify(fn)
        local said = {}
        local notify = vim.notify
        vim.notify = function(msg) table.insert(said, msg) end
        local ok, err = pcall(fn)
        vim.notify = notify
        assert.is_true(ok, tostring(err))
        return said
    end

    it("снимается сама, когда о ней давно нет вестей", function()
        local req = agent.begin(buf, { cell = "a3f9", ttl_ms = 50, label = "Claude" })
        assert.equals(1, #marks_of(buf), "метка стоит, пока агент думает")

        local said = with_notify(function()
            agent.sweep(vim.uv.now() + 500)
        end)

        assert.equals(0, #marks_of(buf), "метка не должна держать ячейку после смерти агента")
        assert.equals(0, #agent.list(buf))
        assert.is_truthy(said[1]:match("Claude"), "о снятии сказано вслух: " .. tostring(said[1]))
        local res = agent.apply(req.token, { "x = 2" })
        assert.is_false(res.ok, "по снятой заявке не пишем")
        assert.equals("expired", res.reason, "«сняли по сроку» и «нет такой» — разные ответы")
        assert.equals("x = 1", lines_of(buf)[4])
    end)

    it("touch продлевает: агент думает дольше срока, но жив", function()
        local req = agent.begin(buf, { cell = "a3f9", ttl_ms = 1000 })

        -- «я ещё здесь» — и отсчёт идёт от этого момента, а не от начала
        assert.is_true(agent.touch(req.token).ok)
        agent.sweep(vim.uv.now() + 800)

        assert.equals(1, #marks_of(buf), "заявка с вестями не снимается")
        assert.is_true(agent.apply(req.token, { "x = 2" }).ok)
        assert.equals("x = 2", lines_of(buf)[4])
    end)

    it("в метке тикает возраст и крутится колесо: видно, что агент работает, а не замер", function()
        agent.begin(buf, { cell = "a3f9", label = "Claude" })
        local now = vim.uv.now()

        agent.sweep(now + 7000)
        local at7 = frame_of(buf)[1]
        agent.sweep(now + 7000 + agent.TICK_MS)
        local next_tick = frame_of(buf)[1]

        assert.is_truthy(at7.text:find("Claude правит · 7с"), "подпись: " .. at7.text)
        assert.equals("JupyterAgentText", at7.group)
        assert.are_not.equals(at7.text:sub(1, 4), next_tick.text:sub(1, 4), "колесо должно провернуться")
    end)

    it("к концу срока метка предупреждает цветом", function()
        agent.begin(buf, { cell = "a3f9", ttl_ms = 1000 })

        agent.sweep(vim.uv.now() + 900)

        assert.equals("JupyterAgentStale", frame_of(buf)[1].group)
    end)

    it("список говорит, сколько заявка держит ячейку и сколько ей осталось", function()
        agent.begin(buf, { cell = "a3f9", ttl_ms = 60000 })

        local entry = agent.list(buf)[1]

        assert.is_true(entry.age_ms >= 0)
        assert.is_true(entry.left_ms > 0 and entry.left_ms <= 60000)
    end)
end)

describe("знак в signcolumn", function()
    local buf

    before_each(function()
        agent._reset()
        buf = make_buf()
        vim.api.nvim_set_current_buf(buf)
    end)

    it("стоит на каждой строке заявленной ячейки и уходит вместе с заявкой", function()
        local req = agent.begin(buf, { cell = "a3f9" })

        local signs = signs_of(buf)
        assert.equals(1, #signs, "ячейка в одну строку — один знак")
        assert.equals("✎ ", signs[1][4].sign_text)
        assert.equals(3, signs[1][2], "знак на строке тела (0-based), а не на фенсе")

        agent.apply(req.token, { "x = 2" })
        assert.equals(0, #signs_of(buf), "заявки нет — знака нет")
    end)

    it("у вставки знак стоит там, где появится ячейка", function()
        local req = agent.begin(buf, { after = "a3f9" })

        assert.equals(1, #signs_of(buf))

        agent.cancel(req.token)
        assert.equals(0, #signs_of(buf))
    end)

    it("к концу срока знак предупреждает тем же цветом, что и подпись", function()
        agent.begin(buf, { cell = "a3f9", ttl_ms = 1000 })

        agent.sweep(vim.uv.now() + 900)

        assert.equals("JupyterAgentStale", signs_of(buf)[1][4].sign_hl_group)
    end)

    it("выключается настройкой: signcolumn бывает занят", function()
        local sign = agent.SIGN
        agent.SIGN = nil

        agent.begin(buf, { cell = "a3f9" })

        assert.equals(0, #signs_of(buf))
        assert.equals(1, #marks_of(buf), "сама метка при этом остаётся")
        agent.SIGN = sign
    end)
end)

describe("скрытый буфер", function()
    it("не перерисовывается, но срок ему всё равно идёт", function()
        agent._reset()
        local buf = make_buf() -- ни в одном окне
        local req = agent.begin(buf, { cell = "a3f9", ttl_ms = 50 })
        local before = vim.api.nvim_buf_get_extmarks(buf, agent.NS_FRAME, 0, -1, { details = true })[1]

        agent.sweep(vim.uv.now() + 20)
        local after = vim.api.nvim_buf_get_extmarks(buf, agent.NS_FRAME, 0, -1, { details = true })[1]
        assert.equals(
            before[4].virt_lines[1][1][1],
            after[4].virt_lines[1][1][1],
            "колесо крутится для глаза, а глаза тут нет"
        )

        local notify = vim.notify
        vim.notify = function() end
        agent.sweep(vim.uv.now() + 500)
        vim.notify = notify

        assert.equals(0, #agent.list(buf), "срок заявки не зависит от того, смотрят ли на неё")
        assert.equals("expired", agent.apply(req.token, { "x = 2" }).reason)
    end)
end)

describe("метки не копятся", function()
    local buf

    before_each(function()
        agent._reset()
        buf = make_buf()
        vim.api.nvim_set_current_buf(buf)
    end)

    local function frame_count()
        return #vim.api.nvim_buf_get_extmarks(buf, agent.NS_FRAME, 0, -1, {})
    end

    it("у вставки подпись одна, сколько бы тиков ни прошло", function()
        agent.begin(buf, { after = "a3f9" })
        assert.equals(1, frame_count())

        local now = vim.uv.now()
        for i = 1, 20 do
            agent.sweep(now + i * agent.TICK_MS)
        end

        assert.equals(1, frame_count(), "каждый тик рисует заново, а не добавляет")
    end)

    it("у правки подписи ровно две", function()
        local req = agent.begin(buf, { cell = "a3f9" })

        local now = vim.uv.now()
        for i = 1, 20 do
            agent.sweep(now + i * agent.TICK_MS)
        end

        assert.equals(2, frame_count())
        agent.cancel(req.token)
        assert.equals(0, frame_count(), "снятая заявка не оставляет ничего")
    end)
end)

describe("вставка в самый конец файла", function()
    local buf

    before_each(function()
        agent._reset()
        buf = make_buf()
        vim.api.nvim_set_current_buf(buf)
    end)

    it("дописывает пустую строку, чтобы подпись встала ПОД ячейкой, и убирает её обратно", function()
        local total = vim.api.nvim_buf_line_count(buf)

        local req = agent.begin(buf, { after = "b7e1", label = "Claude" })

        assert.equals(total + 1, vim.api.nvim_buf_line_count(buf), "появилась строка под фенсом")
        local ghost = frame_of(buf)[1]
        assert.equals(total + 1, ghost.row, "подпись цепляется за неё, а не за скрытый фенс")
        assert.is_false(ghost.above, "и рисуется под ней — ниже всего документа")

        agent.cancel(req.token)
        assert.equals(total, vim.api.nvim_buf_line_count(buf), "документ вернулся как был")
    end)

    it("вставку в середину документа не трогает: там подписи есть за что зацепиться", function()
        local total = vim.api.nvim_buf_line_count(buf)

        agent.begin(buf, { after = "a3f9" })

        assert.equals(total, vim.api.nvim_buf_line_count(buf))
    end)

    it("чужую строку не удаляет: пользователь успел в неё написать", function()
        local req = agent.begin(buf, { after = "b7e1" })
        local total = vim.api.nvim_buf_line_count(buf)
        vim.api.nvim_buf_set_lines(buf, total - 1, total, false, { "моё" })

        agent.cancel(req.token)

        assert.equals("моё", vim.api.nvim_buf_get_lines(buf, total - 1, total, false)[1])
    end)
end)

describe("порядок виртуальных строк", function()
    it("после перерисовки статусов подпись встаёт заново, ниже них", function()
        agent._reset()
        local buf = make_buf()
        vim.api.nvim_set_current_buf(buf)
        local status = require("jupyter.ui.status")
        agent.begin(buf, { after = "a3f9", label = "Claude" })
        local first = vim.api.nvim_buf_get_extmarks(buf, agent.NS_FRAME, 0, -1, {})[1][1]

        -- так плагин перерисовывает статусы на каждое нажатие клавиши
        status.new({}):render(buf, { { row = 5, body_row = 4, text = "✓ 0.1 с", group = "JupyterWinBar" } })
        agent.reanchor(buf)

        local marks = vim.api.nvim_buf_get_extmarks(buf, agent.NS_FRAME, 0, -1, {})
        assert.equals(1, #marks, "подпись по-прежнему одна")
        assert.are_not.equals(first, marks[1][1], "но extmark новее статуса, значит ниже него")
    end)
end)

describe("заявка, открытую плагином", function()
    local buf

    before_each(function()
        agent._reset()
        buf = make_buf()
    end)

    it("метит ячейку сразу, ещё до того, как агент прочитал промпт", function()
        local req = agent.begin(buf, { cell = "a3f9", pending = true, title = "перепиши на polars" })

        assert.is_true(req.ok)
        assert.equals("pending", req.kind)
        local top = frame_of(buf)[1]
        assert.is_truthy(top.text:match("отправлено"), "имени агента ещё нет: промпт только ушёл")
        assert.is_truthy(top.text:match("перепиши на polars"), "в метке видно, что делается")
    end)

    it("sha не берёт: тела ячейки ещё никто не читал", function()
        local req = agent.begin(buf, { cell = "a3f9", pending = true, title = "проверь" })
        assert.is_nil(req.sha)
    end)

    it("писать по ней нельзя, пока агент не сказал, что берёт", function()
        local req = agent.begin(buf, { cell = "a3f9", pending = true, title = "проверь" })
        local res = agent.apply(req.token, { "x = 999" })

        assert.is_false(res.ok)
        assert.equals("not_adopted", res.reason)
        assert.equals("x = 1", lines_of(buf)[4], "ячейка цела")
    end)

    it("держит ячейку от запуска так же, как заявка агента", function()
        local req = agent.begin(buf, { cell = "a3f9", pending = true, title = "проверь" })
        assert.equals(req.token, agent.claim_of(buf, "a3f9").token)
    end)
end)

describe("агент берёт заявку", function()
    local buf

    before_each(function()
        agent._reset()
        buf = make_buf()
    end)

    it("метка остаётся одна и называет того, кто взял", function()
        local req = agent.begin(buf, { cell = "a3f9", pending = true, title = "перепиши на polars" })
        local got = agent.adopt(req.token, { label = "Claude" })

        assert.is_true(got.ok)
        assert.equals("replace", got.kind)
        assert.equals(1, #agent.list(buf), "вторая заявка не открывалась")
        assert.is_truthy(frame_of(buf)[1].text:match("Claude"))
        assert.is_truthy(frame_of(buf)[1].text:match("перепиши на polars"), "заголовок остался")
    end)

    it("sha берёт в момент взятия, а не отправки", function()
        local req = agent.begin(buf, { cell = "a3f9", pending = true, title = "проверь" })
        -- человек дописал строку, пока агент разбирал промпт: это не повод отклонять правку
        vim.api.nvim_buf_set_lines(buf, 4, 4, false, { "y = 2" })

        local got = agent.adopt(req.token, { label = "Claude" })
        local res = agent.apply(req.token, { "x = 3" })

        assert.is_truthy(got.sha)
        assert.is_true(res.ok, "правка прошла: sha описывает документ, который агент видел")
        assert.equals("x = 3", lines_of(buf)[4])
    end)

    it("после взятия чужая правка по-прежнему отклоняется", function()
        local req = agent.begin(buf, { cell = "a3f9", pending = true, title = "проверь" })
        agent.adopt(req.token, { label = "Claude" })
        vim.api.nvim_buf_set_lines(buf, 3, 4, false, { "x = 1  # руками" })

        local res = agent.apply(req.token, { "x = 999" })
        assert.is_false(res.ok)
        assert.equals("changed", res.reason)
    end)

    it("может превратить заявку во вставку: просили дописать, а не переписать", function()
        local req = agent.begin(buf, { cell = "a3f9", pending = true, title = "добавь проверку полноты" })
        local got = agent.adopt(req.token, { label = "Claude", after = true })

        assert.is_true(got.ok)
        assert.equals("insert", got.kind)
        assert.equals("a3f9", got.after)
        assert.equals(1, #frame_of(buf), "рамки вокруг тела нет: ячейку не переписывают")

        local res = agent.apply(req.token, { "assert len(df) > 0" })
        assert.is_true(res.ok)
        assert.equals("x = 1", lines_of(buf)[4], "исходная ячейка цела")
        assert.equals("assert len(df) > 0", lines_of(buf)[res.start_row])
    end)

    it("свой заголовок агента заменяет исходный", function()
        local req = agent.begin(buf, { cell = "a3f9", pending = true, title = "посмотри тут" })
        agent.adopt(req.token, { label = "Claude", title = "переписываю на lazy-скан" })
        assert.is_truthy(frame_of(buf)[1].text:match("переписываю на lazy%-скан"))
    end)

    it("заявки нет — говорит то же, что и остальным вызовам", function()
        local res = agent.adopt(4242, {})
        assert.is_false(res.ok)
        assert.equals("no_request", res.reason)
    end)

    it("ячейку удалили, пока промпт летел — заявка снимается, а не пишет вслепую", function()
        local req = agent.begin(buf, { cell = "a3f9", pending = true, title = "проверь" })
        vim.api.nvim_buf_set_lines(buf, 2, 5, false, {})

        local res = agent.adopt(req.token, { label = "Claude" })
        assert.is_false(res.ok)
        assert.equals("cell_gone", res.reason)
        assert.equals(0, #agent.list(buf))
    end)
end)

describe("заголовок в метке", function()
    local buf

    before_each(function()
        agent._reset()
        buf = make_buf()
    end)

    it("из промпта берёт первую строку: рамка в три строки — уже не рамка", function()
        agent.begin(buf, { cell = "a3f9", pending = true, title = "перепиши на polars\nи добавь окно по дате" })
        local text = frame_of(buf)[1].text
        assert.is_truthy(text:match("перепиши на polars"))
        assert.is_nil(text:match("окно по дате"))
    end)

    it("длинный подрезает, а не выносит за край окна", function()
        agent.begin(buf, { cell = "a3f9", pending = true, title = ("я"):rep(200) })
        local text = frame_of(buf)[1].text
        assert.is_true(vim.fn.strdisplaywidth(text) < 70, "двести знаков в метку не уехали")
        assert.is_truthy(text:match("…"))
    end)

    it("без заголовка подпись прежняя: у заявки агента её никто не отнимал", function()
        agent.begin(buf, { cell = "a3f9", label = "Claude" })
        assert.is_truthy(frame_of(buf)[1].text:match("Claude правит"))
    end)
end)
