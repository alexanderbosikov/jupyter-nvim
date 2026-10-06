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
-- Отправка — не наше дело, этим занят `pane.lua`: сессия агента живёт в своей панели tmux
-- или herdr, и туда пишется текст ровно так, как его набрал бы человек.
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

---Состояние привязки: какая панель tmux/herdr обслуживает этот ноутбук. Рядом с индексом
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

-- --- адрес для агента: файл его панели ---

---Каталог, где плагин оставляет агенту адрес ноутбука: файл на панель, `<id панели>.json`.
---Id своей панели агент знает сам — tmux и herdr ставят его в окружение каждой панели
---(`$TMUX_PANE`, `$HERDR_PANE_ID`), и команды агента его наследуют. Поэтому файл находится
---без всякой подсказки в промпте, и шапке не нужно каждый раз нести полный путь и сокет —
---в том числе после `/clear`, когда агент забыл всё, что ему говорили раньше.
---`nil` — `stdpath("state")/jupyter/panes`; задаётся в тестах.
M.PANES_DIR = nil

---Запись старше этого — выброшена при следующей записи в файл: ноутбук давно не спрашивали.
M.PANE_TTL = 7 * 24 * 3600

---@return string
function M.panes_dir()
    return M.PANES_DIR or vim.fs.joinpath(vim.fn.stdpath("state"), "jupyter", "panes")
end

---Записать адрес ноутбука в файл панели агента.
---
---В одну панель могут слать несколько nvim с разными ноутбуками, поэтому внутри файла —
---запись на ноутбук: `{ [путь] = { socket, at } }`. Агент находит свою по имени из шапки,
---при совпадении имён берёт самую свежую `at`. Чужие записи сохраняются; выбрасываются
---только те, чей nvim закрыт (сокета больше нет) или которые старше `PANE_TTL`. Запись
---через временный файл и `rename`: два nvim, пишущие разом, не оставят полфайла.
---@param pane_id string
---@param addr jupyter.Address
---@param now? integer
---@return boolean записано
function M.remember(pane_id, addr, now)
    if type(pane_id) ~= "string" or pane_id == "" or not addr.notebook or not addr.socket then
        return false
    end
    now = now or os.time()
    local dir = M.panes_dir()
    local path = vim.fs.joinpath(dir, pane_id .. ".json")

    local entries = {}
    if vim.fn.filereadable(path) == 1 then
        local ok, decoded = pcall(vim.json.decode, table.concat(vim.fn.readfile(path), "\n"))
        if ok and type(decoded) == "table" then
            entries = decoded
        end
    end
    local kept = {}
    for notebook, e in pairs(entries) do
        local alive = type(e) == "table" and type(e.socket) == "string" and vim.uv.fs_stat(e.socket) ~= nil
        local fresh = type(e) == "table" and type(e.at) == "number" and now - e.at <= M.PANE_TTL
        if alive and fresh then
            kept[notebook] = e
        end
    end
    kept[addr.notebook] = { socket = addr.socket, at = now }

    vim.fn.mkdir(dir, "p")
    local tmp = ("%s.%d.tmp"):format(path, vim.uv.os_getpid())
    if not pcall(vim.fn.writefile, { vim.json.encode(kept) }, tmp) then
        return false
    end
    local ok = vim.uv.fs_rename(tmp, path)
    if not ok then
        pcall(vim.fn.delete, tmp)
        return false
    end
    return true
end

---Имя ноутбука в шапке: каталог и файл. Одного имени мало — `01_eda.ipynb` есть в каждой
---задаче; с каталогом совпадение в одной панели практически исключено.
---@param notebook string|nil
---@return string
function M.short_name(notebook)
    if not notebook then
        return "ноутбук не сохранён на диск"
    end
    return vim.fn.fnamemodify(notebook, ":h:t") .. "/" .. vim.fn.fnamemodify(notebook, ":t")
end

---Шапка промпта: где ячейка, что с ней и какая заявка ждёт агента.
---
---Пишется словами, а не JSON: это первый текст, который он читает, и человек читает его
---тоже — в журнале промптов и в окне сессии. Поэтому в ней только то, что меняется от
---промпта к промпту. Как обращаться с заявкой — в скилле `jupyter-nvim`, его триггер —
---`[jupyter.nvim]` в начале. Полный путь и сокет — в файле панели (`remember`); если его
---записать не удалось (`remembered = false`), они едут в шапке, как раньше.
---@param addr jupyter.Address
---@param token integer|nil номер открытой заявки
---@param opts? table remembered: адрес лежит в файле панели
---@return string[]
function M.header(addr, token, opts)
    opts = opts or {}
    local first = { "[jupyter.nvim] " .. M.short_name(addr.notebook) }
    if addr.cell_id then
        table.insert(first, "ячейка " .. addr.cell_id)
        if addr.lang then
            table.insert(first, addr.lang)
        end
        if addr.start_row then
            table.insert(first, ("строки %d–%d"):format(addr.start_row, addr.end_row))
        end
    end
    -- выделение всей ячейки ничего не добавляет к её строкам
    local sel = addr.selection
    if sel and not (sel.from == addr.start_row and sel.to == addr.end_row) then
        table.insert(first, ("выделено %d–%d — речь про этот кусок"):format(sel.from, sel.to))
    end
    local out = { table.concat(first, " · ") }

    if not opts.remembered then
        table.insert(out, "ноутбук: " .. (addr.notebook or "не сохранён на диск"))
        if addr.socket then
            table.insert(out, "сокет nvim: " .. addr.socket)
        end
    end

    if addr.output then
        local o = addr.output
        local path = o.path
        if path and addr.notebook then
            -- от каталога ноутбука: полный путь агент соберёт сам. Через resolve — на macOS
            -- /var и /private/var один каталог, а строки разные
            local dir = vim.fn.resolve(vim.fn.fnamemodify(addr.notebook, ":h")) .. "/"
            local full = vim.fn.resolve(path)
            if full:sub(1, #dir) == dir then
                path = full:sub(#dir + 1)
            end
        end
        local parts = { "вывод: " .. (path or "нет на диске") }
        if o.kind then
            table.insert(parts, o.kind)
        end
        if o.rows and o.cols then
            table.insert(parts, ("%d×%d"):format(o.rows, o.cols))
        end
        if o.stale then
            table.insert(parts, "устарел: код правили после прогона")
        end
        table.insert(out, table.concat(parts, " · "))
    end

    if token then
        table.insert(out, ("заявка %d уже открыта → edit_adopt(%d)"):format(token, token))
    else
        table.insert(out, "заявки нет: вопрос не про одну ячейку; править — своей заявкой, edit_begin")
    end
    return out
end

---Весь текст, который уедет в панель агента.
---@param addr jupyter.Address
---@param token integer|nil
---@param prompt string
---@return string
---@param opts? table remembered
function M.compose(addr, token, prompt, opts)
    local out = M.header(addr, token, opts)
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

    local remembered = M.remember(id, addr)
    local ok, err = pane.send(id, M.compose(addr, token, prompt, { remembered = remembered }))
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
    local all = pane.agents()
    if #all == 0 then
        vim.notify("jupyter.nvim: сессии агента нет ни в одной панели tmux/herdr", vim.log.levels.WARN)
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
