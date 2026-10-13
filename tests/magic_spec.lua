-- Строки-магики в python-ячейках (lua/jupyter/magic.lua): что считается магикой.

local magic = require("jupyter.magic")

describe("magic.match", function()
    it("ловит line- и cell-магики и shell", function()
        assert.is_true(magic.match("%connect rs"))
        assert.is_true(magic.match("%%time"))
        assert.is_true(magic.match("    %matplotlib inline"))
        assert.is_true(magic.match("!pip list"))
    end)

    it("не трогает обычный python", function()
        assert.is_false(magic.match("x = 10 % 3"))
        assert.is_false(magic.match("print('%s' % x)"))
        assert.is_false(magic.match("if not x != y:"))
        assert.is_false(magic.match("% 3"))
        assert.is_false(magic.match(""))
    end)
end)

describe("magic.name_range", function()
    it("отделяет имя магики от аргументов", function()
        assert.same({ 0, 8 }, { magic.name_range("%connect rs") })
        assert.same({ 2, 8 }, { magic.name_range("  %%time") })
        assert.same({ 0, 4 }, { magic.name_range("!pip list") })
    end)
end)
