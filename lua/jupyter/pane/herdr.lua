-- Бэкенд herdr для `pane.lua`: список панелей и отправка промпта через его CLI.
--
-- herdr знает об агентах больше, чем tmux: сам определяет, что в панели claude (и через
-- обёртку тоже), и хранит его состояние — idle, working, blocked. Поэтому отправка — одна
-- команда `herdr agent prompt`, а не три шага, как в tmux: bracketed paste и отдельный
-- Enter он делает сам, с учётом того, включён ли paste в панели сейчас.
--
-- И ещё одно, чего у tmux нет вовсе: если агент стоит на диалоге разрешения, herdr
-- отказывает (`agent_blocked`) до того, как что-то отправить. tmux вставил бы промпт
-- прямо в диалог — и Enter в конце выбрал бы там пункт за человека.
--
-- Соответствие понятий с tmux: вкладка herdr (`tab_id`) — окно, workspace — сессия.
-- Лестница поиска в `pane.lua` от этого не меняется.

local M = {}

M.name = "herdr"

---Сколько ждём herdr. Список панелей приходит за миллисекунды, а `agent prompt` делает
---короткую паузу между вставкой и Enter — берём с запасом, но так, чтобы зависший сервер
---не держал редактор дольше пары секунд.
M.TIMEOUT_MS = 3000

---Выполнить команду herdr. Полем модуля — тесты подменяют её целиком, как и в tmux.
---@param args string[] аргументы после самого `herdr`
---@return table|nil { code, stdout, stderr }, nil при ошибке запуска
---@return string|nil текст ошибки
function M.run(args)
    local cmd = { vim.env.HERDR_BIN_PATH or "herdr" }
    vim.list_extend(cmd, args)
    local ok, res = pcall(function()
        return vim.system(cmd, { text = true }):wait(M.TIMEOUT_MS)
    end)
    if not ok then
        return nil, tostring(res)
    end
    return res, nil
end

---nvim сидит внутри herdr. `HERDR_ENV` herdr ставит каждой своей панели.
---@return boolean
function M.active()
    return vim.env.HERDR_ENV == "1"
end

---Панель, в которой сидит сам nvim.
---@return string|nil
function M.self_id()
    return vim.env.HERDR_PANE_ID
end

---Разобрать JSON-ответ herdr. `luanil` — по той же причине, что и везде в плагине: без
---него отсутствующее поле приезжает как `vim.NIL`, а он в Lua истинен.
---@param text string|nil
---@return table|nil
local function decode(text)
    if type(text) ~= "string" or text == "" then
        return nil
    end
    local ok, data = pcall(vim.json.decode, text, { luanil = { object = true, array = true } })
    return ok and type(data) == "table" and data or nil
end

---Все панели всех workspace'ов одним вызовом.
---
---`cmd` здесь — не процесс, а агент, которого распознал herdr (`claude`), или пустая
---строка: в обычной панели поля `agent` нет. Так панель с claude, запущенным через обёртку,
---всё равно узнаётся.
---@return jupyter.Pane[]
function M.panes()
    local res = M.run({ "pane", "list" })
    if not res or res.code ~= 0 then
        return {}
    end
    local data = decode(res.stdout)
    local list = data and data.result and data.result.panes or {}
    local out = {}
    for _, p in ipairs(list) do
        if type(p.pane_id) == "string" then
            -- заголовок терминала у claude — название его сессии: по нему человек
            -- и узнаёт нужную панель в списке выбора
            local title = p.label or p.terminal_title_stripped
            table.insert(out, {
                id = p.pane_id,
                session = p.workspace_id or "",
                window = p.tab_id or "",
                where = title and title ~= "" and (p.pane_id .. " " .. title) or p.pane_id,
                cmd = p.agent or "",
                path = p.foreground_cwd or p.cwd or "",
                status = p.agent_status,
            })
        end
    end
    return out
end

---Панель агента ли это.
---
---`cmd` из конфига задуман для tmux, где видно только имя процесса, и обёртка подменяет
---его своим. herdr агента распознаёт сам и называет `claude` при любой обёртке — поэтому
---принимаем и то, и другое: иначе настройка для tmux ломала бы поиск под herdr.
---@param pane jupyter.Pane
---@param cmd string
---@return boolean
function M.is_agent(pane, cmd)
    return pane.cmd ~= "" and (pane.cmd == cmd or pane.cmd == "claude")
end

---Отправить промпт агенту в панели `id`.
---
---Текст уходит аргументом, а не через шелл: `vim.system` передаёт argv как есть, так что
---кавычки, `$` и переводы строк экранировать не нужно.
---@param id string pane_id
---@param text string
---@return boolean ok
---@return string|nil ошибка
function M.send(id, text)
    local res, err = M.run({ "agent", "prompt", id, text })
    if not res then
        return false, err or "herdr не запустился"
    end
    if res.code ~= 0 then
        -- ошибка приходит JSON'ом в stderr: {"error":{"code":…,"message":…}}
        local data = decode(res.stderr) or decode(res.stdout)
        local e = data and data.error
        if e and e.code == "agent_blocked" then
            return false, "агент ждёт ответа в своей панели (разрешение или вопрос) — промпт не отправлен"
        end
        local msg = e and e.message or (res.stderr or ""):gsub("%s+$", "")
        return false, ("herdr agent prompt: %s"):format(msg ~= "" and msg or "код " .. res.code)
    end
    return true, nil
end

return M
