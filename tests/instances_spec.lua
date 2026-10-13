-- Реестр открытых ноутбуков: тот же .ipynb в другом nvim. Другой nvim изображаем чужой
-- записью в каталоге реестра, живость pid подменяем.

local instances = require("jupyter.instances")

local NB = "/tmp/jupyter-instances/a.ipynb"

---Положить запись «от другого nvim» так же, как её положил бы он сам.
local function foreign(pid, socket)
    local real = vim.fn.getpid
    vim.fn.getpid = function()
        return pid
    end
    instances.claim(NB)
    vim.fn.getpid = real
    -- сокет в записи: перепишем руками, v:servername у теста свой
    local file = vim.fs.joinpath(instances.DIR, ("%s-%d.json"):format(vim.fn.sha256(vim.fn.resolve(NB)):sub(1, 16), pid))
    local record = vim.json.decode(table.concat(vim.fn.readfile(file), "\n"))
    record.socket = socket
    vim.fn.writefile({ vim.json.encode(record) }, file)
    return file
end

describe("тот же ноутбук в другом nvim", function()
    local alive
    before_each(function()
        instances.DIR = vim.fn.tempname()
        alive = instances.alive
    end)
    after_each(function()
        instances.alive = alive
    end)

    it("своя отметка — не «другой»", function()
        instances.claim(NB)
        assert.same({}, instances.others(NB))
    end)

    it("живой чужой nvim виден с pid и сокетом", function()
        foreign(424242, "/tmp/nvim.424242.0")
        instances.alive = function(pid)
            return pid == 424242
        end
        local others = instances.others(NB)
        assert.equals(1, #others)
        assert.equals(424242, others[1].pid)
        assert.equals("/tmp/nvim.424242.0", others[1].socket)
        assert.truthy(instances.describe(others):find("pid 424242", 1, true))
    end)

    it("запись умершего nvim стирается при чтении", function()
        local file = foreign(424243, nil)
        instances.alive = function()
            return false
        end
        assert.same({}, instances.others(NB))
        assert.equals(0, vim.fn.filereadable(file))
    end)

    it("другой ноутбук не путается с этим", function()
        foreign(424244, nil)
        instances.alive = function()
            return true
        end
        assert.same({}, instances.others("/tmp/jupyter-instances/b.ipynb"))
    end)

    it("release снимает только свою отметку", function()
        instances.claim(NB)
        local mine = vim.fn.glob(vim.fs.joinpath(instances.DIR, "*.json"), false, true)
        assert.equals(1, #mine)
        instances.release(NB)
        assert.same({}, vim.fn.glob(vim.fs.joinpath(instances.DIR, "*.json"), false, true))
    end)
end)
