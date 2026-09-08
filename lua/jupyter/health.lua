-- :checkhealth jupyter
--
-- Проверяем то, что реально ломается у пользователя, а не наличие файлов плагина:
-- тот ли python (у kernelspec бывает относительный argv, и ядро уезжает не туда),
-- отвечает ли сайдкар и той ли версией протокола, есть ли нужный kernelspec.
--
-- Сбор вынесен в collect(): его можно позвать из теста, в отличие от vim.health.

local common = require("jupyter.ui.common")
local images = require("jupyter.images")
local sidecar = require("jupyter.sidecar")

local M = {}

local TIMEOUT = 15000

local function run(cmd, opts)
    local ok, result = pcall(function()
        return vim.system(cmd, vim.tbl_extend("force", { text = true }, opts or {})):wait(TIMEOUT)
    end)
    if not ok then
        return nil, tostring(result)
    end
    return result, nil
end

local function python_of(config)
    return (config and config.python) or vim.g.jupyter_python or "python3"
end

---@return table[] список { level, msg }
---Разобрать JSON от внешней команды.
---
---`luanil` тут не украшение: без него JSON `null` становится `vim.NIL`, а она в Lua
---истинна. Проверка «версия модуля есть» проходила, и в отчёт уезжала зелёная строка
---«polars vim.NIL» вместо предупреждения, что polars не установлен.
---@param text string|nil
---@return table|nil
local function decode(text)
    if type(text) ~= "string" or text == "" then
        return nil
    end
    local ok, value = pcall(vim.json.decode, text, { luanil = { object = true, array = true } })
    if not ok or type(value) ~= "table" then
        return nil
    end
    return value
end

function M.collect(config)
    config = config or require("jupyter").config
    local report = {}
    local function add(level, msg)
        table.insert(report, { level = level, msg = msg })
    end

    -- 1. интерпретатор
    local python = python_of(config)
    local resolved = vim.fn.exepath(python)
    if resolved == "" and vim.fn.filereadable(python) == 0 then
        add("error", ("python не найден: %s. Задай vim.g.jupyter_python или opts.python"):format(python))
        return report
    end
    add("ok", ("python: %s"):format(resolved ~= "" and resolved or python))

    -- 2. библиотеки в нём
    local probe = table.concat({
        "import json,sys",
        "out={'python':sys.version.split()[0]}",
        "for m in ('jupyter_client','polars','ipykernel'):",
        "    try:",
        "        out[m]=__import__(m).__version__",
        "    except Exception as e:",
        "        out[m]=None",
        "print(json.dumps(out))",
    }, "\n")
    local result = run({ python, "-c", probe })
    local versions = (result and result.code == 0 and decode(result.stdout)) or {}
    if not versions.python then
        add("error", "не удалось опросить python: " .. ((result and result.stderr) or "нет ответа"))
        return report
    end
    add("ok", ("версия python: %s"):format(versions.python))
    for _, module in ipairs({ "jupyter_client", "polars", "ipykernel" }) do
        if versions[module] then
            add("ok", ("%s %s"):format(module, versions[module]))
        elseif module == "polars" then
            add("warn", "polars не установлен: таблицы в parquet сохраняться не будут")
        else
            add("error", ("%s не установлен — сайдкар без него не поднимется"):format(module))
        end
    end

    -- 3. сайдкар и версия протокола
    local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":h:h:h")
    local hello = vim.json.encode({ v = sidecar.PROTOCOL_V, id = 1, op = "hello", args = vim.empty_dict() })
    local reply = run({ python, "-m", "jupyter_nvim" }, {
        stdin = hello .. "\n",
        env = { PYTHONPATH = root .. "/sidecar" },
    })
    if not reply or reply.code ~= 0 or not reply.stdout or reply.stdout == "" then
        add("error", "сайдкар не отвечает: " .. ((reply and reply.stderr) or "нет вывода"))
    else
        local message = decode((reply.stdout:gsub("\n.*", "")))
        if not message or not message.data then
            add("error", "сайдкар ответил непонятным: " .. common.clip(reply.stdout, 120))
        elseif message.data.v ~= sidecar.PROTOCOL_V then
            add("error", ("версия протокола: сайдкар %s, плагин %d"):format(
                tostring(message.data.v), sidecar.PROTOCOL_V
            ))
        else
            add("ok", ("сайдкар отвечает, протокол v%d, версия %s"):format(
                message.data.v, message.data.version or "?"
            ))
        end
    end

    -- 4. kernelspec
    local wanted = config.kernel_name or "python3"
    local specs = run({
        python,
        "-c",
        "import json;from jupyter_client.kernelspec import KernelSpecManager;"
            .. "print(json.dumps(sorted(KernelSpecManager().find_kernel_specs())))",
    })
    if specs and specs.code == 0 then
        local names = decode(specs.stdout)
        if names then
            if vim.tbl_contains(names, wanted) then
                add("ok", ("kernelspec %s найден"):format(wanted))
            else
                add("error", ("kernelspec %s не найден. Доступны: %s"):format(wanted, table.concat(names, ", ")))
            end
        end
    else
        add("warn", "не удалось перечислить kernelspec'и")
    end

    -- 5. картинки
    if config.images == false then
        add("ok", "картинки выключены в конфиге")
    elseif images.available() then
        add("ok", "image.nvim на месте")
    else
        add("warn", "image.nvim не найден: картинки будут показаны путём к файлу")
    end

    -- 6. осиротевшие ядра. Сюда попадают только те, чей сайдкар умер не своей смертью:
    -- при обычном выходе ядро гасится, а след убирается (см. jupyter.orphans).
    local orphans = require("jupyter.orphans")
    local dir = vim.fn.expand("%:p:h")
    local found = dir ~= "" and orphans.scan(dir, config.out_dir) or {}
    if #found == 0 then
        add("ok", "осиротевших ядер нет")
    end
    for _, orphan in ipairs(found) do
        add(orphan.stale and "warn" or "error", orphans.describe(orphan) .. " — снять: :JupyterOrphans!")
    end

    return report
end

function M.check()
    vim.health.start("jupyter.nvim")
    for _, entry in ipairs(M.collect()) do
        if entry.level == "ok" then
            vim.health.ok(entry.msg)
        elseif entry.level == "warn" then
            vim.health.warn(entry.msg)
        else
            vim.health.error(entry.msg)
        end
    end
end

return M
