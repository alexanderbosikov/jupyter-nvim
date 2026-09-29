-- Панель мультиплексора, в которой живёт агент: найти, проверить, отправить туда промпт.
--
-- Зачем вообще отдельный модуль. Сессия Claude Code — не наш процесс: она открыта
-- человеком, переживает перезапуск nvim и ничего о ноутбуке не знает. Всё, что нам нужно, —
-- это адрес её терминала и способ положить туда текст так, как его кладёт человек.
--
-- Как именно — дело бэкенда (`pane/tmux.lua`, `pane/herdr.lua`): у каждого свой список
-- панелей и своя отправка. Здесь — то, что от мультиплексора не зависит: выбор бэкенда
-- и лестница поиска.
--
-- Поиск панели — лестница от точного к общему (`M.find`). Смысл лестницы в том, что
-- спрашивать пользователя «где твой агент» на каждый промпт нельзя, а угадывать молча
-- нельзя тем более: промпт, ушедший не в ту панель, выглядит как пропавший.

local M = {}

---Команда, по которой узнаём панель агента. Настраивается: кто-то запускает claude через
---обёртку, и тогда `pane_current_command` в tmux покажет её имя, а не claude.
M.CMD = "claude"

---Бэкенды в порядке предпочтения. tmux первым: если он запущен внутри herdr, то ближайший
---к nvim мультиплексор — tmux, и соседние панели, в которых стоит искать агента, — его.
M.BACKENDS = {
    require("jupyter.pane.tmux"),
    require("jupyter.pane.herdr"),
}

---@class jupyter.Pane
---@field id string `%19` в tmux, `w4:p1` в herdr
---@field session string сессия tmux / workspace herdr
---@field window string окно tmux / вкладка herdr
---@field where string человекочитаемое «work:6.2» или «w4:p1 название сессии»
---@field cmd string что в панели: процесс (tmux) или распознанный агент (herdr)
---@field path string рабочий каталог панели

---Бэкенд, внутри которого запущен nvim, или nil.
---@return table|nil
function M.backend()
    for _, b in ipairs(M.BACKENDS) do
        if b.active() then
            return b
        end
    end
    return nil
end

---Все панели текущего мультиплексора.
---@return jupyter.Pane[]
function M.panes()
    local b = M.backend()
    return b and b.panes() or {}
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
function M.is_agent(pane)
    local b = M.backend()
    return pane ~= nil and b ~= nil and b.is_agent(pane, M.CMD)
end

---Все панели с агентом, кроме своей (почему — см. `M.find`).
---@return jupyter.Pane[]
function M.agents()
    local b = M.backend()
    local self_id = b and b.self_id()
    return vim.tbl_filter(function(p)
        return p.id ~= self_id and M.is_agent(p)
    end, M.panes())
end

---Жива ли панель и всё ещё ли в ней агент.
---
---Два вопроса одним: панель могли закрыть, а могли выйти из claude и оставить в ней шелл.
---Второй случай опаснее — промпт ушёл бы в командную строку и там исполнился.
---@param id string
---@return boolean
function M.alive(id)
    return M.is_agent(by_id(M.panes(), id))
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
---Лестница, сверху вниз: запомненная в `agent.json` → соседняя в том же окне (вкладке),
---что и nvim → единственная в той же сессии (workspace) (при нескольких — та, чей каталог
---ближе к ноутбуку) → не нашли, отдаём кандидатов на выбор человеку.
---
---Ступень «соседняя» стоит выше «по каталогу» намеренно: рядом с nvim человек держит того
---агента, с которым сейчас работает, а совпадение каталогов — всего лишь догадка.
---@param opts? table { pane = запомненный id, dir = каталог ноутбука }
---@return string|nil pane_id
---@return string причина: как нашли, либо почему не нашли
---@return jupyter.Pane[] кандидаты — непусто, когда выбирать должен человек
function M.find(opts)
    opts = opts or {}
    local b = M.backend()
    if not b then
        return nil, "nvim запущен не в tmux и не в herdr: панель агента искать негде", {}
    end

    local panes = b.panes()
    if #panes == 0 then
        return nil, b.name .. " не ответил списком панелей", {}
    end

    local remembered = by_id(panes, opts.pane)
    if M.is_agent(remembered) then
        return remembered.id, "запомнена", {}
    end

    -- своя панель агентом быть не может: в ней nvim. Проверка не для красоты — если nvim
    -- запущен из панели, где herdr помнит claude (`:!nvim` из сессии агента), лестница
    -- выбрала бы её «соседней» и вставила промпт в сам редактор
    local self_id = b.self_id()
    local agents = vim.tbl_filter(function(p)
        return p.id ~= self_id and M.is_agent(p)
    end, panes) -- не через M.agents(): список панелей уже на руках, второй вызов лишний
    if #agents == 0 then
        return nil, ("сессии агента нет ни в одной панели %s"):format(b.name), {}
    end

    local self_pane = by_id(panes, self_id)
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

    -- Та же сессия: у этой раскладки сессия — это проект, так что чужой проект
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

---Отправить текст в панель агента.
---
---Сначала проверяем, что в панели всё ещё агент: между поиском и отправкой человек мог
---выйти из claude, и тогда промпт исполнился бы в шелле как команда.
---@param id string pane_id
---@param text string
---@return boolean ok
---@return string|nil ошибка
function M.send(id, text)
    if type(text) ~= "string" or text == "" then
        return false, "пустой промпт"
    end
    local b = M.backend()
    if not b then
        return false, "nvim запущен не в tmux и не в herdr"
    end
    if not M.is_agent(by_id(b.panes(), id)) then
        return false, ("панели %s больше нет или в ней уже не агент"):format(tostring(id))
    end
    return b.send(id, text)
end

return M
