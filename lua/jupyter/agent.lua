-- Правка ноутбука внешним агентом: заявка, якорь, применение (ARCHITECTURE.md §7.5).
--
-- Задача не в том, чтобы записать строки — это одна функция. Задача в том, что между
-- «прочитал ячейку» и «записал ответ» проходят десятки секунд, и всё это время документ
-- живой: пользователь правит соседние ячейки, вставляет строки выше, двигает ячейку.
-- Номера строк, по которым читали, к моменту записи уже ничего не значат.
--
-- Отсюда две фазы. `begin` ставит якорь и метку в буфере, `apply` пишет по якорю, а не по
-- номерам. Якорей два, и это не запас прочности, а разные виды сдвига: `jncell` переживает
-- перемещение ячейки целиком (extmark в таком случае показал бы на чужой текст), extmark —
-- правки выше и ниже (id у ячейки может отсутствовать вовсе). Сверх обоих — sha тела:
-- якорь отвечает «где ячейка», sha отвечает «та ли она, что я читал». Без второго вопроса
-- правка молча затирает то, что пользователь набрал внутри ячейки, пока агент думал.

local cells = require("jupyter.cells")
local cellid = require("jupyter.cellid")
local common = require("jupyter.ui.common")

local M = {}

-- Свой namespace, не общий со статусами: `ui.status` чистит собственный целиком на каждой
-- перерисовке (TextChanged), и метка заявки исчезала бы от первого же нажатия клавиши.
M.NS = vim.api.nvim_create_namespace("jupyter.agent")
M.NS_FLASH = vim.api.nvim_create_namespace("jupyter.agent.flash")
-- Знаки отдельно от самой метки: так «одна заявка — один extmark» остаётся правдой, и
-- поиск метки не приходится фильтровать от знаков, которых на длинной ячейке двадцать.
M.NS_SIGN = vim.api.nvim_create_namespace("jupyter.agent.sign")
-- Рамка — свои extmark'и сверху и снизу области: границы правки видно, даже когда тело
-- ячейки длиннее экрана и ни одного края в кадре нет.
M.NS_FRAME = vim.api.nvim_create_namespace("jupyter.agent.frame")

M.LABEL = "агент"

---Чьё имя стоит в метке, которую открыл сам плагин при отправке промпта. Не «агент»: пока
---никто её не взял, важно именно то, что промпт ушёл, а на той стороне его ещё не читали.
---Как только агент отзовётся `adopt`, имя сменится на его собственное.
M.LABEL_SENT = "отправлено"

---Ширина заголовка в метке. Сорок знаков — это примерно первая фраза промпта: длиннее
---уезжает за край узкого окна, а там его всё равно не прочесть.
M.TITLE_MAX = 40

---Сколько заявка живёт без вестей. Пять минут — это «агент думает над сложной правкой», а
---не «агента больше нет»: обычная правка занимает десятки секунд, а мёртвая метка держит
---ячейку, в которую пользователь после неё боится лезть.
M.TTL_MS = 5 * 60 * 1000

---Шаг «колеса» и пересчёта возраста. 250 мс — как в 99: глазу этого хватает, чтобы
---прочитать движение, а буфер трогается четыре раза в секунду и только пока он на экране.
M.TICK_MS = 250

---Кадры «колеса». Те же десять брайлевых символов, что у 99: набор обкатан, читается в
---любом моноширинном шрифте и не прыгает по ширине.
M.FRAMES = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" }

---Что агент делает с этим куском. Слово настраивается: у плагина всё по-русски, но
---привычное «Implementing» ставится одной строкой в конфиге.
M.VERB = "правит"
M.VERB_INSERT = "пишет новую ячейку"


---Доля срока, после которой метка становится предупреждающей: заявка вот-вот снимется.
M.STALE_AT = 0.75

---Знак в signcolumn на строках заявки. Подпись в тексте видно, только если смотришь именно
---туда, а столбец знаков — то место, где глаз и так ищет чужие правки: там живут
---диагностики и гит. Пустая строка или nil — не ставить.
M.SIGN = '✎'

---Приоритет extmark'ов подписи. Порядок нескольких виртуальных строк на одной строке он,
---вопреки ожиданию, НЕ решает: проверено на живом буфере — подпись со `priority = 5000`
---всё равно менялась со статусом местами, как только тот перерисовывался. Порядок задаёт
---очерёдность extmark'ов, и держит её `M.reanchor` (зовётся после отрисовки статусов).
---Само поле оставлено для подсветки, где приоритет как раз работает.
M.PRIORITY = 5000

