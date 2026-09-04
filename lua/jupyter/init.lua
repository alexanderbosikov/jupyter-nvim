-- Точка входа: setup(), сборка модулей, публичный API.
--
-- Сессия своя на каждый буфер-ноутбук: ядро, exec и drawer живут вместе и гаснут вместе
-- с буфером. Ядро поднимается лениво, на первом запуске ячейки, а не при открытии файла —
-- иначе просто заглянуть в ноутбук означало бы поднять python-процесс.

local cellid = require("jupyter.cellid")
local cells = require("jupyter.cells")
local common = require("jupyter.ui.common")
local exec = require("jupyter.exec")
local highlight = require("jupyter.highlight")
local images = require("jupyter.images")
local kernel = require("jupyter.kernel")
local output = require("jupyter.ui.output")
local status_ui = require("jupyter.ui.status")
local store = require("jupyter.store")
local picker = require("jupyter.ui.picker")
local toc = require("jupyter.toc")
local table_view = require("jupyter.ui.table")

local M = {}

---@class jupyter.Config
M.defaults = {
    kernel_name = "python3",
    python = nil, -- путь к интерпретатору сайдкара; по умолчанию vim.g.jupyter_python
    env = {},
    filetypes = { "python", "markdown" },
    out_dir = ".jupyter-out",
    -- false — не определять группы подсветки, если хочешь задать их сам
    highlight = true,
    -- картинки рисует image.nvim; false — только путь строкой в выводе
    images = true,
    -- size меньше единицы — доля экрана: 0.5 это половина ширины при position = "right".
    -- preview_rows = 0 — не показывать таблицу в окне вывода, только строку-сводку
    -- open_on_attach — открыть окно вывода сразу при открытии ноутбука
    output = {
        position = "bottom",
        size = 15,
        follow_cursor = true,
        preview_rows = 30,
        open_on_attach = false,
    },
    table = { page_size = 100, max_col = 40 },
    -- статус строкой под ячейкой: enabled = false выключает, position = "eol" ставит в конец строки
    status = { enabled = true, position = "below" },
    -- Клавиши: false — не ставить вовсе, дальше пользователь делает это сам.
    keys = {
        run_cell = "<leader>jc",
        run_all = "<leader>jA",
        run_below = "<leader>jB",
        next_cell = "]c",
        prev_cell = "[c",
        prev_run = "[r",
        next_run = "]r",
        insert_above = "<leader>ja",
        insert_below = "<leader>jb",
        toggle_output = "<leader>jo",
        show_toc = "<leader>jT",
        open_table = "<leader>jt",
        interrupt = "<leader>ji",
        restart = "<leader>jR",
    },
}

M.config = vim.deepcopy(M.defaults)

local sessions = {}
local augroup

local LOG_LIMIT = 200

---@param opts? jupyter.Config
function M.setup(opts)
    opts = opts or {}
    M.config = vim.tbl_deep_extend("force", vim.deepcopy(M.defaults), opts)
    -- keys заменяется целиком, а не сливается: частичное переопределение иначе молча
    -- оставило бы дефолты на остальные действия, а они могут конфликтовать с чужими мапами.
    if opts.keys ~= nil then
        M.config.keys = opts.keys
    end
    augroup = vim.api.nvim_create_augroup("jupyter.nvim", { clear = true })

    require("jupyter.commands").setup(M)
    if M.config.highlight ~= false then
        highlight.attach(augroup)
    end

    vim.api.nvim_create_autocmd("VimLeavePre", {
        group = augroup,
        callback = function()
            M.detach_all()
        end,
    })

    -- Своя реакция на потерю фокуса. У image.nvim она есть, но сравнивает текущий
    -- tmux-window с тем, что был на момент запуска nvim, и при переключении окон
    -- не срабатывает: картинка остаётся висеть поверх чужого окна. Нам сравнивать
    -- нечего — потеряли фокус, сняли; вернули — нарисовали заново.
    vim.api.nvim_create_autocmd({ "FocusLost", "VimSuspend" }, {
        group = augroup,
        callback = function()
            M.on_focus(false)
        end,
    })
    vim.api.nvim_create_autocmd({ "FocusGained", "VimResume" }, {
        group = augroup,
        callback = function()
            M.on_focus(true)
        end,
    })

    vim.api.nvim_create_autocmd("FileType", {
        group = augroup,
        pattern = M.config.filetypes,
        callback = function(ev)
            if M.config.keys ~= false then
                M.set_keys(ev.buf)
            end
            if M.config.output.open_on_attach then
                M.open_for(ev.buf)
            end
        end,
    })
