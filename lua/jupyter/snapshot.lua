-- Снимок ноутбука одной структурой: ячейки, их id и последний прогон каждой.
--
-- Нужен внешнему читателю — скрипту или агенту, который работает с ноутбуком через
-- `--remote-expr`. Без него читатель складывает ответ сам: разбирает фенсы, чтобы найти
-- границы ячеек, вынимает `jncell` из info-строки, считает путь к `.jupyter-out`, читает
-- индекс и сверяет sha, чтобы понять, относится ли вывод к нынешнему коду. Это вторая
-- копия правил плагина, и она разойдётся с первой на первом же краевом случае — фенс
-- внутри строки, percent-представление, ячейка без маркера.
--
-- Граница: здесь ничего не вычисляется заново и ничего не пишется в документ. Только
-- сборка того, что плагин уже знает, поэтому снимок — производное представление, а не
-- новый источник истины. Источники прежние: буфер (текст) и `index.jsonl` (выводы).

local cells = require("jupyter.cells")
local exec = require("jupyter.exec")

local M = {}

---Вывод получен не из того кода, что сейчас в ячейке.
---
---sha считается так же, как в `Exec:run` — первые 8 символов sha256 тела, — иначе снимок
---отвечал бы на вопрос «устарел ли вывод» иначе, чем помета `⚠ код изменился` в drawer'е.
---@param buf integer
---@param cell jupyter.Cell
---@param record table|nil
---@return boolean
local function is_stale(buf, cell, record)
    if not record or type(record.code_sha) ~= "string" then
        return false
    end
    return vim.fn.sha256(cells.text(buf, cell)):sub(1, 8) ~= record.code_sha
end

---Последний прогон ячейки в виде, пригодном для чтения снаружи.
---
---Путь абсолютный: в индексе он относительный (§7), а читатель снимка не обязан знать,
---относительно чего именно.
---@param store jupyter.Store|nil
---@param record table|nil
---@return table|nil
local function last_run(store, record)
    if not record then
        return nil
    end
    return {
        run_id = record.run_id,
        status = record.status,
        kind = record.kind,
        path = store and store:path_of(record) or nil,
        rows = record.rows,
        cols = record.cols,
        schema = record.schema,
        ename = record.ename,
        duration_ms = record.duration_ms,
        execution_count = record.execution_count,
        started_at = record.started_at,
    }
end

---@param buf integer
---@param opts? table store: jupyter.Store, kernel: jupyter.Kernel, exec: jupyter.Exec
---@return table
function M.build(buf, opts)
    opts = opts or {}
    local store = opts.store
    if store then
        store:load() -- индекс мог дописаться после последнего прогона
    end

    local list = {}
    for _, cell in ipairs(cells.list(buf)) do
        local id = exec.cell_id(buf, cell) -- только чтение: в документ ничего не пишем
        local record = store and store:last_record(id) or nil
        local live = opts.exec and opts.exec:run_for(id) or nil
        -- через if, а не через `and ... or nil`: у свежего вывода ответ — false, и в
        -- тернарнике он превратился бы в nil, то есть «свежий» стало бы неотличимо от
        -- «истории нет»
        local stale, running = nil, nil
        if record then
            stale = is_stale(buf, cell, record)
        end
        if live then
            running = live.status ~= "ok" and live.status ~= "error"
        end
        table.insert(list, {
            index = cell.index,
            id = id,
            lang = cells.lang_of(buf, cell),
            start_row = cell.start_row,
            end_row = cell.end_row,
            span_start = cell.span_start,
            span_end = cell.span_end,
            runs = store and #store:records_of(id) or 0,
            -- прогон идёт прямо сейчас: вывод на диске ещё от прошлого раза, и читатель,
            -- не знающий об этом, объявил бы его свежим
            running = running,
            last = last_run(store, record),
            stale = stale,
        })
    end

    local name = vim.api.nvim_buf_get_name(buf)
    local info = opts.kernel and opts.kernel:info() or nil
    return {
        notebook = name ~= "" and name or nil,
        buf = buf,
        representation = cells.representation(buf),
        modified = vim.bo[buf].modified,
        lines = vim.api.nvim_buf_line_count(buf),
        out_dir = store and store.base or nil,
        kernel = opts.kernel and {
            state = opts.kernel:state(),
            queued = opts.kernel:queued(),
            kernel_name = info and info.kernel_name or nil,
            connection_file = info and info.connection_file or nil,
            attached = info and info.attached or nil,
        } or nil,
        cells = list,
    }
end

return M
