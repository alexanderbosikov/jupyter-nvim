-- Картинки во всю вкладку (lua/jupyter/ui/image_view.lua). Рендер — забота image.nvim,
-- поэтому вместо jupyter.images — запись вызовов: что показали, с какими лимитами, когда сняли.

local image_view = require("jupyter.ui.image_view")

local PNG_1X1 = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8DwHwAFAAH/q842iQAAAABJRU5ErkJggg=="

local function png_file()
    local path = vim.fn.tempname() .. ".png"
    local f = assert(io.open(path, "wb"))
    f:write(vim.base64.decode(PNG_1X1))
    f:close()
    return path
end

-- терминала в тестах нет: размер ячейки — как у Ghostty на retina
local function CELL()
    return 14, 32
end

local function fake_images()
    local rec = { shown = {}, cleared = 0 }
    function rec:show_all(list, win, buf, extra)
        table.insert(self.shown, { path = list[1].path, row = list[1].row, win = win, buf = buf, extra = extra })
        return true
    end
    function rec:clear()
        self.cleared = self.cleared + 1
    end
    return rec
end

describe("картинки во всю вкладку", function()
    local tabs_before

    before_each(function()
        tabs_before = #vim.api.nvim_list_tabpages()
    end)

    after_each(function()
        -- вкладку за собой убираем, даже если тест упал посередине
        while #vim.api.nvim_list_tabpages() > tabs_before do
            vim.cmd("tabclose!")
        end
    end)

    it("открывает отдельную вкладку и рисует первую картинку на всё окно", function()
        local img = fake_images()
        local view = image_view.new({ images = img })

        view:open({ "/a.png", "/b.png" }, "ячейка a3f9 · прогон 3", "a3f9")

        assert.equals(tabs_before + 1, #vim.api.nvim_list_tabpages())
        assert.equals("/a.png", img.shown[1].path)
        assert.equals(view.win, img.shown[1].win)
        -- вписывается в окно: ширина — всё окно, высота — без строки-якоря
        assert.same({
            width = vim.api.nvim_win_get_width(view.win),
            height = vim.api.nvim_win_get_height(view.win) - 1,
            max_width_window_percentage = 100,
            max_height_window_percentage = 100,
        }, img.shown[1].extra)
        assert.matches("^1/2", view:status())
    end)

    it("Tab листает картинки ячейки, на краю спрашивает соседнюю ячейку", function()
        local img = fake_images()
        local asked = {}
        local view = image_view.new({
            images = img,
            on_step = function(dir)
                table.insert(asked, dir)
                return false
            end,
        })
        view:open({ "/a.png", "/b.png" }, nil, "a3f9")

        view:get_actions().image_next()
        assert.equals("/b.png", img.shown[#img.shown].path)
        assert.matches("^2/2", view:status())
        assert.same({}, asked, "внутри ячейки соседку не ищем")

        assert.is_false(view:step(1))
        assert.same({ 1 }, asked, "за последней — к ячейке ниже")
        assert.matches("^2/2", view:status(), "не нашлась — остаёмся на месте")

        view:get_actions().image_prev()
        view:get_actions().image_prev()
        assert.same({ 1, -1 }, asked, "перед первой — к ячейке выше")
    end)

    it("шаг назад из соседки открывает её с последней картинки", function()
        local view = image_view.new({ images = fake_images() })

        view:open({ "/a.png", "/b.png", "/c.png" }, nil, "b7e1", -1)

        assert.matches("^3/3", view:status())
    end)

    it("q закрывает вкладку, снимает картинку и отдаёт экран окну вывода — один раз", function()
        local img = fake_images()
        local closed = 0
        local view = image_view.new({ images = img, on_close = function() closed = closed + 1 end })
        view:open({ "/a.png" }, nil, "a3f9")

        view:get_actions().close()
        vim.wait(50)

        assert.equals(tabs_before, #vim.api.nvim_list_tabpages())
        assert.equals(1, img.cleared)
        assert.equals(1, closed)
    end)

    it(":tabclose тоже возвращает окно вывода", function()
        local img = fake_images()
        local closed = 0
        local view = image_view.new({ images = img, on_close = function() closed = closed + 1 end })
        view:open({ "/a.png" }, nil, "a3f9")

        vim.cmd("tabclose")
        vim.wait(200, function() return closed > 0 end)

        assert.equals(1, closed)
        assert.equals(1, img.cleared)
    end)

    it("повторное открытие переиспользует вкладку", function()
        local view = image_view.new({ images = fake_images() })
        view:open({ "/a.png" }, nil, "a3f9")

        view:open({ "/x.png", "/y.png" }, nil, "b7e1")

        assert.equals(tabs_before + 1, #vim.api.nvim_list_tabpages())
        assert.equals("b7e1", view.cell_id)
    end)

    it("напрямую по kitty: размещает сам, листание меняет картинку, закрытие удаляет", function()
        local png = vim.base64.decode("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8DwHwAFAAH/q842iQAAAABJRU5ErkJggg==")
        local a, b = vim.fn.tempname() .. ".png", vim.fn.tempname() .. ".png"
        for _, path in ipairs({ a, b }) do
            local f = assert(io.open(path, "wb"))
            f:write(png)
            f:close()
        end
        local img, sent = fake_images(), {}
        local view = image_view.new({ images = img, direct = true, cell_size = CELL, send = function(s) table.insert(sent, s) end })

        view:open({ a, b }, nil, "a3f9")
        assert.equals(0, #img.shown, "image.nvim не участвует")
        assert.truthy(sent[1]:find(vim.base64.encode(a), 1, true))
        local first = view.direct_id

        view:get_actions().image_next()
        assert.equals(("\27_Ga=d,d=I,i=%d,q=2\27\\"):format(first), sent[2], "прошлую удалили")
        assert.truthy(sent[3]:find(vim.base64.encode(b), 1, true))

        view:get_actions().close()
        assert.truthy(sent[#sent]:find("a=d,d=I", 1, true))
        assert.is_nil(view.direct_id)
    end)

    it("в фоновой вкладке не рисует: картинка легла бы поверх текущей", function()
        local sent = {}
        local view = image_view.new({ images = fake_images(), direct = true, cell_size = CELL, send = function(s) table.insert(sent, s) end })
        view:open({ png_file() }, nil, "a3f9")

        vim.cmd("tabprevious")
        assert.truthy(sent[#sent]:find("a=d,d=I", 1, true), "уход с вкладки снимает картинку")
        local before = #sent
        view:render() -- то же, что делают WinResized и возврат фокуса
        vim.wait(50)

        assert.is_true(view:is_open())
        assert.is_false(view:is_visible())
        assert.equals(before, #sent, "в терминал ничего не ушло")
    end)

    it("открытие при вкладке в фоне переходит в неё", function()
        local sent = {}
        local view = image_view.new({ images = fake_images(), direct = true, cell_size = CELL, send = function(s) table.insert(sent, s) end })
        local b = png_file()
        view:open({ png_file() }, nil, "a3f9")
        vim.cmd("tabprevious")

        view:open({ b }, nil, "b7e1")

        assert.equals(view.win, vim.api.nvim_get_current_win())
        assert.equals(tabs_before + 1, #vim.api.nvim_list_tabpages())
        assert.truthy(sent[#sent]:find(vim.base64.encode(b), 1, true))
    end)

    it("hide снимает картинку, вкладка остаётся", function()
        local sent = {}
        local view = image_view.new({ images = fake_images(), direct = true, cell_size = CELL, send = function(s) table.insert(sent, s) end })
        view:open({ png_file() }, nil, "a3f9")

        view:hide()

        assert.truthy(sent[#sent]:find("a=d,d=I", 1, true))
        assert.is_nil(view.direct_id)
        assert.is_true(view:is_visible())
    end)

    it("у двух ноутбуков свои подписки: вторая вкладка не отключает первую", function()
        local sent1, sent2 = {}, {}
        local v1 = image_view.new({ images = fake_images(), direct = true, cell_size = CELL, send = function(s) table.insert(sent1, s) end })
        local v2 = image_view.new({ images = fake_images(), direct = true, cell_size = CELL, send = function(s) table.insert(sent2, s) end })
        v1:open({ png_file() }, nil, "a3f9")
        local tab1 = vim.api.nvim_get_current_tabpage()
        v2:open({ png_file() }, nil, "b7e1")
        vim.api.nvim_set_current_tabpage(tab1)
        vim.wait(200, function() return v1.direct_id ~= nil end) -- TabEnter рисует через schedule
        local before = #sent1

        vim.cmd("tabprevious") -- уходим с вкладки первого

        assert.truthy(#sent1 > before and sent1[#sent1]:find("a=d,d=I", 1, true), "первый снял свою картинку")
    end)

    it("svg → png: картинка image.nvim снимается, прежде чем рисовать напрямую", function()
        local img = fake_images()
        local view = image_view.new({ images = img, direct = true, cell_size = CELL, send = function() end })
        view:open({ "/нет/такого.svg", png_file() }, nil, "a3f9")
        assert.equals(1, #img.shown, "svg рисует image.nvim")

        view:get_actions().image_next()

        assert.equals(1, img.cleared)
        assert.equals(1, #img.shown)
        assert.truthy(view.direct_id)
    end)

    it("терминал не дал размер ячейки — рисует image.nvim, не напрямую", function()
        local img, sent = fake_images(), {}
        local view = image_view.new({
            images = img,
            direct = true,
            cell_size = function() return nil end,
            send = function(s) table.insert(sent, s) end,
        })

        view:open({ png_file() }, nil, "a3f9")

        assert.equals(1, #img.shown)
        assert.equals(0, #sent)
    end)

    it("картинка крупнее предела терминала — рисует image.nvim, не напрямую", function()
        local img, sent = fake_images(), {}
        local view = image_view.new({
            images = img,
            direct = true,
            cell_size = CELL,
            max_pixels = 0, -- png 1×1 уже крупнее
            send = function(s) table.insert(sent, s) end,
        })

        view:open({ png_file() }, nil, "a3f9")

        assert.equals(1, #img.shown)
        assert.equals(0, #sent)
    end)

    it("напрямую не png — рисует image.nvim", function()
        local img = fake_images()
        local view = image_view.new({ images = img, direct = true, cell_size = CELL, send = function() end })

        view:open({ "/нет/такого.svg" }, nil, "a3f9")

        assert.equals("/нет/такого.svg", img.shown[1].path)
    end)
end)