end

---Поставить буфер-локальные мапы. Значением действия может быть как одна клавиша,
---так и список: `next_cell = { "<C-j>", "]n" }` — привычная и идиоматичная разом.
---@param buf? integer
function M.set_keys(buf)
    buf = buf or vim.api.nvim_get_current_buf()
    for action, keys in pairs(M.config.keys or {}) do
        local fn = M[action]
        if fn and keys then
            for _, key in ipairs(type(keys) == "table" and keys or { keys }) do
                common.map("n", key, function() fn() end, {
                    buffer = buf,
                    silent = true,
                    desc = "jupyter: " .. action,
                })
            end
        end
    end
end

-- --- сессии ---

---@return table
function M.session(buf)
    buf = buf or vim.api.nvim_get_current_buf()
    local found = sessions[buf]
    if found then
        return found
    end

    -- курсор может стоять в наших же окнах — в drawer'е или во вкладке таблицы.
    -- Тогда сессия та же, что у ноутбука, которому они принадлежат, а не новая.
    for _, session in pairs(sessions) do
        if buf == session.output.buf or buf == session.table.buf then
            return session
        end
    end

    local sc = require("jupyter.sidecar").new({ python = M.config.python })
    local k = kernel.new({
        sidecar = sc,
        kernel_name = M.config.kernel_name,
        env = M.config.env,
    })
    local ex, drawer
    drawer = output.new(vim.tbl_extend("force", M.config.output, {
        -- сколько прогонов идёт помимо показываемого: без статуса под ячейкой (шаг 6)
        -- это единственный признак, что где-то ещё выполняется запрос
        pending = function()
            if not ex then
                return 0
            end
            local shown = drawer.run and drawer.run.cell_id
            local count = 0
            for cell_id, run in pairs(ex.runs) do
                if run.status == "running" and cell_id ~= shown then
                    count = count + 1
                end
            end
            return count
        end,
        -- вывод получен из другого кода, чем сейчас в ячейке: сравниваем sha так же,
        -- как считает сайдкар. Это и есть ответ на «почему тут старый вывод»
        stale = function(run)
            return M.is_stale(buf, run)
        end,
        preview = function(run, limit, cb)
            sc:request("table.page", { path = run.table.path, offset = 0, limit = limit }, function(err, page)
                if err then
                    return cb({ "(не удалось прочитать таблицу: " .. (err.msg or err.code or "?") .. ")" })
                end
                local lines = table_view.format(page.header, page.rows, { max_col = M.config.table.max_col })
                local shown = #page.rows
                if page.total_rows > shown then
                    table.insert(lines, (" … ещё %d строк · :JupyterTable"):format(page.total_rows - shown))
                end
                cb(lines)
            end)
        end,
        preview_rows = M.config.output.preview_rows,
        on_open_table = function()
            M.open_table()
        end,
        images = images.new({ enabled = M.config.images ~= false }),
    }))
    ex = exec.new({
        kernel = k,
        on_update = function(run, is_new)
            -- Новый прогон показываем всегда, даже если окно было закрыто: нажал запуск —
            -- хочешь видеть результат. Обновление чужого прогона окно не забирает, но
            -- счётчик «ещё выполняется» в winbar обновить надо.
            if is_new then
                local session = sessions[buf]
                if session then
                    session.browse[run.cell_id] = nil -- новый прогон снимает просмотр истории
                end
                drawer:show(run)
            elseif not drawer:update(run) then
                drawer:refresh_status()
            end
            M.repaint(buf)
        end,
    }):attach()

    local tbl = table_view.new({
        sidecar = sc,
        page_size = M.config.table.page_size,
        max_col = M.config.table.max_col,
    })

    local name = vim.api.nvim_buf_get_name(buf)
    found = {
        buf = buf,
        kernel = k,
        exec = ex,
        output = drawer,
        table = tbl,
        status = status_ui.new(M.config.status),
        store = store.new({ notebook = name ~= "" and name or nil, out_dir = M.config.out_dir }),
        stale_cache = { tick = -1, value = {} },
        browse = {}, -- cell_id -> номер просматриваемого прогона в истории
        started = false,
        log = {},
    }
    sessions[buf] = found

    -- Диагностика. Без этого любая поломка сайдкара была бы невидимой: события log
    -- приходят, но подписчика нет, и они просто теряются.
    sc:on("log", function(msg)
        local data = msg.data or {}
        table.insert(found.log, {
            at = os.date("%H:%M:%S"),
            level = data.level or "info",
            msg = tostring(data.msg or ""),
        })
        if #found.log > LOG_LIMIT then
            table.remove(found.log, 1)
        end
        -- "kernel" — это собственный вывод ядра (баннеры на старте), не ошибка.
        if data.level == "error" or data.level == "stderr" then
            vim.notify("jupyter.nvim: " .. tostring(data.msg), vim.log.levels.ERROR)
        end
    end)
    sc:on("orphan", function(msg)
        table.insert(found.log, {
            at = os.date("%H:%M:%S"),
            level = "orphan",
            msg = ("сообщение с неизвестным родителем: %s"):format((msg.data or {}).msg_type or "?"),
        })
    end)
    k.on_state = function(state, data)
        table.insert(found.log, { at = os.date("%H:%M:%S"), level = "state", msg = state })
        if state == "dead" then
            vim.notify(
                "jupyter.nvim: ядро умерло — " .. ((data or {}).reason or "причина неизвестна"),
                vim.log.levels.ERROR
            )
        end
    end

    vim.api.nvim_create_autocmd("VimResized", {
        group = augroup or vim.api.nvim_create_augroup("jupyter.nvim", { clear = false }),
        callback = function()
            local session = sessions[buf]
            if session then
                session.output:resize()
            end
        end,
    })

    vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI", "InsertLeave" }, {
        group = augroup or vim.api.nvim_create_augroup("jupyter.nvim", { clear = false }),
        buffer = buf,
        callback = function()
            M.repaint(buf)
        end,
    })

    if M.config.output.follow_cursor ~= false then
        vim.api.nvim_create_autocmd("CursorMoved", {
            group = augroup or vim.api.nvim_create_augroup("jupyter.nvim", { clear = false }),
            buffer = buf,
            callback = function()
                M.follow_cursor(buf)
            end,
        })
    end

    vim.api.nvim_create_autocmd({ "BufUnload" }, {
        group = augroup or vim.api.nvim_create_augroup("jupyter.nvim", { clear = false }),
        buffer = buf,
        callback = function()
            M.detach(buf)
        end,
    })
    return found
