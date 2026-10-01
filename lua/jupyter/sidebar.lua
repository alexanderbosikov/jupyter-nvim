-- Статус прогона в сайдбаре herdr: панель с nvim встаёт в тот же ряд, что агенты, и из
-- соседнего воркспейса видно, что ячейки досчитались или упали.
--
-- Состояний у herdr четыре, репортим три: working — идёт прогон, idle — нет, blocked —
-- «требует внимания». Четвёртое, done, herdr выводит сам: working → idle, пока воркспейс
-- не в фокусе, показывается как done и гаснет, когда в него зашёл. Поэтому «досчиталось»
-- — это просто idle, отдельно его не сообщаем.
--
-- Прогресс — «волна»: прогоны от момента, когда ноутбук стал занят, до момента, когда
-- освободился. Ячейки, брошенные в очередь посреди волны, её увеличивают; следующая волна
-- начинается с нуля. Чем кончилась волна, решает, idle это или blocked:
--   * ошибка в коде, смерть ядра, упавший сайдкар — blocked, пока не посмотришь в nvim
--     (FocusGained) или не запустишь следующее;
--   * остановил сам — прерывание, рестарт, :JupyterStop — idle: внимания требовать не о чем,
--     человек только что это сделал;
--   * `input()` в ячейке — blocked, пока волна не сдвинется: ячейка ждёт человека.
--
-- Одна панель herdr на весь nvim, а ноутбуков в нём может быть несколько — их сводка
-- складывается в один статус (см. combine).

local exec = require("jupyter.exec")

local M = {}

M.SOURCE = "jupyter.nvim"
M.AGENT = "jupyter"
M.DEBOUNCE_MS = 250
---Сколько ждать herdr при выходе из редактора: снять статус надо успеть, но выход держать нельзя.
M.RELEASE_TIMEOUT_MS = 500

---Остановки, которые сделал сам человек. Код ошибки прогона: ename из ядра или код
---отказа из kernel.lua, когда запуск сняли с очереди до отправки.
M.USER_STOP = {
    KeyboardInterrupt = true,
    interrupted = true,
    kernel_restart = true,
    kernel_shutdown = true,
}

local RANK = { idle = 1, working = 2, blocked = 3 }

-- --- чистая часть ---

---Сводка одного ноутбука.
---@param nb table runs (cell_id -> Run), base (run_id, с которого идёт волна), kernel_state
---@return table|nil { state, done, total, message }; nil — ноутбуку нечего показывать
function M.summarize(nb)
    local done, total, busy = 0, 0, 0
    local waiting, failed
    for _, run in pairs(nb.runs or {}) do
        if run.run_id > (nb.base or 0) then
            total = total + 1
            if exec.is_busy(run) then
                busy = busy + 1
                if run.input_prompt then
                    waiting = waiting or run
                end
            else
                done = done + 1
                local code = run.error and run.error.code
                if run.status == "error" and not M.USER_STOP[code] then
                    -- первую по run_id, а не по порядку pairs: сообщение не должно прыгать
                    if not failed or run.run_id < failed.run_id then
                        failed = run
                    end
                end
            end
        end
    end

    local kstate = nb.kernel_state
    if kstate == "dead" or kstate == "stuck" then
        return {
            state = "blocked",
            done = done,
            total = total,
            message = kstate == "dead" and "ядро умерло" or "ядро молчит",
        }
    end
    if waiting then
        local prompt = waiting.input_prompt ~= "" and (": " .. waiting.input_prompt) or ""
        return { state = "blocked", done = done, total = total, message = "ждёт ввода" .. prompt }
    end
    if busy > 0 then
        return { state = "working", done = done, total = total }
    end
    if failed then
        local code = failed.error and failed.error.code
        return {
            state = "blocked",
            done = done,
            total = total,
            message = ("ошибка в %s%s"):format(failed.cell_id, code and (": " .. code) or ""),
        }
    end
    if total == 0 and (kstate == nil or kstate == "none") then
        return nil -- ядро ни разу не поднимали: в сайдбаре ноутбуку делать нечего
    end
    return { state = "idle", done = done, total = total }
end

