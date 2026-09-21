-- Откуда берётся интерпретатор сайдкара.
--
-- Один конфиг nvim живёт на нескольких машинах, и путь к окружению на них разный.
-- Поэтому `opts.python` — не обязательно строка: это может быть список кандидатов
-- (берётся первый существующий) или функция от контекста ноутбука. А если явно не задано
-- ничего, интерпретатор ищется сам: активный `$VIRTUAL_ENV`, затем `.venv` вверх по
-- дереву от каталога ноутбука, затем `python3` из PATH.
--
-- Явно заданное — строгое: сказали «этот python», его нет — это ошибка, а не повод молча
-- взять другой. Иначе неверный путь в конфиге маскировался бы случайным окружением,
-- где нет polars, и результат-датафрейм тихо не собирался бы (CONTRIBUTING, §6.3).
--
-- Модуль ничего не запускает и не знает о сайдкаре: только пути.

local M = {}

---@class jupyter.PythonCtx
---@field buf integer буфер ноутбука
---@field dir string каталог ноутбука, для безымянного буфера — cwd
---@field venv string|nil python ближайшего окружения: $VIRTUAL_ENV, иначе .venv вверх от dir

---@alias jupyter.PythonSpec string|string[]|fun(ctx: jupyter.PythonCtx): string|string[]|nil

-- Где внутри окружения лежит интерпретатор. На Windows nvim тоже бывает.
local BIN = { "bin/python", "Scripts/python.exe" }

---@param root string каталог окружения
---@return string|nil
local function venv_python(root)
    for _, rel in ipairs(BIN) do
        local candidate = root .. "/" .. rel
        if vim.fn.executable(candidate) == 1 then
            return candidate
        end
    end
    return nil
end

---Ближайшее окружение: активный $VIRTUAL_ENV, иначе .venv или venv вверх по дереву.
---@param dir string откуда подниматься
---@return string|nil python
---@return string|nil source откуда взят
function M.find_venv(dir)
    local active = vim.env.VIRTUAL_ENV
    if active and active ~= "" then
        local found = venv_python(active)
        if found then
            return found, "$VIRTUAL_ENV"
        end
    end
    local current = vim.fn.fnamemodify(dir, ":p"):gsub("/$", "")
    while current ~= "" do
        for _, name in ipairs({ ".venv", "venv" }) do
            local found = venv_python(current .. "/" .. name)
            if found then
                return found, name .. " в " .. current
            end
        end
        local parent = vim.fn.fnamemodify(current, ":h")
        if parent == current then
            break
        end
        current = parent
    end
    return nil, nil
end

---Контекст для выбора интерпретатора: каталог ноутбука и ближайшее окружение.
---@param buf? integer
---@return jupyter.PythonCtx
function M.context(buf)
    buf = buf or vim.api.nvim_get_current_buf()
    local name = vim.api.nvim_buf_get_name(buf)
    local dir = name ~= "" and vim.fn.fnamemodify(name, ":p:h") or vim.fn.getcwd()
    return { buf = buf, dir = dir, venv = (M.find_venv(dir)) }
end

---Привести spec к списку кандидатов. nil — «не задано».
---@param spec jupyter.PythonSpec|nil
---@param ctx jupyter.PythonCtx
---@return string[]|nil
local function candidates(spec, ctx)
    if type(spec) == "function" then
        spec = spec(ctx)
    end
    if spec == nil or spec == "" then
        return nil
    end
    if type(spec) == "string" then
        return { spec }
    end
    -- не ipairs: список из функции вида { ctx.venv, "~/.venvs/x/bin/python" } начинается
    -- с nil, когда окружения рядом нет, и ipairs остановился бы на первом же элементе
    local list = {}
    for i = 1, table.maxn(spec) do
        local item = spec[i]
        if type(item) == "string" and item ~= "" then
            table.insert(list, item)
        end
    end
    return #list > 0 and list or nil
end

---Первый существующий из списка. Имя без слэшей ищется в PATH, путь — как есть.
---@param list string[]
---@return string|nil found
---@return string[] tried раскрытые пути, для сообщения об ошибке
local function first_executable(list)
    local tried = {}
    for _, item in ipairs(list) do
        local path = vim.fn.expand(item)
        table.insert(tried, path)
        if vim.fn.executable(path) == 1 then
            return path, tried
        end
    end
    return nil, tried
end

---Выбрать интерпретатор.
---
---Порядок: `spec` (обычно opts.python) → `vim.g.jupyter_python` → `$JUPYTER_NVIM_PYTHON`
---→ автопоиск. Первый заданный уровень решает: если в нём ни одного существующего пути,
---дальше не идём и возвращаем nil.
---@param spec jupyter.PythonSpec|nil
---@param ctx? jupyter.PythonCtx
---@return string|nil python найденный путь
---@return string source откуда взят, для журнала и :checkhealth
---@return string[] tried что проверяли
function M.resolve(spec, ctx)
    ctx = ctx or M.context()
    local explicit = {
        { "opts.python", spec },
        { "vim.g.jupyter_python", vim.g.jupyter_python },
        { "$JUPYTER_NVIM_PYTHON", vim.env.JUPYTER_NVIM_PYTHON },
    }
    for _, level in ipairs(explicit) do
        local list = candidates(level[2], ctx)
        if list then
            local found, tried = first_executable(list)
            return found, level[1], tried
        end
    end

    -- автопоиск: окружение рядом с ноутбуком, иначе PATH
    local venv, venv_source = M.find_venv(ctx.dir)
    if venv then
        return venv, venv_source, { venv }
    end
    local found, tried = first_executable({ "python3", "python" })
    return found, "PATH", tried
end

return M