end

---Код ячейки изменился с момента прогона? Ответ кэшируется по changedtick: функция
---зовётся на каждое движение курсора и на каждую правку.
---@param buf integer
---@param run jupyter.Run|nil
---@return boolean
function M.is_stale(buf, run)
    local s = sessions[buf]
    if not s or not run or not run.code_sha then
        return false
    end

    local tick = vim.api.nvim_buf_get_changedtick(buf)
    if s.stale_cache.tick ~= tick then
        s.stale_cache = { tick = tick, value = {} }
    end
    local key = run.cell_id .. ":" .. run.code_sha
    if s.stale_cache.value[key] == nil then
        local cell = cellid.find(buf, run.cell_id)
        s.stale_cache.value[key] = cell ~= nil
            and vim.fn.sha256(cells.text(buf, cell)):sub(1, 8) ~= run.code_sha
    end
    return s.stale_cache.value[key]
end

---Открыть окно вывода при открытии ноутбука — если есть что показать.
---
---Две проверки, и обе нужны. Ячейки: `ft = python` ловит любой скрипт, поднимать над ним
---окно незачем. История: пустое окно на пол-экрана хуже, чем никакого, а при первом же
---запуске ячейки окно откроется само. Ядро при этом не стартует — оно по-прежнему ленивое.
---@param buf integer
---@return boolean открыли
function M.open_for(buf)
    local list = cells.list(buf)
    if #list == 0 then
        return false
    end

    local s = M.session(buf)
    M.repaint(buf) -- статусы под ячейками рисуем в любом случае: они не занимают окна

    -- Открываем один раз на сессию. FileType срабатывает на каждое перечитывание буфера —
    -- например при прыжке из telescope, — и без этого окно вывода поднималось бы заново
    -- после каждого перехода, даже если его только что закрыли руками.
    if s.attached then
        return false
    end

    -- показать прогон ячейки под курсором, иначе самый свежий по ноутбуку
    local run
    local cell = cells.at(buf, vim.api.nvim_win_get_cursor(0)[1])
    if cell then
        run = s.store:last_run(exec.cell_id(buf, cell))
    end
    run = run or s.store:to_run(s.store:latest_record())
    if not run then
        return false
    end

    -- отмечаем по факту открытия: если показывать было нечего, попытка не считается
    s.attached = true
    s.output:show(run)
    return true
