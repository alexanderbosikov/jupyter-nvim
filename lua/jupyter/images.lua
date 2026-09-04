-- Картинки — целиком на image.nvim (ARCHITECTURE.md §4.4).
--
-- Мы не рисуем ничего сами и не считаем геометрию: сайдкар кладёт png файлом рядом с
-- выводами, мы отдаём путь и строку-якорь. Самая забагованная зона molten (наложение
-- картинок, сбитые позиции при правках) не воспроизводится ровно потому, что картинка
-- живёт в окне вывода, а не поверх кода в ноутбуке.

local M = {}

---Доступен ли image.nvim.
---@return boolean, table|nil
function M.available()
    local ok, api = pcall(require, "image")
    if ok and type(api) == "table" and type(api.from_file) == "function" then
        return true, api
    end
    return false, nil
end

---@class jupyter.Images
local Images = {}
Images.__index = Images

---@param opts? table enabled, api (для тестов)
function M.new(opts)
    opts = opts or {}
    return setmetatable({
        enabled = opts.enabled ~= false,
        api = opts.api, -- подменяется в тестах
        current = nil,
        _seq = 0,
    }, Images)
end

function Images:_api()
    if self.api then
        return self.api
    end
    local ok, api = M.available()
    return ok and api or nil
end

function Images:clear()
    if self.current then
        pcall(function()
            self.current:clear()
        end)
        self.current = nil
    end
end

---Показать картинку в окне.
---@param path string
---@param win integer
---@param buf integer
---@param row integer строка-якорь, 0-based
---@return boolean показали
function Images:show(path, win, buf, row)
    self:clear()
    if not self.enabled or not path then
        return false
    end
    local api = self:_api()
    if not api then
        return false
    end
    if vim.fn.filereadable(path) == 0 then
        return false
    end

    -- id уникальный на показ: from_file с уже занятым id возвращает СТАРУЮ картинку,
    -- и в окне осталась бы предыдущая
    self._seq = self._seq + 1
    local ok, image = pcall(api.from_file, path, {
        id = ("jupyter:%d:%d"):format(buf, self._seq),
        window = win,
        buffer = buf,
        x = 0,
        y = row,
        with_virtual_padding = true,
        inline = true,
    })
    if not ok or not image then
        return false
    end

    self.current = image
    return pcall(function()
        image:render()
    end)
end

return M
