-- Панель tmux, в которой живёт агент: найти, проверить, отправить туда промпт.
--
-- Зачем вообще отдельный модуль. Сессия Claude Code — не наш процесс: она открыта
-- человеком, переживает перезапуск nvim и ничего о ноутбуке не знает. Всё, что нам нужно, —
-- это адрес её терминала и способ положить туда текст так, как его кладёт человек. tmux
-- даёт и то, и другое: `pane_id` (`%19`) держится всю жизнь панели и не меняется от
-- перестановки окон, а `paste-buffer` пишет прямо в PTY.
--
-- Почему промпт идёт через файл и буфер tmux, а не через `send-keys -l "текст"`. У
-- `send-keys` текст — аргумент команды: его надо экранировать, а внутри промпта живут
-- кавычки, `$`, обратные слэши и переводы строк. Хуже того, перевод строки для `send-keys`
-- неотличим от нажатия Enter — многострочный промпт отправился бы по частям, и первая же
-- строка ушла бы агенту как целый вопрос. `load-buffer` читает файл как байты, а
-- `paste-buffer -p` заворачивает вставку в bracketed paste, где переводы строк остаются
-- переводами строк. Единственный Enter — наш собственный, отдельной командой.
--
-- Поиск панели — лестница от точного к общему (`M.find`). Смысл лестницы в том, что
-- спрашивать пользователя «где твой агент» на каждый промпт нельзя, а угадывать молча
-- нельзя тем более: промпт, ушедший не в ту панель, выглядит как пропавший.

local M = {}

---Команда, по которой узнаём панель агента. Настраивается: кто-то запускает claude через
---обёртку, и тогда `pane_current_command` покажет её имя, а не claude.
M.CMD = "claude"

---Имя буфера tmux под промпт. Своё, а не безымянный: безымянный кладётся в общий стек
---буферов и затирает то, что пользователь скопировал руками.
M.BUFFER = "jupyter-nvim"

---Сколько ждём tmux. Он локальный и отвечает мгновенно; секунда — это «tmux-сервер завис»,
---и лучше сказать об этом, чем держать редактор.
M.TIMEOUT_MS = 1000

---Разделитель полей в выводе `list-panes`. `\t` в путях и именах сессий не встречается,
---а пробел встречается всегда: каталог задачи вида «PROJ-123 Отчёт по воронке» — обычное
---дело, и разбор по пробелу разложил бы одну панель на пять полей.
local SEP = "\t"

---Выполнить команду tmux. Отдельной функцией и полем модуля, потому что тесты подменяют
---её целиком: поднимать настоящий tmux-сервер в headless-прогоне значило бы проверять
---tmux, а не нас.
---@param args string[] аргументы после самого `tmux`
---@return table|nil { code, stdout, stderr }, nil при ошибке запуска
---@return string|nil текст ошибки
function M.run(args)
    local cmd = { "tmux" }
    vim.list_extend(cmd, args)
    local ok, res = pcall(function()
        return vim.system(cmd, { text = true }):wait(M.TIMEOUT_MS)
    end)
    if not ok then
        return nil, tostring(res)
    end
    return res, nil
end

---@class jupyter.Pane
---@field id string `%19`
---@field session string имя tmux-сессии
---@field window string `@6`
---@field where string человекочитаемое «work:6.2»
---@field cmd string что в панели исполняется сейчас
---@field path string рабочий каталог панели

---Все панели всех сессий одним вызовом.
---
---Одним, а не по одной на шаг лестницы: tmux отвечает быстро, но каждый вызов — это
---процесс, а лестница проходит до четырёх ступеней. Дешевле спросить один раз и разбирать
---в Lua.
---@return jupyter.Pane[]
function M.panes()
    local fmt = table.concat({
        "#{pane_id}",
        "#{session_name}",
        "#{window_id}",
        "#{window_index}.#{pane_index}",
        "#{pane_current_command}",
        "#{pane_current_path}",
    }, SEP)
    local res = M.run({ "list-panes", "-a", "-F", fmt })
    if not res or res.code ~= 0 then
        return {}
    end
    local out = {}
    for _, line in ipairs(vim.split(res.stdout or "", "\n", { plain = true })) do
        if line ~= "" then
            local f = vim.split(line, SEP, { plain = true })
            if #f >= 6 then
                table.insert(out, {
                    id = f[1],
                    session = f[2],
                    window = f[3],
                    where = f[2] .. ":" .. f[4],
                    cmd = f[5],
                    path = f[6],
                })
            end
        end
    end
    return out
end

---@param panes jupyter.Pane[]
---@param id string|nil
---@return jupyter.Pane|nil
local function by_id(panes, id)
    if type(id) ~= "string" or id == "" then
        return nil
    end
    for _, p in ipairs(panes) do
        if p.id == id then
            return p
        end
    end
    return nil
end

---Панель агента ли это.
---@param pane jupyter.Pane|nil
---@return boolean
local function is_agent(pane)
    return pane ~= nil and pane.cmd == M.CMD
