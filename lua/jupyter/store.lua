-- История прогонов с диска (ARCHITECTURE.md §7, §13.1 идеи).
--
-- Сайдкар пишет `.jupyter-out/<ноутбук>/index.jsonl`: по строке на прогон. Здесь эти записи
-- читаются обратно и превращаются в такой же объект прогона, какой рисует drawer. Значит
-- вывод вчерашней ячейки виден сразу при открытии файла, без перезапуска и без ядра вообще.
--
-- Ключ — тот же cell-id, что лежит в тексте документа (cellid.lua). Поэтому история находится
-- и снаружи nvim: `python -m jupyter_nvim.cli <файл> <id>`.

local M = {}

---Смещение локальной зоны от UTC в секундах.
local function utc_offset()
    local now = os.time()
    return os.difftime(now, os.time(os.date("!*t", now)))
end

---ISO-время из индекса (оно в UTC) в локальное «дд.мм чч:мм».
---@param iso string|nil
---@return string|nil
function M.local_time(iso)
    if type(iso) ~= "string" then
        return nil
    end
    local y, mo, d, h, mi = iso:match("^(%d+)-(%d+)-(%d+)T(%d+):(%d+)")
    if not y then
        return nil
    end
    local epoch = os.time({
        year = tonumber(y),
        month = tonumber(mo),
        day = tonumber(d),
        hour = tonumber(h),
        min = tonumber(mi),
        sec = 0,
        isdst = false,
    }) + utc_offset()
    return os.date("%d.%m %H:%M", epoch)
end

---@class jupyter.Store
local Store = {}
Store.__index = Store

---@param opts table notebook (путь к файлу), out_dir
function M.new(opts)
    local notebook = opts.notebook
    return setmetatable({
        notebook = notebook,
        out_dir = opts.out_dir or ".jupyter-out",
        base = notebook and (
            vim.fs.joinpath(
                vim.fn.fnamemodify(notebook, ":h"),
                opts.out_dir or ".jupyter-out",
                vim.fn.fnamemodify(notebook, ":t:r")
            )
        ) or nil,
        history = {},
        loaded = false,
    }, Store)
end

function Store:index_path()
    return self.base and vim.fs.joinpath(self.base, "index.jsonl") or nil
end

---Перечитать индекс. Дешёво: одна строка на прогон.
---@return integer прочитано записей
function Store:load()
    self.history = {}
    self.loaded = true
    local path = self:index_path()
    if not path or vim.fn.filereadable(path) == 0 then
        return 0
    end

    local count = 0
    for _, line in ipairs(vim.fn.readfile(path)) do
        if line:match("%S") then
            local ok, record = pcall(vim.json.decode, line)
            -- обрезанная строка после падения не должна терять остальные
            if ok and type(record) == "table" and record.cell_id then
                self.history[record.cell_id] = self.history[record.cell_id] or {}
                table.insert(self.history[record.cell_id], record)
                count = count + 1
            end
        end
    end
    return count
end

function Store:ensure_loaded()
    if not self.loaded then
        self:load()
    end
end

---@param cell_id string
---@return table[] записи в порядке выполнения
function Store:records_of(cell_id)
    self:ensure_loaded()
    return self.history[cell_id] or {}
end

---@param cell_id string
---@return table|nil
function Store:last_record(cell_id)
    local records = self:records_of(cell_id)
    return records[#records]
end

---Абсолютный путь к файлу вывода: в индексе он относительный (§7).
---@param record table
---@return string|nil
function Store:path_of(record)
    if not record or not record.path or not self.base then
        return nil
    end
    return vim.fs.joinpath(self.base, record.path)
end

---Собрать из записи объект прогона — такой же, какой рисует drawer.
---@param record table
---@return jupyter.Run|nil
function Store:to_run(record)
    if not record then
        return nil
    end
    local path = self:path_of(record)
    local run = {
        cell_id = record.cell_id,
        run_id = record.run_id,
        status = record.status or "ok",
        duration_ms = record.duration_ms,
        lines = {},
        historical = true, -- drawer покажет это в статусе
        record = record,
        code_sha = record.code_sha,
        at = M.local_time(record.started_at),
    }

    if record.kind == "table" then
        run.table = {
            path = path,
            rows = record.rows,
            cols = record.cols,
            schema = record.schema,
        }
        run.lines = { ("[таблица] %s строк × %s колонок"):format(record.rows, record.cols) }
    elseif record.kind == "image" then
        run.image = path
        run.lines = { "[картинка] " .. (path or "") }
    elseif path and vim.fn.filereadable(path) == 1 then
        run.lines = vim.fn.readfile(path)
    elseif record.ename then
        run.lines = { record.ename }
    end

    if record.ename then
        run.error = { code = record.ename }
    end
    return run
end

---Последний прогон ячейки как объект для отрисовки.
---@param cell_id string
---@return jupyter.Run|nil
function Store:last_run(cell_id)
    return self:to_run(self:last_record(cell_id))
end

---Сколько прогонов знаем по всем ячейкам.
---@return integer cells, integer runs
function Store:size()
    self:ensure_loaded()
    local cells_count, runs = 0, 0
    for _, records in pairs(self.history) do
        cells_count = cells_count + 1
        runs = runs + #records
    end
    return cells_count, runs
end

return M
