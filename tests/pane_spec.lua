-- Поиск панели агента и отправка в неё промпта.
--
-- tmux здесь подменён целиком: поднимать настоящий сервер в headless-прогоне значило бы
-- проверять tmux, а не лестницу поиска. Зато проверяется то, ради чего лестница написана:
-- промпт не должен уходить в чужую панель, а многострочный текст с кавычками — приезжать
-- покусанным.

local pane = require("jupyter.pane")

local NB = "/Users/ab/work/proj/PROJ-123 Отчёт по воронке. Черновик"

---Раскладка, списанная с живой: сессия на проект, где-то claude рядом с nvim в одном окне,
---где-то в своём. Пробелы и точки в каталоге — не выдумка, а обычное имя задачи.
local LAYOUT = table.concat({
    "%2\twork\t@1\t1.1\tnvim\t/Users/ab/work",
    "%10\twork\t@6\t2.1\tzsh\t/Users/ab/work",
    "%11\twork\t@6\t2.2\tclaude\t/Users/ab/work/другой проект",
    "%18\twork\t@11\t6.1\tnvim\t" .. NB,
    "%19\twork\t@11\t6.2\tclaude\t" .. NB,
    "%20\twarehouse\t@2\t1.1\tnvim\t/Users/ab/work/warehouse",
    "%21\twarehouse\t@3\t2.1\tclaude\t/Users/ab/work/warehouse",
}, "\n")

local real_run, real_tmux, real_tmux_pane
local calls, pasted

---@param layout string выдача list-panes
---@param on_run? fun(args: string[]): table|nil ответ на остальные команды
local function fake_tmux(layout, on_run)
    calls, pasted = {}, nil
    pane.run = function(args)
        table.insert(calls, args)
        if args[1] == "list-panes" then
            return { code = 0, stdout = layout }
        end
        if args[1] == "load-buffer" then
            -- то, что реально уехало бы в tmux: файл читаем до того, как send его удалит
            pasted = table.concat(vim.fn.readfile(args[4]), "\n")
        end
        if on_run then
            local res = on_run(args)
            if res then
                return res
            end
        end
        return { code = 0, stdout = "" }
    end
end

---Имена команд по порядку: проверяем последовательность, не разбирая аргументы.
local function verbs()
    local out = {}
    for _, args in ipairs(calls) do
        table.insert(out, args[1])
    end
    return out
end

---Окружение вокруг теста: подменённый tmux и «мы сидим в панели nvim рядом с агентом».
---Функциями, а не одним before_each на файл: plenary зовёт before_each только внутри
---describe, а на верхнем уровне падает на пустом списке хуков.
local function enter()
    real_run, real_tmux, real_tmux_pane = pane.run, vim.env.TMUX, vim.env.TMUX_PANE
    vim.env.TMUX = "/private/tmp/tmux-502/default,2485,4"
    vim.env.TMUX_PANE = "%18"
end

local function leave()
    pane.run, vim.env.TMUX, vim.env.TMUX_PANE = real_run, real_tmux, real_tmux_pane
end

describe("разбор панелей", function()
    before_each(enter)
    after_each(leave)

    it("не теряет поля из-за пробелов и точек в пути", function()
        fake_tmux(LAYOUT)
        local found
        for _, p in ipairs(pane.panes()) do
            if p.id == "%19" then
                found = p
            end
        end
        assert.are.same({
            id = "%19",
            session = "work",
            window = "@11",
            where = "work:6.2",
            cmd = "claude",
            path = NB,
        }, found)
    end)

    it("молчит, а не падает, когда tmux-сервера нет", function()
        fake_tmux(LAYOUT)
        pane.run = function()
            return { code = 1, stdout = "", stderr = "no server running" }
        end
        assert.are.same({}, pane.panes())
    end)
end)

