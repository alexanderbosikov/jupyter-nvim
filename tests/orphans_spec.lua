-- Ядра без хозяина. Проверка процессов подменяется: тест не должен зависеть от того,
-- какие pid выданы в системе, а убивать что-либо настоящее ему тем более незачем.

local orphans = require("jupyter.orphans")

---Записать след с нужными полями.
---@param record table
---@return string path
local function trace(record)
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir, "p")
    local path = vim.fs.joinpath(dir, orphans.FILE)
    vim.fn.writefile({ vim.json.encode(record) }, path)
    return path
end

---Подмена: живыми считаются перечисленные pid, командная строка одна на всех.
local function world(live, command)
    return {
        alive = function(pid)
            return vim.tbl_contains(live, pid)
        end,
        command_of = function()
            return command or ""
        end,
    }
end

local RECORD = {
    sidecar_pid = 1001,
    kernel_pid = 2002,
    kernel_name = "python3",
    started_at = "2026-09-07T12:00:00",
    connection_file = "/tmp/kernel-abc.json",
}

describe("след живого ядра", function()
    it("живой сайдкар — это не сирота, а работающая сессия", function()
        local path = trace(RECORD)

        assert.is_nil(orphans.check(path, world({ 1001, 2002 }, "python -m ipykernel -f /tmp/kernel-abc.json")))
    end)

    it("ядро без сайдкара — сирота", function()
        local path = trace(RECORD)

        local found = orphans.check(path, world({ 2002 }, "python -m ipykernel -f /tmp/kernel-abc.json"))

        assert.is_not_nil(found)
        assert.equals(2002, found.kernel_pid)
        assert.is_false(found.stale, "процесс жив: это не просто забытый файл")
        assert.is_truthy(orphans.describe(found):find("2002", 1, true))
    end)

    it("нет ни сайдкара, ни ядра — остался только файл", function()
        local path = trace(RECORD)

        local found = orphans.check(path, world({}))

        assert.is_not_nil(found)
        assert.is_true(found.stale)
    end)

    it("pid переиспользован чужим процессом — не трогаем", function()
        local path = trace(RECORD)

        -- pid жив, но это не наше ядро: connection-файла в его argv нет
        local found = orphans.check(path, world({ 2002 }, "/usr/bin/ssh -N -L 5432:localhost:5432 db"))

        assert.is_not_nil(found)
        assert.is_true(found.stale, "чужой процесс убивать нельзя")
    end)

    it("битый или пустой след игнорируется", function()
        local dir = vim.fn.tempname()
        vim.fn.mkdir(dir, "p")
        local path = vim.fs.joinpath(dir, orphans.FILE)
        vim.fn.writefile({ "{это не json" }, path)

        assert.is_nil(orphans.check(path, world({})))
        assert.is_nil(orphans.check(vim.fs.joinpath(dir, "нет-такого.json"), world({})))
    end)

    it("след без pid ядра ничего не значит", function()
        local path = trace({ sidecar_pid = 1001, kernel_name = "python3" })

        assert.is_nil(orphans.check(path, world({})))
    end)
end)

describe("поиск следов", function()
    it("обходит все ноутбуки каталога", function()
        local dir = vim.fn.tempname()
        for _, name in ipairs({ "первый", "второй" }) do
            local sub = vim.fs.joinpath(dir, ".jupyter-out", name)
            vim.fn.mkdir(sub, "p")
            vim.fn.writefile({ vim.json.encode(RECORD) }, vim.fs.joinpath(sub, orphans.FILE))
        end

        local found = orphans.scan(dir, nil, world({ 2002 }, "ipykernel -f /tmp/kernel-abc.json"))

        assert.equals(2, #found)
    end)

    it("путь следа считается от имени ноутбука", function()
        local path = orphans.record_for("/data/отчёт.ipynb")

        assert.equals("/data/.jupyter-out/отчёт/" .. orphans.FILE, path)
    end)

    it("имя каталога выводов берётся из конфига", function()
        local path = orphans.record_for("/data/отчёт.ipynb", ".outs")

        assert.equals("/data/.outs/отчёт/" .. orphans.FILE, path)
    end)
end)

describe("снятие сироты", function()
    it("забытый файл просто удаляется, сигналов не летит", function()
        local path = trace(RECORD)
        local found = orphans.check(path, world({}))

        assert.is_true(orphans.kill(found))
        assert.equals(0, vim.fn.filereadable(path), "след должен быть убран")
    end)

    it("живое ядро гасится сигналом", function()
        -- настоящий процесс, который не завершится сам
        local job = vim.fn.jobstart({ "sleep", "60" })
        local pid = vim.fn.jobpid(job)
        local path = trace(vim.tbl_extend("force", RECORD, { kernel_pid = pid }))
        local found = orphans.check(path, {
            alive = function(p)
                return p == pid
            end,
            command_of = function()
                return "sleep 60 -f /tmp/kernel-abc.json"
            end,
        })
        assert.is_false(found.stale)

        assert.is_true(orphans.kill(found))
        assert.is_false(orphans.alive(pid), "процесс должен быть снят по-настоящему")
        assert.equals(0, vim.fn.filereadable(path))
    end)
end)
