-- Выбор интерпретатора сайдкара (lua/jupyter/python.lua). Ничего не запускается:
-- проверяются только правила выбора на поддельных окружениях во временном каталоге.

local python = require("jupyter.python")

---Поддельное окружение: исполняемый файл <root>/bin/python.
local function fake_env(root)
    vim.fn.mkdir(root .. "/bin", "p")
    local path = root .. "/bin/python"
    vim.fn.writefile({ "#!/bin/sh", "exit 0" }, path)
    vim.fn.setfperm(path, "rwxr-xr-x")
    return path
end

describe("выбор python", function()
    local root
    local saved

    before_each(function()
        root = vim.fn.tempname()
        vim.fn.mkdir(root, "p")
        -- харнесс кладёт JUPYTER_NVIM_PYTHON в vim.g; на время теста все внешние источники снимаем
        saved = { g = vim.g.jupyter_python, env = vim.env.JUPYTER_NVIM_PYTHON, venv = vim.env.VIRTUAL_ENV }
        vim.g.jupyter_python = nil
        vim.env.JUPYTER_NVIM_PYTHON = nil
        vim.env.VIRTUAL_ENV = nil
    end)

    after_each(function()
        vim.g.jupyter_python = saved.g
        vim.env.JUPYTER_NVIM_PYTHON = saved.env
        vim.env.VIRTUAL_ENV = saved.venv
        vim.fn.delete(root, "rf")
    end)

    local function ctx_in(dir)
        return { buf = 0, dir = dir, venv = (python.find_venv(dir)) }
    end

    it("строка берётся как есть", function()
        local p = fake_env(root .. "/env")

        local found, source = python.resolve(p, ctx_in(root))

        assert.equals(p, found)
        assert.equals("opts.python", source)
    end)

    it("несуществующая строка — nil, а не подмена другим интерпретатором", function()
        fake_env(root .. "/proj/.venv") -- рядом есть рабочее окружение, но брать его нельзя

        local found, source, tried = python.resolve(root .. "/нет/python", ctx_in(root .. "/proj"))

        assert.is_nil(found)
        assert.equals("opts.python", source)
        assert.same({ root .. "/нет/python" }, tried)
    end)

    it("список — первый существующий, остальные перечислены как проверенные", function()
        local second = fake_env(root .. "/b")
        local third = fake_env(root .. "/c")

        local found, _, tried = python.resolve({ root .. "/a/bin/python", second, third }, ctx_in(root))

        assert.equals(second, found)
        assert.same({ root .. "/a/bin/python", second }, tried)
    end)

    it("функция получает контекст и может предпочесть окружение ноутбука", function()
        local venv = fake_env(root .. "/proj/.venv")
        local fallback = fake_env(root .. "/shared")
        local spec = function(ctx)
            return { ctx.venv, fallback }
        end

        local near, _ = python.resolve(spec, ctx_in(root .. "/proj/nb"))
        local far, _ = python.resolve(spec, ctx_in(root .. "/elsewhere"))

        assert.equals(venv, near)
        assert.equals(fallback, far)
    end)

    it("функция, вернувшая nil, отдаёт выбор автопоиску", function()
        local venv = fake_env(root .. "/proj/.venv")

        local found, source = python.resolve(function() return nil end, ctx_in(root .. "/proj"))

        assert.equals(venv, found)
        assert.is_truthy(source:find(".venv", 1, true))
    end)

    it("без явного — активный $VIRTUAL_ENV", function()
        local active = root .. "/active"
        local p = fake_env(active)
        fake_env(root .. "/proj/.venv") -- .venv рядом проигрывает активному окружению
        vim.env.VIRTUAL_ENV = active

        local found, source = python.resolve(nil, ctx_in(root .. "/proj"))

        assert.equals(p, found)
        assert.equals("$VIRTUAL_ENV", source)
    end)

    it("без явного — .venv вверх по дереву от каталога ноутбука", function()
        local p = fake_env(root .. "/proj/.venv")
        vim.fn.mkdir(root .. "/proj/notebooks/deep", "p")

        local found, source = python.resolve(nil, ctx_in(root .. "/proj/notebooks/deep"))

        assert.equals(p, found)
        assert.equals(".venv в " .. root .. "/proj", source)
    end)

    it("vim.g.jupyter_python перекрывает автопоиск", function()
        local g = fake_env(root .. "/g")
        fake_env(root .. "/proj/.venv")
        vim.g.jupyter_python = g

        local found, source = python.resolve(nil, ctx_in(root .. "/proj"))

        assert.equals(g, found)
        assert.equals("vim.g.jupyter_python", source)
    end)

    it("$JUPYTER_NVIM_PYTHON перекрывает автопоиск и уступает vim.g", function()
        local e = fake_env(root .. "/e")
        local g = fake_env(root .. "/g")
        fake_env(root .. "/proj/.venv")
        vim.env.JUPYTER_NVIM_PYTHON = e

        local found, source = python.resolve(nil, ctx_in(root .. "/proj"))
        assert.equals(e, found)
        assert.equals("$JUPYTER_NVIM_PYTHON", source)

        vim.g.jupyter_python = g
        found = python.resolve(nil, ctx_in(root .. "/proj"))
        assert.equals(g, found)
    end)

    it("контекст буфера — каталог ноутбука и его окружение", function()
        local p = fake_env(root .. "/proj/.venv")
        vim.fn.mkdir(root .. "/proj/notebooks", "p")
        local buf = vim.api.nvim_create_buf(false, true)
        vim.api.nvim_buf_set_name(buf, root .. "/proj/notebooks/отчёт.md")

        local ctx = python.context(buf)

        assert.equals(root .. "/proj/notebooks", ctx.dir)
        assert.equals(p, ctx.venv)
        vim.api.nvim_buf_delete(buf, { force = true })
    end)

    it("без окружений — python3 из PATH", function()
        local in_path = vim.fn.exepath("python3")
        if in_path == "" then
            pending("в PATH нет python3")
            return
        end

        local found, source = python.resolve(nil, ctx_in(root))

        assert.equals("PATH", source)
        assert.equals(in_path, vim.fn.exepath(found))
    end)
end)
