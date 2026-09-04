-- Картинки. Сам рендер — забота image.nvim, поэтому проверяется наша часть:
-- что путь и якорь отдаются один раз, прошлая картинка снимается, а отсутствие
-- image.nvim или файла не роняет окно вывода.

local images = require("jupyter.images")
local output = require("jupyter.ui.output")

---Заглушка, повторяющая устройство image.nvim: свой реестр всех отрисованных картинок,
---который сам плагин никогда не чистит, и выборка по буферу.
local function fake_api()
    local api = { made = {}, cleared = 0, state = { images = {} }, sent = {} }
    api.send = function(payload) table.insert(api.sent, payload) end
    api.from_file = function(path, opts)
        local image = {
            id = opts.id,
            path = path,
            opts = opts,
            buffer = opts.buffer,
            window = opts.window,
            rendered = 0,
            global_state = api.state,
            clear = function() api.cleared = api.cleared + 1 end,
        }
        image.render = function(self)
            self.rendered = self.rendered + 1
            api.state.images[self.id] = self -- как renderer.lua
        end
        table.insert(api.made, image)
        return image
    end
    api.get_images = function(opts)
        local out = {}
        for _, image in pairs(api.state.images) do
            if not opts or not opts.buffer or opts.buffer == image.buffer then
                table.insert(out, image)
            end
        end
        return out
    end
    return api
end

local function png()
    local path = vim.fn.tempname() .. ".png"
    vim.fn.writefile({ "\137PNG" }, path, "b")
    return path
end

