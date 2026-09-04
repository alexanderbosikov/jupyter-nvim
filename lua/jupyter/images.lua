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
        send = opts.send, -- куда писать escape-последовательности; тесты подменяют
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

---Снять все картинки, нарисованные в этом буфере.
---
---Почему не одну текущую: image.nvim держит все когда-либо отрисованные картинки в своём
---состоянии и **никогда не удаляет их оттуда**, а на WinScrolled/WinResized перерисовывает
---всё, что знает про окно (image/init.lua:153). Поэтому снятой картинки мало — запись надо
---убрать из состояния, иначе следующая прокрутка вернёт её на экран поверх новой.
---@param buf? integer оставлен для совместимости вызовов; чистим всё равно всё
function Images:clear(buf)
    local api = self:_api()
    if api then
        -- Без фильтра по буферу. С фильтром (`get_images({ buffer = buf })`) картинка на
        -- практике не снималась, хотя собственный обработчик FocusLost у image.nvim —
        -- он перебирает `get_images()` целиком — снимает её надёжно. Разница только в
        -- фильтре, поэтому повторяем то, что доказанно работает.
        local ok, list = pcall(api.get_images)
        if ok then
            for _, image in ipairs(list or {}) do
                pcall(function()
                    image:clear()
                end)
                pcall(function()
                    -- своего API для этого нет, а без удаления картинка воскреснет
                    if image.global_state and image.global_state.images then
                        image.global_state.images[image.id] = nil
                    end
                end)
            end
        end
    elseif self.current then
        pcall(function()
            self.current:clear()
        end)
    end

    -- И добиваем напрямую: удаление в kitty-протоколе — одна последовательность, а вот
    -- рисование мы отдаём image.nvim. `d=A` заглавной убирает и размещения, и данные;
    -- image.nvim шлёт строчную `d=a`, и в Ghostty под tmux этого не хватало.
    M.purge_terminal(self.send)
    self.current = nil
end

---Обернуть последовательность для tmux: без passthrough tmux её съест.
---@param sequence string
---@return string
function M.tmux_wrap(sequence)
    if not vim.env.TMUX then
        return sequence
    end
    return "\27Ptmux;" .. sequence:gsub("\27", "\27\27") .. "\27\\"
end

M.PURGE = "\27_Ga=d,d=A\27\\"

---Куда писать управляющие последовательности. Отдельно, чтобы тесты не сыпали
---escape-кодами в терминал, которым их запустили.
---@param payload string
function M.send(payload)
    pcall(vim.api.nvim_chan_send, vim.v.stderr, payload)
end

---@param send? fun(payload: string)
---@return boolean
function M.purge_terminal(send)
    return pcall(send or M.send, M.tmux_wrap(M.PURGE))
end

---Показать картинку в окне.
---@param path string
---@param win integer
---@param buf integer
---@param row integer строка-якорь, 0-based
---@return boolean показали
function Images:show(path, win, buf, row)
    self:clear(buf)
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
