-- Поиск панели агента и отправка в неё промпта.
--
-- tmux здесь подменён целиком: поднимать настоящий сервер в headless-прогоне значило бы
-- проверять tmux, а не лестницу поиска. Зато проверяется то, ради чего лестница написана:
-- промпт не должен уходить в чужую панель, а многострочный текст с кавычками — приезжать
-- покусанным.

local pane = require("jupyter.pane")
local tmux = require("jupyter.pane.tmux")
local herdr = require("jupyter.pane.herdr")

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

local real_run, real_herdr_run, saved_env
local calls, pasted

---Переменные окружения, по которым выбирается бэкенд. Сохраняются и чистятся целиком:
---тесты сами могут идти внутри herdr или tmux, и настоящий мультиплексор подхватился бы.
local ENV = { "TMUX", "TMUX_PANE", "HERDR_ENV", "HERDR_PANE_ID" }

---@param layout string выдача list-panes
---@param on_run? fun(args: string[]): table|nil ответ на остальные команды
local function fake_tmux(layout, on_run)
    calls, pasted = {}, nil
    tmux.run = function(args)
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
    real_run, real_herdr_run, saved_env = tmux.run, herdr.run, {}
    for _, k in ipairs(ENV) do
        saved_env[k] = vim.env[k]
        vim.env[k] = nil
    end
    -- настоящий herdr не должен откликнуться ни в одном тесте
    herdr.run = function()
        error("herdr в тесте tmux")
    end
    vim.env.TMUX = "/private/tmp/tmux-502/default,2485,4"
    vim.env.TMUX_PANE = "%18"
end

