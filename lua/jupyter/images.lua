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

---Снять все картинки, нарисованные в этом буфере.
---
---Почему не одну текущую: image.nvim держит все когда-либо отрисованные картинки в своём
---состоянии и **никогда не удаляет их оттуда**, а на WinScrolled/WinResized перерисовывает
---всё, что знает про окно (image/init.lua:153). Поэтому снятой картинки мало — запись надо
---убрать из состояния, иначе следующая прокрутка вернёт её на экран поверх новой.
---@param buf? integer буфер, в котором чистим; без него — только текущая картинка
function Images:clear(buf)
    local api = self:_api()
    -- намеренно без проверки валидности буфера: у выгруженного как раз и остаётся
    -- мусор в состоянии image.nvim, и его надо снять
    if api and buf then
        local ok, list = pcall(api.get_images, { buffer = buf })
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
    self.current = nil
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

---Обернуть управляющую последовательность для tmux: без passthrough она до терминала
---не дойдёт, tmux её съест.
---@param sequence string
---@return string
function M.tmux_wrap(sequence)
    if not vim.env.TMUX then
        return sequence
    end
    return "\27Ptmux;" .. sequence:gsub("\27", "\27\27") .. "\27\\"
end

---Последовательность kitty «удалить всё».
---
---`d=A` заглавной, а не `d=a`: строчная убирает только размещения, оставляя сами данные
---картинок в терминале, и в Ghostty этого не всегда достаточно. image.nvim шлёт именно
---строчную (`codes.control.delete.all = "a"`), поэтому его clear() не помогает от залипших.
M.PURGE = "\27_Ga=d,d=A\27\\"

---Отправить в терминал команду удаления всех картинок, минуя image.nvim.
---@return boolean
function M.purge_terminal()
    return pcall(vim.api.nvim_chan_send, vim.v.stderr, M.tmux_wrap(M.PURGE))
end

---Стереть вообще все картинки в терминале, включая чужие и осиротевшие.
---
---Нужно, когда на экране остались картинки, о которых текущая сессия не знает: например
---плагин перезагрузили, а нарисованное прошлым процессом осталось. `api.clear()` без id
---уходит в ветку «delete all placements» kitty-бэкенда, то есть чистит сам терминал.
---@return boolean
function Images:clear_terminal()
    local api = self:_api()
    if not api then
        return M.purge_terminal() -- image.nvim может быть не установлен, а картинки висеть
    end
    self.current = nil
    local cleared = pcall(api.clear) == true
    -- добиваем своей последовательностью: image.nvim удаляет только размещения
    M.purge_terminal()
    return cleared
end

return M
