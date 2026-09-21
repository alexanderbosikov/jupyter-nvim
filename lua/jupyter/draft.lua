-- Черновик несохранённого буфера: защита от краша и от «забыл сохранить».
--
-- Задача не та, которую решает `:w`. Буфер тут — markdown от jupytext, а на диске лежит
-- `.ipynb`: каждая настоящая запись гоняет внешний конвертер и дёргает `BufWritePre` всех
-- остальных плагинов — форматтер переформатирует markdown прямо под курсором, линтеры
-- побегут, gitsigns перерисуется. Делать это по таймеру во время печати нельзя. Поэтому
-- черновик пишет ровно то, что сейчас в буфере, как есть: без конвертации, мимо файла
-- ноутбука и мимо чужих автокоманд. Цена одной записи — `writefile` на пару десятков
-- килобайт, и её можно позволить себе каждые пару секунд.
--
-- Куда: `.jupyter-out/<ноутбук>/drafts/` — рядом с историей прогонов, в каталоге, который
-- у ноутбука уже есть и который уже в `.gitignore`. Отдельно оговорка: **не** `<имя>.md`
-- рядом с ноутбуком. Это ровно тот файл, который jupytext.nvim считает своим кэшем и
-- начинает показывать вместо ноутбука (README, «Про jupytext.nvim стоит знать ещё одно»).
--
-- Имя файла — `<pid>-<номер>.md`, а не один общий на ноутбук. Два nvim на одном файле —
-- законный случай, и общий черновик означал бы, что второй молча затирает несохранённую
-- работу первого. Номер растёт на каждое открытие буфера в этом процессе: иначе новая
-- жизнь того же ноутбука писала бы поверх черновика, который сама же и нашла.
--
-- Граница: в файл ноутбука здесь не пишут никогда. Черновик только копится и отдаётся
-- обратно в буфер по явному решению — `:JupyterRecover`. Сохранять или нет, решает
-- пользователь; плагин лишь не даёт работе исчезнуть, пока он решает.

local orphans = require("jupyter.orphans")
local store = require("jupyter.store")

local M = {}

M.DIR = "drafts"

---Номер открытия внутри процесса: см. про имя файла в шапке.
local seq = 0

---buf -> { draft, timer, debounce_ms, found }
local state = {}

---@param lines string[]
---@return string
local function sha_of(lines)
    return vim.fn.sha256(table.concat(lines, "\n"))
end

---@param buf integer
---@return string[]
local function buf_lines(buf)
    return vim.api.nvim_buf_get_lines(buf, 0, -1, false)
end

---Время правки файла в миллисекундах.
---
---Не `getftime`: он считает целыми секундами, а сохранение и запись черновика в одну и ту
---же секунду — обычное дело. Для вопроса «файл изменился с тех пор?» такая гранулярность
---означает «не знаю», и ответ пришлось бы угадывать.
---
---Миллисекунды целым числом, а не секунды дробным: дробное проходит через `vim.json` с
---потерей последних знаков, и прочитанное обратно оказывается чуть меньше записанного —
---то есть «файл изменился» там, где не менялось ничего.
---@param path string|nil
---@return integer -1, если файла нет
local function mtime_of(path)
    if type(path) ~= "string" or path == "" then
        return -1
    end
    local stat = vim.uv.fs_stat(path)
    if not stat or not stat.mtime then
        return -1
    end
    return stat.mtime.sec * 1000 + math.floor((stat.mtime.nsec or 0) / 1e6)
end

-- --- сам черновик ---

M.TRACE = "trace.log"

---Сколько строк журнала держим: он пишется при каждой правке и расти ему незачем.
local TRACE_LIMIT = 400