describe("лестница поиска", function()
    before_each(enter)
    after_each(leave)

    it("запомненная панель побеждает всё остальное", function()
        fake_tmux(LAYOUT)
        local id, how = pane.find({ pane = "%11", dir = NB })
        assert.are.equal("%11", id)
        assert.are.equal("запомнена", how)
    end)

    it("запомненную, в которой уже не агент, не берёт", function()
        -- человек вышел из claude и оставил в панели шелл: промпт исполнился бы как команда
        fake_tmux(LAYOUT:gsub("%%11\twork\t@6\t2%.2\tclaude", "%%11\twork\t@6\t2.2\tzsh"))
        local id = pane.find({ pane = "%11", dir = NB })
        assert.are.equal("%19", id) -- упали на ступень «рядом в окне»
    end)

    it("берёт соседнюю в том же окне, что и nvim", function()
        fake_tmux(LAYOUT)
        local id, how = pane.find({ dir = NB })
        assert.are.equal("%19", id)
        assert.are.equal("рядом в окне", how)
    end)

    it("без соседа в окне берёт единственную в своей tmux-сессии", function()
        vim.env.TMUX_PANE = "%20" -- nvim в warehouse, там ровно один агент
        fake_tmux(LAYOUT)
        local id, how = pane.find({ dir = "/Users/ab/work/warehouse" })
        assert.are.equal("%21", id)
        assert.are.equal("единственная в сессии", how)
    end)

    it("чужую сессию не трогает, даже когда своей панели нет вовсе", function()
        vim.env.TMUX_PANE = "%2" -- окно только с nvim; в этой сессии два агента
        fake_tmux(LAYOUT)
        local id, how, candidates = pane.find({ dir = "/Users/ab/work/nowhere" })
        assert.is_nil(id)
        assert.are.equal("панелей агента несколько — какая нужна", how)
        local ids = vim.tbl_map(function(p)
            return p.id
        end, candidates)
        assert.are.same({ "%11", "%19" }, ids) -- из чужой сессии не предложено ничего
    end)

    it("при нескольких в сессии выбирает ту, чей каталог содержит ноутбук", function()
        vim.env.TMUX_PANE = "%2"
        fake_tmux(LAYOUT)
        local id, how = pane.find({ dir = NB })
        assert.are.equal("%19", id)
        assert.are.equal("по каталогу ноутбука", how)
    end)

    it("вне tmux говорит об этом прямо, а не «не нашёл»", function()
        vim.env.TMUX = nil
        fake_tmux(LAYOUT)
        local id, how = pane.find({ dir = NB })
        assert.is_nil(id)
        assert.is_truthy(how:match("не в tmux"))
    end)

    it("агента нет ни в одной панели — отдельная причина, не список кандидатов", function()
        fake_tmux(LAYOUT:gsub("claude", "zsh"))
        local id, how, candidates = pane.find({ dir = NB })
        assert.is_nil(id)
        assert.is_truthy(how:match("ни в одной панели"))
        assert.are.same({}, candidates)
    end)
end)

describe("отправка промпта", function()
    before_each(enter)
    after_each(leave)

    it("кладёт текст буфером и жмёт Enter отдельно", function()
        fake_tmux(LAYOUT)
        local ok = pane.send("%19", "проверь ячейку")
        assert.is_true(ok)
        -- list-panes — проверка, что панель ещё жива; дальше три шага отправки
        assert.are.same({ "list-panes", "load-buffer", "paste-buffer", "send-keys" }, verbs())
        assert.are.same({ "send-keys", "-t", "%19", "Enter" }, calls[4])
    end)

    it("вставляет с -p: перевод строки не превращается в Enter", function()
        fake_tmux(LAYOUT)
        pane.send("%19", "первая\nвторая")
        local args = table.concat(calls[3], " ")
        assert.is_truthy(args:match("%-p")) -- bracketed paste
        assert.is_truthy(args:match("%-d")) -- буфер не остаётся в стеке tmux
    end)

    it("не портит промпт с кавычками, долларами и слэшами", function()
        fake_tmux(LAYOUT)
        local text = [[перепиши на polars: df["a"] > $x \ "цитата" 'и ещё']] .. "\nвторая строка"
        assert.is_true(pane.send("%19", text))
        assert.are.equal(text, pasted)
    end)

    it("в мёртвую панель не пишет ничего", function()
        fake_tmux(LAYOUT)
        local ok, err = pane.send("%42", "привет")
        assert.is_false(ok)
        assert.is_truthy(err:match("больше нет"))
        assert.are.same({ "list-panes" }, verbs()) -- до отправки дело не дошло
    end)

    it("ошибку tmux показывает его словами", function()
        fake_tmux(LAYOUT, function(args)
            if args[1] == "paste-buffer" then
                return { code = 1, stdout = "", stderr = "no such buffer\n" }
            end
        end)
        local ok, err = pane.send("%19", "привет")
        assert.is_false(ok)
        assert.is_truthy(err:match("no such buffer"))
    end)

    it("пустой промпт не отправляет", function()
        fake_tmux(LAYOUT)
        local ok = pane.send("%19", "")
        assert.is_false(ok)
        assert.are.same({}, verbs())
    end)
end)
