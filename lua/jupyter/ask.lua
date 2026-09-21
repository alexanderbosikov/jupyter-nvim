-- Промпт агенту из ноутбука: адрес, заявка, отправка.
--
-- Зачем это вообще нужно. Написать агенту «поправь вот эту ячейку» можно и руками — но
-- тогда «вот эту» приходится объяснять словами, а он тратит ходы на поиск того места,
-- которое человек видит перед собой. Здесь место передаётся само: ноутбук, сокет nvim, id
-- ячейки под курсором и путь к её последнему выводу уезжают в шапке промпта.
--
-- Порядок шагов важнее их содержания:
--
--   1. заявка открывается ДО отправки, самим плагином (`agent.begin{pending = true}`).
--      Метка встаёт на ячейку в ту секунду, когда нажата клавиша, а не тогда, когда на той
--      стороне дочитали промпт. Заявка, открытая агентом за миг до записи, формально
--      честна, но человеку не сообщает ничего — а между отправкой и правкой проходят
--      десятки секунд, и всё это время он в этой ячейке работает;
--   2. её номер уходит в шапке, и агент её ЗАБИРАЕТ (`edit_adopt`), а не открывает свою.
--      Иначе на одной ячейке оказываются две метки;
--   3. промпт не ушёл — заявка снимается сразу. Метка, за которой никого нет, врёт хуже,
--      чем её отсутствие.
--
-- Отправка — не наше дело, этим занят `pane.lua`: сессия агента живёт в своей панели tmux,
-- и туда пишется текст ровно так, как его набрал бы человек.
--
-- Граница: в документ ноутбука здесь пишется ровно одно — `jncell` у ячейки, которая его
-- ещё не имеет (`cellid.ensure`). Без id заявку не на что повесить и агенту нечего назвать,
-- а сам плагин делает это и так при первом прогоне. Всё остальное — метки поверх текста.

local agent = require("jupyter.agent")
local cellid = require("jupyter.cellid")
local cells = require("jupyter.cells")
local common = require("jupyter.ui.common")
local pane = require("jupyter.pane")

local M = {}

---Состояние привязки: какая панель tmux обслуживает этот ноутбук. Рядом с индексом
---прогонов и `runtime.json` — это такое же состояние ноутбука, живущее между запусками.
M.STATE = "agent.json"

---Журнал отправленных промптов: одна строка на промпт. Нужен затем же, зачем история
---прогонов, — вспомнить, что именно просил, когда результат уже в документе.
M.PROMPTS = "prompts.jsonl"

---Сколько промптов держим в журнале.
M.HISTORY_LIMIT = 200

---Размер окна промпта: доля ширины экрана и строки высоты.
M.WIDTH = 0.6
M.MAX_WIDTH = 80
M.HEIGHT = 8

---Клавиши внутри окна промпта. `<CR>` отправляет только из нормального режима: в insert он
---должен оставаться переводом строки, иначе многострочный промпт набрать нельзя.
M.KEYS = {
    { mode = "n", key = "<CR>", action = "send" },
    { mode = { "n", "i" }, key = "<C-s>", action = "send" },
    { mode = "n", key = "q", action = "cancel" },
    { mode = "n", key = "<Esc>", action = "cancel" },
}

-- --- состояние привязки ---

---@param store jupyter.Store|nil
---@param name string
---@return string|nil
local function file_in_base(store, name)
    local base = store and store.base
    return base and vim.fs.joinpath(base, name) or nil
end

---@param store jupyter.Store|nil
---@return table
function M.load_state(store)
    local path = file_in_base(store, M.STATE)
    if not path or vim.fn.filereadable(path) == 0 then
        return {}
    end
    local ok, decoded = pcall(vim.json.decode, table.concat(vim.fn.readfile(path), "\n"))
    return (ok and type(decoded) == "table") and decoded or {}
end

---Дописать состояние, не затирая чужие поля: рядом с `pane` тут будет жить `session_id`,
---а позже — то, что положит слой статусов.
---@param store jupyter.Store|nil
---@param patch table
---@return boolean
function M.save_state(store, patch)
    local path = file_in_base(store, M.STATE)
    if not path then
        return false
    end
    local state = vim.tbl_extend("force", M.load_state(store), patch)
    vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
    return pcall(vim.fn.writefile, { vim.json.encode(state) }, path) == true
