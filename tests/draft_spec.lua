-- Черновик несохранённого буфера. Проверяется то, ради чего он есть: после падения
-- работа находится, а чужую при этом никто не трогает.

local draft = require("jupyter.draft")

local NOTEBOOK = {
    "# Отчёт",
    "",
    '```python jncell="a3f9"',
    "x = 1",
    "```",
}

---Ноутбук на диске и буфер с ним. Возвращает путь и буфер.
local function notebook(lines)
    local path = vim.fn.tempname() .. ".py"
    vim.fn.writefile(lines or NOTEBOOK, path)
    vim.cmd.edit(path)
    vim.bo.filetype = "python"
    return path, vim.api.nvim_get_current_buf()
end

local function edit(buf, lines)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
end

local function drafts_dir(path)
    return vim.fs.joinpath(
        vim.fn.fnamemodify(path, ":h"),
        ".jupyter-out",
        vim.fn.fnamemodify(path, ":t:r"),
        "drafts"
    )
end

describe("черновик", function()
    after_each(function()
        for _, buf in ipairs(draft.bufs()) do
            draft.detach(buf)
        end
    end)

    it("без файла писать некуда", function()
        local d = draft.new({ notebook = "" })

        assert.is_nil(d.dir)
        assert.is_false(d:save(vim.api.nvim_get_current_buf()))
        assert.same({}, d:candidates())
    end)

    it("кладёт файлы рядом с историей прогонов, а не рядом с ноутбуком", function()
        local path = vim.fn.tempname() .. "/отчёт.ipynb"
        local d = draft.new({ notebook = path })

        assert.equals(drafts_dir(path), d.dir)
        -- именно не <имя>.md рядом: этот файл jupytext.nvim считает своим кэшем
        assert.is_nil(d:path():match("отчёт%.md$"))
    end)

    it("пишет текст буфера как есть и читает его обратно", function()
        local path, buf = notebook()
        edit(buf, { "x = 2", "y = 3" })
        local d = draft.new({ notebook = path })

        assert.is_true(d:save(buf))
        local found = d:read()

        assert.same({ "x = 2", "y = 3" }, found.lines)
        assert.is_true(found.trusted)
        assert.is_false(found.outside)
        assert.equals(vim.fn.getpid(), found.pid)
    end)

    it("не оставляет после себя обрывков", function()
        local path, buf = notebook()
        local d = draft.new({ notebook = path })
        d:save(buf)

        local left = vim.fn.glob(d.dir .. "/*.tmp", false, true)

        assert.same({}, left)
    end)

    it("тот же текст второй раз не пишет, а по force пишет", function()
        local path, buf = notebook()
        local d = draft.new({ notebook = path })

        assert.is_true(d:save(buf))
        assert.is_false(d:save(buf))
        assert.is_true(d:save(buf, true))
    end)

    it("метаданиям от другого текста не верит", function()
        local path, buf = notebook()
        local d = draft.new({ notebook = path })
        d:save(buf)
        -- краш между записью текста и записью метаданных: текст новее, мета от прошлого
        vim.fn.writefile({ "и ещё строка" }, d:path(), "a")

        local found = d:read()

        assert.is_false(found.trusted)
        assert.is_nil(found.saved_at)
        assert.equals("и ещё строка", found.lines[#found.lines])
    end)

    it("замечает, что ноутбук переписали снаружи", function()
        local path, buf = notebook()
        local d = draft.new({ notebook = path })
        d:save(buf)
        -- getftime считает в секундах: без сдвига запись «в ту же секунду» не отличить
        vim.fn.writefile({ "правка из Jupyter Lab" }, path)
        vim.fn.system({ "touch", "-A", "0001", path })

        assert.is_true(d:read().outside)
    end)

    it("свой черновик от прошлого открытия предлагает, а нынешний — нет", function()
        local path, buf = notebook()
        local past = draft.new({ notebook = path }) -- прошлая жизнь того же буфера
        past:save(buf)
        local now = draft.new({ notebook = path })

        local list = now:candidates()

        assert.equals(1, #list)
        assert.equals(past.id, list[1].id)
        assert.is_nil(vim.tbl_filter(function(f)
            return f.id == now.id
        end, list)[1])
    end)

    it("чужой черновик с живым процессом не трогает", function()
        local path, buf = notebook()
        local mine = draft.new({ notebook = path })
        -- настоящий живой процесс: там сейчас «кто-то печатает», и это не наш черновик
        local job = vim.fn.jobstart({ "sleep", "30" })
        local alive_pid = vim.fn.jobpid(job)
        local alien = draft.new({ notebook = path, pid = alive_pid, id = alive_pid .. "-1" })
        alien:save(buf)

        local list = mine:candidates()
        vim.fn.jobstop(job)

        assert.same({}, list)
    end)

    it("чужой черновик от умершего процесса подбирает", function()
        local path, buf = notebook()
        local mine = draft.new({ notebook = path })
        -- pid, которого точно нет: за границей допустимых номеров
        local dead = draft.new({ notebook = path, pid = 4194303, id = "4194303-1" })
        dead:save(buf)

        local list = mine:candidates()

        assert.equals(1, #list)
        assert.equals("4194303-1", list[1].id)
    end)

    it("удаляет и текст, и метаданные", function()
        local path, buf = notebook()
        local d = draft.new({ notebook = path })
        d:save(buf)

        assert.is_true(d:drop())

        assert.equals(0, vim.fn.filereadable(d:path()))
        assert.equals(0, vim.fn.filereadable(d:meta_path()))
        assert.is_nil(d:read())
    end)
end)

describe("черновик при буфере", function()
    after_each(function()
        for _, buf in ipairs(draft.bufs()) do
            draft.detach(buf)
        end
    end)

    it("сохранённый буфер черновика не держит", function()
        local path, buf = notebook()
        draft.attach(buf, { out_dir = ".jupyter-out" })
        edit(buf, { "x = 2" })
        assert.is_true(draft.save(buf))

        vim.cmd("silent write")
        draft.save(buf)

        assert.is_nil(draft.of(buf):read())
    end)

    it("совпавший с буфером черновик убирает молча", function()
        local path, buf = notebook()
        local past = draft.new({ notebook = path })
        past:save(buf) -- прошлая жизнь закончилась ровно на том, что сейчас в буфере
        draft.attach(buf, { out_dir = ".jupyter-out" })

        local found = draft.check(buf)

        assert.same({}, found)
        assert.equals(0, vim.fn.filereadable(past:path()))
    end)

    it("расходящийся черновик показывает", function()
        local path, buf = notebook()
        local past = draft.new({ notebook = path })
        edit(buf, { "x = 2", "потерянная работа" })
        past:save(buf)
        vim.cmd.edit({ args = { path }, bang = true }) -- вернулись к тому, что на диске
        buf = vim.api.nvim_get_current_buf()
        draft.attach(buf, { out_dir = ".jupyter-out" })

        local found = draft.check(buf)

        assert.equals(1, #found)
        assert.equals("потерянная работа", found[1].lines[2])
        assert.same(found, draft.found(buf))
    end)

    it("восстановление кладёт текст в буфер и не трогает файл", function()
        local path, buf = notebook()
        local before = vim.fn.readfile(path)

        assert.is_true(draft.apply(buf, { "вернулось", "из черновика" }))

        assert.same({ "вернулось", "из черновика" }, vim.api.nvim_buf_get_lines(buf, 0, -1, false))
        assert.same(before, vim.fn.readfile(path))
        assert.is_true(vim.bo[buf].modified)
    end)

    it("восстановление снимается одним undo", function()
        local _, buf = notebook()
        local before = vim.api.nvim_buf_get_lines(buf, 0, -1, false)

        draft.apply(buf, { "вернулось" })
        vim.cmd("undo")

        assert.same(before, vim.api.nvim_buf_get_lines(buf, 0, -1, false))
    end)

    it("правка буфера доезжает до черновика по таймеру", function()
        local path, buf = notebook()
        draft.attach(buf, { out_dir = ".jupyter-out", debounce_ms = 10 })

        edit(buf, { "напечатали и забыли" })
        local ok = vim.wait(2000, function()
            local found = draft.of(buf):read()
            return found ~= nil and found.lines[1] == "напечатали и забыли"
        end, 20)

        assert.is_true(ok)
    end)

    it("закрытый несохранённым буфер черновик оставляет", function()
        local path, buf = notebook()
        draft.attach(buf, { out_dir = ".jupyter-out" })
        edit(buf, { "не успел сохранить" })
        draft.save(buf)
        local d = draft.of(buf)

        draft.detach(buf)

        assert.same({ "не успел сохранить" }, d:read().lines)
    end)
end)

describe("черновик в плагине", function()
    local jupyter = require("jupyter")

    -- Percent-представление, а не фенсы: открытие .md тянет за собой ftplugin/markdown,
    -- а тот в headless падает на отсутствующем парсере treesitter. К черновику это
    -- отношения не имеет, но тест бы валило.
    local PERCENT = { "# %%", "x = 1" }

    ---Ноутбук на диске: открытие такого файла проходит через FileType плагина.
    local function open(lines)
        local path = vim.fn.tempname() .. ".py"
        vim.fn.writefile(lines or PERCENT, path)
        vim.cmd.edit(path)
        return path, vim.api.nvim_get_current_buf()
    end

    before_each(function()
        jupyter.setup({ autosave = { debounce_ms = 10 } })
    end)

    after_each(function()
        for _, buf in ipairs(draft.bufs()) do
            draft.detach(buf)
        end
    end)

    it("берёт ноутбук под черновик при открытии", function()
        local _, buf = open()

        assert.is_not_nil(draft.of(buf))
    end)

    it("документ без ячеек под черновик не берёт", function()
        local buf = vim.api.nvim_create_buf(true, false)
        vim.api.nvim_buf_set_name(buf, vim.fn.tempname() .. ".md")
        vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "просто текст", "без единой ячейки" })
        vim.bo[buf].filetype = "markdown"

        assert.same({}, jupyter.watch_draft(buf))

        assert.is_nil(draft.of(buf))
    end)

    it("находит черновик от прошлой жизни и выбрасывает его по требованию", function()
        local path = vim.fn.tempname() .. ".py"
        vim.fn.writefile(PERCENT, path)
        -- прошлая сессия умерла, успев напечатать больше, чем лежит на диске
        local past = draft.new({ notebook = path, pid = 4194303, id = "4194303-7" })
        local scratch = vim.api.nvim_create_buf(false, true)
        vim.api.nvim_buf_set_lines(scratch, 0, -1, false, vim.list_extend(vim.deepcopy(PERCENT), { "потеряно" }))
        past:save(scratch)

        vim.cmd.edit(path)
        local buf = vim.api.nvim_get_current_buf()

        assert.equals(1, #draft.found(buf))
        assert.equals("4194303-7", draft.found(buf)[1].id)

        jupyter.recover(buf, true)

        assert.same({}, draft.found(buf))
        assert.is_nil(past:read())
    end)

    it("по умолчанию перед прогоном ноутбук не сохраняет", function()
        local _, buf = open()
        vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "x = 2" })

        assert.is_false(jupyter.write_before_run(buf))
        assert.is_true(vim.bo[buf].modified)
    end)

    it("с write_on_run сохраняет ноутбук перед прогоном", function()
        jupyter.setup({ autosave = { write_on_run = true } })
        local path, buf = open()
        vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "x = 2" })

        assert.is_true(jupyter.write_before_run(buf))

        assert.is_false(vim.bo[buf].modified)
        assert.same({ "x = 2" }, vim.fn.readfile(path))
    end)

    it("сохранение ноутбука снимает черновик", function()
        local _, buf = open()
        vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "x = 2" })
        draft.save(buf)
        local d = draft.of(buf)
        assert.is_not_nil(d:read())

        vim.cmd("silent write")

        assert.is_nil(d:read())
    end)
