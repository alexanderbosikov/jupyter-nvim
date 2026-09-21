-- :checkhealth jupyter
--
-- Проверяем то, что реально ломается у пользователя, а не наличие файлов плагина:
-- тот ли python (у kernelspec бывает относительный argv, и ядро уезжает не туда),
-- отвечает ли сайдкар и той ли версией протокола, есть ли нужный kernelspec.
--
-- Сбор вынесен в collect(): его можно позвать из теста, в отличие от vim.health.

local common = require("jupyter.ui.common")
local images = require("jupyter.images")
local python_mod = require("jupyter.python")
local sidecar = require("jupyter.sidecar")

local M = {}

local TIMEOUT = 15000

local UNITS = { { 1024 ^ 3, "ГБ" }, { 1024 ^ 2, "МБ" } }

local function human(bytes)
    for _, unit in ipairs(UNITS) do
        if bytes >= unit[1] then
            return ("%.1f %s"):format(bytes / unit[1], unit[2])
        end
    end
    return ("%d КБ"):format(math.ceil(bytes / 1024))
end

---Похоже ли, что id порядковый — тот, что выдаёт exec.fallback_id ("%04x" от номера ячейки).
---
---Отличать их от настоящих сирот важно: настоящая сирота означает, что из документа
---исчезла ячейка с результатами, а порядковый id в документ не пишется НИКОГДА, так что
---его история осиротевшая с рождения и ни о какой потере не говорит. В индексе пометки
---нет, поэтому различаем по форме — отсюда осторожное «похоже»: sha-префикс тоже бывает
---вида 00xx. Ставить пометку в индекс (сайдкар) стоило бы, тогда угадывать не придётся.
local function looks_ordinal(cell_id)
    return cell_id:match("^00%x%x$") ~= nil
end

local function run(cmd, opts)
    local ok, result = pcall(function()
        return vim.system(cmd, vim.tbl_extend("force", { text = true }, opts or {})):wait(TIMEOUT)
    end)
    if not ok then
        return nil, tostring(result)
    end
    return result, nil
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

    -- 1. интерпретатор — теми же правилами, что и сессия, и с указанием источника:
    -- когда python «не тот», первый вопрос — откуда он взялся
    local ctx = python_mod.context()
    local python, source, tried = python_mod.resolve(config.python, ctx)
    if not python then
        add("error", ("python не найден (%s): %s. Задай opts.python — строку, список кандидатов или функцию")
            :format(source, table.concat(tried, ", ")))
        return report
    end
    add("ok", ("python: %s (%s)"):format(python, source))

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

    -- 4. kernelspec: не только есть ли, но и какой интерпретатор он запускает.
    -- Абсолютный argv на чужой python — самый частый способ получить ядро без polars (§6.3);
    -- относительный безопасен: сайдкар кладёт свой каталог первым в PATH ядра
    local wanted = config.kernel_name or "python3"
    if type(wanted) == "function" then
        wanted = wanted(ctx)
    end
    local spec_probe = table.concat({
        "import json,os,sys",
        "from jupyter_client.kernelspec import KernelSpecManager, NoSuchKernel",
        "ksm=KernelSpecManager()",
        "out={'names':sorted(ksm.find_kernel_specs())}",
        "try:",
        "    spec=ksm.get_kernel_spec(sys.argv[1])",
        "    argv0=spec.argv[0] if spec.argv else ''",
        "    out['dir']=spec.resource_dir",
        "    out['argv0']=argv0",
        "    out['relative']=not os.path.isabs(argv0)",
        "    out['same']=out['relative'] or os.path.realpath(argv0)==os.path.realpath(sys.executable)",
        "except NoSuchKernel:",
        "    pass",
        "print(json.dumps(out))",
    }, "\n")
    local specs = run({ python, "-c", spec_probe, wanted })
    local info
    if specs and specs.code == 0 then
        -- decode(), а не vim.json.decode: там уже стоит luanil, без которого JSON null
        -- стал бы vim.NIL и прошёл проверку «поле задано»
        local parsed = decode(specs.stdout)
        if type(parsed) == "table" and type(parsed.names) == "table" then
            info = parsed
        end
    end
    if not info then
        add("warn", "не удалось перечислить kernelspec'и")
    elseif not info.dir then
        add("error", ("kernelspec %s не найден. Доступны: %s"):format(wanted, table.concat(info.names, ", ")))
    else
        add("ok", ("kernelspec %s найден: %s"):format(wanted, info.dir))
        if info.same == false then
            add("warn", ("kernelspec %s запускает другой интерпретатор: %s. Ядро и сайдкар должны быть "
                .. "из одного окружения, иначе в ядре не будет polars и результат-датафрейм не соберётся")
                :format(wanted, info.argv0))
        elseif info.relative then
            add("ok", ("argv kernelspec относительный (%s): ядро возьмётся из окружения сайдкара"):format(info.argv0))
        else
            add("ok", "kernelspec запускает тот же интерпретатор, что и сайдкар")
        end
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

    -- 7. история прогонов: её вес и ячейки, которых в документе больше нет
    vim.list_extend(report, M.history(config))

    return report
end

