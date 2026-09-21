-- Точка входа: setup(), сборка модулей, публичный API.
--
-- Сессия своя на каждый буфер-ноутбук: ядро, exec и drawer живут вместе и гаснут вместе
-- с буфером. Ядро поднимается лениво, на первом запуске ячейки, а не при открытии файла —
-- иначе просто заглянуть в ноутбук означало бы поднять python-процесс.

local cellid = require("jupyter.cellid")
local cells = require("jupyter.cells")
local edit = require("jupyter.edit")
local common = require("jupyter.ui.common")
local draft = require("jupyter.draft")
local exec = require("jupyter.exec")
local highlight = require("jupyter.highlight")
local images = require("jupyter.images")
local kernel = require("jupyter.kernel")
local output = require("jupyter.ui.output")
local status_ui = require("jupyter.ui.status")
local store = require("jupyter.store")
local picker = require("jupyter.ui.picker")
local agent = require("jupyter.agent")
local ask = require("jupyter.ask")
local pane = require("jupyter.pane")
local snapshot = require("jupyter.snapshot")
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
    -- Оставлять ли ядро жить после выхода из редактора. По умолчанию нет: забытое ядро
    -- держит память и соединения, а заметить его труднее, чем потерять. Кому дороже
    -- состояние — включает, и тогда :JupyterAttach при следующем открытии вернёт его.
    keep_kernel_on_exit = false,
    -- false — не определять группы подсветки, если хочешь задать их сам
    highlight = true,
    -- Прогресс-бар текстом вместо виджета: tqdm в ядре с ipywidgets рисует бар через
    -- comm-протокол, которого у нас нет, и ячейка с долгим циклом навсегда остаётся на
    -- «0%» (§6.6). false — не трогать ядро, бар тогда не обновляется вовсе.
    text_progress = true,
    -- картинки рисует image.nvim; false — только путь строкой в выводе
    -- Прыжок по ячейкам центрирует экран. Без этого следующая ячейка встаёт у нижнего
    -- края, и её тело остаётся за кадром — а прыгают именно чтобы его увидеть.
    center_on_jump = true,
    -- Новая ячейка пустая: сразу встаём в insert, чтобы не нажимать `i` после каждой вставки.
    insert_on_new_cell = true,
    images = true,
    -- Черновик несохранённого буфера: защита от краша и от «забыл сохранить». Пишется
    -- текст буфера как есть, рядом с историей прогонов, мимо файла ноутбука — настоящая
    -- запись тут дорогая (jupytext гоняет конвертер) и тянет за собой чужие BufWritePre.
    -- Подробности и то, чего нельзя делать с путями, — в draft.lua.
    --
    -- write_on_run сохраняет ноутбук по-настоящему перед прогоном ячейки: код, который
    -- выполнился, тогда лежит на диске, и code_sha в истории относится к нему, а не к
    -- фантому в буфере. По умолчанию выключено, потому что `:w` зовёт чужие автокоманды —
    -- форматтер переформатирует markdown прямо во время работы.
    autosave = {
        draft = true,
        debounce_ms = 2000,
        write_on_run = false,
        write_on_focus_lost = false,
    },
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
    -- Заявка внешнего агента на правку ячейки. Метка `✎ имя` стоит в буфере, пока он
    -- думает, и в ней тикает возраст — по нему видно, что работа идёт. Вестей нет дольше
    -- ttl_ms — заявка снимается сама: агент мог упасть, упереться в лимит или уйти
    -- спрашивать, а метка всё это время держала бы ячейку занятой (§7.5).
    -- sign — знак в signcolumn на строках заявки; false или "" — не ставить.
    -- verb — что агент делает с куском; в подписи рамки это слово между его именем и
    -- возрастом заявки: « ⠋ Claude правит · 12с ». Кому привычнее 99 — "Implementing".
    -- cmd — по какой команде узнаём панель tmux с агентом: кто-то запускает claude
    -- через обёртку, и тогда tmux показывает её имя, а не claude.
    -- ask_height — высота окна, в котором набирается промпт.
    agent = {
        ttl_ms = 5 * 60 * 1000,
        sign = "✎",
        verb = "правит",
        verb_insert = "пишет новую ячейку",
        cmd = "claude",
        ask_height = 8,
    },
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
        edit_cell_args = "<leader>jg", -- g как «аргументы»: jа/jb/jc уже заняты
        -- перестройка ячеек. m и y — как в командном режиме Jupyter, остальное свободно
        split_cell = "<leader>js",
        merge_cell = "<leader>jM",
        move_cell_up = "<leader>jK",
        move_cell_down = "<leader>jJ",
        cell_to_markdown = "<leader>jm",
        cell_to_code = "<leader>jy",
        cell_lang = "<leader>jl", -- l как «language»: переключает python ↔ sql
        -- q как «вопрос»: тот же ключ в visual спрашивает про выделенный кусок
        ask = "<leader>jq",
        -- начало и конец своей ячейки: пара к ]c/[c, которые ходят по соседним
        cell_start = "[C",
        cell_end = "]C",
        interrupt = "<leader>ji",
        restart = "<leader>jR",
    },
    -- Текстовые объекты ячейки, visual и operator-pending: ic — тело, ac — вместе с
    -- маркером и закрывающим фенсом. Отдельно от keys, потому что там нормальный режим.
    textobjects = {
        inner = "ic",
        around = "ac",
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

    local agent_cfg = M.config.agent or {}
    agent.TTL_MS = agent_cfg.ttl_ms or agent.TTL_MS
    agent.SIGN = agent_cfg.sign ~= false and agent_cfg.sign or nil
    agent.VERB = agent_cfg.verb or agent.VERB
    agent.VERB_INSERT = agent_cfg.verb_insert or agent.VERB_INSERT
    pane.CMD = agent_cfg.cmd or pane.CMD
    ask.HEIGHT = agent_cfg.ask_height or ask.HEIGHT

    require("jupyter.commands").setup(M)
    if M.config.highlight ~= false then
        highlight.attach(augroup)
    end

    vim.api.nvim_create_autocmd("VimLeavePre", {
        group = augroup,
        callback = function()
            -- Черновики первыми: detach_all гасит сессии и может занять время, а выход с
            -- несохранённым буфером — ровно тот случай, ради которого черновик и есть.
            draft.flush_all("выход из редактора")
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

    -- Окно вывода принадлежит ноутбуку, а не экрану. Сессия своя на каждый буфер, и
    -- drawer вместе с ней, поэтому открыть второй ноутбук поверх первого (через yazi,
    -- :e, что угодно) означало два окна вывода на экране: одно от ноутбука, которого
    -- уже не видно, второе от нового. Правило простое: окна вывода следуют за тем, какие
    -- ноутбуки сейчас на экране — ушёл с глаз, окно ушло; вернулся, окно вернулось.
    --
    -- Проверяем по всем вкладкам (win_findbuf), а не по текущей: два ноутбука в разных
    -- вкладках — законный случай, и закрывать чужой drawer при переключении вкладки
    -- нельзя. Два ноутбука рядом в сплитах тоже переживут: оба буфера показаны.
    vim.api.nvim_create_autocmd({ "BufWinEnter", "WinClosed" }, {
        group = augroup,
        callback = function(ev)
            -- Появление наших собственных окон — не повод для проверки. Drawer,
            -- открываясь, шлёт BufWinEnter сам за себя, и без этой оговорки закрывал
            -- бы себя же в тот же миг, если буфер ноутбука в этот момент нигде не
            -- показан. Событие от чужого буфера (в том числе не-ноутбука: открыли
            -- в том же окне текстовый файл) проверку по-прежнему запускает.
            for _, session in pairs(sessions) do
                if ev.buf == session.output.buf or ev.buf == session.table.buf then
                    return
                end
            end
            M.sync_output_windows()
        end,
    })

    vim.api.nvim_create_autocmd("FileType", {
        group = augroup,
        pattern = M.config.filetypes,
        callback = function(ev)
            if M.config.keys ~= false then
                M.set_keys(ev.buf)
            end
            M.warn_orphan(ev.buf)
            M.watch_draft(ev.buf)
            if M.config.output.open_on_attach then
                M.open_for(ev.buf)
            end
        end,
    })
end

---Свести окна вывода с тем, какие ноутбуки сейчас на экране.
---
---Ноутбук пропал с глаз — его окно вывода уходит; вернулся — окно возвращается таким же.
---Второе не менее важно первого: без него переключение через telescope, harpoon или yazi
---оставляло бы после себя пустое место, а поднимать окно приходилось бы руками.
---
---Закрытое нами помечается (`output_hidden`), и возвращаем мы только его. Окно, закрытое
---руками по `toggle_output`, обратно не всплывает: пользователь его закрыл, значит не
---хотел видеть.
---
---Сессия при этом не трогается вовсе: ядро работает, переменные живы, прогоны идут,
---история копится. Уходит только окно (и картинки вместе с ним — они рисуются поверх
---и без окна висели бы над чужим текстом).
---@return integer скрыли, integer вернули
function M.sync_output_windows()
    local hidden, shown = 0, 0
    for buf, session in pairs(sessions) do
        local visible = #vim.fn.win_findbuf(buf) > 0
        if not visible and session.output:is_open() then
            session.output:close()
            session.output_hidden = true
            hidden = hidden + 1
        elseif visible and session.output_hidden and not session.output:is_open() then
            if session.output.run then
                session.output:show(session.output.run) -- с последним прогоном, он мог смениться
            else
                session.output:open()
            end
            session.output_hidden = nil
            shown = shown + 1
        end
    end
    return hidden, shown
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

    -- Спросить про выделенное — тем же ключом, что и про ячейку: место в промпте
    -- разное, действие одно, и держать под него вторую клавишу в памяти незачем.
    local ask_key = (M.config.keys or {}).ask
    if ask_key then
        common.map("x", ask_key, function()
            M.ask_selection()
        end, { buffer = buf, silent = true, desc = "jupyter: спросить про выделенное" })
    end

    for kind, key in pairs(M.config.textobjects or {}) do
        if key then
            common.map({ "x", "o" }, key, function()
                M.select_cell(kind == "inner")
            end, {
                buffer = buf,
                silent = true,
                desc = "jupyter: ячейка (" .. kind .. ")",
            })
        end
    end
end

---Выделить ячейку под курсором: тело или ячейку целиком.
---
---Выделение линейное: ячейка — это всегда строки целиком, посимвольное здесь лишено
---смысла. Годится и для visual, и для operator-pending — оператор применяется к тому,
---что выделено, поэтому отдельной ветки под `d`/`y`/`c` не нужно.
---@param inner boolean тело без маркера и закрывающего фенса
---@return boolean выделили ли что-нибудь
function M.select_cell(inner)
    local buf = vim.api.nvim_get_current_buf()
    local row = vim.api.nvim_win_get_cursor(0)[1]
    local cell = cells.at(buf, row)
    if not cell then
        return false -- курсор в прозе: молча ничего не делаем, как и штатные объекты
    end
    local from = inner and cell.start_row or cell.span_start
    local to = inner and cell.end_row or cell.span_end
    -- Из visual-режима выходим перед выделением. Нажатое `v` уже поставило якорь, и одно
    -- движение курсора его не сдвинет: выделение пошло бы от якоря до конца ячейки, то
    -- есть с середины — половина. В operator-pending якоря нет, поэтому там всё работало
    -- и тесты на `dic`/`yac` этого не ловили.
    if vim.fn.mode():match("^[vV\22]") then
        vim.cmd("normal! \27")
    end
    vim.cmd(("normal! %dGV%dG"):format(from, to))
    return true
end

-- --- сессии ---

---Выполнить, когда сайдкар поднят, подняв его при необходимости.
---
---Parquet читает сайдкар — polars живёт там, — поэтому и предпросмотр таблицы в окне
---вывода, и само окно таблицы без него не работают. А поднимается он лениво, при первом
---прогоне ячейки. История же обещана и БЕЗ ядра: открыл ноутбук — вчерашний вывод на
---месте (README, «Свежий вывод и старый»). Для таблиц это обещание не держалось: до
---первого прогона в окне стояло «не удалось прочитать таблицу: сайдкар не запущен».
---
---Ядро при этом не поднимается: сайдкар и ядро — разные процессы, `hello` ядра не
---требует, так что лень ядра остаётся в силе.
---@param sc table
---@param cb fun(err?: table)
local function with_sidecar(sc, cb)
    if sc:is_running() then
        return cb()
    end
    sc:start(function(err)
        if err and err.code ~= "already_running" then
            return cb(err)
        end
        cb()
    end)
end

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
        text_progress = M.config.text_progress,
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
                if exec.is_busy(run) and cell_id ~= shown then
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
            with_sidecar(sc, function(start_err)
            if start_err then
                return cb({ "(сайдкар не поднялся: " .. (start_err.msg or start_err.code or "?") .. ")" })
            end
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
            end)
        end,
        preview_rows = M.config.output.preview_rows,
        on_open_table = function()
            M.open_table()
        end,
        images = images.new({ enabled = M.config.images ~= false }),
    }))
    -- Ячейку, которую прямо сейчас переписывает агент, не запускаем: её код через
    -- секунду будет другим, а прогон уже уедет в историю как настоящий. Сообщаем не
    -- чаще раза в секунду — «запустить всё» иначе даёт залп одинаковых уведомлений.
    local said_blocked = 0
    ex = exec.new({
        kernel = k,
        blocked = function(cell_id)
            local claim = agent.claim_of(buf, cell_id)
            if not claim then
                return false
            end
            local now = vim.uv.now()
            if now - said_blocked > 1000 then
                said_blocked = now
                vim.notify(
                    ("jupyter.nvim: ячейку правит %s — запуск отклонён"):format(claim.label),
                    vim.log.levels.WARN
                )
            end
            return true
        end,
        on_update = function(run, is_new)
            -- Новый прогон показываем всегда, даже если окно было закрыто: нажал запуск —
            -- хочешь видеть результат. Обновление чужого прогона окно не забирает, но
            -- счётчик «ещё выполняется» в winbar обновить надо.
            if is_new then
                local session = sessions[buf]
                if session then
                    session.browse[run.cell_id] = nil -- новый прогон снимает просмотр истории
                end
                -- Ноутбука не видно — окно не поднимаем: прогоны спрятанного ноутбука
                -- идут своим чередом, но всплывать поверх чужого документа они не право.
                -- Прогон запоминаем и помечаем сессию: вернёшься — окно откроется с ним.
                if #vim.fn.win_findbuf(buf) > 0 then
                    drawer:show(run)
                else
                    drawer:stage(run)
                    if session then
                        session.output_hidden = true
                    end
                end
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
        sidecar = sc,
        exec = ex,
        output = drawer,
        table = tbl,
        status = status_ui.new(M.config.status),
        store = store.new({ notebook = name ~= "" and name or nil, out_dir = M.config.out_dir }),
        stale_cache = { value = {}, dirty = nil }, -- dirty: диапазон строк, правленных после расчёта
        browse = {}, -- cell_id -> номер просматриваемого прогона в истории
        started = false,
        log = {},
    }
    sessions[buf] = found
    M.watch_edits(buf) -- диапазоны правок для кэша свежести

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

    -- TextChangedP отдельно от TextChangedI: пока открыто меню автодополнения, nvim шлёт
    -- именно его. В ячейках работает LSP через otter, меню там обычное дело, и без этого
    -- события пометка «код правили после прогона» ждала, пока сработает что-то ещё.
    vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI", "TextChangedP", "InsertLeave" }, {
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

    -- Подстраховка на случай правки, о которой не пришло ни одно из событий выше: раз
    -- диапазон правленых строк непуст, статусы устарели. Стоит это ноль, пока не правили,
    -- потому что диапазон копится в on_lines, а он не врёт ни в одном режиме.
    vim.api.nvim_create_autocmd("CursorMoved", {
        group = augroup or vim.api.nvim_create_augroup("jupyter.nvim", { clear = false }),
        buffer = buf,
        callback = function()
            local session = sessions[buf]
            if session and session.stale_cache.dirty then
                M.repaint(buf)
            end
        end,
    })

    vim.api.nvim_create_autocmd({ "BufUnload" }, {
        group = augroup or vim.api.nvim_create_augroup("jupyter.nvim", { clear = false }),
        buffer = buf,
        callback = function()
            M.detach(buf)
        end,
    })
    return found
end

---Код ячейки изменился с момента прогона? Считается через sha, как у сайдкара.
---
---Зовётся на каждую правку для каждой ячейки с историей, поэтому ответ кэшируется.
---Сбрасывать кэш целиком по changedtick было дорого: печатают всегда в одной ячейке, а
---пересчитывались все — на 27 ячейках это 2.4 мс на нажатие, и растёт линейно. Теперь
---`on_lines` (см. watch_edits) копит диапазон правленых строк, и пересчитываются только
---ячейки, которые в него попали.
---@param buf integer
---@param run jupyter.Run|nil
---@param cell? jupyter.Cell ячейка прогона, если она уже найдена вызывающим
---@return boolean
function M.is_stale(buf, run, cell)
    local s = sessions[buf]
    if not s or not run or not run.code_sha then
        return false
    end

    local key = run.cell_id .. ":" .. run.code_sha
    local cached = s.stale_cache.value[key]
    local dirty = s.stale_cache.dirty
    cell = cell or cellid.find(buf, run.cell_id)
    if not cell then
        return cached or false -- ячейку удалили: последний известный ответ лучше выдумки
    end
    -- правка не пересеклась с ячейкой — старый ответ всё ещё верен
    local touched = dirty ~= nil and not (cell.span_end < dirty.from or cell.span_start > dirty.to)
    if cached == nil or touched then
        cached = vim.fn.sha256(cells.text(buf, cell)):sub(1, 8) ~= run.code_sha
        s.stale_cache.value[key] = cached
    end
    return cached
end

---Следить за правками буфера, чтобы знать, какие ячейки пересчитывать.
---
---`nvim_buf_attach`, а не автокоманда: TextChanged говорит только «что-то изменилось»,
---а on_lines приносит диапазон строк. Копим объединение до следующей перерисовки.
---@param buf integer
function M.watch_edits(buf)
    vim.api.nvim_buf_attach(buf, false, {
        on_lines = function(_, _, _, first, last_old, last_new)
            local s = sessions[buf]
            if not s then
                return true -- сессии нет: отписываемся
            end
            local from, to = first + 1, math.max(last_old, last_new)
            local dirty = s.stale_cache.dirty
            if dirty then
                dirty.from, dirty.to = math.min(dirty.from, from), math.max(dirty.to, to)
            else
                s.stale_cache.dirty = { from = from, to = to }
            end
        end,
        on_reload = function()
            local s = sessions[buf]
            if s then
                s.stale_cache = { value = {}, dirty = nil }
            end
        end,
    })
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
    if not gained then
        -- Ждать дебаунса поздно: ушли из редактора, и следующего события может не быть.
        draft.flush_all("потерян фокус")
        if M.config.autosave.write_on_focus_lost then
            for _, buf in ipairs(draft.bufs()) do
                M.write_buffer(buf)
            end
        end
    end
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
    s.output.images:clear(s.output.buf, true) -- аварийный выход: шлём удаление в любом случае
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
            local text, group = status_ui.text_of(run, M.is_stale(buf, run, cell))
            -- последняя строка ЯЧЕЙКИ, а не последняя непустая: `cells.body` срезает
            -- хвостовые пустые строки, и это правильно для кода, который уходит ядру,
            -- но статус из-за этого оставался висеть над только что добавленной строкой
            -- до первого непробельного символа в ней — перевод строки его не двигал.
            -- И не `end_row`, а `span_end`: конец ячейки вместе с закрывающим фенсом.
            -- Между телом и фенсом статус стоять не может — фенс бывает скрыт целиком
            -- (render-markdown), а виртуальная строка перед скрытой ломает прокрутку
            -- (см. common.virt_line_below). В percent-представлении это одна и та же строка.
            table.insert(entries, {
                row = cell.span_end,
                body_row = cell.end_row, -- запасной якорь: фенс бывает последней строкой файла
                text = text,
                group = group,
            })
        end
    end
    -- все ячейки пересчитаны: накопленный диапазон правок больше не нужен
    s.stale_cache.dirty = nil

    local drawn = s.status:render(buf, entries)
    -- статусы только что пересозданы; подписи агента переставляем следом, иначе они
    -- окажутся выше статуса — виртуальные строки на одной строке идут в порядке своих
    -- extmark'ов, и приоритет тут ничего не решает (§7.5)
    agent.reanchor(buf)
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
---Добавить запись в журнал сессии (виден в :JupyterLog).
---@param s table
---@param level string
---@param msg string
local function note(s, level, msg)
    table.insert(s.log, { at = os.date("%H:%M:%S"), level = level, msg = msg })
    if #s.log > LOG_LIMIT then
        table.remove(s.log, 1)
    end
end

---Запомнить, каким увиделось представление буфера, и предупредить, если оно угадано.
---
---Ловушка на ненайденную причину пропажи `filetype` (§10 ARCHITECTURE.md). Зовётся на
---каждый запуск, но пишет только при смене пары filetype→представление: журнал не должен
---превращаться в поток. Предупреждение — один раз на такую пару, иначе оно надоест
---быстрее, чем принесёт пользу.
---@param s table сессия
---@return table info результат cells.explain
function M.note_representation(s)
    local info = cells.explain(s.buf)
    local key = ("%s→%s"):format(info.filetype == "" and "нет" or info.filetype, info.representation)
    if s.repr_seen == key then
        return info
    end
    s.repr_seen = key

    local what = ("представление %s при filetype=%s (маркеров %d, фенсов %d)"):format(
        info.representation,
        info.filetype == "" and "нет" or info.filetype,
        info.markers,
        info.fences
    )
    note(s, info.guessed and "warn" or "info", what)
    if info.guessed then
        vim.notify(
            "jupyter.nvim: " .. what .. ". Выбрано по тексту, а не по filetype — это тот самый "
                .. "случай, причина которого не найдена; подробности в :JupyterLog",
            vim.log.levels.WARN
        )
    end
    return info
end

function M.ensure_started(buf)
    local s = M.session(buf)
    M.note_representation(s) -- ловушка на промах filetype: зовётся на каждый запуск
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
---Отцепить сессию от буфера и погасить её ядро.
---
---По умолчанию завершения не ждём. Ждали 3 секунды, и это была самая заметная плата за
---плагин: выход из nvim с живым ядром стоил 1.9 с, закрытие буфера — столько же. Ждать
---незачем: сайдкару закрыт stdin, он гасит ядро с дедлайном в секунду и выходит сам, а
---если не доживёт до этого — останется `runtime.json`, по которому осиротевшее ядро
---находится (см. jupyter.orphans и `:checkhealth jupyter`).
---@param buf integer
---@param timeout_ms? integer ждать завершения сайдкара; нужно тестам, где важен порядок
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
    if timeout_ms and timeout_ms > 0 then
        s.kernel.sidecar:wait(timeout_ms)
    end
end

---Погасить все сессии. Вешается на VimLeavePre.
---
---Снимок именно ключей: `detach` удаляет запись из `sessions`, а править таблицу под
---`pairs` нельзя. Копировать саму таблицу через `deepcopy` тем более нельзя — в сессии
---лежат живые объекты (ядро, сайдкар с uv-хендлами, окна), и обход их графа не
---заканчивается за разумное время. При обычном выходе это не стреляло только потому,
---что `BufUnload` успевал снять сессию раньше и копировать было уже нечего.
function M.detach_all()
    for _, buf in ipairs(vim.tbl_keys(sessions)) do
        if M.config.keep_kernel_on_exit then
            M.release(buf)
        else
            M.detach(buf)
        end
    end
end

-- --- действия ---

function M.run_cell()
    local s = M.ensure_started()
    M.write_before_run(s.buf) -- до чтения курсора: `:w` может позвать форматтер
    local row = vim.api.nvim_win_get_cursor(0)[1]
    if not s.exec:run_at(s.buf, row) then
        vim.notify("jupyter.nvim: под курсором нет ячейки с кодом", vim.log.levels.WARN)
    end
end

function M.run_all()
    local s = M.ensure_started()
    M.write_before_run(s.buf)
    s.exec:run_all(s.buf)
end

function M.run_below()
    local s = M.ensure_started()
    M.write_before_run(s.buf)
    s.exec:run_all(s.buf, vim.api.nvim_win_get_cursor(0)[1])
end

local function jump(cell)
    if not cell then
        return
    end
    vim.api.nvim_win_set_cursor(0, { cell.start_row, 0 })
    if M.config.center_on_jump ~= false then
        vim.cmd("normal! zz")
    end
end

function M.next_cell()
    jump(cells.next(0, vim.api.nvim_win_get_cursor(0)[1]))
end

function M.prev_cell()
    jump(cells.prev(0, vim.api.nvim_win_get_cursor(0)[1]))
end

---Встать в тело новой ячейки и, если так настроено, сразу начать печатать.
---
---Новая ячейка пустая, и делать в ней в normal-режиме нечего — а руками это ещё одно
---нажатие после каждой вставки. `insert_on_new_cell = false` возвращает прежнее поведение.
---@param row integer|nil строка тела новой ячейки
local function land_in_new_cell(row)
    if not row then
        return
    end
    vim.api.nvim_win_set_cursor(0, { row, 0 })
    if M.config.insert_on_new_cell ~= false then
        vim.cmd("startinsert")
    end
end

function M.insert_above()
    land_in_new_cell(cells.insert(0, vim.api.nvim_win_get_cursor(0)[1], "above"))
end

function M.insert_below()
    land_in_new_cell(cells.insert(0, vim.api.nvim_win_get_cursor(0)[1], "below"))
end

---Открыть таблицу-результат ячейки под курсором. Если её нет — того прогона, что показан
---в drawer'е: так работает и когда курсор стоит в markdown между ячейками.
---Параметры магики для ячейки под курсором: `df_name=orders`, пусто — убрать.
---
---Живут они в info-строке фенса, а не в теле — так их хранит jupytext. Набранные в теле
---ломают файл: при сохранении магика допишется второй раз.
---@param args string
---@return boolean
function M.cell_args(args)
    local buf = vim.api.nvim_get_current_buf()
    local cell = cells.at(buf, vim.api.nvim_win_get_cursor(0)[1])
    if not cell then
        vim.notify("jupyter.nvim: под курсором нет ячейки", vim.log.levels.WARN)
        return false
    end
    if not cells.set_magic_args(buf, cell, vim.trim(args or "")) then
        vim.notify(
            "jupyter.nvim: параметры бывают только у ячейки с магикой языка (```sql)",
            vim.log.levels.WARN
        )
        return false
    end
    local shown = vim.trim(args or "")
    vim.notify(shown ~= "" and ("jupyter.nvim: параметры ячейки — %s"):format(shown)
        or "jupyter.nvim: параметры ячейки убраны")
    return true
end

---Спросить параметры магики, подставив нынешние.
---
---Отдельно от `cell_args`, а не «нет аргументов — спросить»: команда без аргументов
---параметры убирает, и путать эти два смысла в одном имени — способ однажды стереть их
---нажатием клавиши.
---@return boolean
function M.edit_cell_args()
    local buf = vim.api.nvim_get_current_buf()
    local cell = cells.at(buf, vim.api.nvim_win_get_cursor(0)[1])
    if not cell or not cells.MAGIC_LANGS[cell.lang or ""] then
        vim.notify(
            "jupyter.nvim: параметры бывают только у ячейки с магикой языка (```sql)",
            vim.log.levels.WARN
        )
        return false
    end
    vim.ui.input({
        prompt = ("параметры %%%%%s: "):format(cell.lang),
        default = cell.magic_args or "",
    }, function(input)
        if input == nil then
            return -- передумал
        end
        M.cell_args(input)
    end)
    return true
end

---Ячейка под курсором вместе с буфером и строкой.
---@return jupyter.Cell|nil cell, integer buf, integer row
local function here()
    local buf = vim.api.nvim_get_current_buf()
    local row = vim.api.nvim_win_get_cursor(0)[1]
    return cells.at(buf, row), buf, row
end

---После перестройки статусы под ячейками стоят не там: extmark'и привязаны к строкам,
---а строки уехали. Перерисовка дешёвая (около миллисекунды), так что зовём её всегда.
---@param buf integer
---@param row integer|nil куда поставить курсор
local function settle(buf, row)
    if row then
        pcall(vim.api.nvim_win_set_cursor, 0, { row, 0 })
    end
    M.repaint(buf)
end

---Курсор в начало тела ячейки под курсором.
---
---Отдельно от `prev_cell`: тот из середины ячейки уходит к предыдущей, а вернуться к
---началу своей нечем. Экран не двигаем — движение внутри ячейки, она и так на виду.
---@return boolean
function M.cell_start()
    local cell, buf = here()
    if not cell then
        vim.notify("jupyter.nvim: под курсором нет ячейки", vim.log.levels.WARN)
        return false
    end
    local first = cells.body(buf, cell)
    pcall(vim.api.nvim_win_set_cursor, 0, { first, 0 })
    return true
end

---Курсор в конец тела ячейки: последняя непустая строка, последний символ.
---
---Дописать что-то в конец ячейки — самое частое движение в ноутбуке, а руками это
---`]n` и потом три раза `k` через пустую строку и закрывающий фенс.
---@return boolean
function M.cell_end()
    local cell, buf = here()
    if not cell then
        vim.notify("jupyter.nvim: под курсором нет ячейки", vim.log.levels.WARN)
        return false
    end
    local _, last = cells.body(buf, cell)
    local line = vim.api.nvim_buf_get_lines(buf, last - 1, last, false)[1] or ""
    pcall(vim.api.nvim_win_set_cursor, 0, { last, math.max(0, #line - 1) })
    return true
end

---Разрезать ячейку по курсору: строка под курсором и ниже уезжают в новую.
---@return boolean
function M.split_cell()
    local _, buf, row = here()
    local at = edit.split(buf, row)
    if not at then
        vim.notify("jupyter.nvim: резать нечего — курсор не в теле ячейки", vim.log.levels.WARN)
        return false
    end
    settle(buf, at)
    return true
end

---Склеить ячейку со следующей.
---@return boolean
function M.merge_cell()
    local cell, buf = here()
    if not cell then
        vim.notify("jupyter.nvim: под курсором нет ячейки", vim.log.levels.WARN)
        return false
    end
    local ok, why = edit.merge(buf, cell)
    if not ok then
        vim.notify("jupyter.nvim: не склеить — " .. (why or "?"), vim.log.levels.WARN)
        return false
    end
    settle(buf, nil)
    return true
end

---@param dir "up"|"down"
---@return boolean
local function move(dir)
    local cell, buf = here()
    if not cell then
        vim.notify("jupyter.nvim: под курсором нет ячейки", vim.log.levels.WARN)
        return false
    end
    local at = edit.move(buf, cell, dir)
    if not at then
        vim.notify("jupyter.nvim: двигаться некуда", vim.log.levels.WARN)
        return false
    end
    settle(buf, at)
    return true
end

function M.move_cell_up()
    return move("up")
end

function M.move_cell_down()
    return move("down")
end

---Превратить код-ячейку в markdown.
---@return boolean
function M.cell_to_markdown()
    local cell, buf = here()
    if not cell then
        vim.notify("jupyter.nvim: под курсором нет код-ячейки", vim.log.levels.WARN)
        return false
    end
    edit.to_markdown(buf, cell)
    settle(buf, nil)
    return true
end

---Сменить язык ячейки под курсором. Без аргумента — переключить python ↔ sql.
---
---Переключатель, а не выбор из списка, потому что на клавише выбирать не из чего: языков
---магики у нас ровно один. Явный язык остаётся у команды — `:JupyterCellLang python`.
---@param lang? string
---@return boolean
function M.cell_lang(lang)
    local cell, buf = here()
    if not cell then
        vim.notify("jupyter.nvim: под курсором нет код-ячейки", vim.log.levels.WARN)
        return false
    end
    lang = vim.trim(lang or "")
    if lang == "" then
        lang = cells.lang_of(buf, cell) == cells.CODE_LANG and "sql" or cells.CODE_LANG
    end

    local ok, why = edit.set_lang(buf, cell, lang)
    if not ok then
        vim.notify("jupyter.nvim: " .. (why or "язык не сменить"), vim.log.levels.WARN)
        return false
    end
    settle(buf, nil)
    vim.notify(("jupyter.nvim: ячейка теперь %s"):format(lang))
    return true
end

---Превратить markdown под курсором в код-ячейку.
---@return boolean
function M.cell_to_code()
    local _, buf, row = here()
    local at = edit.to_code(buf, row)
    if not at then
        vim.notify(
            "jupyter.nvim: тут нечего превращать — это уже код или пустая строка",
            vim.log.levels.WARN
        )
        return false
    end
    settle(buf, at)
    return true
end

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
    with_sidecar(s.sidecar, function(err)
        if err then
            vim.notify(
                "jupyter.nvim: сайдкар не поднялся — " .. (err.msg or err.code or "?"),
                vim.log.levels.ERROR
            )
            return
        end
        s.table:open(run.table.path, ("ячейка %s · прогон %d"):format(run.cell_id, run.run_id))
    end)
end

---Ядра без хозяина в каталоге текущего файла: показать или снять.
---@param kill? boolean
---@return jupyter.Orphan[]
function M.orphans(kill)
    local orphans = require("jupyter.orphans")
    local dir = vim.fn.expand("%:p:h")
    local found = dir ~= "" and orphans.scan(dir, M.config.out_dir) or {}
    if #found == 0 then
        vim.notify("jupyter.nvim: ядер без хозяина нет")
        return found
    end
    for _, orphan in ipairs(found) do
        if kill then
            local ok = orphans.kill(orphan)
            vim.notify(
                ("jupyter.nvim: %s — %s"):format(orphans.describe(orphan), ok and "снято" or "не удалось"),
                ok and vim.log.levels.INFO or vim.log.levels.ERROR
            )
        else
            vim.notify("jupyter.nvim: " .. orphans.describe(orphan), vim.log.levels.WARN)
        end
    end
    return found
end

---Отпустить ядро: сессия закроется, а процесс останется жить.
---
---След на диске сохраняется, наш сайдкар вскоре умрёт — и запись сама превратится в то,
---что ищет `:JupyterAttach`: живое ядро без хозяина.
---@param buf? integer
---@return boolean отпустили ли что-нибудь
function M.release(buf)
    buf = buf or vim.api.nvim_get_current_buf()
    local s = sessions[buf]
    if not s or not s.started then
        vim.notify("jupyter.nvim: у этого буфера нет живого ядра", vim.log.levels.WARN)
        return false
    end
    -- Ответа не ждём: запрос уже в трубе, а порядок записи в неё сохраняется, поэтому
    -- сайдкар прочитает release раньше, чем увидит закрытый stdin.
    s.kernel:release(function(err, data)
        if err then
            vim.notify(
                ("jupyter.nvim: отпустить ядро не вышло — %s: %s"):format(err.code or "?", err.msg or ""),
                vim.log.levels.ERROR
            )
        elseif data and data.kernel_pid then
            vim.notify(("jupyter.nvim: ядро %d оставлено жить; вернуться — :JupyterAttach"):format(data.kernel_pid))
        end
    end)
    M.detach(buf)
    return true
end

---Подключиться к ядру, оставшемуся от прошлой сессии редактора.
---
---Ядро переживает и перезапуск nvim, и смерть сайдкара: оно чужой процесс, а не наш
---потомок. Смысл подключения в том, что в нём осталась память — фреймы после долгого
---запроса стоят дороже самого редактора. Ядро ищется по следу рядом с выводами, тому же,
---по которому находятся ядра без хозяина (jupyter.orphans).
---@param buf? integer
---@return boolean начали ли подключение
function M.attach(buf)
    local s = M.session(buf)
    if s.started then
        vim.notify("jupyter.nvim: у этого буфера уже своё ядро", vim.log.levels.WARN)
        return false
    end
    local orphans = require("jupyter.orphans")
    local name = vim.api.nvim_buf_get_name(s.buf)
    local found = name ~= "" and orphans.check(orphans.record_for(name, M.config.out_dir)) or nil
    if not found or found.stale or not found.connection_file then
        vim.notify(
            "jupyter.nvim: подключаться не к чему — живого ядра от прошлой сессии нет",
            vim.log.levels.WARN
        )
        return false
    end

    s.started = true
    s.kernel:attach({
        connection_file = found.connection_file,
        pid = found.kernel_pid,
        kernel_name = found.kernel_name,
        notebook = name,
        cwd = vim.fn.fnamemodify(name, ":h"),
    }, function(err)
        if err then
            s.started = false
            vim.notify(
                ("jupyter.nvim: подключиться не удалось — %s: %s"):format(err.code or "?", err.msg or ""),
                vim.log.levels.ERROR
            )
            return
        end
        vim.notify(("jupyter.nvim: подключились к ядру %d, живёт с %s"):format(
            found.kernel_pid,
            found.started_at or "?"
        ))
    end)
    return true
end

---Проверить, не осталось ли у этого ноутбука ядра от прошлой жизни.
---
---Зовётся при открытии: чтение одного файла, которого обычно нет. Если он есть, а
---сайдкара нет — один вызов ps. Молчим про следы без процессов: это наша же
---бухгалтерия, её просто убираем.
---@param buf integer
---@return jupyter.Orphan|nil
function M.warn_orphan(buf)
    local name = vim.api.nvim_buf_get_name(buf)
    if name == "" then
        return nil
    end
    local orphans = require("jupyter.orphans")
    local orphan = orphans.check(orphans.record_for(name, M.config.out_dir))
    if not orphan then
        return nil
    end
    if orphan.stale then
        pcall(vim.fn.delete, orphan.path)
        return nil
    end
    vim.notify(
        ("jupyter.nvim: %s. Подключиться — :JupyterAttach, снять — :JupyterOrphans!"):format(
            orphans.describe(orphan)
        ),
        vim.log.levels.WARN
    )
    return orphan
end

-- --- черновик несохранённого буфера ---

---@return table
local function draft_opts()
    return {
        out_dir = M.config.out_dir,
        debounce_ms = M.config.autosave.debounce_ms,
        enabled = M.config.autosave.draft ~= false,
        augroup = augroup,
    }
end

---Взять ноутбук под черновик и сказать, если от прошлой жизни что-то осталось.
---
---Зовётся при открытии, до всякого ядра: черновик защищает текст, а не сессию, и нужен
---он как раз тогда, когда python ещё ни разу не поднимали.
---@param buf integer
---@return jupyter.DraftFound[]
function M.watch_draft(buf)
    -- Буфер должен стоять за настоящим файлом. Иначе под черновик попадает синтетика:
    -- otter.nvim держит копию кода ячеек в буфере `<ноутбук>.otter.py` с ft=python, на
    -- диске его нет и сохранять его некуда, а имя `:t:r` даёт ему собственный каталог в
    -- .jupyter-out. Проверено на живом конфиге: черновики писались туда вместо ноутбука.
    local name = vim.api.nvim_buf_get_name(buf)
    if name == "" or vim.fn.filereadable(name) == 0 or vim.bo[buf].buftype == "nofile" then
        return {}
    end
    -- Ячейки: тот же filetype носит любой python-файл, а черновик — про ноутбуки.
    if #cells.list(buf) == 0 then
        return {}
    end
    if not draft.attach(buf, draft_opts()) then
        return {}
    end
    if M.config.autosave.draft == false then
        return {} -- присмотр остаётся ради write_on_*, но черновика не будет
    end
    local found = draft.check(buf)
    for _, item in ipairs(found) do
        vim.notify(
            ("jupyter.nvim: остался несохранённый %s — :JupyterRecover"):format(draft.describe(item)),
            vim.log.levels.WARN
        )
    end
    return found
end

---Сохранить ноутбук по-настоящему.
---
---Именно `:w`, а не `noautocmd write`: markdown в `.ipynb` превращает jupytext, и делает
---он это автокомандой `BufWriteCmd`. Без автокоманд в файл ноутбука уехал бы сырой
---markdown — то есть молча испорченный `.ipynb`.
---@param buf integer
---@return boolean
function M.write_buffer(buf)
    if not vim.api.nvim_buf_is_valid(buf) or not vim.bo[buf].modified then
        return false
    end
    if vim.api.nvim_buf_get_name(buf) == "" or vim.bo[buf].readonly then
        return false
    end
    local ok, err = pcall(vim.api.nvim_buf_call, buf, function()
        vim.cmd("silent write")
    end)
    if not ok then
        -- Не сохранили — не повод не выполнять ячейку: прогон важнее, чем запись.
        vim.notify("jupyter.nvim: не удалось сохранить ноутбук — " .. tostring(err), vim.log.levels.WARN)
    end
    return ok
end

---@param buf integer
---@return boolean
function M.write_before_run(buf)
    draft.note(draft.of(buf), "run", "прогон ячейки")
    if not M.config.autosave.write_on_run then
        return false
    end
    return M.write_buffer(buf)
end

---Показать, чем черновик отличается от того, что сейчас в буфере.
---@param buf integer
---@param found jupyter.DraftFound
---@return boolean
local function diff_draft(buf, found)
    local win = vim.fn.win_findbuf(buf)[1]
    if not win then
        return false
    end
    vim.api.nvim_set_current_win(win)

    local scratch = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(scratch, 0, -1, false, found.lines)
    vim.bo[scratch].filetype = vim.bo[buf].filetype
    vim.bo[scratch].modifiable = false
    pcall(vim.api.nvim_buf_set_name, scratch, "jupyter://черновик/" .. found.id)

    vim.cmd("diffthis")
    vim.cmd("vsplit")
    vim.api.nvim_win_set_buf(0, scratch)
    vim.cmd("diffthis")
    return true
end

local DRAFT_ACTIONS = { "показать разницу", "восстановить в буфер", "выбросить" }

---@param buf integer
---@param found jupyter.DraftFound
local function draft_actions(buf, found)
    vim.ui.select(DRAFT_ACTIONS, { prompt = draft.describe(found) }, function(choice)
        if choice == DRAFT_ACTIONS[1] then
            if diff_draft(buf, found) then
                vim.notify("jupyter.nvim: закончить сравнение — :diffoff!, вернуться к выбору — :JupyterRecover")
            end
        elseif choice == DRAFT_ACTIONS[2] then
            if draft.apply(buf, found.lines) then
                draft.drop(buf, found.id)
                vim.notify(
                    "jupyter.nvim: черновик в буфере, файл не тронут — :w, если он тот самый, `u`, если нет"
                )
            end
        elseif choice == DRAFT_ACTIONS[3] then
            draft.drop(buf, found.id)
            vim.notify("jupyter.nvim: черновик выброшен")
        end
    end)
end

---Разобраться с черновиками этого ноутбука.
---
---Восстановление кладёт текст в буфер и на этом останавливается: писать в файл за
---пользователя нельзя — он ещё не видел, что именно вернулось. Отсюда и `u` как выход.
---@param buf? integer
---@param discard? boolean выбросить всё найденное, ничего не спрашивая
---@return jupyter.DraftFound[]
function M.recover(buf, discard)
    buf = buf or vim.api.nvim_get_current_buf()
    if not draft.attach(buf, draft_opts()) then
        vim.notify("jupyter.nvim: у буфера нет файла — черновику негде лежать", vim.log.levels.WARN)
        return {}
    end

    local list = draft.found(buf)
    if #list == 0 then
        list = draft.check(buf) -- команду могли позвать раньше, чем что-то нашлось
    end
    if #list == 0 then
        vim.notify("jupyter.nvim: черновиков от прошлых сессий нет")
        return {}
    end

    if discard then
        for _, found in ipairs(list) do
            draft.drop(buf, found.id)
        end
        vim.notify(("jupyter.nvim: черновиков выброшено: %d"):format(#list))
        return list
    end

    if #list == 1 then
        draft_actions(buf, list[1])
    else
        vim.ui.select(list, {
            prompt = "черновики этого ноутбука:",
            format_item = draft.describe,
        }, function(found)
            if found then
                draft_actions(buf, found)
            end
        end)
    end
    return list
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

---Снимок ноутбука одной структурой: ячейки, их id и последний прогон каждой.
---
---Нужен тому, кто читает ноутбук снаружи — скрипту или агенту через `--remote-expr`:
---иначе он повторяет разбор фенсов и раскладку `.jupyter-out` у себя, и эта копия
---правил расходится с нашей. Ничего не пишет: снимок — производное представление.
---@param buf? integer
---@return table
function M.snapshot(buf)
    local s = M.session(buf)
    return snapshot.build(s.buf, { store = s.store, kernel = s.kernel, exec = s.exec })
end

---Тот же снимок строкой JSON: форма, в которой его забирает `--remote-expr`.
---@param buf? integer
---@return string
function M.snapshot_json(buf)
    return vim.json.encode(M.snapshot(buf))
end

---Снимок в файл. Путь возвращается, чтобы вызвавший снаружи сразу знал, что читать.
---@param path? string без пути — во временный файл
---@param buf? integer
---@return string
function M.write_snapshot(path, buf)
    path = (path and path ~= "") and vim.fn.fnamemodify(path, ":p") or (vim.fn.tempname() .. ".json")
    vim.fn.writefile({ M.snapshot_json(buf) }, path)
    return path
end

---Что сказать человеку про отправленный промпт.
---@param res table|nil
---@param err string|nil
---@param candidates table[]|nil
local function report_ask(res, err, candidates)
    if res then
        local what = res.cell_id and ("ячейка " .. res.cell_id) or "весь ноутбук"
        vim.notify(("jupyter.nvim: промпт ушёл агенту — %s, панель %s"):format(what, res.pane))
        return
    end
    local msg = "jupyter.nvim: " .. (err or "промпт не ушёл")
    if candidates and #candidates > 0 then
        -- список кандидатов в уведомлении не разворачиваем: выбирать всё равно в пикере,
        -- и он покажет их с каталогами, по которым только и можно отличить один от другого
        msg = msg .. "\n  выбрать: :JupyterAgentAttach"
    end
    vim.notify(msg, vim.log.levels.WARN)
end

---Спросить агента про ячейку под курсором.
---
---Смысл не в том, чтобы отправить текст, — это и так делается руками. Смысл в том, что
---вместе с текстом уезжает место: ноутбук, сокет nvim, id ячейки и путь к её последнему
---выводу. Агент не тратит ходы на поиск того, что человек видит перед собой, а человек не
---объясняет словами, какую именно ячейку правит.
---
---Заявку открывает сам плагин, до отправки: метка встаёт на ячейку в ту секунду, когда
---нажата клавиша (§7.5, `ask.lua`).
---@param opts? table prompt — готовый текст вместо окна; scope = "notebook" — вопрос про
---весь документ; selection; row; buf
function M.ask(opts)
    opts = opts or {}
    local s = M.session(opts.buf)
    local args = {
        store = s.store,
        row = opts.row or vim.api.nvim_win_get_cursor(0)[1],
        selection = opts.selection,
        scope = opts.scope,
        height = (M.config.agent or {}).ask_height,
    }
    if type(opts.prompt) == "string" and opts.prompt ~= "" then
        report_ask(ask.send(s.buf, opts.prompt, args))
        return
    end
    args.on_send = report_ask
    ask.open(s.buf, args)
end

---Спросить про выделенный кусок.
---
---Из visual выходим до чтения марок: `'<` и `'>` ставятся при выходе из режима, а не по
---ходу выделения, и без этого пришли бы координаты прошлого выделения.
function M.ask_selection()
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Esc>", true, false, true), "nx", false)
    local from = vim.api.nvim_buf_get_mark(0, "<")[1]
    local to = vim.api.nvim_buf_get_mark(0, ">")[1]
    if from > to then
        from, to = to, from
    end
    M.ask({ row = from, selection = { from = from, to = to } })
end

---Привязать ноутбук к панели агента руками: когда лестница поиска не решает сама.
---@param buf? integer
function M.agent_attach(buf)
    local s = M.session(buf)
    ask.attach(s.buf, { store = s.store })
end

---Взять заявку, которую плагин открыл при отправке промпта.
---
---Первый шаг агента после чтения промпта: её номер он получил в шапке. Своя заявка вместо
---этой означала бы вторую метку на той же ячейке (§7.5).
---@param token integer
---@param opts? table label — имя агента; title — что делается; after — не переписывать
---ячейку, а вставить новую после неё
---@return table
function M.edit_adopt(token, opts)
    return agent.adopt(token, opts)
end

---Открыть заявку на правку от внешнего читателя: ячейку он получит по id, а мы пометим её
---в буфере и запомним, какой она была. Писать по номерам строк нельзя — пока агент думает,
---документ живёт (§7.5 ARCHITECTURE.md).
---@param opts table cell | after | at_end, label, buf
---@return table
function M.edit_begin(opts)
    opts = opts or {}
    return agent.begin(M.session(opts.buf).buf, opts)
end

---Применить правку по заявке.
---@param token integer
---@param lines string[]
---@return table
function M.edit_apply(token, lines)
    local res = agent.apply(token, lines)
    if res.ok and res.buf then
        M.repaint(res.buf) -- статусы ячеек и пометка «код изменился» — сразу, а не по таймеру
    end
    return res
end

---Снять заявку, ничего не записав.
---@param token integer
---@return table
function M.edit_cancel(token)
    return agent.cancel(token)
end

---Продлить заявку: «думаю дальше». Без этого она снимется сама (§7.5).
---@param token integer
---@return table
function M.edit_touch(token)
    return agent.touch(token)
end

---Открытые заявки этого буфера.
---@param buf? integer
---@return table[]
function M.edits(buf)
    return agent.list(M.session(buf).buf)
end

---Снять все заявки буфера.
---@param buf? integer
---@return integer сколько снято
function M.edit_cancel_all(buf)
    return agent.cancel_all(M.session(buf).buf)
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