end

---Реакция на фокус окна: без фокуса картинок на экране быть не должно.
---@param gained boolean
function M.on_focus(gained)
    for _, session in pairs(sessions) do
        -- в журнал: по нему видно, доходит ли до nvim focus-событие от tmux
        table.insert(session.log, {
            at = os.date("%H:%M:%S"),
            level = "focus",
            msg = gained and "фокус вернулся" or "фокус потерян, картинки сняты",
        })
        if not gained then
            session.output.images:clear(session.output.buf)
        elseif session.output:is_open() and session.output.run and session.output.run.image then
            local drawer = session.output
            vim.schedule(function()
                drawer:render()
            end)
        end
    end
end

---Снять все картинки этой сессии. Аварийный выход: image.nvim не удаляет картинки из
---своего состояния сам, и если что-то всё же осталось на экране — это лечится отсюда.
---@param buf? integer
function M.clear_images(buf)
    buf = buf or vim.api.nvim_get_current_buf()
    local s = sessions[buf]
    if not s then
        return false
    end
    s.output.images:clear(s.output.buf)
    return true
end

---Перерисовать состояние: статусы под ячейками и строку drawer'а.
---Зовётся на правку буфера и на движение курсора — оба дешёвые благодаря кэшу выше.
---@param buf? integer
function M.repaint(buf)
    buf = buf or vim.api.nvim_get_current_buf()
    local s = sessions[buf]
    if not s then
        return 0
    end

    local entries = {}
    for _, cell in ipairs(cells.list(buf)) do
        local cell_id = exec.cell_id(buf, cell)
        local run = s.exec:run_for(cell_id) or s.store:last_run(cell_id)
        if run then
            local text, group = status_ui.text_of(run, M.is_stale(buf, run))
            local _, last = cells.body(buf, cell)
            table.insert(entries, { row = last, text = text, group = group })
        end
    end

    local drawn = s.status:render(buf, entries)
    if s.output:is_open() then
        s.output:refresh_status()
    end
    return drawn
end

---Показать в drawer'е вывод ячейки под курсором.
---
---Правило одно: переключаемся, только если у ячейки под курсором есть прогон — пустое окно
---вместо чужого вывода никому не нужно. Идущий запрос при этом уходить из вида не мешает:
---пока он выполняется, в winbar висит счётчик «ещё N», а его завершение окно не забирает.
---@param buf integer
function M.follow_cursor(buf)
    local s = sessions[buf]
    if not s or not s.output:is_open() then
        return
    end
    local shown = s.output.run

    local cell = cells.at(buf, vim.api.nvim_win_get_cursor(0)[1])
    if not cell then
        s.output:focus_cell(nil) -- курсор в markdown между ячейками
        return
    end
    local cell_id = exec.cell_id(s.buf, cell)
    -- если по этой ячейке листают историю, курсор не должен возвращать к последнему прогону
    local browsing = s.browse[cell_id]
    local run
    if browsing then
        run = s.store:to_run(s.store:records_of(cell_id)[browsing])
    end
    -- иначе: прогон этой сессии, потом история с диска — так вывод вчерашней ячейки
    -- виден сразу при открытии файла, без перезапуска и без ядра
    run = run or s.exec:run_for(cell_id) or s.store:last_run(cell_id)
    if run and (not shown or shown.cell_id ~= run.cell_id or shown.run_id ~= run.run_id) then
        s.output:show(run)
    else
        s.output:refresh_status() -- прогон тот же, но «код изменился» мог поменяться
        -- ушли на ячейку, которую ещё не запускали: показанный прогон не сменился,
        -- а картинка от него висеть над чужой ячейкой не должна
        s.output:focus_cell(cell_id)
    end
