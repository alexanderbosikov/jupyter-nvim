-- Картинки. Сам рендер — забота image.nvim, поэтому проверяется наша часть:
-- что путь и якорь отдаются один раз, прошлая картинка снимается, а отсутствие
-- image.nvim или файла не роняет окно вывода.

local images = require("jupyter.images")
local output = require("jupyter.ui.output")

local function fake_api()
    local api = { made = {}, cleared = 0 }
    api.from_file = function(path, opts)
        local image = {
            path = path,
            opts = opts,
            rendered = 0,
            render = function(self) self.rendered = self.rendered + 1 end,
            clear = function() api.cleared = api.cleared + 1 end,
        }
        table.insert(api.made, image)
        return image
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

    it("clear снимает текущую", function()
        local api = fake_api()
        local im = images.new({ api = api })
        im:show(png(), 1, 2, 0)

        im:clear()
        im:clear()

        assert.equals(1, api.cleared)
        assert.is_nil(im.current)
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
    end)

    it("смена прогона снимает прошлую картинку", function()
        local api = fake_api()
        local out = output.new({ size = 8, images = images.new({ api = api }) })
        local path = png()
        out:show({ cell_id = "a3f9", run_id = 1, status = "ok", lines = { "x" }, image = path })

        out:show({ cell_id = "b7e1", run_id = 1, status = "ok", lines = { "текст" } })

        assert.equals(1, api.cleared)
        assert.equals(1, #api.made, "у текстового прогона картинки нет")
        out:close()
    end)
end)
