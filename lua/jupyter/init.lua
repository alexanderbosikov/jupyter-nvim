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
    output = { position = "bottom", size = 15 },
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

---@param opts? jupyter.Config
function M.setup(opts)
    M.config = vim.tbl_deep_extend("force", vim.deepcopy(M.defaults), opts or {})
    augroup = vim.api.nvim_create_augroup("jupyter.nvim", { clear = true })

    require("jupyter.commands").setup(M)

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
    local drawer = output.new(M.config.output)
    local ex = exec.new({
        kernel = k,
        on_update = function(run)
            if not drawer:update(run) then
                drawer:show(run)
            end
        end,
    }):attach()

    found = { buf = buf, kernel = k, exec = ex, output = drawer, started = false }
    sessions[buf] = found

    vim.api.nvim_create_autocmd({ "BufUnload" }, {
        group = augroup or vim.api.nvim_create_augroup("jupyter.nvim", { clear = false }),
        buffer = buf,
        callback = function()
            M.detach(buf)
        end,
    })
    return found
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

function M.detach(buf)
    local s = sessions[buf]
    if not s then
        return
    end
    sessions[buf] = nil
    s.output:close()
    s.kernel:stop()
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
