-- Точка входа: setup(), сборка модулей, публичный API.
--
-- Сессия своя на каждый буфер-ноутбук: ядро, exec и drawer живут вместе и гаснут вместе
-- с буфером. Ядро поднимается лениво, на первом запуске ячейки, а не при открытии файла —
-- иначе просто заглянуть в ноутбук означало бы поднять python-процесс.

local cells = require("jupyter.cells")
local common = require("jupyter.ui.common")
local exec = require("jupyter.exec")
local kernel = require("jupyter.kernel")
local output = require("jupyter.ui.output")

local M = {}

---@class jupyter.Config
M.defaults = {
    kernel_name = "python3",
    python = nil, -- путь к интерпретатору сайдкара; по умолчанию vim.g.jupyter_python
    env = {},
    filetypes = { "python", "markdown" },
    output = { position = "bottom", size = 15, follow_cursor = true },
    -- Клавиши: false — не ставить вовсе, дальше пользователь делает это сам.
    keys = {
        run_cell = "<leader>jc",
        run_all = "<leader>jA",
        run_below = "<leader>jB",
        next_cell = "]c",
        prev_cell = "[c",
        insert_above = "<leader>ja",
        insert_below = "<leader>jb",
        toggle_output = "<leader>jo",
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

    vim.api.nvim_create_autocmd("VimLeavePre", {
        group = augroup,
        callback = function()
            M.detach_all()
        end,
    })

    if M.config.keys ~= false then
        vim.api.nvim_create_autocmd("FileType", {
            group = augroup,
            pattern = M.config.filetypes,
            callback = function(ev)
                M.set_keys(ev.buf)
            end,
        })
    end
end

---@param buf? integer
function M.set_keys(buf)
    buf = buf or vim.api.nvim_get_current_buf()
    for action, key in pairs(M.config.keys or {}) do
        local fn = M[action]
        if fn and key then
            common.map("n", key, function() fn() end, {
                buffer = buf,
                silent = true,
                desc = "jupyter: " .. action,
            })
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
    }))
    ex = exec.new({
        kernel = k,
        on_update = function(run, is_new)
            -- Новый прогон показываем всегда, даже если окно было закрыто: нажал запуск —
            -- хочешь видеть результат. Обновление чужого прогона окно не забирает, но
            -- счётчик «ещё выполняется» в winbar обновить надо.
            if is_new then
                drawer:show(run)
            elseif not drawer:update(run) then
                drawer:refresh_status()
            end
        end,
    }):attach()

    found = { buf = buf, kernel = k, exec = ex, output = drawer, started = false, log = {} }
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
        return
    end
    local run = s.exec:run_for(exec.cell_id(cell))
    if run and (not shown or shown.cell_id ~= run.cell_id) then
        s.output:show(run)
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
---Ждём намеренно: иначе при выходе из nvim остаются висеть python-процесс и ядро —
---ровно то, за что у molten открытые issue про утечку ресурсов.
---@param buf integer
---@param timeout_ms? integer
function M.detach(buf, timeout_ms)
    local s = sessions[buf]
    if not s then
        return
    end
    sessions[buf] = nil
    s.output:close()
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
    return {
        state = s.kernel:state(),
        queued = s.kernel:queued(),
        info = s.kernel:info(),
        cells = #cells.list(s.buf),
    }
end

return M