---Сложить сводки всех ноутбуков в один статус панели.
---@param list table[] { name, summary }
---@return table|nil { state, label, name, message }; nil — показывать нечего
function M.combine(list)
    local shown = {}
    for _, item in ipairs(list) do
        if item.summary then
            table.insert(shown, item)
        end
    end
    if #shown == 0 then
        return nil
    end
    -- главный — с самым тревожным состоянием; при равенстве тот, что раньше в списке
    local top = shown[1]
    local done, total = 0, 0
    for _, item in ipairs(shown) do
        if RANK[item.summary.state] > RANK[top.summary.state] then
            top = item
        end
        if item.summary.state == "working" then
            done, total = done + item.summary.done, total + item.summary.total
        end
    end
    local name = top.name
    if #shown > 1 then
        name = ("%s +%d"):format(name, #shown - 1)
    end
    return {
        state = top.summary.state,
        label = total > 0 and ("%d/%d"):format(done, total) or nil,
        name = name,
        message = top.summary.message,
    }
end

-- --- состояние и отправка ---

local notebooks = {} -- key -> { name, runs = fn, kernel_state = fn, base }
local order = {} -- ключи в порядке появления: для стабильного «главного» в combine
local last -- последний отправленный статус; nil — ничего не показано
local timer
local seq_base, seq_n = nil, 0

---Номер отчёта. herdr отбрасывает отчёт с номером не больше последнего — и помнит его
---даже после release, так что после перезапуска nvim в той же панели счётчик с нуля
---не прошёл бы ни разу. Отсюда время: миллисекунды × 1000 + номер внутри запуска.
local function seq()
    if not seq_base then
        local sec, usec = vim.uv.gettimeofday()
        seq_base = (sec * 1000 + math.floor(usec / 1000)) * 1000
    end
    seq_n = seq_n + 1
    -- не tostring: число в 16 знаков LuaJIT печатает как 1.7e+15, и herdr его не примет
    return ("%.0f"):format(seq_base + seq_n)
end

---Отключено, или nvim не в herdr.
function M.active()
    return M.enabled ~= false and vim.env.HERDR_ENV == "1" and (vim.env.HERDR_PANE_ID or "") ~= ""
end

---Запустить herdr. Полем модуля — тесты подменяют.
---@param args string[]
---@param wait_ms? integer ждать завершения; без него — не ждём вовсе
function M.spawn(args, wait_ms)
    local cmd = { vim.env.HERDR_BIN_PATH or "herdr" }
    vim.list_extend(cmd, args)
    local ok, proc = pcall(vim.system, cmd, { text = true }, wait_ms == nil and function() end or nil)
    if ok and wait_ms then
        pcall(proc.wait, proc, wait_ms)
    end
end

local function send(status)
    local pane_id = vim.env.HERDR_PANE_ID
    if status == nil then
        M.spawn({ "pane", "release-agent", pane_id, "--source", M.SOURCE, "--agent", M.AGENT, "--seq", seq() })
        return
    end
    local args = {
        "pane", "report-agent", pane_id,
        "--source", M.SOURCE, "--agent", M.AGENT,
        "--state", status.state, "--seq", seq(),
    }
    if status.message then
        vim.list_extend(args, { "--message", status.message })
    end
    M.spawn(args)
    local meta = {
        "pane", "report-metadata", pane_id,
        "--source", M.SOURCE, "--agent", M.AGENT,
        "--display-agent", status.name, "--seq", seq(),
    }
    if status.label then
        vim.list_extend(meta, { "--state-label", "working=" .. status.label })
    else
        table.insert(meta, "--clear-state-labels")
    end
    M.spawn(meta)
end

---Текущий общий статус. Для тестов и :JupyterLog.
function M.current()
    local list = {}
    for _, key in ipairs(order) do
        local nb = notebooks[key]
        table.insert(list, {
            name = nb.name,
            summary = M.summarize({ runs = nb.runs(), base = nb.base, kernel_state = nb.kernel_state() }),
        })
    end
    return M.combine(list)
end

local function same(a, b)
    if a == nil or b == nil then
        return a == b
    end
    return a.state == b.state and a.label == b.label and a.name == b.name and a.message == b.message
end

---Посчитать и отправить, если изменилось.
function M.flush()
    if timer then
        timer:stop()
    end
    if not M.active() then
        return
    end
    local now = M.current()
    if same(now, last) then
        return
    end
    last = now
    send(now)
end

---Отложенный flush. На каждый чанк вывода звать herdr — два процесса на строку tqdm;
---дебаунс собирает их в один отчёт.
function M.schedule()
    if not M.active() then
        return
    end
    timer = timer or vim.uv.new_timer()
    timer:stop()
    timer:start(M.DEBOUNCE_MS, 0, vim.schedule_wrap(M.flush))
end

---Подключить ноутбук.
---@param key any
---@param opts table name, runs = fun(): table, kernel_state = fun(): string
function M.attach(key, opts)
    if not notebooks[key] then
        table.insert(order, key)
    end
    notebooks[key] = { name = opts.name, runs = opts.runs, kernel_state = opts.kernel_state, base = 0 }
end

---Отключить ноутбук: закрыли буфер.
function M.detach(key)
    if not notebooks[key] then
        return
    end
    notebooks[key] = nil
    for i, k in ipairs(order) do
        if k == key then
            table.remove(order, i)
            break
        end
    end
    M.schedule()
end

---Прогон обновился. Новый прогон, пока в ноутбуке ничего не идёт, открывает волну — именно
---здесь, в момент события, а не в отложенном flush: быстрая ячейка успела бы начаться и
---кончиться за время дебаунса, и граница волны потерялась бы.
---@param key any
---@param run jupyter.Run
---@param is_new boolean
function M.update(key, run, is_new)
    local nb = notebooks[key]
    if not nb then
        return
    end
    if is_new then
        local other_busy = false
        for _, r in pairs(nb.runs()) do
            if r ~= run and exec.is_busy(r) then
                other_busy = true
                break
            end
        end
        if not other_busy then
            nb.base = run.run_id - 1
        end
    end
    M.schedule()
end

---Человек посмотрел в nvim: итог закрытой волны больше не требует внимания. Идущую волну
---не трогаем, а смерть ядра держится своим состоянием, не волной.
function M.seen()
    for _, nb in pairs(notebooks) do
        local busy, top = false, nb.base
        for _, run in pairs(nb.runs()) do
            busy = busy or exec.is_busy(run)
            top = math.max(top, run.run_id)
        end
        if not busy then
            nb.base = top
        end
    end
    M.schedule()
end

---Снять статус сразу и дождаться herdr. Для выхода из редактора: отложенный отчёт уже
---не успеет, а панель, оставленная в working, так и висела бы.
function M.release()
    if timer then
        timer:stop()
    end
    if not M.active() or last == nil then
        return
    end
    last = nil
    local pane_id = vim.env.HERDR_PANE_ID
    M.spawn(
        { "pane", "release-agent", pane_id, "--source", M.SOURCE, "--agent", M.AGENT, "--seq", seq() },
        M.RELEASE_TIMEOUT_MS
    )
end

---Сбросить всё. Для тестов.
function M._reset()
    if timer then
        timer:stop()
    end
    notebooks, order, last = {}, {}, nil
    seq_base, seq_n = nil, 0
end

return M