---@class jupyter.EditRequest
---@field token integer
---@field buf integer
---@field kind "replace"|"insert"
---@field cell_id string|nil id ячейки: для replace — какой, для insert — после какой
---@field by_id boolean id настоящий (из текста), а не запасной от номера ячейки
---@field sha string|nil тело ячейки на момент заявки
---@field mark integer extmark: область правки или точка вставки
---@field signs integer[] extmark'и знаков в signcolumn, по одному на строку заявки
---@field label string
---@field title string|nil что делается: первая строка промпта либо слова самого агента
---@field opened_at integer когда заявка открыта (vim.uv.now)
---@field touched_at integer когда о ней в последний раз были вести
---@field ttl_ms integer сколько ей жить без вестей

local requests = {}
---Токены заявок, снятых по сроку. Нужны, чтобы ответить агенту «твою заявку сняли», а не
---«такой заявки не было»: первое значит «открой новую и продолжай», второе — «ты перепутал
---токен», и разбираться в этом агент должен без нас.
local expired = {}
local last_token = 0
local timer = nil
local stop_timer -- определены ниже, а нужны уже в forget
local clear_frame
local unpad

---sha тела ячейки — тот же, что кладёт в индекс сайдкар и с которым сверяется снимок.
---@param buf integer
---@param cell jupyter.Cell
---@return string
local function sha_of(buf, cell)
    return vim.fn.sha256(cells.text(buf, cell)):sub(1, 8)
end

---Разорвать undo-блок в этом буфере.
---
---Без разрыва правка агента склеивается с тем, что пользователь печатал в этот же момент,
---и один `u` сносит обе. Нужен с обеих сторон записи: до — чтобы отделиться от его ввода,
---после — чтобы его следующий ввод не прилип к нашей правке.
---
---Через `nvim_buf_call`, потому что `&undolevels` читается и пишется у текущего буфера:
---агент правит тот, который назвал, а пользователь в это время может смотреть другой — и
---разрыв ушёл бы не в тот документ.
---@param buf integer
local function break_undo(buf)
    pcall(vim.api.nvim_buf_call, buf, function()
        vim.cmd("let &undolevels = &undolevels")
    end)
end

---@param req jupyter.EditRequest
---@return integer|nil строка (1-based), где стоит якорь
local function mark_row(req)
    local pos = vim.api.nvim_buf_get_extmark_by_id(req.buf, M.NS, req.mark, {})
    return pos[1] and pos[1] + 1 or nil
end

---Где сейчас ячейка заявки.
---
---Сначала по id: он переживает перестановку ячеек, при которой extmark остался бы на
---прежнем месте, то есть указывал бы на соседа. Запасной id (от номера ячейки) для этого
---не годится — после вставки соседа он достаётся другой ячейке.
---@param req jupyter.EditRequest
---@return jupyter.Cell|nil
local function locate(req)
    if req.by_id and req.cell_id then
        local found = cellid.find(req.buf, req.cell_id)
        if found then
            return found
        end
    end
    local row = mark_row(req)
    return row and cells.at(req.buf, row) or nil
end

---@param req jupyter.EditRequest
local function forget(req)
    unpad(req) -- дописанная в конец пустая строка уходит вместе с заявкой
    -- удаляем свои extmark'и, а не чистим namespace: в нём могут стоять чужие заявки
    pcall(vim.api.nvim_buf_del_extmark, req.buf, M.NS, req.mark)
    for _, id in ipairs(req.signs or {}) do
        pcall(vim.api.nvim_buf_del_extmark, req.buf, M.NS_SIGN, id)
    end
    clear_frame(req)
    requests[req.token] = nil
    stop_timer()
end

---Вспышка на только что вставленном: правка в двадцать строк иначе теряется на экране,
---особенно если пришла выше видимой области.
---@param buf integer
---@param from integer 1-based
---@param to integer 1-based, включительно
local function flash(buf, from, to)
    local hl = vim.hl or vim.highlight
    if not (hl and hl.range) then
        return
    end
    pcall(hl.range, buf, M.NS_FLASH, "JupyterAgentFlash", { from - 1, 0 }, { to - 1, -1 }, {
        timeout = 400,
    })
end

---Возраст словами: «12с», «2м08с». Секунды нужны и в минутах — по ним видно, что
---счётчик идёт, то есть агент жив, а не замер.
---@param ms integer
---@return string
local function fmt_age(ms)
    local sec = math.max(0, math.floor(ms / 1000))
    if sec < 60 then
        return ("%dс"):format(sec)
    end
    return ("%dм%02dс"):format(math.floor(sec / 60), sec % 60)
