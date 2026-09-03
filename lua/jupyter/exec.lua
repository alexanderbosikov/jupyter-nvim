-- Запуск ячеек и накопление их вывода.
--
-- Здесь живут два решения из ARCHITECTURE.md:
--
--   §4.4 — отбраковка по run_id. Событие с чужим run_id к текущему прогону не применяется:
--          так вывод повторного запуска не смешивается с выводом предыдущего;
--   §7.1 — result_expr, то есть ЧТО сериализовать в parquet, решает Lua, потому что только
--          она разбирает магику. nb_utils кладёт результат в user_ns[df_name] либо в df_temp
--          (nb_utils/jupyter/magics.py): "%%sql df_name=orders limit=0" -> orders.
--
-- Нюанс про replace_last: stdout и stderr на стороне сайдкара — отдельные потоки со своей
-- нумерацией строк, а показываем мы их в одном списке. Поэтому запоминаем, какая строка
-- списка была последней для каждого потока: иначе "\r" в stdout перерисует строку stderr.

local cellid = require("jupyter.cellid")
local cells = require("jupyter.cells")

local M = {}

---@class jupyter.Run
---@field cell_id string
---@field run_id integer
---@field lines string[] вывод, как он показывается
---@field status "running"|"ok"|"error"|"aborted"
---@field error table|nil
---@field table table|nil результат-датафрейм: path, rows, cols, schema
---@field duration_ms integer|nil

---@class jupyter.Exec
local Exec = {}
Exec.__index = Exec

---Выражение, которое сайдкар передаст ядру для сериализации результата.
---@param code string
---@return string
function M.result_expr(code)
    local first = code:match("^[^\n]*") or ""
    local args = first:match("^%%%%sql%s*(.*)$")
    if args then
        return args:match("df_name=(%S+)") or "df_temp"
    end
    return "_"
end

---@param opts table kernel, on_update
function M.new(opts)
    return setmetatable({
        kernel = opts.kernel,
        on_update = opts.on_update,
        runs = {}, -- cell_id -> jupyter.Run (текущий прогон ячейки)
        _next_run = 0,
        _stream_tail = {}, -- cell_id -> { [stream] = индекс последней строки }
    }, Exec)
end

---Подписаться на события сайдкара. Зовётся один раз после создания.
function Exec:attach()
    self.kernel.sidecar:on("*", function(msg)
        self:on_event(msg)
    end)
    return self
end

-- --- запуск ---

---Запасной идентификатор — номер ячейки в буфере. Нужен там, где стабильный id записать
---некуда: ячейка без маркера (код до первого `# %%` или файл вообще без маркеров).
---Формат hex, потому что сайдкар проверяет cell_id регуляркой перед записью на диск.
---@param cell jupyter.Cell
---@return string
function M.fallback_id(cell)
    return ("%04x"):format(cell.index)
end

---Идентификатор ячейки только для чтения: в документ ничего не пишется.
---@param buf integer
---@param cell jupyter.Cell
---@return string
function M.cell_id(buf, cell)
    return cellid.of(buf, cell) or M.fallback_id(cell)
end

---@param buf integer
---@param cell jupyter.Cell
---@return jupyter.Run|nil
function Exec:run(buf, cell)
    local code = cells.text(buf, cell)
    if not code:match("%S") then
        return nil -- пустая ячейка: ядру отправлять нечего
    end

    -- Единственный момент, когда плагин правит документ: стабильный id дописывается
    -- к маркеру ячейки при первом запуске (§4.6). Id детерминирован от содержимого,
    -- поэтому даже несохранённый буфер получит тот же id и не потеряет историю.
    local cell_id = cellid.ensure(buf, cell) or M.fallback_id(cell)
    self._next_run = self._next_run + 1
    local run = {
        cell_id = cell_id,
        run_id = self._next_run,
        lines = {},
        status = "running",
    }
    self.runs[cell_id] = run
    self._stream_tail[cell_id] = {}

    self.kernel:execute({
        cell_id = cell_id,
        run_id = run.run_id,
        code = code,
        result_expr = M.result_expr(code),
    }, function(err)
        if err then
            run.status = "error"
            run.error = err
            table.insert(run.lines, ("[%s] %s"):format(err.code or "ошибка", err.msg or ""))
            self:_updated(run)
        end
    end)

    self:_updated(run, true)
    return run
end

---Запустить ячейку под курсором.
---@return jupyter.Run|nil
function Exec:run_at(buf, row)
    local cell = cells.at(buf, row)
    return cell and self:run(buf, cell)
end

---Запустить все ячейки буфера; from_row — только начиная с ячейки под этой строкой.
---@return jupyter.Run[]
function Exec:run_all(buf, from_row)
    local started = {}
    local from = from_row and cells.at(buf, from_row)
    for _, cell in ipairs(cells.list(buf)) do
        if not from or cell.index >= from.index then
            local run = self:run(buf, cell)
            if run then table.insert(started, run) end
        end
    end
    return started
end

-- --- приём событий ---

function Exec:on_event(msg)
    local cell_id = msg.cell_id
    if not cell_id then
        return
    end
    local run = self.runs[cell_id]
    if not run then
        return
    end
    -- §4.4: событие устаревшего прогона к текущему не применяется
    if msg.run_id ~= run.run_id then
        return
    end

    local data = msg.data or {}
    if msg.ev == "stream" then
        self:_apply_ops(run, data.name or "stdout", data.ops or {})
    elseif msg.ev == "result" or msg.ev == "display" then
        self:_apply_result(run, data)
    elseif msg.ev == "exec.error" then
        run.error = { code = data.ename, msg = data.evalue }
        -- элемент трейсбека IPython может сам содержать несколько строк
        vim.list_extend(run.lines, require("jupyter.ui.common").flatten(data.traceback))
    elseif msg.ev == "exec.done" then
        run.status = data.status or "ok"
        run.duration_ms = data.duration_ms
    elseif msg.ev == "clear_output" then
        run.lines = {}
        self._stream_tail[cell_id] = {}
    else
        return
    end
    self:_updated(run)
end

function Exec:_apply_ops(run, stream, ops)
    local tail = self._stream_tail[run.cell_id] or {}
    self._stream_tail[run.cell_id] = tail
    for _, op in ipairs(ops) do
        if op.op == "replace_last" and tail[stream] then
            run.lines[tail[stream]] = op.text
        else
            table.insert(run.lines, op.text)
            tail[stream] = #run.lines
        end
    end
end

function Exec:_apply_result(run, data)
    if data.kind == "table" then
        run.table = data
        table.insert(run.lines, ("[таблица] %s строк × %s колонок"):format(data.rows, data.cols))
    elseif data.kind == "image" then
        run.image = data.path
        table.insert(run.lines, "[картинка] " .. (data.path or ""))
    elseif data.kind == "html" then
        table.insert(run.lines, "[html] " .. (data.path or ""))
    elseif data.text then
        vim.list_extend(run.lines, vim.split(data.text, "\n", { plain = true }))
    end
end

---Строки прогона в виде, готовом для буфера.
---@param run jupyter.Run
---@return string[]
function M.lines_of(run)
    return require("jupyter.ui.common").flatten(run.lines)
end

---@param run jupyter.Run
---@param is_new boolean|nil прогон только что начат, а не обновлён
function Exec:_updated(run, is_new)
    if self.on_update then
        self.on_update(run, is_new == true)
    end
end

---@return jupyter.Run|nil
function Exec:run_for(cell_id)
    return self.runs[cell_id]
end

return M
