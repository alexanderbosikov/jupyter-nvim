-- Бэкенд tmux для `pane.lua`: список панелей и отправка текста в панель.
--
-- `pane_id` (`%19`) держится всю жизнь панели и не меняется от перестановки окон, а
-- `paste-buffer` пишет прямо в PTY — этого хватает, чтобы адресовать сессию агента.
--
-- Почему промпт идёт через файл и буфер tmux, а не через `send-keys -l "текст"`. У
-- `send-keys` текст — аргумент команды: его надо экранировать, а внутри промпта живут
-- кавычки, `$`, обратные слэши и переводы строк. Хуже того, перевод строки для `send-keys`
-- неотличим от нажатия Enter — многострочный промпт отправился бы по частям, и первая же
-- строка ушла бы агенту как целый вопрос. `load-buffer` читает файл как байты, а
-- `paste-buffer -p` заворачивает вставку в bracketed paste, где переводы строк остаются
-- переводами строк. Единственный Enter — наш собственный, отдельной командой.

local M = {}

M.name = "tmux"

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

---nvim сидит внутри tmux.
---@return boolean
function M.active()
    return vim.env.TMUX ~= nil and vim.env.TMUX ~= ""
end

---Панель, в которой сидит сам nvim.
---@return string|nil
function M.self_id()
    return vim.env.TMUX_PANE
end

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

---Панель агента ли это: tmux видит только имя процесса в панели.
---@param pane jupyter.Pane
---@param cmd string
---@return boolean
function M.is_agent(pane, cmd)
    return pane.cmd == cmd
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
