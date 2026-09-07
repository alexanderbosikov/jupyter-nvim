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