local function leave()
    tmux.run, herdr.run = real_run, real_herdr_run
    for _, k in ipairs(ENV) do
        vim.env[k] = saved_env[k]
    end
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
        tmux.run = function()
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

    it("вне мультиплексора говорит об этом прямо, а не «не нашёл»", function()
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

-- --- herdr ---

---Раскладка herdr, списанная с живой `herdr pane list`: workspace на проект, во вкладке
---nvim и claude рядом, в соседнем workspace — другой claude. `agent` есть только у панелей,
---где herdr распознал агента.
local HERDR_PANES = {
    { pane_id = "w1:p1", workspace_id = "w1", tab_id = "w1:t1", cwd = "/home/u",
      agent = "claude", agent_status = "idle", terminal_title_stripped = "шрифты" },
    { pane_id = "w4:p1", workspace_id = "w4", tab_id = "w4:t1", cwd = NB,
      foreground_cwd = NB },
    { pane_id = "w4:p2", workspace_id = "w4", tab_id = "w4:t1", cwd = NB,
      agent = "claude", agent_status = "idle", terminal_title_stripped = "визуал ноутбука" },
    { pane_id = "w4:p3", workspace_id = "w4", tab_id = "w4:t2", cwd = NB },
}

local herdr_calls

---@param panes table[] содержимое result.panes
---@param on_run? fun(args: string[]): table|nil ответ на остальные команды
local function fake_herdr(panes, on_run)
    herdr_calls = {}
    herdr.run = function(args)
        table.insert(herdr_calls, args)
        if args[1] == "pane" and args[2] == "list" then
            return {
                code = 0,
                stdout = vim.json.encode({ id = "cli:pane:list", result = { panes = panes, type = "pane_list" } }),
            }
        end
        if on_run then
            local res = on_run(args)
            if res then
                return res
            end
        end
        return { code = 0, stdout = "{}" }
    end
end

---Сидим в herdr: nvim в панели w4:p1, tmux-переменных нет.
local function enter_herdr()
    enter()
    vim.env.TMUX, vim.env.TMUX_PANE = nil, nil
    vim.env.HERDR_ENV = "1"
    vim.env.HERDR_PANE_ID = "w4:p1"
    tmux.run = function()
        error("tmux в тесте herdr")
    end
end

describe("herdr", function()
    before_each(enter_herdr)
    after_each(leave)

    it("выбирается, когда nvim в herdr и не в tmux", function()
        assert.are.equal("herdr", pane.backend().name)
    end)

    it("tmux внутри herdr побеждает: он ближе к nvim", function()
        vim.env.TMUX = "/tmp/tmux-1000/default,1,0"
        assert.are.equal("tmux", pane.backend().name)
    end)

    it("разбирает панель: вкладка — окно, workspace — сессия, агент — по распознаванию herdr", function()
        fake_herdr(HERDR_PANES)
        local found
        for _, p in ipairs(pane.panes()) do
            if p.id == "w4:p2" then
                found = p
            end
        end
        assert.are.same({
            id = "w4:p2",
            session = "w4",
            window = "w4:t1",
            where = "w4:p2 визуал ноутбука",
            cmd = "claude",
            path = NB,
            status = "idle",
        }, found)
    end)

    it("берёт соседнюю во вкладке, а не агента из другого workspace", function()
        fake_herdr(HERDR_PANES)
        local id, how = pane.find({ dir = NB })
        assert.are.equal("w4:p2", id)
        assert.are.equal("рядом в окне", how)
    end)

    it("claude через обёртку узнаётся и при cmd из конфига под tmux", function()
        local saved = pane.CMD
        pane.CMD = "my-claude-wrapper"
        fake_herdr(HERDR_PANES)
        local id = pane.find({ dir = NB })
        pane.CMD = saved
        assert.are.equal("w4:p2", id)
    end)

    it("отправляет одним agent prompt, текст — аргументом как есть", function()
        fake_herdr(HERDR_PANES)
        local text = [[перепиши: df["a"] > $x \ 'и ещё']] .. "\nвторая строка"
        local ok = pane.send("w4:p2", text)
        assert.is_true(ok)
        assert.are.same({ "agent", "prompt", "w4:p2", text }, herdr_calls[2])
        assert.are.equal(2, #herdr_calls) -- pane list (жива ли) + prompt, больше ничего
    end)

    it("в панель без агента не пишет", function()
        fake_herdr(HERDR_PANES)
        local ok, err = pane.send("w4:p3", "привет")
        assert.is_false(ok)
        assert.is_truthy(err:match("уже не агент"))
        assert.are.equal(1, #herdr_calls)
    end)

    it("агент на диалоге разрешения — говорит об этом по-человечески", function()
        fake_herdr(HERDR_PANES, function(args)
            if args[1] == "agent" then
                return {
                    code = 1,
                    stdout = "",
                    stderr = '{"error":{"code":"agent_blocked","message":"agent is blocked"},"id":"cli:agent:prompt"}',
                }
            end
        end)
        local ok, err = pane.send("w4:p2", "привет")
        assert.is_false(ok)
        assert.is_truthy(err:match("ждёт ответа"))
    end)

    it("прочие ошибки herdr показывает его словами", function()
        fake_herdr(HERDR_PANES, function(args)
            if args[1] == "agent" then
                return { code = 1, stdout = "", stderr = '{"error":{"code":"x","message":"server gone"}}' }
            end
        end)
        local ok, err = pane.send("w4:p2", "привет")
        assert.is_false(ok)
        assert.is_truthy(err:match("server gone"))
    end)

    it("молчит, а не падает, когда herdr ответил не JSON'ом", function()
        herdr.run = function()
            return { code = 0, stdout = "not json" }
        end
        assert.are.same({}, pane.panes())
    end)
end)

describe("своя панель", function()
    before_each(enter_herdr)
    after_each(leave)

    it("не бывает кандидатом, даже если herdr числит в ней агента", function()
        local panes = vim.deepcopy(HERDR_PANES)
        panes[2].agent = "claude" -- nvim запущен из панели, где раньше был claude
        fake_herdr(panes)
        local id = pane.find({ dir = NB })
        assert.are.equal("w4:p2", id)
    end)
end)
