-- Чтение и запись .ipynb: в буфере markdown, на диске json (ARCHITECTURE.md §7.8).
--
-- Раньше это делал jupytext.nvim, и делал через `<имя>.md` рядом с ноутбуком: конвертил в
-- файл, читал файл, на `:w` писал файл и конвертил его обратно. Этот файл и был вторым
-- источником правды: переживший сессию `.md` читался вместо ноутбука без сверки дат,
-- правки из Jupyter Lab становились невидимы, а `:w` затирал их старым снимком. Здесь
-- jupytext ходит через пайпы — ноутбук → stdout на чтении, stdin → ноутбук на записи, — и
-- на диске нет ничего, кроме самого ноутбука.
--
-- Два правила, без которых этого лучше не делать вовсе:
--   - конвертация не удалась — буфер не пустой: в нём сырой json, filetype json, и `:w`
--     пишет его как есть. Пустой буфер под именем ноутбука — это ноутбук, стёртый первым
--     же `:w`;
--   - запись через временный файл рядом и `rename`: прерванная запись не оставляет
--     полноутбука. Временный файл начинается копией ноутбука, потому что выводы ячеек
--     `--update` берёт из того файла, поверх которого пишет.
--
-- Автокоманды регистрирует ftdetect/jupyter.lua, а не setup(): плагин грузится лениво, а
-- `BufReadCmd` должен стоять до того, как откроется первый ноутбук.

local M = {}

M.FORMAT = "md:markdown"

-- Конвертация — это запуск python, ~140 мс. Таймаут на случай, когда он повис.
M.TIMEOUT = 30000

local function config()
    local mod = package.loaded["jupyter"]
    return type(mod) == "table" and mod.config or {}
end

---Команда jupytext: `opts.jupytext` (строка или список), иначе `jupytext` из PATH.
---@return string[]
function M.command()
    local spec = config().jupytext or "jupytext"
    if type(spec) == "table" then
        return vim.deepcopy(spec)
    end
    return { vim.fn.expand(spec) }
end

---Чем jupytext объясняет отказ: последняя непустая строка stderr, у трейсбека это
---само исключение.
---@param stderr string|nil
---@return string
local function reason(stderr)
    local last
    for line in (stderr or ""):gmatch("[^\n]+") do
        if line:match("%S") then
            last = line
        end
    end
    return last or "jupytext завершился без объяснений"
end

---@param args string[]
---@param stdin string|nil
---@return string|nil stdout
---@return string|nil err
local function jupytext(args, stdin)
    local cmd = vim.list_extend(M.command(), args)
    local ok, result = pcall(function()
        return vim.system(cmd, { text = true, stdin = stdin }):wait(M.TIMEOUT)
    end)
    if not ok then
        -- ENOENT от vim.system: команды нет вовсе
        return nil, ("не запускается %s: %s"):format(cmd[1], tostring(result))
    end
    if result.code ~= 0 then
        return nil, reason(result.stderr)
    end
    return result.stdout, nil
end

local function notify(msg, level)
    -- из BufReadCmd при старте сообщение затёрла бы первая же перерисовка
    vim.schedule(function()
        vim.notify("jupyter.nvim: " .. msg, level)
    end)
end

local function doautocmd(buf, event, path)
    vim.api.nvim_buf_call(buf, function()
        vim.cmd(("doautocmd <nomodeline> %s %s"):format(event, vim.fn.fnameescape(path)))
    end)
end

---Залить строки, не оставив шага в undo: `u` сразу после открытия не должен стирать
---ноутбук. История сбрасывается правкой при `undolevels=-1`, а правка у нас и так есть.
local function fill(buf, lines)
    local levels = vim.bo[buf].undolevels
    vim.bo[buf].undolevels = -1
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.bo[buf].undolevels = levels
end