end

---Кадр «колеса» на этот момент.
---
---Считается от часов, а не от числа тиков: пропущенный тик (буфер был не на экране,
---редактор был занят) тогда не замедляет колесо, а просто не показывается.
---@param now integer
---@return string
local function frame(now)
    return M.FRAMES[math.floor(now / M.TICK_MS) % #M.FRAMES + 1]
end

---Заголовок заявки: одна строка, подрезанная по ширине.
---
---Из промпта берётся первая строка — она почти всегда и есть «что делается». Многострочный
---заголовок разорвал бы рамку в три виртуальные строки, а длинный уехал бы за край окна.
---@param text string|nil
---@return string|nil
local function title_of(text)
    if type(text) ~= "string" then
        return nil
    end
    local first = (vim.split(text, "\n", { plain = true })[1] or ""):gsub("^%s+", ""):gsub("%s+$", "")
    if first == "" then
        return nil
    end
    return common.clip(first, M.TITLE_MAX)
end

---Подпись: колесо, кто работает, что делает и сколько уже. Возраст — тот самый ответ на
---«он думает или его больше нет»: колесо крутится у любого таймера, счётчик — нет.
---@param req jupyter.EditRequest
---@param now integer
---@return string
local function label_text(req, now)
    local age = fmt_age(now - req.opened_at)
    if req.title then
        -- заголовок отвечает на «что делается» точнее любого глагола, и глагол рядом с ним
        -- только отнимал бы ширину у самого заголовка
        return (" %s %s · %s · %s "):format(frame(now), req.label, req.title, age)
    end
    local verb = req.kind == "insert" and M.VERB_INSERT or M.VERB
    return (" %s %s %s · %s "):format(frame(now), req.label, verb, age)
end

---Цвет подписи: в конце срока заявка предупреждает, что вот-вот снимется сама.
---@param req jupyter.EditRequest
---@param now integer
---@return string
local function label_group(req, now)
    local waited = now - req.touched_at
    return waited >= req.ttl_ms * M.STALE_AT and "JupyterAgentStale" or "JupyterAgentText"
end

---Переставить знаки в signcolumn на строки заявки.
---
---Пересобираются целиком, а не двигаются: строк в ячейке единицы, а следить, какая из них
---куда уехала, — это вторая копия того, что extmark'и и так делают сами.
---@param req jupyter.EditRequest
---@param from_row integer 1-based
---@param to_row integer 1-based, включительно
---@param group string
local function mark_signs(req, from_row, to_row, group)
    if req.sign_group == group and req.sign_from == from_row and req.sign_to == to_row then
        return -- ничего не изменилось: незачем трогать буфер каждую секунду
    end
    for _, id in ipairs(req.signs or {}) do
        pcall(vim.api.nvim_buf_del_extmark, req.buf, M.NS_SIGN, id)
    end
    req.signs = {}
    req.sign_group, req.sign_from, req.sign_to = group, from_row, to_row
    if not M.SIGN or M.SIGN == "" then
        return
    end
    for row = from_row, to_row do
        local ok, id = pcall(vim.api.nvim_buf_set_extmark, req.buf, M.NS_SIGN, row - 1, 0, {
            sign_text = M.SIGN,
            sign_hl_group = group,
        })
        if ok then
            table.insert(req.signs, id)
        end
    end
end

---Пустая строка сразу за ячейкой, если она там есть.
---
---Пустую строку не прячет ни один рендерер — в отличие от закрывающего фенса, — поэтому
---она годится в якоря всегда, когда существует.
---@param buf integer
---@param row integer 1-based конец ячейки
---@return integer|nil 1-based номер пустой строки
local function blank_line_after(buf, row)
    local next_row = row + 1
    if next_row > vim.api.nvim_buf_line_count(buf) then
        return nil
    end
    local line = vim.api.nvim_buf_get_lines(buf, next_row - 1, next_row, false)[1]
    return line == "" and next_row or nil
end

---Дописать пустую строку в конец, чтобы подписи было за что зацепиться.
---
---Единственное место, где заявка трогает документ, и только в одном случае: ячейка, после
---которой вставляем, кончается последней строкой буфера. Вешать подпись тогда не на что —
---закрывающий фенс render-markdown прячет целиком, а на скрытой строке `virt_lines` не
---рисуются, и запасной якорь уводит подпись ВНУТРЬ ячейки, где она читается как «правят
---эту», а не «добавят новую».
---
---Скрыта ли строка на самом деле, мы не спрашиваем: `conceal_lines` рендерер ставит по
---видимой области, и в момент заявки их может не быть вовсе — проверка отвечала бы то так,
---то эдак на один и тот же документ. Пустая строка в конце безвредна при любом ответе:
---jupytext её не заметит, а `forget` уберёт её обратно, если она всё ещё пуста и её не
---занял пользователь.
---@param req jupyter.EditRequest
---@param row integer 1-based строка якоря
local function pad_eof(req, row)
    local total = vim.api.nvim_buf_line_count(req.buf)
    if req.pad or row < total then
        return
    end
    local ok = pcall(vim.api.nvim_buf_set_lines, req.buf, total, total, false, { "" })
    req.pad = ok or nil
end

---Убрать дописанную строку, если она так и осталась пустой.
---@param req jupyter.EditRequest
function unpad(req)
    if not req.pad or not vim.api.nvim_buf_is_valid(req.buf) then
        return
    end
    req.pad = nil
    local total = vim.api.nvim_buf_line_count(req.buf)
    local last = vim.api.nvim_buf_get_lines(req.buf, total - 1, total, false)[1]
    if last == "" and total > 1 then
        pcall(vim.api.nvim_buf_set_lines, req.buf, total - 1, total, false, {})
    end
end

---Убрать прошлые строки рамки: они ставятся заново на каждый тик.
---
---Поля перечислены по одному, а не списком: у вставки верхней строки нет, и `ipairs`
---по `{ nil, id }` не обходит ничего — подпись оставалась в буфере, а следующий тик
---рисовал ещё одну. За минуту их накапливалось под три сотни.
---@param req jupyter.EditRequest
function clear_frame(req)
    if req.frame_top then
        pcall(vim.api.nvim_buf_del_extmark, req.buf, M.NS_FRAME, req.frame_top)
    end
    if req.frame_bottom then
        pcall(vim.api.nvim_buf_del_extmark, req.buf, M.NS_FRAME, req.frame_bottom)
    end
    req.frame_top, req.frame_bottom = nil, nil
end

---Виртуальная строка под строкой документа — тем же способом, что и статус ячейки.
---
---Своим extmark'ом это не делается: строка ячейки, под которой напрашивается подпись, —
---закрывающий ```, а render-markdown прячет его целиком (`conceal_lines`). На скрытой
---строке `virt_lines` не рисуются вовсе — подпись появлялась, только когда пользователь
---ставил на неё курсор и conceal отпускал строку. Вся причина и запасной якорь для конца
---файла расписаны в `ui/common.lua`.
---@param req jupyter.EditRequest
---@param row integer 1-based строка, ПОД которой встанет подпись
---@param edge_row integer 1-based видимая строка на случай конца буфера
---@param chunk table { текст, группа }
---@return integer|nil
local function virt_line(req, id, row, edge_row, chunk)
    return common.virt_line_below(req.buf, M.NS_FRAME, row, { { chunk } }, edge_row, {
        id = id,
        priority = M.PRIORITY,
    })
end

---Обвести кусок виртуальными строками сверху и снизу.
---
---Виртуальные не для красоты: этих строк нет в документе, поэтому в них нельзя встать
---курсором, их не сохранит `:w` и не увидит jupytext. Ячейка остаётся ровно тем, чем
---была, — рамка живёт поверх неё.
---@param req jupyter.EditRequest
---@param body_first integer 1-based первая строка тела
---@param body_last integer 1-based последняя строка тела
---@param chunk table { текст, группа }
local function frame_lines(req, body_first, body_last, chunk)
    if body_first > 1 then
        req.frame_top = virt_line(req, req.frame_top, body_first - 1, body_first, chunk)
    else
        local ok, id = pcall(vim.api.nvim_buf_set_extmark, req.buf, M.NS_FRAME, 0, 0, {
            id = req.frame_top,
            priority = M.PRIORITY,
            virt_lines = { { chunk } },
            virt_lines_above = true,
        })
        req.frame_top = ok and id or nil
    end
    -- снизу — под закрывающим фенсом, а не под последней строкой тела: иначе подпись
    -- встаёт вплотную к скрытой строке, а это та самая пара, на которой ломается
    -- прокрутка (см. `ui/common.lua`)
    req.frame_bottom = virt_line(req, req.frame_bottom, body_last + (req.fence or 0), body_last, chunk)
end

---Перерисовать метку на прежнем месте: меняется только подпись.
---
---Координаты берутся у самого extmark'а, а не из заявки: он всё это время ехал вместе с
---текстом, и записанные в `begin` номера строк давно не те.
---@param req jupyter.EditRequest
---@param now integer
local function refresh(req, now)
    local pos = vim.api.nvim_buf_get_extmark_by_id(req.buf, M.NS, req.mark, { details = true })
    if not pos[1] then
        return
    end
    local details = pos[3] or {}
    local chunk = { label_text(req, now), label_group(req, now) }

    if req.kind ~= "insert" then
        local body_first, body_last = pos[1] + 1, details.end_row or pos[1]
        pcall(vim.api.nvim_buf_set_extmark, req.buf, M.NS, pos[1], pos[2], {
            id = req.mark,
            end_row = body_last,
            end_col = details.end_col,
            hl_group = "JupyterAgentPending",
            hl_eol = true,
            hl_mode = "combine",
        })
        frame_lines(req, body_first, body_last, chunk)
        mark_signs(req, body_first, body_last, chunk[2])
    else
        -- вставке обводить нечего: ячейки ещё нет, есть только место под неё. Якорь
        -- заявки при этом не двигается — по нему пишет `apply`, и он должен указывать
        -- на конец ячейки, а не на строку, где удобно нарисовать подпись
        local anchor = pos[1] + 1
        pad_eof(req, anchor) -- конец файла: подписи нужна видимая строка под ячейкой
        local edge = math.max(1, anchor - 1)
        local gap = blank_line_after(req.buf, anchor)
        if gap then
            -- Между ячейками почти всегда стоит пустая строка. Вешаем подпись ПОД неё:
            -- статус предыдущей ячейки цепляется за ту же строку сверху, и на одном
            -- якоре они начинали меняться местами — порядок виртуальных строк на одной
            -- строке определяется порядком extmark'ов, а статусы пересоздаются на каждое
            -- нажатие клавиши. Разные слоты — и спорить не о чем. Заодно подпись стоит
            -- ровно в той щели, где появится новая ячейка.
            local ok, id = pcall(vim.api.nvim_buf_set_extmark, req.buf, M.NS_FRAME, gap - 1, 0, {
                id = req.frame_bottom,
                priority = M.PRIORITY,
                virt_lines = { { chunk } },
                virt_lines_above = false,
            })
            req.frame_bottom = ok and id or nil
        elseif req.pad then
            -- опора дописана нами, и подпись вешается ПОД неё: место вставки — конец
            -- документа, там ей и место, а не в зазоре между ячейкой и пустой строкой
            local total = vim.api.nvim_buf_line_count(req.buf)
            local ok, id = pcall(vim.api.nvim_buf_set_extmark, req.buf, M.NS_FRAME, total - 1, 0, {
                id = req.frame_bottom,
                priority = M.PRIORITY,
                virt_lines = { { chunk } },
                virt_lines_above = false,
            })
            req.frame_bottom = ok and id or nil
        else
            req.frame_bottom = virt_line(req, req.frame_bottom, anchor, edge, chunk)
        end
        mark_signs(req, edge, edge, chunk[2])
    end
end

function stop_timer()
    if timer and next(requests) == nil then
        timer:stop()
        timer:close()
        timer = nil
    end
end

---Таймер живёт только при открытых заявках: без них тикать незачем.
local function ensure_timer()
    if timer or next(requests) == nil then
        return
    end
    timer = vim.uv.new_timer()
    timer:start(M.TICK_MS, M.TICK_MS, function()
        vim.schedule(function()
            M.sweep()
        end)
    end)
end

---@param req jupyter.EditRequest
---@param cell jupyter.Cell
local function mark_cell(req, cell)
    req.mark = vim.api.nvim_buf_set_extmark(req.buf, M.NS, cell.start_row - 1, 0, {
        end_row = cell.end_row,
        end_col = 0,
        hl_group = "JupyterAgentPending",
        hl_eol = true,
        hl_mode = "combine",
    })
    refresh(req, req.opened_at) -- рамку, знаки и подпись рисует общий путь
end

---@param req jupyter.EditRequest
---@param row integer 1-based строка, после которой появится ячейка
local function mark_insert(req, row)
    req.mark = vim.api.nvim_buf_set_extmark(req.buf, M.NS, row - 1, 0, {})
    refresh(req, req.opened_at)
end

---Снять всё нарисованное и поставить заново: вид заявки сменился, а рисуются виды
---по-разному — у замены рамка вокруг тела и знак на каждой строке, у вставки подпись в
---щели между ячейками. Без этого от прежнего вида остаются знаки на теле ячейки, которую
---агент решил не трогать.
---@param req jupyter.EditRequest
---@param draw fun()
local function remark(req, draw)
    unpad(req) -- опора для подписи ставится заново, если новому виду она вообще нужна
    pcall(vim.api.nvim_buf_del_extmark, req.buf, M.NS, req.mark)
    for _, id in ipairs(req.signs or {}) do
        pcall(vim.api.nvim_buf_del_extmark, req.buf, M.NS_SIGN, id)
    end
    req.signs, req.sign_group, req.sign_from, req.sign_to = {}, nil, nil, nil
    clear_frame(req)
    draw()
end

local function fail(reason, msg)
    return { ok = false, reason = reason, msg = msg }
end

---Ответ про заявку, которой больше нет.
---@param token integer
---@return table
function M.gone(token)
    if expired[token] then
        return fail("expired", "заявка снята по сроку: открой новую и повтори")
    end
    return fail("no_request", "нет заявки " .. tostring(token))
end

---Открыть заявку на правку.
---
---@param buf integer
---Заявку открывает не только агент. Когда промпт уходит из nvim, её открывает сам плагин
---(`pending = true`): метка появляется в ту секунду, когда нажата клавиша, а не тогда,
---когда на той стороне дочитали промпт. Разница в этом и есть — заявка, открытая агентом
---за миг до записи, формально честна, но человеку не сообщает ничего.
---@param opts table cell — заменить тело этой ячейки; after — вставить после неё;
---at_end — вставить в конец документа; label — чьё имя показывать в буфере;
---title — что делается, первой строкой метки; pending — заявку открыл плагин, вид правки
---определит `adopt`
---@return table результат: ok, token, cell_id, start_row, end_row, sha
function M.begin(buf, opts)
    opts = opts or {}
    if not vim.api.nvim_buf_is_valid(buf) then
        return fail("no_buffer", "буфера нет")
    end

    last_token = last_token + 1
    local now = vim.uv.now()
    local req = {
        token = last_token,
        buf = buf,
        label = opts.label or (opts.pending and M.LABEL_SENT or M.LABEL),
        title = title_of(opts.title),
        opened_at = now,
        touched_at = now,
        ttl_ms = tonumber(opts.ttl_ms) or M.TTL_MS,
    }

    if opts.cell then
        local cell = cellid.find(buf, opts.cell)
        if not cell then
            return fail("no_cell", "нет ячейки " .. tostring(opts.cell))
        end
        req.kind, req.cell_id, req.by_id = opts.pending and "pending" or "replace", opts.cell, true
        -- у заявки плагина тела ещё никто не читал: sha возьмёт `adopt`, когда агент
        -- скажет, что берётся. Взятый сейчас, он описывал бы документ до того, как агент
        -- вообще увидел ячейку, и первая же правка отклонилась бы по нашей собственной вине
        req.sha = req.kind == "replace" and sha_of(buf, cell) or nil
        -- сколько строк ячейка занимает сверх тела: у фенса это закрывающий ```,
        -- у percent-представления — ноль. Представление документа по ходу не меняется
        req.fence = cell.span_end - cell.end_row
        mark_cell(req, cell)
        requests[req.token] = req
        ensure_timer()
        return {
            ok = true,
            token = req.token,
            kind = req.kind,
            cell_id = req.cell_id,
            start_row = cell.start_row,
            end_row = cell.end_row,
            sha = req.sha,
            ttl_ms = req.ttl_ms,
        }
    end

    local row
    if opts.after then
        local cell = cellid.find(buf, opts.after)
        if not cell then
            return fail("no_cell", "нет ячейки " .. tostring(opts.after))
        end
        req.cell_id, req.by_id = opts.after, true
        row = cell.span_end
    else
        row = vim.api.nvim_buf_line_count(buf) -- в конец документа
    end

    req.kind = "insert"
    mark_insert(req, row)
    requests[req.token] = req
    ensure_timer()
    return {
        ok = true,
        token = req.token,
        kind = req.kind,
        after = req.cell_id,
        at_row = row,
        ttl_ms = req.ttl_ms,
    }
end

---Взять заявку, которую открыл плагин.
---
---Смысл в том, чтобы метка на ячейке была одна. Промпт уходит из nvim с уже открытой
---заявкой и её номером в шапке; агент не открывает свою, а говорит «беру эту» — и заодно
---говорит, что собирается делать: переписать ячейку или дописать новую после неё. До этого
---момента вид правки не известен никому, потому что он в тексте промпта.
---
---Здесь же берётся sha: отсчёт «ячейку не трогали» начинается с той секунды, когда агент
---её увидел, а не с отправки промпта — иначе правка отклонялась бы из-за того, что человек
---дописал строку, пока агент ещё не начал.
---@param token integer
---@param opts? table label — имя агента; title — что делается, если он назовёт точнее;
---after — не переписывать ячейку, а вставить новую после неё
---@return table
function M.adopt(token, opts)
    opts = opts or {}
    local req = requests[token]
    if not req then
        return M.gone(token)
    end
    if not vim.api.nvim_buf_is_valid(req.buf) then
        requests[token] = nil
        return fail("no_buffer", "буфер закрыт")
    end

    local cell = req.cell_id and cellid.find(req.buf, req.cell_id) or nil
    if not cell then
        forget(req)
        return fail("cell_gone", "ячейка исчезла из документа")
    end

    if opts.label then
        req.label = opts.label
    elseif req.kind == "pending" then
        req.label = M.LABEL -- имени не назвал, но заявку взял: «отправлено» больше не правда
    end
    if opts.title ~= nil then
        req.title = title_of(opts.title)
    end
    req.touched_at = vim.uv.now()

    if opts.after then
        req.kind, req.sha = "insert", nil
        remark(req, function()
            mark_insert(req, cell.span_end)
        end)
        ensure_timer()
        return {
            ok = true,
            token = token,
            kind = "insert",
            after = req.cell_id,
            at_row = cell.span_end,
            ttl_ms = req.ttl_ms,
        }
    end

    req.kind = "replace"
    req.sha = sha_of(req.buf, cell)
    req.fence = cell.span_end - cell.end_row
    remark(req, function()
        mark_cell(req, cell)
    end)
    ensure_timer()
    return {
        ok = true,
        token = token,
        kind = "replace",
        cell_id = req.cell_id,
        start_row = cell.start_row,
        end_row = cell.end_row,
        sha = req.sha,
        ttl_ms = req.ttl_ms,
    }
end

---Применить правку. Пишется по якорю, а не по номерам строк из заявки.
---@param token integer
---@param lines string[]
---@return table результат: ok, cell_id, start_row, end_row — либо ok = false и reason
function M.apply(token, lines)
    local req = requests[token]
    if not req then
        return M.gone(token)
    end
    if not vim.api.nvim_buf_is_valid(req.buf) then
        requests[token] = nil
        return fail("no_buffer", "буфер закрыт")
    end
    if req.kind == "pending" then
        -- заявку открыл плагин, и он не знает, переписывают ячейку или дописывают новую:
        -- это сказано в промпте. Отказ, а не догадка — догадка молча перепишет код
        return fail("not_adopted", "заявка не взята: позови edit_adopt, он вернёт границы и sha")
    end

    local text = common.flatten(lines or {})
    if #text == 0 then
        return fail("empty", "пустая правка: нечего писать")
    end

    if req.kind == "replace" then
        local cell = locate(req)
        if not cell then
            forget(req)
            return fail("cell_gone", "ячейка исчезла из документа, правка не применена")
        end
        if sha_of(req.buf, cell) ~= req.sha then
            forget(req)
            return fail("changed", "ячейку правили после заявки, правка не применена")
        end

        break_undo(req.buf)
        vim.api.nvim_buf_set_lines(req.buf, cell.start_row - 1, cell.end_row, false, text)
        break_undo(req.buf)
        forget(req)
        flash(req.buf, cell.start_row, cell.start_row + #text - 1)
        return {
            ok = true,
            kind = "replace",
            buf = req.buf,
            cell_id = req.cell_id,
            start_row = cell.start_row,
            end_row = cell.start_row + #text - 1,
        }
    end

    local row = mark_row(req)
    if not row then
        forget(req)
        return fail("anchor_gone", "место вставки исчезло, ячейка не добавлена")
    end

    break_undo(req.buf)
    local body = cells.insert(req.buf, row, "below")
    vim.api.nvim_buf_set_lines(req.buf, body - 1, body, false, text)
    break_undo(req.buf)
    forget(req)
    flash(req.buf, body, body + #text - 1)
    return { ok = true, kind = "insert", buf = req.buf, start_row = body, end_row = body + #text - 1 }
end

---Снять заявку, ничего не записав.
---@param token integer
---@return table
function M.cancel(token)
    local req = requests[token]
    if not req then
        return M.gone(token)
    end
    forget(req)
    return { ok = true, token = token }
end

---Продлить заявку: «я ещё здесь».
---
---Нужна тому, кто думает дольше срока — читает соседние ячейки, ходит в базу, ждёт ответа
---пользователя. Без неё единственный способ не потерять заявку был бы «успеть за ttl», а
---единственный способ его пережить — задрать срок всем, то есть оставлять мёртвые метки
---висеть дольше.
---@param token integer
---@return table
function M.touch(token)
    local req = requests[token]
    if not req then
        return M.gone(token)
    end
    local now = vim.uv.now()
    req.touched_at = now
    refresh(req, now)
    return { ok = true, token = token, ttl_ms = req.ttl_ms, age_ms = now - req.opened_at }
end

---Тик жизни заявок: обновить возраст в метках, снять те, о ком давно нет вестей.
---
---Снятие — не уборка мусора, а честность метки: пока она висит, пользователь считает
---ячейку занятой и в неё не лезет. Агент, который упал, упёрся в лимит или ушёл
---спрашивать и не вернулся, никакого `cancel` уже не пришлёт.
---@param now? integer подменяется в тестах
function M.sweep(now)
    now = now or vim.uv.now()
    for token, req in pairs(requests) do
        if not vim.api.nvim_buf_is_valid(req.buf) then
            requests[token] = nil
        elseif now - req.touched_at >= req.ttl_ms then
            local label, ttl = req.label, req.ttl_ms
            forget(req)
            expired[token] = true
            vim.notify(
                ("jupyter.nvim: заявка «%s» снята — %s без вестей"):format(label, fmt_age(ttl)),
                vim.log.levels.WARN
            )
        elseif #vim.fn.win_findbuf(req.buf) > 0 then
            -- буфер не на экране — перерисовывать нечего: колесо крутится для глаза, и
            -- четыре раза в секунду трогать скрытый документ незачем. Срок при этом
            -- проверяется всегда: заявка не должна пережить агента только потому, что
            -- пользователь ушёл в другую вкладку.
            refresh(req, now)
        end
    end
    stop_timer()
end

---Переставить подписи заново — поверх того, что нарисовано только что.
---
---Зовётся после перерисовки статусов ячеек. Виртуальные строки, сидящие на одной строке
---буфера, рисуются в порядке своих extmark'ов, а статусы пересоздаются на каждое нажатие
---клавиши: без этого вызова подпись агента один раз уезжала выше статуса и оставалась там
---до конца заявки. Приоритет здесь не помогает — это проверено.
---@param buf integer
function M.reanchor(buf)
    local now = vim.uv.now()
    for _, req in pairs(requests) do
        if req.buf == buf and vim.api.nvim_buf_is_valid(buf) then
            clear_frame(req)
            refresh(req, now)
        end
    end
end

---Заявка, которая прямо сейчас держит эту ячейку под правку.
---
---Нужна запуску: пока агент переписывает тело, выполнять прежнее бессмысленно — вывод
---окажется от кода, которого через секунду не будет, и ляжет в историю как настоящий.
---Вставка (`insert`) ничего не держит: ячейки, о которой речь, ещё нет.
---@param buf integer
---@param cell_id string|nil
---@return jupyter.EditRequest|nil
function M.claim_of(buf, cell_id)
    if not cell_id then
        return nil
    end
    for _, req in pairs(requests) do
        -- не только "replace": заявка плагина ещё не знает, чем станет, но ячейку уже
        -- держит — запускать код, который через секунду перепишут, незачем
        if req.buf == buf and req.kind ~= "insert" and req.cell_id == cell_id then
            return req
        end
    end
    return nil
end

---Открытые заявки: чем они держат документ и с какого места.
---@param buf? integer только по этому буферу
---@return table[]
function M.list(buf)
    local out = {}
    for token, req in pairs(requests) do
        if not vim.api.nvim_buf_is_valid(req.buf) then
            requests[token] = nil
        elseif buf == nil or req.buf == buf then
            local now = vim.uv.now()
            table.insert(out, {
                token = token,
                buf = req.buf,
                kind = req.kind,
                cell_id = req.cell_id,
                label = req.label,
                title = req.title,
                row = mark_row(req),
                age_ms = now - req.opened_at,
                left_ms = req.ttl_ms - (now - req.touched_at),
            })
        end
    end
    table.sort(out, function(a, b)
        return a.token < b.token
    end)
    return out
end

---Снять все заявки буфера. Возвращает, сколько сняла.
---@param buf? integer
---@return integer
function M.cancel_all(buf)
    local dropped = 0
    for _, entry in ipairs(M.list(buf)) do
        M.cancel(entry.token)
        dropped = dropped + 1
    end
    return dropped
end

---Только для тестов: забыть все заявки, не трогая буферы.
function M._reset()
    requests = {}
    expired = {}
    last_token = 0
    stop_timer()
end

return M