---Журнал действий черновика: одна строка на событие, дописывается сразу.
---
---Нужен потому, что всё интересное про черновик происходит при выходе из редактора и
---после падения — то есть тогда, когда ни `:JupyterLog`, ни `:messages` уже не спросишь.
---Файл лежит рядом с самим черновиком и переживает и `:qa!`, и `SIGKILL`.
---@param self jupyter.Draft
---@param event string
---@param detail? string
local function trace(self, event, detail)
    if not self.dir then
        return
    end
    if vim.fn.isdirectory(self.dir) == 0 then
        vim.fn.mkdir(self.dir, "p")
    end
    local path = vim.fs.joinpath(self.dir, M.TRACE)
    local line = ("%s %s %s %s"):format(os.date("%H:%M:%S"), self.id, event, detail or "")
    local fh = io.open(path, "a")
    if fh then
        fh:write(line, "\n")
        fh:close()
    end
    -- обрезаем редко и целиком: считать строки на каждой записи дороже, чем изредка
    -- переписать четыреста строк
    if vim.fn.getfsize(path) > TRACE_LIMIT * 120 then
        local lines = vim.fn.readfile(path)
        vim.fn.writefile(vim.list_slice(lines, #lines - TRACE_LIMIT + 1, #lines), path)
    end
end

---Запись в журнал снаружи модуля: тем местам, что живут при буфере, а не при объекте.
---@param d jupyter.Draft
---@param event string
---@param detail? string
function M.note(d, event, detail)
    if d then
        trace(d, event, detail)
    end
end

---@class jupyter.DraftFound
---@field id string имя черновика: `<pid>-<номер>`
---@field pid integer процесс, который его писал
---@field path string
---@field lines string[]
---@field sha string
---@field saved_at string|nil время записи, ISO в UTC
---@field trusted boolean метаданные относятся именно к этому тексту
---@field outside boolean ноутбук переписали после того, как черновик записан

---@class jupyter.Draft
local Draft = {}
Draft.__index = Draft

---@param opts table notebook (путь к файлу), out_dir, id (для тестов)
---@return jupyter.Draft
function M.new(opts)
    local base = store.base_for(opts.notebook, opts.out_dir)
    local pid = opts.pid or vim.fn.getpid()
    seq = seq + 1
    return setmetatable({
        notebook = opts.notebook,
        pid = pid,
        id = opts.id or ("%d-%d"):format(pid, seq),
        dir = base and vim.fs.joinpath(base, M.DIR) or nil,
        sha = nil, -- sha последнего записанного текста: то же самое второй раз не пишем
    }, Draft)
end

---@param id? string
---@return string|nil
function Draft:path(id)
    return self.dir and vim.fs.joinpath(self.dir, (id or self.id) .. ".md") or nil
end

---@param id? string
---@return string|nil
function Draft:meta_path(id)
    return self.dir and vim.fs.joinpath(self.dir, (id or self.id) .. ".json") or nil
end

---Записать текст буфера.
---
---Атомарно, через временный файл и `rename`: краш посреди записи иначе оставил бы
---обрубок, и восстанавливать было бы нечего. Сначала текст, потом метаданные — текст и
---есть то, ради чего всё; метаданные несут sha, по которой видно, что они от него же.
---@param buf integer
---@param force? boolean записать, даже если текст не менялся с прошлого раза
---@return boolean
function Draft:save(buf, force)
    if not self.dir or not vim.api.nvim_buf_is_valid(buf) then
        return false
    end
    local lines = buf_lines(buf)
    local sha = sha_of(lines)
    if sha == self.sha and not force then
        trace(self, "save.skip", "текст не менялся")
        return false
    end
    if vim.fn.isdirectory(self.dir) == 0 then
        vim.fn.mkdir(self.dir, "p")
    end

    local path, tmp = self:path(), self:path() .. ".tmp"
    if vim.fn.writefile(lines, tmp) ~= 0 or vim.fn.rename(tmp, path) ~= 0 then
        pcall(vim.fn.delete, tmp)
        trace(self, "save.fail", "писать не дали: " .. path)
        return false
    end

    -- mtime ноутбука — чтобы при восстановлении отличить «файл с тех пор никто не трогал»
    -- от «его переписали из Jupyter Lab». Во втором случае подсовывать черновик молча
    -- нельзя: он затрёт чужую работу.
    local meta = {
        notebook = self.notebook,
        notebook_mtime = mtime_of(self.notebook),
        sha = sha,
        saved_at = os.date("!%Y-%m-%dT%H:%M:%SZ"),
        pid = self.pid,
        lines = #lines,
    }
    local mpath, mtmp = self:meta_path(), self:meta_path() .. ".tmp"
    if vim.fn.writefile({ vim.json.encode(meta) }, mtmp) == 0 then
        vim.fn.rename(mtmp, mpath)
    else
        pcall(vim.fn.delete, mtmp)
    end

    self.sha = sha
    self.notebook_mtime = meta.notebook_mtime
    trace(self, "save", ("строк %d, ноутбук %d"):format(#lines, meta.notebook_mtime))
    return true
end

---@param id? string
---@return jupyter.DraftFound|nil
function Draft:read(id)
    id = id or self.id
    local path = self:path(id)
    if not path or vim.fn.filereadable(path) == 0 then
        return nil
    end
    local lines = vim.fn.readfile(path)
    local sha = sha_of(lines)

    local meta
    local mpath = self:meta_path(id)
    if mpath and vim.fn.filereadable(mpath) == 1 then
        local ok, decoded = pcall(
            vim.json.decode,
            table.concat(vim.fn.readfile(mpath), ""),
            { luanil = { object = true, array = true } }
        )
        if ok and type(decoded) == "table" then
            meta = decoded
        end
    end

    -- Метаданные пишутся вторыми. Если краш пришёлся между двумя записями, они от
    -- прошлого текста — видно это по sha, и тогда верим тексту, а не рассказу о нём.
    local trusted = meta ~= nil and meta.sha == sha
    local outside = false
    if trusted and type(meta.notebook_mtime) == "number" and meta.notebook_mtime >= 0 and self.notebook then
        outside = mtime_of(self.notebook) > meta.notebook_mtime
    end

    return {
        id = id,
        pid = tonumber(id:match("^(%d+)")) or self.pid,
        path = path,
        lines = lines,
        sha = sha,
        trusted = trusted,
        saved_at = trusted and meta.saved_at or nil,
        -- не под trusted: даже метаданные от прошлой записи дают верную нижнюю границу
        -- того, когда ноутбук в последний раз видели неизменным
        notebook_mtime = meta and meta.notebook_mtime or nil,
        outside = outside,
    }
end

---Снять черновик, если работа действительно доехала до диска.
---
---Не по флагу `modified`: его ставит не только nvim. jupytext.nvim снимает его в своём
---`BufWriteCmd` сразу после записи промежуточного `.md` — до того, как отработает внешний
---конвертер, и независимо от того, отработает ли он вообще. Один раз это уже стоило
---работы: в буфере «сохранено», в `.ipynb` — состояние получасовой давности, а черновик
---снят как ненужный.
---
---Факт, которому можно верить, один: файл ноутбука на диске не старше черновика. Пока он
---старше — работа никуда не доехала, и держим.
---@return boolean сняли ли
function Draft:release()
    if not self.dir or mtime_of(self:path()) < 0 then
        return false -- черновика и нет
    end
    if not self.notebook then
        trace(self, "release.drop", "ноутбук неизвестен")
        return self:drop()
    end

    -- Сравниваем с mtime ноутбука на момент, когда черновик писался: работа доехала до
    -- диска тогда и только тогда, когда файл ноутбука с тех пор изменился.
    local taken = self.notebook_mtime
    if taken == nil then
        local mine = self:read() -- черновик от прошлой жизни: спрашиваем его метаданные
        taken = mine and mine.notebook_mtime or nil
    end
    local now = mtime_of(self.notebook)
    if type(taken) == "number" and taken >= 0 and now <= taken then
        trace(self, "release.keep", ("ноутбук %d <= %d"):format(now, taken))
        return false
    end
    trace(self, "release.drop", ("ноутбук %d > %s"):format(now, tostring(taken)))
    return self:drop()
end

---@param id? string
---@return boolean удалили ли что-нибудь
function Draft:drop(id)
    id = id or self.id
    if not self.dir then
        return false
    end
    local gone = false
    for _, path in ipairs({ self:path(id), self:meta_path(id) }) do
        if vim.fn.filereadable(path) == 1 then
            pcall(vim.fn.delete, path)
            gone = true
        end
    end
    if id == self.id then
        self.sha, self.notebook_mtime = nil, nil
    end
    if gone then
        trace(self, "drop", id)
    end
    return gone
end

---Черновики, которые можно предложить к восстановлению.
---
---Свой процесс — да: буфер могли закрыть через `:bd!` и открыть заново в том же nvim,
---работа от этого не менее потеряна. Чужой с живым процессом — нет: там сейчас кто-то
---печатает, и это не наш черновик. Остаётся осиротевший, от процесса, которого больше
---нет, — а это ровно то, что оставляет после себя краш.
---@return jupyter.DraftFound[]
function Draft:candidates()
    if not self.dir or vim.fn.isdirectory(self.dir) == 0 then
        return {}
    end
    local out = {}
    for name, kind in vim.fs.dir(self.dir) do
        local id = kind == "file" and name:match("^(%d+%-%d+)%.md$") or nil
        if id and id ~= self.id then
            local pid = tonumber(id:match("^(%d+)"))
            if pid == self.pid or not orphans.alive(pid) then
                local found = self:read(id)
                if found then
                    table.insert(out, found)
                end
            end
        end
    end
    table.sort(out, function(a, b)
        return (a.saved_at or "") .. a.id < (b.saved_at or "") .. b.id
    end)
    return out
end

-- --- жизнь при буфере ---

---Взять буфер под черновик: дебаунс на правки, снятие при сохранении.
---
---`nvim_buf_attach`, а не `TextChanged`: `on_lines` приходит в любом режиме и на правку
---из Lua тоже — значит и вставка ячейки, и правка агента доедут до черновика.
---
---`enabled = false` не отменяет присмотра, а только запрещает запись: буфер всё равно
---числится ноутбуком, и это единственный список, по которому `write_on_focus_lost`
---понимает, что сохранять. Иначе выключенный черновик молча выключал бы и его.
---@param buf integer
---@param opts table out_dir, debounce_ms, augroup, enabled
---@return jupyter.Draft|nil
function M.attach(buf, opts)
    if state[buf] then
        return state[buf].draft
    end
    local d = M.new({ notebook = vim.api.nvim_buf_get_name(buf), out_dir = opts.out_dir })
    if not d.dir then
        return nil -- безымянный буфер: писать некуда
    end
    state[buf] = {
        draft = d,
        debounce_ms = opts.debounce_ms or 2000,
        enabled = opts.enabled ~= false,
    }
    M.note(d, "attach", ("buf %d, %s"):format(buf, vim.api.nvim_buf_get_name(buf)))

    vim.api.nvim_buf_attach(buf, false, {
        on_lines = function()
            if not state[buf] then
                return true -- черновика больше нет: отписываемся
            end
            M.touch(buf)
        end,
        on_reload = function()
            -- буфер перечитан с диска — но только если на диске и правда лежит то, что
            -- было в буфере. Отсюда release, а не drop: см. Draft:release.
            if state[buf] then
                state[buf].draft:release()
            end
        end,
    })

    vim.api.nvim_create_autocmd("BufWritePost", {
        group = opts.augroup,
        buffer = buf,
        callback = function()
            local st = state[buf]
            if st then
                st.draft:release()
            end
        end,
    })
    vim.api.nvim_create_autocmd("BufUnload", {
        group = opts.augroup,
        buffer = buf,
        callback = function()
            M.detach(buf)
        end,
    })
    return d
end

---Перезапустить дебаунс. Зовётся на каждую правку, поэтому не делает ничего, кроме таймера.
---@param buf integer
function M.touch(buf)
    local st = state[buf]
    if not st or not st.enabled then
        return
    end
    if not st.timer then
        st.timer = vim.uv.new_timer()
    end
    st.timer:stop()
    st.timer:start(st.debounce_ms, 0, function()
        vim.schedule(function()
            M.save(buf)
        end)
    end)
end

---Записать черновик этого буфера сейчас.
---@param buf integer
---@return boolean
function M.save(buf)
    local st = state[buf]
    if not st or not st.enabled or not vim.api.nvim_buf_is_valid(buf) then
        return false
    end
    if not vim.bo[buf].modified then
        M.note(st.draft, "save.unmodified", "буфер считается сохранённым")
        st.draft:release() -- сняли, только если работа доехала до файла
        return false
    end
    return st.draft:save(buf)
end

---Записать черновики всех буферов сейчас.
---
---Вешается на выход из редактора и на потерю фокуса: оба — моменты, когда ждать
---дебаунса уже поздно.
---@param reason? string что именно случилось: попадёт в журнал
---@return integer сколько записали
function M.flush_all(reason)
    local written = 0
    for buf, st in pairs(state) do
        M.note(st.draft, "flush", reason or "по требованию")
        if M.save(buf) then
            written = written + 1
        end
    end
    return written
end

---Отпустить буфер.
---
---Черновик при этом не трогаем, если буфер закрыли несохранённым: это ровно тот случай,
---ради которого он писался. `:bd!` теряет работу так же, как краш.
---@param buf integer
function M.detach(buf)
    local st = state[buf]
    if not st then
        return
    end
    state[buf] = nil
    if st.timer then
        st.timer:stop()
        if not st.timer:is_closing() then
            st.timer:close()
        end
    end
    local ok, modified = pcall(function()
        return vim.api.nvim_buf_is_valid(buf) and vim.bo[buf].modified
    end)
    M.note(st.draft, "detach", ("modified=%s"):format(tostring(ok and modified)))
    if ok and modified then
        -- Пишем прямо здесь, а не надеемся на `flush_all` из `VimLeavePre`: при `:qa!`
        -- буфер выгружается РАНЬШЕ, чем приходит VimLeavePre, и к тому моменту этого
        -- буфера в списке уже нет. Проверено по журналу: `detach` есть, `flush` нет.
        -- Без этой записи терялось всё, что напечатали за последние секунды дебаунса.
        st.draft:save(buf)
    elseif ok then
        st.draft:release()
    end
end

---Что осталось от прошлой жизни этого ноутбука.
---
---Совпавшие с буфером убираем молча — но только когда буфер без правок, то есть совпадает
---с файлом на диске. Тогда «черновик как буфер» и правда значит «всё уже сохранено».
---
---Если правки есть, не трогаем ничего. «Черновик совпал с буфером» тогда значит ровно
---обратное: черновик свежий, а работа нигде не сохранена. На этом однажды потерялась целая
---сессия — при выходе буфер успевал отцепиться и тут же прицепиться заново, новый черновик
---находил старый, видел совпадение с несохранённым буфером и удалял его. В журнале это
---выглядело как `detach` → `attach` → `check.same` → `drop` в одну секунду.
---@param buf integer
---@return jupyter.DraftFound[]
function M.check(buf)
    local st = state[buf]
    if not st then
        return {}
    end
    local saved = not vim.bo[buf].modified
    local current = sha_of(buf_lines(buf))
    local live = {}
    for _, found in ipairs(st.draft:candidates()) do
        if saved and found.sha == current then
            M.note(st.draft, "check.same", found.id)
            st.draft:drop(found.id)
        else
            table.insert(live, found)
        end
    end
    st.found = live
    M.note(st.draft, "check", ("строк в буфере %d, найдено %d"):format(
        vim.api.nvim_buf_line_count(buf), #live
    ))
    return live
end

---@param buf integer
---@return jupyter.DraftFound[]
function M.found(buf)
    local st = state[buf]
    return st and st.found or {}
end

---Буферы, которые сейчас под черновиком.
---@return integer[]
function M.bufs()
    return vim.tbl_keys(state)
end

---@param buf integer
---@return jupyter.Draft|nil
function M.of(buf)
    local st = state[buf]
    return st and st.draft or nil
end

---@param buf integer
---@param id string
---@return boolean
function M.drop(buf, id)
    local st = state[buf]
    if not st then
        return false
    end
    st.found = vim.tbl_filter(function(f)
        return f.id ~= id
    end, st.found or {})
    return st.draft:drop(id)
end

---Положить текст черновика в буфер.
---
---В файл не пишем: решение сохранять — пользователя, и восстановление не должно быть
---необратимым. undo рвём с обеих сторон, как это делает agent.lua, — иначе правка
---склеится с тем, что пользователь печатал, и один `u` снесёт обе.
---@param buf integer
---@param lines string[]
---@return boolean
function M.apply(buf, lines)
    if not vim.api.nvim_buf_is_valid(buf) or not vim.bo[buf].modifiable then
        return false
    end
    local function break_undo()
        pcall(vim.api.nvim_buf_call, buf, function()
            vim.cmd("let &undolevels = &undolevels")
        end)
    end
    break_undo()
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    break_undo()
    return true
end

---Человеческое описание находки: что нашли и насколько ему можно верить.
---@param found jupyter.DraftFound
---@return string
function M.describe(found)
    local when = found.saved_at and store.local_time(found.saved_at)
    local parts = {
        ("черновик %s, строк %d"):format(when or "неизвестно когда", #found.lines),
    }
    if not found.trusted then
        table.insert(parts, "метаданные не сошлись — писался в момент падения")
    end
    if found.outside then
        table.insert(parts, "ноутбук с тех пор изменился снаружи")
    end
    return table.concat(parts, " · ")
end

return M