end

---Поднять ядро, если оно ещё не поднято.
function M.ensure_started(buf)
    local s = M.session(buf)
    if s.started then
        return s
    end
    s.started = true

    local name = vim.api.nvim_buf_get_name(s.buf)
    s.kernel:start({
        -- notebook включает запись выводов в .jupyter-out/. На шаге 3 cell_id — это номер
        -- ячейки, поэтому вставка ячейки выше сдвигает привязку на диске; стабильный id
        -- из текста приходит на шаге 5 (ARCHITECTURE.md §10).
        notebook = name ~= "" and name or nil,
        cwd = name ~= "" and vim.fn.fnamemodify(name, ":h") or nil,
    }, function(err)
        if err then
            vim.notify(
                ("jupyter.nvim: ядро не поднялось — %s: %s"):format(err.code or "?", err.msg or ""),
                vim.log.levels.ERROR
            )
        end
    end)
    return s
end

---Погасить сессию буфера и дождаться выхода сайдкара.
---Ждём намеренно: иначе при выходе из nvim остаются висеть python-процесс и ядро.
---@param buf integer
---@param timeout_ms? integer
function M.detach(buf, timeout_ms)
    local s = sessions[buf]
    if not s then
        return
    end
    sessions[buf] = nil
    s.status:clear(buf)
    s.output:close()
    s.table:close()
    s.kernel:stop()
    s.kernel.sidecar:wait(timeout_ms or 3000)
end

---Погасить все сессии. Вешается на VimLeavePre.
function M.detach_all()
    for buf in pairs(vim.deepcopy(sessions)) do
        M.detach(buf, 1500)
    end
end

-- --- действия ---

function M.run_cell()
    local s = M.ensure_started()
    local row = vim.api.nvim_win_get_cursor(0)[1]
    if not s.exec:run_at(s.buf, row) then
        vim.notify("jupyter.nvim: под курсором нет ячейки с кодом", vim.log.levels.WARN)
    end
end

function M.run_all()
    local s = M.ensure_started()
    s.exec:run_all(s.buf)
end

function M.run_below()
    local s = M.ensure_started()
    s.exec:run_all(s.buf, vim.api.nvim_win_get_cursor(0)[1])
end

local function jump(cell)
    if cell then
        vim.api.nvim_win_set_cursor(0, { cell.start_row, 0 })
    end
end

function M.next_cell()
    jump(cells.next(0, vim.api.nvim_win_get_cursor(0)[1]))
end

function M.prev_cell()
    jump(cells.prev(0, vim.api.nvim_win_get_cursor(0)[1]))
end

function M.insert_above()
    local row = cells.insert(0, vim.api.nvim_win_get_cursor(0)[1], "above")
    vim.api.nvim_win_set_cursor(0, { row, 0 })
end

function M.insert_below()
    local row = cells.insert(0, vim.api.nvim_win_get_cursor(0)[1], "below")
    vim.api.nvim_win_set_cursor(0, { row, 0 })
end

---Открыть таблицу-результат ячейки под курсором. Если её нет — того прогона, что показан
---в drawer'е: так работает и когда курсор стоит в markdown между ячейками.
function M.open_table()
    local s = M.session()
    local run
    -- позиция курсора имеет смысл только в самом ноутбуке: из drawer'а берём
    -- тот прогон, который в нём сейчас показан
    if vim.api.nvim_get_current_buf() == s.buf then
        local cell = cells.at(s.buf, vim.api.nvim_win_get_cursor(0)[1])
        if cell then
            local cell_id = exec.cell_id(s.buf, cell)
            run = s.exec:run_for(cell_id) or s.store:last_run(cell_id)
        end
    end
    run = run or s.output.run

    if not run then
        vim.notify("jupyter.nvim: ячейка ещё не выполнялась", vim.log.levels.WARN)
        return
    end
    if not (run.table and run.table.path) then
        vim.notify(
            ("jupyter.nvim: у ячейки %s нет результата-таблицы"):format(run.cell_id),
            vim.log.levels.WARN
        )
        return
    end
    s.table:open(run.table.path, ("ячейка %s · прогон %d"):format(run.cell_id, run.run_id))
end

function M.toggle_output()
    M.session().output:toggle()
end