end

---Жива ли панель и всё ещё ли в ней агент.
---
---Два вопроса одним: панель могли закрыть, а могли выйти из claude и оставить в ней шелл.
---Второй случай опаснее — промпт ушёл бы в командную строку и там исполнился.
---@param id string
---@return boolean
function M.alive(id)
    return is_agent(by_id(M.panes(), id))
end

---Путь `dir` лежит внутри `root` (или совпадает с ним).
---@param dir string|nil
---@param root string|nil
---@return boolean
local function under(dir, root)
    if type(dir) ~= "string" or type(root) ~= "string" or root == "" then
        return false
    end
    if dir == root then
        return true
    end
    return dir:sub(1, #root + 1) == root .. "/"
end

---Найти панель агента.
---
---Лестница, сверху вниз: запомненная в `agent.json` → соседняя в том же окне, что и nvim →
---единственная в той же tmux-сессии (при нескольких — та, чей каталог ближе к ноутбуку) →
---не нашли, отдаём кандидатов на выбор человеку.
---
---Ступень «соседняя» стоит выше «по каталогу» намеренно: рядом с nvim человек держит того
---агента, с которым сейчас работает, а совпадение каталогов — всего лишь догадка.
---@param opts? table { pane = запомненный id, dir = каталог ноутбука }
---@return string|nil pane_id
---@return string причина: как нашли, либо почему не нашли
---@return jupyter.Pane[] кандидаты — непусто, когда выбирать должен человек
function M.find(opts)
    opts = opts or {}
    if not vim.env.TMUX then
        return nil, "nvim запущен не в tmux: панель агента искать негде", {}
    end

    local panes = M.panes()
    if #panes == 0 then
        return nil, "tmux не ответил списком панелей", {}
    end

    local remembered = by_id(panes, opts.pane)
    if is_agent(remembered) then
        return remembered.id, "запомнена", {}
    end

    local agents = vim.tbl_filter(is_agent, panes)
    if #agents == 0 then
        return nil, "сессии агента нет ни в одной панели tmux", {}
    end

    local self_pane = by_id(panes, vim.env.TMUX_PANE)
    if self_pane then
        local siblings = vim.tbl_filter(function(p)
            return p.window == self_pane.window
        end, agents)
        if #siblings == 1 then
            return siblings[1].id, "рядом в окне", {}
        end
        if #siblings > 1 then
            return nil, "в этом окне несколько панелей агента", siblings
        end
    end

    -- Та же tmux-сессия: у этой раскладки сессия — это проект, так что чужой проект
    -- отсекается целиком, не разбираясь в каталогах.
    local same = self_pane
            and vim.tbl_filter(function(p)
                return p.session == self_pane.session
            end, agents)
        or agents
    local pool = #same > 0 and same or agents

    if #pool == 1 then
        return pool[1].id, "единственная в сессии", {}
    end

    local near = vim.tbl_filter(function(p)
        return under(opts.dir, p.path)
    end, pool)
    if #near == 1 then
        return near[1].id, "по каталогу ноутбука", {}
    end

    return nil, "панелей агента несколько — какая нужна", #near > 1 and near or pool
end

---Отправить текст в панель так, как его набрал бы человек.
---
---Три шага, и каждый нужен: файл → буфер tmux (байты как есть, без экранирования),
---вставка с `-p` (bracketed paste: переводы строк не превращаются в Enter'ы), затем
---единственный Enter отдельной командой. `-d` убирает буфер сразу после вставки, чтобы
---промпт не оставался в стеке буферов tmux.
---@param id string pane_id
---@param text string
---@return boolean ok
---@return string|nil ошибка
function M.send(id, text)
    if type(text) ~= "string" or text == "" then
        return false, "пустой промпт"
    end
    if not is_agent(by_id(M.panes(), id)) then
        return false, ("панели %s больше нет или в ней уже не агент"):format(tostring(id))
    end

    local path = vim.fn.tempname()
    local ok_write = pcall(vim.fn.writefile, vim.split(text, "\n", { plain = true }), path)
    if not ok_write then
        return false, "не удалось записать промпт во временный файл"
    end

    local steps = {
        { "load-buffer", "-b", M.BUFFER, path },
        { "paste-buffer", "-d", "-p", "-b", M.BUFFER, "-t", id },
        { "send-keys", "-t", id, "Enter" },
    }
    for _, args in ipairs(steps) do
        local res, err = M.run(args)
        if not res then
            pcall(vim.fn.delete, path)
            return false, err or "tmux не запустился"
        end
        if res.code ~= 0 then
            pcall(vim.fn.delete, path)
            local msg = (res.stderr or ""):gsub("%s+$", "")
            return false, ("tmux %s: %s"):format(args[1], msg ~= "" and msg or "код " .. res.code)
        end
    end
    pcall(vim.fn.delete, path)
    return true, nil
end

return M