---@param text string
---@return string[]
local function split(text)
    local lines = vim.split(text, "\n", { plain = true })
    if lines[#lines] == "" then
        table.remove(lines)
    end
    return lines
end

---BufReadCmd: ноутбук с диска в буфер markdown-ом.
---
---`b:jupyter_ipynb` — чем стал буфер: true — markdown от jupytext, false — сырой json,
---конвертация не удалась. По нему filetype-детект и запись решают, что делать дальше.
---@param buf integer
---@param path string абсолютный путь
function M.read(buf, path)
    local lines, converted = {}, true
    if vim.uv.fs_stat(path) then
        local out, err = jupytext({ "--quiet", "--from", "ipynb", "--to", M.FORMAT, "--output", "-", path })
        if out then
            lines = split(out)
        else
            converted = false
            local ok, raw = pcall(vim.fn.readfile, path)
            lines = ok and raw or {}
            if not ok then
                -- даже json не прочитался: пустой буфер под этим именем не должен
                -- уметь записаться поверх ноутбука
                vim.bo[buf].readonly = true
            end
            notify(("%s не открылся как ноутбук, показан как есть: %s"):format(
                vim.fn.fnamemodify(path, ":t"), err
            ), vim.log.levels.ERROR)
        end
    end
    -- файла нет — новый ноутбук: пустой буфер, kernelspec появится при первой записи

    fill(buf, lines)
    vim.bo[buf].fileencoding = "utf-8"
    vim.bo[buf].fileformat = "unix"
    vim.bo[buf].modified = false
    vim.b[buf].jupyter_ipynb = converted

    -- При BufReadCmd nvim сам BufReadPost не шлёт, а на нём висят чужие плагины (линтеры,
    -- возврат курсора) и детект filetype. Filetype всё равно ставим явно: детект может
    -- быть переопределён в конфиге.
    doautocmd(buf, "BufReadPost", path)
    local ft = converted and "markdown" or "json"
    if vim.bo[buf].filetype ~= ft then
        vim.bo[buf].filetype = ft
    end
end

-- Каталоги kernelspec'ов по правилам jupyter_core, без python: он нужен ради одного
-- display_name, и запускать его на запись незачем.
local function kernel_dirs()
    local dirs = {}
    if vim.env.JUPYTER_DATA_DIR then
        table.insert(dirs, vim.env.JUPYTER_DATA_DIR)
    end
    for dir in (vim.env.JUPYTER_PATH or ""):gmatch("[^:]+") do
        table.insert(dirs, dir)
    end
    local home = vim.uv.os_homedir()
    table.insert(dirs, home .. "/Library/Jupyter")
    table.insert(dirs, (vim.env.XDG_DATA_HOME or (home .. "/.local/share")) .. "/jupyter")
    table.insert(dirs, "/usr/local/share/jupyter")
    table.insert(dirs, "/usr/share/jupyter")
    return dirs
end

---kernelspec для нового ноутбука: тот, что в `opts.kernel_name`. Без него Jupyter Lab на
---открытии спрашивает ядро, а jupytext без него пишет `notebook_metadata_filter: -all`.
---@param name string
---@return table
function M.kernelspec(name)
    for _, dir in ipairs(kernel_dirs()) do
        local file = ("%s/kernels/%s/kernel.json"):format(dir, name)
        local ok, spec = pcall(function()
            return vim.json.decode(table.concat(vim.fn.readfile(file), "\n"))
        end)
        if ok and type(spec) == "table" then
            return { name = name, display_name = spec.display_name or name, language = spec.language or "python" }
        end
    end
    return { name = name, display_name = name, language = "python" }
end

local function seed(path)
    local spec = M.kernelspec(config().kernel_name or "python3")
    local text = ('{"cells": [], "metadata": {"kernelspec": %s, "language_info": {"name": %s}}, '
        .. '"nbformat": 4, "nbformat_minor": 5}'):format(vim.json.encode(spec), vim.json.encode(spec.language))
    return vim.fn.writefile({ text }, path) == 0
end

---Пустые строки в конце jupytext превращает в лишнюю пустую markdown-ячейку — каждый раз,
---`--update` тоже. Ноутбук с такой ячейкой в конце не нужен никому, а строку-опору в
---конце буфера держит, например, заявка агента на вставку (`agent.lua`, `pad_eof`).
---@param lines string[]
---@return string[]
function M.trim(lines)
    local last = #lines
    while last > 0 and not lines[last]:match("%S") do
        last = last - 1
    end
    return vim.list_slice(lines, 1, last)
end

---Временный файл рядом с ноутбуком: `rename` атомарен только в пределах одной ФС.
---Расширение `.ipynb` — чтобы jupytext не гадал о формате того, что обновляет.
local function temp_for(target)
    local dir, name = vim.fn.fnamemodify(target, ":h"), vim.fn.fnamemodify(target, ":t:r")
    return ("%s/.%s.jupyter-nvim-%d.ipynb"):format(dir, name, vim.uv.os_getpid())
end

---BufWriteCmd / FileWriteCmd: буфер в ноутбук.
---
---`modified` снимается только после `rename`: не записалось — буфер остаётся изменённым,
---и `:wq` не закроет nvim с потерянной работой.
---@param buf integer
---@param path string абсолютный путь, куда пишем
---@param range? integer[] {first, last}, 1-based, для записи части буфера
---@return boolean
function M.write(buf, path, range)
    -- писать в сам файл, а не на место симлинка: rename заменил бы ссылку файлом
    local target = vim.fn.resolve(path)
    local whole = range == nil
    local event = whole and "BufWrite" or "FileWrite"

    doautocmd(buf, event .. "Pre", path)
    local lines = whole and vim.api.nvim_buf_get_lines(buf, 0, -1, false)
        or vim.api.nvim_buf_get_lines(buf, range[1] - 1, range[2], false)

    local tmp = temp_for(target)
    local ok, err
    if vim.b[buf].jupyter_ipynb == false then
        -- сырой json: конвертация на чтении не удалась, пишем то, что видим
        ok = vim.fn.writefile(lines, tmp) == 0
        err = not ok and "не удалось записать временный файл" or nil
    else
        if vim.uv.fs_stat(target) then
            ok, err = vim.uv.fs_copyfile(target, tmp)
        else
            ok = seed(tmp)
            err = not ok and "не удалось записать временный файл" or nil
        end
        if ok then
            local text = table.concat(M.trim(lines), "\n") .. "\n"
            local _
            _, err = jupytext({ "--quiet", "--from", M.FORMAT, "--to", "ipynb", "--update", "--output", tmp, "-" }, text)
            ok = err == nil
        end
    end

    if ok then
        -- `--update` без изменений файл не трогает, и mtime остался бы от копии. А на
        -- mtime ноутбука черновик решает, доехала ли работа до диска (draft.lua).
        local now = vim.uv.clock_gettime("realtime")
        vim.uv.fs_utime(tmp, now.sec + now.nsec / 1e9, now.sec + now.nsec / 1e9)
        ok, err = vim.uv.fs_rename(tmp, target)
    end
    if not ok then
        vim.uv.fs_unlink(tmp)
        vim.notify(("jupyter.nvim: %s не записан: %s"):format(vim.fn.fnamemodify(path, ":t"), err),
            vim.log.levels.ERROR)
        return false
    end

    if whole and vim.fn.resolve(vim.api.nvim_buf_get_name(buf)) == target then
        vim.bo[buf].modified = false
    end
    doautocmd(buf, event .. "Post", path)
    vim.api.nvim_echo({ { ('"%s" записан'):format(vim.fn.fnamemodify(path, ":~:.")) } }, false, {})
    return true
end

return M