describe("картинки", function()
    it("отдают путь и якорь в image.nvim", function()
        local api = fake_api()
        local im = images.new({ api = api })
        local path = png()

        assert.is_true(im:show(path, 1000, 2000, 7))

        assert.equals(1, #api.made)
        assert.equals(path, api.made[1].path)
        assert.equals(7, api.made[1].opts.y)
        assert.equals(2000, api.made[1].opts.buffer)
        assert.equals(1000, api.made[1].opts.window)
        assert.is_true(api.made[1].opts.with_virtual_padding)
        assert.equals(1, api.made[1].rendered)
    end)

    it("каждый показ получает свой id, иначе вернётся прошлая картинка", function()
        local api = fake_api()
        local im = images.new({ api = api })
        local path = png()

        im:show(path, 1, 2, 0)
        im:show(path, 1, 2, 0)

        assert.are_not.equals(api.made[1].opts.id, api.made[2].opts.id)
        assert.equals(1, api.cleared, "прошлая картинка снимается перед новой")
    end)

    it("новая картинка убирает прошлую из состояния image.nvim", function()
        -- иначе WinScrolled перерисует старую поверх новой: image.nvim свой реестр не чистит
        local api = fake_api()
        local im = images.new({ api = api })

        im:show(png(), 1, 2, 0)
        im:show(png(), 1, 2, 0)
        im:show(png(), 1, 2, 0)

        assert.equals(1, vim.tbl_count(api.state.images), "в состоянии остаётся только текущая")
        assert.equals(2, api.cleared)
    end)

    it("clear снимает все известные картинки, а не только свои", function()
        -- с фильтром по буферу картинка на практике не снималась; повторяем то, что
        -- доказанно работает у самого image.nvim в обработчике FocusLost
        local api = fake_api()
        local im = images.new({ api = api, send = api.send })
        im:show(png(), 1, 2, 0)
        local other = api.from_file(png(), { id = "чужая", buffer = 99, window = 1 })
        other:render()

        im:clear(2)

        assert.equals(0, vim.tbl_count(api.state.images))
        assert.is_nil(im.current)
    end)

    it("после чистки уходит прямая последовательность удаления", function()
        local api = fake_api()
        local im = images.new({ api = api, send = api.send })
        im:show(png(), 1, 2, 0)

        im:clear(2)

        -- show() тоже чистит перед рисованием, поэтому последовательностей две
        assert.is_true(#api.sent >= 1)
        for _, payload in ipairs(api.sent) do
            assert.is_truthy(payload:find("a=d,d=A", 1, true), "kitty: удалить и размещения, и данные")
        end
    end)

    it("последовательность заворачивается в tmux-passthrough", function()
        local saved = vim.env.TMUX
        vim.env.TMUX = "/tmp/tmux-502/default,1,0"

        local wrapped = images.tmux_wrap(images.PURGE)

        assert.is_truthy(wrapped:find("^\27Ptmux;"))
        assert.is_truthy(wrapped:find("\27\27_Ga=d,d=A", 1, true), "escape удваивается")
        vim.env.TMUX = saved
    end)

    it("нет файла — не показываем и не падаем", function()
        local api = fake_api()
        local im = images.new({ api = api })

        assert.is_false(im:show("/нет/такого.png", 1, 2, 0))
        assert.equals(0, #api.made)
    end)

    it("выключенные картинки ничего не рисуют", function()
        local api = fake_api()
        local im = images.new({ api = api, enabled = false })

        assert.is_false(im:show(png(), 1, 2, 0))
        assert.equals(0, #api.made)
    end)

    it("без image.nvim просто отвечают «нет»", function()
        local im = images.new({})

        -- в изолированном rtp тестов image.nvim нет
        assert.is_false(im:show(png(), 1, 2, 0))
    end)
end)

describe("картинка в окне вывода", function()
    it("рисуется под текстом и снимается при закрытии", function()
        local api = fake_api()
        local out = output.new({ size = 8, images = images.new({ api = api }) })
        local path = png()

        out:show({
            cell_id = "a3f9",
            run_id = 1,
            status = "ok",
            lines = { "[картинка] " .. path },
            image = path,
        })

        assert.equals(1, #api.made, "картинка должна быть отрисована")
        local anchor = api.made[1].opts.y
        local shown = vim.api.nvim_buf_get_lines(out.buf, 0, -1, false)
        assert.equals(#shown - 1, anchor, "якорь — последняя строка буфера")
        assert.equals("", shown[#shown], "под картинку добавляется пустая строка")

        out:close()
        assert.equals(1, api.cleared)
        assert.equals(0, vim.tbl_count(api.state.images), "после закрытия окна ничего не остаётся")
    end)

    it("смена прогона снимает прошлую картинку", function()
        local api = fake_api()
        local out = output.new({ size = 8, images = images.new({ api = api }) })
        local path = png()
        out:show({ cell_id = "a3f9", run_id = 1, status = "ok", lines = { "x" }, image = path })

        out:show({ cell_id = "b7e1", run_id = 1, status = "ok", lines = { "текст" } })

        assert.equals(1, api.cleared)
        assert.equals(1, #api.made, "у текстового прогона картинки нет")
        assert.equals(0, vim.tbl_count(api.state.images), "таблица не должна рисоваться поверх картинки")
        out:close()
    end)
end)

describe("картинка следует за ячейкой", function()
    local function make(api)
        local out = output.new({ size = 8, images = images.new({ api = api }) })
        local path = png()
        out:show({ cell_id = "a3f9", run_id = 1, status = "ok", lines = { "график" }, image = path })
        return out, path
    end

    it("уход на другую ячейку снимает картинку", function()
        local api = fake_api()
        local out = make(api)
        assert.equals(1, #api.made)

        out:focus_cell("b7e1")

        assert.equals(1, api.cleared, "картинка не должна висеть над чужой ячейкой")
        assert.equals(0, vim.tbl_count(api.state.images))
        out:close()
    end)

    it("возврат на свою ячейку рисует снова", function()
        local api = fake_api()
        local out = make(api)
        out:focus_cell("b7e1")

        out:focus_cell("a3f9")

        assert.equals(2, #api.made, "картинка вернулась")
        out:close()
    end)

    it("повторный уход не дёргает лишний раз", function()
        local api = fake_api()
        local out = make(api)

        out:focus_cell("b7e1")
        out:focus_cell("b7e1")

        assert.equals(1, api.cleared)
        out:close()
    end)

    it("курсор вне ячеек тоже снимает", function()
        local api = fake_api()
        local out = make(api)

        out:focus_cell(nil)

        assert.equals(1, api.cleared)
        out:close()
    end)

    it("у прогона без картинки делать нечего", function()
        local api = fake_api()
        local out = output.new({ size = 8, images = images.new({ api = api }) })
        out:show({ cell_id = "a3f9", run_id = 1, status = "ok", lines = { "текст" } })

        out:focus_cell("b7e1")

        assert.equals(0, api.cleared)
        out:close()
    end)
end)