end

---Записать промпт в журнал. Молча ничего не делает без каталога ноутбука: журнал — вещь
---полезная, но не такая, ради которой стоит отменять отправку.
---@param store jupyter.Store|nil
---@param entry table
function M.record(store, entry)
    local path = file_in_base(store, M.PROMPTS)
    if not path then
        return
    end
    local lines = vim.fn.filereadable(path) == 1 and vim.fn.readfile(path) or {}
    table.insert(lines, vim.json.encode(entry))
    if #lines > M.HISTORY_LIMIT then
        lines = vim.list_slice(lines, #lines - M.HISTORY_LIMIT + 1)
    end
    vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
    pcall(vim.fn.writefile, lines, path)
end

-- --- адрес ---

---@class jupyter.Address
---@field notebook string|nil путь к файлу ноутбука
---@field socket string|nil адрес nvim: по нему агент и читает, и пишет
---@field modified boolean в буфере есть несохранённое
---@field cell_id string|nil ячейка под курсором
---@field lang string|nil
---@field start_row integer|nil тело ячейки, 1-based
---@field end_row integer|nil
---@field selection table|nil { from, to } — что выделено внутри ячейки
---@field output table|nil последний вывод ячейки: path, kind, rows, cols, stale

---Куда относится промпт.
---
---`scope = "notebook"` — про весь документ: ячейку под курсором тогда не трогаем вовсе,
---потому что вопрос не о ней. Это же происходит, если курсор стоит в прозе.
---@param buf integer
---@param opts? table store, row, selection, scope
---@return jupyter.Address
function M.address(buf, opts)
    opts = opts or {}
    local name = vim.api.nvim_buf_get_name(buf)
    local addr = {
        notebook = name ~= "" and name or nil,
        socket = vim.v.servername ~= "" and vim.v.servername or nil,
        modified = vim.bo[buf].modified,
    }
    if opts.scope == "notebook" then
        return addr
    end

    local row = opts.row or vim.api.nvim_win_get_cursor(0)[1]
    local cell = cells.at(buf, row)
    if not cell then
        return addr
    end

    -- Единственная запись в документ. Без `jncell` ячейку не назвать: заявка ищет её по id,
    -- и запасной номер для этого не годится — после вставки соседа он достаётся другой
    -- ячейке. Плагин проставляет id и сам, при первом прогоне (§7.2).
    local id = cellid.ensure(buf, cell)
    if not id then
        return addr
    end
    addr.cell_id = id
    addr.lang = cells.lang_of(buf, cell)
    addr.start_row, addr.end_row = cell.start_row, cell.end_row
    addr.selection = opts.selection

    local store = opts.store
    if store then
        store:load() -- индекс мог дописаться после последнего прогона
        local record = store:last_record(id)
        if record then
            addr.output = {
                path = store:path_of(record),
                kind = record.kind,
                rows = record.rows,
                cols = record.cols,
                status = record.status,
                -- тот же ответ, что даёт снимок и помета «код изменился» в drawer'е:
                -- вывод относится не к тому коду, что сейчас в ячейке
                stale = type(record.code_sha) == "string"
                    and vim.fn.sha256(cells.text(buf, cell)):sub(1, 8) ~= record.code_sha,
            }
        end
    end
    return addr
end

---Шапка промпта: всё, что агенту иначе пришлось бы искать.
---
---Пишется словами, а не JSON: это первый текст, который он читает, и человек читает его
---тоже — в журнале промптов и в окне сессии.
---@param addr jupyter.Address
---@param token integer|nil номер открытой заявки
---@return string[]
function M.header(addr, token)
    local out = {
        "[jupyter.nvim] ноутбук открыт в nvim; читать и править его — через скилл jupyter-nvim.",
        "ноутбук: " .. (addr.notebook or "не сохранён на диск"),
    }
    if addr.socket then
        table.insert(out, "сокет nvim: " .. addr.socket)
    end
    if addr.modified then
        table.insert(out, "в буфере есть несохранённое: читай через сокет, не с диска")
    end

    if addr.cell_id then
        local where = ("ячейка: %s"):format(addr.cell_id)
        if addr.lang then
            where = where .. " · " .. addr.lang
        end
        if addr.start_row then
            where = where .. (" · строки %d–%d"):format(addr.start_row, addr.end_row)
        end
        table.insert(out, where)
    end
    if addr.selection then
        table.insert(
            out,
            ("выделено: строки %d–%d — речь про этот кусок"):format(addr.selection.from, addr.selection.to)
        )
    end
    if addr.output then
        local o = addr.output
        local desc = ("вывод ячейки: %s"):format(o.path or "нет на диске")
        local marks = {}
        if o.kind then
            table.insert(marks, o.kind)
        end
        if o.rows and o.cols then
            table.insert(marks, ("%d×%d"):format(o.rows, o.cols))
        end
        if o.stale then
            table.insert(marks, "устарел: код правили после прогона")
        end
        if #marks > 0 then
            desc = desc .. " · " .. table.concat(marks, " · ")
        end
        table.insert(out, desc)
    end

    if token then
        table.insert(out, ("заявка: %d — уже открыта, метка стоит в буфере, человек её видит."):format(token))
        table.insert(out, ("  взять её: edit_adopt(%d) — перепишешь тело ячейки;"):format(token))
        table.insert(out, ("           edit_adopt(%d, {after = true}) — допишешь новую после неё."):format(token))
        table.insert(out, "  edit_begin не зови: на ячейке окажется вторая метка.")
        table.insert(out, ("  дальше как обычно: edit_apply(%d, строки), edit_touch(%d), edit_cancel(%d)."):format(token, token, token))
    else
        table.insert(out, "заявки нет: вопрос не про одну ячейку. Возьмёшься править — открой её сам (edit_begin).")
    end
    return out
end

---Весь текст, который уедет в панель агента.
---@param addr jupyter.Address
---@param token integer|nil
---@param prompt string
---@return string
function M.compose(addr, token, prompt)
    local out = M.header(addr, token)
    table.insert(out, "")
    table.insert(out, prompt)
    return table.concat(out, "\n")
end

-- --- отправка ---

---@param addr jupyter.Address
---@return string|nil каталог, рядом с которым стоит искать панель агента
local function dir_of(addr)
    return addr.notebook and vim.fn.fnamemodify(addr.notebook, ":h") or nil
end

---Отправить промпт в панель агента.
---
---@param buf integer
---@param prompt string
---@param opts? table store, row, selection, scope, label
---@return table|nil { token, pane, how, cell_id } — либо nil
---@return string|nil причина отказа
---@return jupyter.Pane[]|nil кандидаты, если выбирать должен человек
function M.send(buf, prompt, opts)
    opts = opts or {}
    prompt = type(prompt) == "string" and prompt:gsub("^%s+", ""):gsub("%s+$", "") or ""
    if prompt == "" then
        return nil, "пустой промпт"
    end

    local addr = M.address(buf, opts)
    if not addr.notebook then
        return nil, "буфер не сохранён: агенту нечего адресовать"
    end
    if not addr.socket then
        return nil, "у nvim нет адреса сервера: агент не сможет ни прочитать ноутбук, ни ответить"
    end

    local state = M.load_state(opts.store)
    local id, how, candidates = pane.find({ pane = state.pane, dir = dir_of(addr) })
    if not id then
        return nil, how, candidates
    end

    -- Заявка до отправки — весь смысл упражнения. Ячейки под курсором может не быть
    -- (вопрос про ноутбук целиком) — тогда метить нечего, и это не ошибка.
    local token
    if addr.cell_id then
        local claim = agent.begin(buf, {
            cell = addr.cell_id,
            pending = true,
            title = prompt,
            label = opts.label,
        })
        if not claim.ok then
            return nil, claim.msg or claim.reason
        end
        token = claim.token
    end

    local ok, err = pane.send(id, M.compose(addr, token, prompt))
    if not ok then
        if token then
            agent.cancel(token) -- промпт не ушёл: за меткой никого нет, и висеть ей нельзя
        end
        return nil, err
    end

    M.save_state(opts.store, { pane = id, notebook = addr.notebook })
    M.record(opts.store, {
        at = os.date("!%Y-%m-%dT%H:%M:%SZ"),
        cell_id = addr.cell_id,
        token = token,
        pane = id,
        prompt = prompt,
    })
    return { token = token, pane = id, how = how, cell_id = addr.cell_id }
end

---Привязать ноутбук к панели агента руками: когда кандидатов несколько или нужен не тот,
---кого нашла лестница.
---@param buf integer
---@param opts? table store
---@param on_done? fun(id: string|nil)
function M.attach(buf, opts, on_done)
    opts = opts or {}
    local all = vim.tbl_filter(function(p)
        return p.cmd == pane.CMD
    end, pane.panes())
    if #all == 0 then
        vim.notify("jupyter.nvim: сессии агента нет ни в одной панели tmux", vim.log.levels.WARN)
        return
    end
    vim.ui.select(all, {
        prompt = "панель агента для этого ноутбука:",
        format_item = function(p)
            return ("%s  %s"):format(p.where, vim.fn.fnamemodify(p.path, ":~"))
        end,
    }, function(choice)
        if not choice then
            return
        end
        M.save_state(opts.store, { pane = choice.id })
        vim.notify(("jupyter.nvim: агент — панель %s (%s)"):format(choice.id, choice.where))
        if on_done then
            on_done(choice.id)
        end
    end)
end

-- --- окно промпта ---

---Окно для набора промпта.
---
---Отдельным плавающим буфером, а не строкой в документе: ноутбук — это код, который
---исполняется, и текст вопроса в нём живёт ровно до первого `:w`, после чего уезжает в
---`.ipynb` и ломает прогон. Здесь же доступен весь nvim — многострочный ввод, yank из
---ячейки, отмена.
---@param buf integer буфер ноутбука
---@param opts? table store, row, selection, scope, on_send
---@return integer|nil win
function M.open(buf, opts)
    opts = opts or {}
    local addr = M.address(buf, vim.tbl_extend("force", opts, { scope = opts.scope }))
    local prompt_buf = vim.api.nvim_create_buf(false, true)
    vim.bo[prompt_buf].buftype = "nofile"
    vim.bo[prompt_buf].bufhidden = "wipe"
    vim.bo[prompt_buf].filetype = "markdown"

    local width = math.min(M.MAX_WIDTH, math.max(30, math.floor(vim.o.columns * M.WIDTH)))
    local height = math.max(3, opts.height or M.HEIGHT)
    local title = addr.cell_id and (" спросить · ячейка " .. addr.cell_id .. " ") or " спросить · весь ноутбук "
    local win = vim.api.nvim_open_win(prompt_buf, true, {
        relative = "editor",
        width = width,
        height = height,
        row = math.max(0, math.floor((vim.o.lines - height) / 2) - 1),
        col = math.max(0, math.floor((vim.o.columns - width) / 2)),
        style = "minimal",
        border = "rounded",
        title = title,
        title_pos = "center",
        footer = " <CR> отправить · q отмена ",
        footer_pos = "center",
    })

    local closed = false
    local function close()
        if closed then
            return
        end
        closed = true
        pcall(vim.api.nvim_win_close, win, true)
    end

    local actions = {
        cancel = close,
        send = function()
            local text = table.concat(vim.api.nvim_buf_get_lines(prompt_buf, 0, -1, false), "\n")
            if not text:match("%S") then
                vim.notify("jupyter.nvim: промпт пустой", vim.log.levels.WARN)
                return
            end
            close()
            local res, err, candidates = M.send(buf, text, opts)
            if opts.on_send then
                opts.on_send(res, err, candidates)
            end
        end,
    }
    common.apply_keys(prompt_buf, actions, opts.keys or M.KEYS)

    if opts.insert ~= false then
        vim.cmd("startinsert")
    end
    return win
end

return M
