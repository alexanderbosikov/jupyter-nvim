-- :checkhealth. Проверяется сбор, а не отрисовка: collect() возвращает список записей.

local health = require("jupyter.health")

local function levels(report)
    local out = {}
    for _, entry in ipairs(report) do
        out[entry.level] = (out[entry.level] or 0) + 1
    end
    return out
end

local function find(report, pattern)
    for _, entry in ipairs(report) do
        if entry.msg:find(pattern) then
            return entry
        end
    end
end

describe("здоровье", function()
    it("на рабочем окружении всё зелёное", function()
        local report = health.collect({ python = vim.g.jupyter_python, kernel_name = "python3" })

        local counts = levels(report)
        assert.is_nil(counts.error, "ошибок быть не должно: " .. vim.inspect(report))
        assert.is_truthy(find(report, "jupyter_client"), "версия jupyter_client")
        assert.is_truthy(find(report, "polars"))
        assert.is_truthy(find(report, "сайдкар отвечает"), "рукопожатие с сайдкаром")
        assert.is_truthy(find(report, "kernelspec python3 найден"))
    end)

    it("модуль без версии — предупреждение, а не зелёная строка с userdata", function()
        -- Зонд пишет null для модуля, которого нет. В JSON это null, в Lua без luanil —
        -- vim.NIL, а она истинна, поэтому проверка «версия есть» проходила и в отчёт
        -- уезжало «polars vim.NIL» со статусом ok.
        local fake = vim.fn.tempname()
        vim.fn.writefile({
            "#!/bin/sh",
            [[echo '{"python":"3.14.0","jupyter_client":"8.9.1","polars":null,"ipykernel":"6.30.1"}']],
        }, fake)
        vim.fn.setfperm(fake, "rwxr-xr-x")

        local report = health.collect({ python = fake, kernel_name = "python3" })

        assert.is_nil(find(report, "vim%.NIL"), "userdata в отчёте: " .. vim.inspect(report))
        local entry = find(report, "polars не установлен")
        assert.is_truthy(entry, "ожидали предупреждение про polars: " .. vim.inspect(report))
        assert.equals("warn", entry.level)
    end)

    it("несуществующий python — ошибка и ранний выход", function()
        local report = health.collect({ python = "/нет/такого/python" })

        assert.equals(1, #report)
        assert.equals("error", report[1].level)
        assert.is_truthy(report[1].msg:find("python не найден"))
    end)

    it("отсутствующий kernelspec назван вместе с доступными", function()
        local report = health.collect({ python = vim.g.jupyter_python, kernel_name = "нет-такого-ядра" })

        local entry = find(report, "kernelspec нет%-такого%-ядра не найден")
        assert.is_truthy(entry, "ожидали ошибку про kernelspec: " .. vim.inspect(report))
        assert.equals("error", entry.level)
        assert.is_truthy(entry.msg:find("Доступны:"))
    end)

    it("без image.nvim предупреждает, но не ошибается", function()
        local report = health.collect({ python = vim.g.jupyter_python, kernel_name = "python3" })

        local entry = find(report, "image%.nvim")
        assert.is_truthy(entry)
        assert.equals("warn", entry.level, "в тестовом rtp image.nvim нет — это предупреждение")
    end)

    it("выключенные картинки не считаются проблемой", function()
        local report = health.collect({ python = vim.g.jupyter_python, kernel_name = "python3", images = false })

        assert.equals("ok", find(report, "картинки выключены").level)
    end)
end)

-- Отчёт про историю прогонов. Проверяем разбор и арифметику, а не отрисовку: collect()
-- и history() возвращают список записей. Python и сайдкар тут не нужны — отчёт читает
-- только индекс на диске и текст буфера.
describe("история прогонов", function()
    local function fixture(records, files, lines, name)
        local dir = vim.fn.tempname()
        vim.fn.mkdir(dir, "p")
        local notebook = vim.fs.joinpath(dir, (name or "nb") .. (name and ".ipynb" or ".py"))
        vim.fn.writefile(lines, notebook)

        local base = vim.fs.joinpath(dir, ".jupyter-out", vim.fn.fnamemodify(notebook, ":t:r"))
        vim.fn.mkdir(base, "p")
        vim.fn.writefile(vim.tbl_map(vim.json.encode, records), vim.fs.joinpath(base, "index.jsonl"))
        for path, size in pairs(files) do
            local full = vim.fs.joinpath(base, path)
            vim.fn.mkdir(vim.fn.fnamemodify(full, ":h"), "p")
            vim.fn.writefile({ string.rep("x", size - 1) }, full) -- +1 байт на перевод строки
        end

        vim.cmd.edit(notebook)
        return vim.api.nvim_get_current_buf()
    end

    local function record(cell_id, run_id, path)
        return { cell_id = cell_id, run_id = run_id, status = "ok", path = path,
            started_at = "2026-09-09T10:00:00Z", code_sha = "0badc0de" }
    end

    after_each(function()
        vim.cmd("silent! %bwipeout!")
    end)

    it("считает вес и отделяет сирот от порядковых id", function()
        local buf = fixture({
            record("a3f9", 1, "a3f9/1.txt"), -- ячейка на месте
            record("b7e1", 1, "b7e1/1.txt"), -- id настоящий, а ячейки в документе нет
            record("0002", 1, "0002/1.txt"), -- порядковый: в документ такой id не пишется
        }, {
            ["a3f9/1.txt"] = 2048, ["b7e1/1.txt"] = 2048, ["0002/1.txt"] = 2048,
        }, { '# %% jncell="a3f9"', "x = 1" })

        local report = health.history({ out_dir = ".jupyter-out" }, buf)

        assert.is_truthy(find(report, "история: 3 ячеек, 3 прогонов, 6 КБ"), vim.inspect(report))
        local orphans = find(report, "нет в документе")
        assert.is_truthy(orphans, vim.inspect(report))
        assert.equals("warn", orphans.level)
        assert.is_truthy(orphans.msg:find("b7e1"), orphans.msg)
        assert.is_nil(orphans.msg:find("0002"), "порядковый id не сирота, а мусор: " .. orphans.msg)
        assert.is_truthy(orphans.msg:find("2 КБ"), "вес сирот: " .. orphans.msg)
        local ordinal = find(report, "под порядковым id")
        assert.equals("info", ordinal.level)
        assert.is_truthy(ordinal.msg:find("1 ячеек"), ordinal.msg)
    end)

    it("замечает файлы, на которые индекс не ссылается", function()
        local buf = fixture({ record("a3f9", 1, "a3f9/1.txt") },
            { ["a3f9/1.txt"] = 1024, ["a3f9/99.parquet"] = 4096 },
            { '# %% jncell="a3f9"', "x = 1" })

        local stray = find(health.history({ out_dir = ".jupyter-out" }, buf), "не упомянуты в индексе")

        assert.is_truthy(stray)
        assert.equals("warn", stray.level)
        assert.is_truthy(stray.msg:find("4 КБ"), stray.msg)
    end)

    it("в неконвертированном .ipynb не объявляет всю историю осиротевшей", function()
        -- в сыром json id лежит полем `"jncell": "a3f9"`, формы `jncell="a3f9"` там нет,
        -- и наивная проверка сочла бы сиротой каждую ячейку сразу
        local buf = fixture({ record("a3f9", 1, "a3f9/1.txt") }, { ["a3f9/1.txt"] = 1024 }, {
            '{"cells": [{"cell_type": "code", "metadata": {"jncell": "a3f9"}, "source": ["x = 1"]}],',
            ' "nbformat": 4, "nbformat_minor": 5}',
        }, "raw")

        local report = health.history({ out_dir = ".jupyter-out" }, buf)

        assert.is_nil(find(report, "нет в документе"), vim.inspect(report))
        assert.is_truthy(find(report, "ячеек в этом буфере не видно"), vim.inspect(report))
        assert.is_truthy(find(report, "история: 1 ячеек"), vim.inspect(report))
    end)

    it("без истории на диске молчит", function()
        local dir = vim.fn.tempname()
        vim.fn.mkdir(dir, "p")
        vim.cmd.edit(vim.fs.joinpath(dir, "empty.py"))

        assert.same({}, health.history({ out_dir = ".jupyter-out" }, vim.api.nvim_get_current_buf()))
    end)
end)