end)

describe("черновик в :checkhealth", function()
    local health = require("jupyter.health")

    local function notebook_with_draft()
        local path = vim.fn.tempname() .. ".py"
        vim.fn.writefile({ "# %%", "x = 1" }, path)
        vim.cmd.edit(path)
        local buf = vim.api.nvim_get_current_buf()
        local past = draft.new({ notebook = path, pid = 4194303, id = "4194303-3" })
        past:save(buf, true)
        return path, buf, past
    end

    local function levels(report, pattern)
        return vim.tbl_filter(function(item)
            return item.msg:match(pattern)
        end, report)
    end

    it("говорит о черновиках, даже когда истории прогонов ещё нет", function()
        local _, buf = notebook_with_draft()

        local found = levels(health.history({ out_dir = ".jupyter-out" }, buf), "черновик")

        assert.equals(1, #found)
        assert.equals("warn", found[1].level)
    end)

    it("черновик не числится мусором в каталоге выводов", function()
        local path, buf = notebook_with_draft()
        local base = vim.fs.joinpath(
            vim.fn.fnamemodify(path, ":h"), ".jupyter-out", vim.fn.fnamemodify(path, ":t:r")
        )
        vim.fn.writefile({ '{"cell_id":"a3f9","run_id":1,"status":"ok"}' }, base .. "/index.jsonl")

        local report = health.history({ out_dir = ".jupyter-out" }, buf)

        assert.same({}, levels(report, "не упомянуты в индексе"))
    end)
end)

describe("черновик выключен", function()
    local jupyter = require("jupyter")

    before_each(function()
        jupyter.setup({ autosave = { draft = false, debounce_ms = 10 } })
    end)

    after_each(function()
        for _, buf in ipairs(draft.bufs()) do
            draft.detach(buf)
        end
        jupyter.setup({})
    end)

    it("ничего не пишет, но ноутбук из виду не теряет", function()
        local path = vim.fn.tempname() .. ".py"
        vim.fn.writefile({ "# %%", "x = 1" }, path)
        vim.cmd.edit(path)
        local buf = vim.api.nvim_get_current_buf()
        vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "# %%", "x = 2" })

        assert.is_false(draft.save(buf))
        assert.is_nil(draft.of(buf):read())

        -- список нужен write_on_focus_lost: без него выключенный черновик выключил бы и его
        assert.is_true(vim.tbl_contains(draft.bufs(), buf))
    end)
