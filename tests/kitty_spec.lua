-- Прямой путь картинок по протоколу kitty (lua/jupyter/kitty.lua): геометрия и
-- последовательности. Терминала в тестах нет, поэтому проверяется то, что уходит в него.

local kitty = require("jupyter.kitty")

-- 1×1 png
local PNG_1X1 = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8DwHwAFAAH/q842iQAAAABJRU5ErkJggg=="

describe("kitty: вписать картинку", function()
    local cell = { w = 14, h = 32 }

    it("широкий график упирается в ширину окна", function()
        -- 2352×754 в окне 193×55 ячеек: по ширине 2702 px, по высоте 1760 px
        local fit = kitty.fit({ w = 2352, h = 754 }, { cols = 193, rows = 55 }, cell)

        assert.same({ cols = 193, col_offset = 0 }, fit)
    end)

    it("высокий упирается в высоту и встаёт по центру", function()
        local fit = kitty.fit({ w = 800, h = 1600 }, { cols = 193, rows = 55 }, cell)

        assert.equals(55, fit.rows)
        assert.is_nil(fit.cols, "вторую сторону терминал выводит из пропорций")
        -- 800 px × (1760/1600) = 880 px = 63 колонки; (193 - 63) / 2
        assert.equals(65, fit.col_offset)
    end)
end)

describe("kitty: последовательности", function()
    it("размер png читается из заголовка", function()
        local path = vim.fn.tempname() .. ".png"
        local f = assert(io.open(path, "wb"))
        f:write(vim.base64.decode(PNG_1X1))
        f:close()

        assert.same({ 1, 1 }, { kitty.png_size(path) })
        assert.is_nil(kitty.png_size("/нет/такого.png"))
    end)

    it("передача файлом, позиция со сдвигом, размещение без сдвига курсора", function()
        local seq = kitty.place_sequence(7, "/x.png", { row = 3, col = 1 }, { rows = 50, col_offset = 10 })

        assert.truthy(seq:find("a=t,t=f,f=100,i=7", 1, true))
        assert.truthy(seq:find(vim.base64.encode("/x.png"), 1, true))
        assert.truthy(seq:find("\27[3;11H", 1, true), "колонка сдвинута на col_offset")
        assert.truthy(seq:find("a=p,i=7,p=1,q=2,C=1,r=50", 1, true))
        assert.truthy(seq:find("\27[s", 1, true) < seq:find("\27[u", 1, true), "курсор сохранён и возвращён")
    end)

    it("удаление — по id, вместе с данными", function()
        assert.equals("\27_Ga=d,d=I,i=7,q=2\27\\", kitty.delete_sequence(7))
    end)

    it("в headless недоступно: терминала нет", function()
        assert.is_false(kitty.available())
    end)

    describe("терминал по окружению", function()
        local list_uis, saved = vim.api.nvim_list_uis, {}
        local NAMES = { "TERM_PROGRAM", "TMUX", "KITTY_WINDOW_ID", "GHOSTTY_RESOURCES_DIR" }

        before_each(function()
            vim.api.nvim_list_uis = function() return { {} } end
            for _, name in ipairs(NAMES) do
                saved[name] = vim.env[name]
                vim.env[name] = nil
            end
        end)

        after_each(function()
            vim.api.nvim_list_uis = list_uis
            for _, name in ipairs(NAMES) do
                vim.env[name] = saved[name]
            end
        end)

        it("Ghostty под herdr: TERM_PROGRAM подменён, переменные Ghostty остались", function()
            vim.env.TERM_PROGRAM = "herdr"
            vim.env.GHOSTTY_RESOURCES_DIR = "/Applications/Ghostty.app/Contents/Resources/ghostty"
            assert.is_true(kitty.available())
        end)

        it("под herdr крупные картинки не напрямую: предел по пикселям", function()
            assert.is_nil(kitty.max_pixels())
            vim.env.TERM_PROGRAM = "herdr"
            local limit = kitty.max_pixels()
            assert.is_true(2383 * 1379 <= limit) -- такие доходили
            assert.is_true(3170 * 3399 > limit) -- такая пропала
        end)

        it("herdr не в Ghostty — через image.nvim", function()
            vim.env.TERM_PROGRAM = "herdr"
            assert.is_false(kitty.available())
        end)

        it("под tmux — через image.nvim, даже в Ghostty", function()
            vim.env.TERM_PROGRAM = "ghostty"
            vim.env.TMUX = "/tmp/tmux-1/default,1,0"
            assert.is_false(kitty.available())
        end)
    end)
end)