function M.interrupt()
    M.session().kernel:interrupt()
end

function M.restart()
    M.session().kernel:restart(function(err)
        if err then
            vim.notify("jupyter.nvim: рестарт не удался — " .. (err.msg or ""), vim.log.levels.ERROR)
        else
            vim.notify("jupyter.nvim: ядро перезапущено")
        end
    end)
end

---Последние сообщения сайдкара и переходы состояний. Первое, куда смотреть, если что-то не так.
---@return table[]
function M.log(buf)
    return M.session(buf).log
end

---Показать журнал в scratch-буфере.
function M.show_log()
    local entries = M.log()
    local lines = {}
    for _, entry in ipairs(entries) do
        table.insert(lines, ("%s  %-7s %s"):format(entry.at, entry.level, entry.msg))
    end
    if #lines == 0 then
        lines = { "журнал пуст" }
    end

    local buf = common.scratch_buf("jupyter://log", "jupyter-log")
    common.set_lines(buf, lines)
    vim.cmd(("botright %dsplit"):format(math.min(#lines + 1, 20)))
    vim.api.nvim_win_set_buf(0, buf)
    common.map("n", "q", "<cmd>close<cr>", { buffer = buf, nowait = true, silent = true })
end

function M.status()
    local s = M.session()
    local known_cells, known_runs = s.store:size()
    return {
        state = s.kernel:state(),
        queued = s.kernel:queued(),
        info = s.kernel:info(),
        cells = #cells.list(s.buf),
        history_cells = known_cells,
        history_runs = known_runs,
    }
end

---Листать историю прогонов ячейки под курсором.
---@param step integer -1 назад, 1 вперёд
---@return jupyter.Run|nil
function M.browse_run(step)
    local s = M.session()
    local cell = cells.at(s.buf, vim.api.nvim_win_get_cursor(0)[1])
    if not cell then
        vim.notify("jupyter.nvim: под курсором нет ячейки", vim.log.levels.WARN)
        return nil
    end

    local cell_id = exec.cell_id(s.buf, cell)
    s.store:load() -- индекс мог дописаться после последнего прогона
    local records = s.store:records_of(cell_id)
    if #records == 0 then
        vim.notify("jupyter.nvim: истории по этой ячейке нет", vim.log.levels.WARN)
        return nil
    end

    local at = s.browse[cell_id] or #records
    local want = math.min(#records, math.max(1, at + step))
    s.browse[cell_id] = want

    local run = s.store:to_run(records[want])
    s.output:show(run)
    vim.notify(("jupyter.nvim: прогон %d из %d%s"):format(
        want,
        #records,
        run.status == "error" and (" · " .. (run.error and run.error.code or "ошибка")) or ""
    ))
    return run
end

function M.prev_run()
    return M.browse_run(-1)
end

function M.next_run()
    return M.browse_run(1)
end

---Оглавление ноутбука: заголовки вместе с ячейками и их состоянием.
---@param buf? integer
---@return jupyter.TocEntry[]
function M.toc(buf)
    buf = buf or vim.api.nvim_get_current_buf()
    local s = sessions[buf]
    return toc.collect(buf, {
        run_of = s and function(cell)
            local cell_id = exec.cell_id(buf, cell)
            return s.exec:run_for(cell_id) or s.store:last_run(cell_id)
        end or nil,
    })
end

---Показать оглавление списком и прыгнуть к выбранному.
---Списком, а не сайдбаром: он появляется, отрабатывает и исчезает, не занимая места.
function M.show_toc()
    local buf = vim.api.nvim_get_current_buf()
    local entries = M.toc(buf)
    if #entries == 0 then
        vim.notify("jupyter.nvim: ни заголовков, ни ячеек не нашлось", vim.log.levels.WARN)
        return
    end

    picker.select(entries, {
        prompt = "Оглавление",
        format = toc.format,
        buf = buf,
    }, function(choice)
        vim.api.nvim_win_set_cursor(0, { choice.row, 0 })
        vim.cmd("normal! zz")
    end)
end

---Перечитать историю прогонов с диска: нужно, если ноутбук считали заново
---или его правили другим редактором.
function M.reload_history()
    local s = M.session()
    local count = s.store:load()
    vim.notify(("jupyter.nvim: прочитано прогонов — %d"):format(count))
    return count
end

return M