end)

describe("черновик снимается по факту, а не по флагу", function()
    ---Буфер с файлом и записанным черновиком.
    local function prepared()
        local path = vim.fn.tempname() .. ".py"
        vim.fn.writefile({ "# %%", "x = 1" }, path)
        vim.cmd.edit(path)
        local buf = vim.api.nvim_get_current_buf()
        draft.attach(buf, { out_dir = ".jupyter-out" })
        vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "# %%", "x = 2" })
        assert.is_true(draft.save(buf))
        return path, buf, draft.of(buf)
    end

    after_each(function()
        for _, buf in ipairs(draft.bufs()) do
            draft.detach(buf)
        end
    end)

    it("держит черновик, когда буфер «сохранён», а файл не изменился", function()
        local _, buf, d = prepared()
        -- ровно то, что делает jupytext.nvim в своём BufWriteCmd: снимает modified до
        -- того, как отработает внешний конвертер, — а тот может и не отработать
        vim.bo[buf].modified = false

        assert.is_false(draft.save(buf))

        assert.is_not_nil(d:read())
    end)

    it("снимает черновик, когда файл ноутбука стал не старше него", function()
        local path, buf, d = prepared()
        -- getftime считает секундами: без сдвига «записан позже» не отличить
        vim.fn.system({ "touch", "-A", "0001", path })
        vim.bo[buf].modified = false

        assert.is_false(draft.save(buf))

        assert.is_nil(d:read())
    end)

    it("закрытие буфера черновик тоже не снимает, пока файл старше", function()
        local _, buf, d = prepared()
        vim.bo[buf].modified = false

        draft.detach(buf)

        assert.is_not_nil(d:read())
    end)

    it("буфер без файла на диске под черновик не берётся", function()
        local jupyter = require("jupyter")
        jupyter.setup({})
        -- так выглядит буфер otter.nvim: имя есть, файла нет, ft=python
        local buf = vim.api.nvim_create_buf(true, false)
        vim.api.nvim_buf_set_name(buf, vim.fn.tempname() .. ".ipynb.otter.py")
        vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "x = 1" })
        vim.bo[buf].filetype = "python"

        assert.same({}, jupyter.watch_draft(buf))

        assert.is_nil(draft.of(buf))
    end)