---Отчёт про историю прогонов текущего буфера.
---
---Зачем в checkhealth: осиротевшую историю не подчистит никто. `prune` оставляет последние
---`history_limit` прогонов, но зовётся только по той ячейке, которую прогнали, — а под
---исчезнувшим id уже ничего не запускается. Сам отчёт ничего не удаляет: он показывает
---цену вопроса, чтобы решение про уборку принималось по числам, а не на глаз.
---@param config? table
---@param buf? integer
---@return table[] список { level, msg }
function M.history(config, buf)
    config = config or require("jupyter").config
    buf = buf or vim.api.nvim_get_current_buf()
    local report = {}
    local function add(level, msg)
        table.insert(report, { level = level, msg = msg })
    end

    local notebook = vim.api.nvim_buf_get_name(buf)
    if notebook == "" then
        return report
    end
    -- Черновики раньше истории: у ноутбука, который ни разу не прогоняли, индекса нет,
    -- а несохранённая работа в нём быть вполне может — и сказать о ней важнее.
    local draft = require("jupyter.draft")
    local left = draft.new({ notebook = notebook, out_dir = config.out_dir }):candidates()
    if #left > 0 then
        local bytes = 0
        for _, found in ipairs(left) do
            bytes = bytes + math.max(vim.fn.getfsize(found.path), 0)
        end
        add("warn", ("%d черновиков от прошлых сессий (%s): %s — :JupyterRecover"):format(
            #left, human(bytes), draft.describe(left[1])
        ))
    end

    local store = require("jupyter.store").new({ notebook = notebook, out_dir = config.out_dir })
    local index = store:index_path()
    if not index or vim.fn.filereadable(index) == 0 then
        return report -- истории ещё нет, говорить не о чем
    end
    store:load()

    local cells_count, runs = store:size()

    -- Живые id читаем из текста документа, а не из списка ячеек: id лежит на строке
    -- маркера, и этого достаточно — ячейка, которую ни разу не прогоняли, id не имеет.
    -- Но сперва убеждаемся, что в буфере вообще видны ячейки: в НЕ конвертированном
    -- .ipynb (сырой json, без jupytext) id лежит json-полем `"jncell": "a3f9"`, форму
    -- `jncell="a3f9"` там не найти, и отчёт объявил бы осиротевшей всю историю сразу.
    local shape = require("jupyter.cells").explain(buf)
    if shape.markers == 0 and shape.fences == 0 then
        add("ok", ("история: %d ячеек, %d прогонов в %s"):format(
            cells_count, runs, vim.fn.fnamemodify(store.base, ":~:.")
        ))
        add("info", "ячеек в этом буфере не видно — какие id ещё живые, отсюда не проверить")
        return report
    end
    local live = require("jupyter.cellid").used(buf)

    local total, referenced = 0, {}
    local orphan = { count = 0, bytes = 0, ids = {} }
    local ordinal = { count = 0, bytes = 0 }
    for _, cell_id in ipairs(store:cell_ids()) do
        local bytes = 0
        for _, record in ipairs(store:records_of(cell_id)) do
            local path = store:path_of(record)
            local size = path and vim.fn.getfsize(path) or -1
            if size > 0 then
                bytes = bytes + size
                referenced[vim.fs.normalize(path)] = true
            end
        end
        total = total + bytes
        if not live[cell_id] then
            local bucket = looks_ordinal(cell_id) and ordinal or orphan
            bucket.count, bucket.bytes = bucket.count + 1, bucket.bytes + bytes
            if bucket.ids then
                table.insert(bucket.ids, cell_id)
            end
        end
    end

    add("ok", ("история: %d ячеек, %d прогонов, %s в %s"):format(
        cells_count, runs, human(total), vim.fn.fnamemodify(store.base, ":~:.")
    ))

    if orphan.count > 0 then
        add("warn", ("%d ячеек с историей нет в документе (%s): %s. Под исчезнувшим id "):format(
            orphan.count, human(orphan.bytes), table.concat(orphan.ids, " ")
        ) .. "чистка не работает — prune идёт только по прогнанной ячейке; уборка вся сразу: снести каталог")
    else
        add("ok", "все ячейки с историей есть в документе")
    end

    if ordinal.count > 0 then
        add("info", ("%d ячеек под порядковым id (%s): такой id в документ не пишется, "):format(
            ordinal.count, human(ordinal.bytes)
        ) .. "поэтому его история осиротевшая с рождения — это не потеря ячейки, а мусор")
    end

    -- файлы, на которые индекс не ссылается: обычно остатки прерванной записи. Смотрим
    -- только в каталогах ячеек (<base>/<id>/*), чтобы не считать index.jsonl и kernel.log
    -- drafts/ сюда не попадает: он живёт по своим правилам (§7.4.1), индекс о нём и не
    -- должен знать, а без этой оговорки каждый черновик считался бы мусором.
    local stray, stray_bytes = 0, 0
    for _, path in ipairs(vim.fn.glob(store.base .. "/*/*", false, true)) do
        local size = vim.fn.getfsize(path)
        local in_drafts = vim.fn.fnamemodify(path, ":h:t") == draft.DIR
        if size > 0 and not in_drafts and not referenced[vim.fs.normalize(path)] then
            stray, stray_bytes = stray + 1, stray_bytes + size
        end
    end
    if stray > 0 then
        add("warn", ("%d файлов в каталоге не упомянуты в индексе (%s)"):format(stray, human(stray_bytes)))
    end

    return report
end

function M.check()
    vim.health.start("jupyter.nvim")
    for _, entry in ipairs(M.collect()) do
        if entry.level == "ok" then
            vim.health.ok(entry.msg)
        elseif entry.level == "info" then
            -- info появился в 0.10; требования плагина — 0.10+, но падать на старом
            -- незачем: сообщение важнее уровня
            local info = vim.health.info or vim.health.ok
            info(entry.msg)
        elseif entry.level == "warn" then
            vim.health.warn(entry.msg)
        else
            vim.health.error(entry.msg)
        end
    end
end

return M