end)

describe("черновик при повторном подключении буфера", function()
    after_each(function()
        for _, buf in ipairs(draft.bufs()) do
            draft.detach(buf)
        end
    end)

    -- Ровно то, что случилось на выходе из редактора: буфер отцепился и тут же прицепился
    -- заново, и новый черновик нашёл старый. Журнал: detach → attach → check.same → drop.
    it("не сносит черновик, пока в буфере есть несохранённые правки", function()
        local path = vim.fn.tempname() .. ".py"
        vim.fn.writefile({ "# %%", "x = 1" }, path)
        vim.cmd.edit(path)
        local buf = vim.api.nvim_get_current_buf()
        draft.attach(buf, { out_dir = ".jupyter-out" })
        vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "# %%", "работа, которой нет на диске" })
        assert.is_true(draft.save(buf))
        local first = draft.of(buf)

        draft.detach(buf)
        draft.attach(buf, { out_dir = ".jupyter-out" }) -- второй раз на тот же буфер
        local found = draft.check(buf)

        assert.is_not_nil(first:read())
        assert.equals(1, #found)
        assert.equals("работа, которой нет на диске", found[1].lines[2])
    end)

    it("сохранённый буфер свой прошлый черновик по-прежнему убирает молча", function()
        local path = vim.fn.tempname() .. ".py"
        vim.fn.writefile({ "# %%", "x = 1" }, path)
        vim.cmd.edit(path)
        local buf = vim.api.nvim_get_current_buf()
        draft.attach(buf, { out_dir = ".jupyter-out" })
        local first = draft.of(buf)
        first:save(buf, true) -- черновик слово в слово как файл
        draft.detach(buf)

        draft.attach(buf, { out_dir = ".jupyter-out" })
        local found = draft.check(buf)

        assert.same({}, found)
        assert.is_nil(first:read())
    end)
end)
