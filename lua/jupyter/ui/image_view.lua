-- Картинки прогона во всю вкладку — пара к постраничной таблице (ui/table.lua).
--
-- В окне вывода картинка делит место с текстом, а image.nvim ещё и режет её по своему
-- max_height_window_percentage. Здесь вкладка отдана одной картинке целиком: она
-- вписывается в окно — во всю ширину или во всю высоту, смотря что упрётся раньше, и
-- видна целиком (см. View:geometry). <Tab>/<S-Tab> листают картинки ячейки, а за
-- последней — ячейки с картинками дальше по ноутбуку, как <Tab> в таблице.
--
-- Рисует двумя путями. Где можно — напрямую по протоколу kitty (jupyter.kitty): масштаб
-- считает терминал, и показ мгновенный. Иначе — тем же экземпляром jupyter.images, что и
-- окно вывода: снятие картинок у image.nvim глобальное, и два владельца снимали бы друг у
-- друга. В обоих случаях после закрытия окно вывода перерисовывается — это делает on_close.

local common = require("jupyter.ui.common")
local hl = require("jupyter.highlight")
local kitty = require("jupyter.kitty")

-- id картинок в терминале: свой диапазон, чтобы не задеть картинки image.nvim
local direct_seq = 0x4A4E0000

local M = {}

M.DEFAULT_KEYS = {
    { mode = "n", key = "<Tab>", action = "image_next" },
    { mode = "n", key = "<S-Tab>", action = "image_prev" },
    { mode = "n", key = "q", action = "close" },
}

---@class jupyter.ImageView
local View = {}
View.__index = View

---@param opts table images (jupyter.Images), keys, on_step, on_close,
---  direct (рисовать по kitty напрямую; nil — где терминал позволяет), send и cell_size (для тестов),
---  max_pixels (крупнее — через image.nvim; nil — по терминалу, false — без предела)
function M.new(opts)
    local direct = opts.direct
    if direct == nil then
        direct = kitty.available()
    end
    local max_pixels = opts.max_pixels
    if max_pixels == nil then
        max_pixels = kitty.max_pixels() or false
    end
    return setmetatable({
        images = opts.images,
        direct = direct,
        max_pixels = max_pixels,
        send = opts.send or kitty.send,
        cell_size = opts.cell_size or kitty.cell_size,
        direct_id = nil, -- id картинки, нарисованной напрямую и ещё не удалённой
        nvim_shown = false, -- на экране картинка от image.nvim (svg, или терминал не дал размер ячейки)
        keys = opts.keys or M.DEFAULT_KEYS,
        -- переход к соседней ячейке с картинками: какая соседняя, знает ноутбук, не окно.
        -- fun(dir: 1|-1): boolean — нашлась ли
        on_step = opts.on_step,
        on_close = opts.on_close,
        buf = nil,
        win = nil,
        list = {}, -- пути к картинкам ячейки, по порядку
        index = 1,
        label = nil,
        cell_id = nil, -- чьи картинки на экране: от неё ищется соседняя ячейка
    }, View)
end

function View:is_open()
    return self.win ~= nil and vim.api.nvim_win_is_valid(self.win)
end

---Вкладка не просто открыта, а на экране. Картинка, нарисованная напрямую, — это терминал:
---нарисованная из фоновой вкладки, она легла бы поверх текущей.
function View:is_visible()
    return self:is_open() and vim.api.nvim_win_get_tabpage(self.win) == vim.api.nvim_get_current_tabpage()
end

---Снять картинку с экрана, не закрывая вкладку: ушёл фокус. Вернёт её render.
function View:hide()
    self:_direct_clear()
end

function View:_ensure_buf()
    if self.buf and vim.api.nvim_buf_is_valid(self.buf) then
        return self.buf
    end
    self.buf = common.scratch_buf("jupyter://image", "jupyter-image")
    common.apply_keys(self.buf, self:get_actions(), self.keys)
    -- вкладку закрыли не нашим q (:tabclose, :q) — окно вывода всё равно надо вернуть
    vim.api.nvim_create_autocmd("BufWinLeave", {
        buffer = self.buf,
        callback = function()
            vim.schedule(function()
                if not self:is_open() then
                    self:_closed()
                end
            end)
        end,
    })
    return self.buf
end

---Открыть картинки ячейки. Отдельная вкладка, как у таблицы: q возвращает ноутбук нетронутым.
---@param list string[] пути к картинкам, по порядку
---@param label? string что показать в winbar
---@param cell_id? string ячейка, чьи это картинки
---@param index? integer с какой начать; -1 — с последней (шаг назад из следующей ячейки)
function View:open(list, label, cell_id, index)
    self.list = list
    self.label = label
    self.cell_id = cell_id
    self.index = (index == -1) and #list or math.max(1, math.min(index or 1, #list))

    local buf = self:_ensure_buf()
    if not self:is_open() then
        vim.cmd("tab split") -- не tabnew: иначе плодятся пустые [No Name]
        self.win = vim.api.nvim_get_current_win()
        vim.api.nvim_win_set_buf(self.win, buf)
        vim.wo[self.win].number = false
        vim.wo[self.win].relativenumber = false
        vim.wo[self.win].signcolumn = "no"
        vim.wo[self.win].cursorline = false
        self._open = true
        -- своя группа на каждый вид: у двух ноутбуков две вкладки картинок
        local group = vim.api.nvim_create_augroup("jupyter.image_view." .. buf, { clear = true })
        -- размер вписан в окно в ячейках: окно поменялось — вписать заново
        vim.api.nvim_create_autocmd({ "WinResized", "VimResized" }, {
            group = group,
            callback = function()
                if not self:is_open() then
                    return true -- вкладки нет — и подписка больше не нужна
                end
                vim.schedule(function() self:render() end)
            end,
        })
        -- картинка, нарисованная напрямую, — это терминал, а не nvim: при уходе с вкладки
        -- она осталась бы висеть поверх чужого окна. Снимаем и возвращаем сами
        vim.api.nvim_create_autocmd("TabLeave", {
            group = group,
            callback = function()
                if not self:is_open() then
                    return true
                end
                if vim.api.nvim_win_get_tabpage(self.win) == vim.api.nvim_get_current_tabpage() then
                    self:_direct_clear()
                end
            end,
        })
        vim.api.nvim_create_autocmd("TabEnter", {
            group = group,
            callback = function()
                if not self:is_open() then
                    return true
                end
                if vim.api.nvim_win_get_tabpage(self.win) == vim.api.nvim_get_current_tabpage() then
                    vim.schedule(function() self:render() end)
                end
            end,
        })
    elseif not self:is_visible() then
        -- вкладка открыта в фоне: перейти в неё, а не рисовать в спрятанное окно
        vim.api.nvim_set_current_win(self.win)
    end
    self:render()
end

---Нарисовать текущую картинку. Только на экране: фоновую вкладку дорисует TabEnter.
function View:render()
    if not self:is_visible() then
        return
    end
    local path = self.list[self.index]
    -- одна пустая строка-якорь: картинка рисуется под ней и занимает всё окно
    common.set_lines(self.buf, { "" })
    self:_render_winbar()
    if not path then
        return
    end
    if self.direct and self:_direct_show(path) then
        return
    end
    if self.images then
        self.images:show_all({ { path = path, row = 0 } }, self.win, self.buf, self:geometry())
        self.nvim_shown = true
    end
end

---Нарисовать напрямую по kitty: исходный png, масштаб — на стороне терминала.
---@param path string
---@return boolean получилось; нет — рисует image.nvim
function View:_direct_show(path)
    self:_direct_clear()
    local w, h = kitty.png_size(path)
    if not w then
        return false -- не png (svg, битый файл): это image.nvim умеет, мы нет
    end
    if self.max_pixels and w * h > self.max_pixels then
        return false -- терминал такую не донесёт (kitty.max_pixels): image.nvim ужмёт под окно
    end
    local cw, ch = self.cell_size()
    if not cw then
        -- терминал не сообщает пиксели ячейки: высоту не проверить, и высокая картинка
        -- вылезла бы на statusline. image.nvim вписывает сам
        return false
    end
    -- до этого на экране могла быть картинка image.nvim (svg той же ячейки): снять её,
    -- пока своей ещё нет — снятие у image.nvim может задеть все картинки терминала
    if self.nvim_shown and self.images then
        self.images:clear(self.buf)
        self.nvim_shown = false
    end
    local fit = kitty.fit(
        { w = w, h = h },
        { cols = vim.api.nvim_win_get_width(self.win), rows = vim.api.nvim_win_get_height(self.win) },
        { w = cw, h = ch }
    )
    -- экран nvim должен быть уже нарисован: TUI, дорисовывая вкладку после нас, мог бы
    -- очистить экран, а с ним и наше размещение
    vim.cmd("redraw")
    local pos = vim.api.nvim_win_get_position(self.win) -- 0-based, вместе с winbar
    local winbar = vim.wo[self.win].winbar ~= "" and 1 or 0
    direct_seq = direct_seq + 1
    self.direct_id = direct_seq
    self.send(kitty.place_sequence(self.direct_id, path, { row = pos[1] + winbar + 1, col = pos[2] + 1 }, fit))
    return true
end

---Удалить картинку, нарисованную напрямую.
function View:_direct_clear()
    if self.direct_id then
        self.send(kitty.delete_sequence(self.direct_id))
        self.direct_id = nil
    end
end

---Размер картинки для image.nvim: всё окно под строкой-якорем.
---
---Сам image.nvim картинку не увеличивает — без размера она рисуется в родных пикселях,
---и график на 1100 px занимает треть экрана. Заданные же ширину и высоту он подгоняет
---под пропорции картинки, оставляя меньший из двух масштабов (adjust_to_aspect_ratio):
---картинка упирается в ширину или в высоту окна и не вылезает за другую. Свои лимиты
---в процентах окна снимаем — иначе глобальные 50% высоты урезали бы и здесь.
---@return table опции поверх jupyter.images
function View:geometry()
    return {
        width = vim.api.nvim_win_get_width(self.win),
        -- первая строка — якорь, картинка встаёт под ней
        height = math.max(1, vim.api.nvim_win_get_height(self.win) - 1),
        max_width_window_percentage = 100,
        max_height_window_percentage = 100,
    }
end

---Шаг по картинкам: внутри ячейки, а за краем — к соседней ячейке с картинками.
---@param dir 1|-1
---@return boolean сдвинулись ли
function View:step(dir)
    local next_index = self.index + dir
    if self.list[next_index] then
        self.index = next_index
        self:render()
        return true
    end
    if self.on_step and self.on_step(dir) then
        return true
    end
    vim.notify(
        dir > 0 and "jupyter.nvim: дальше картинок нет" or "jupyter.nvim: раньше картинок нет",
        vim.log.levels.INFO
    )
    return false
end

---Строка статуса: какая картинка из скольких. Отдельно — её удобно проверять тестом.
---@return string
function View:status()
    if #self.list == 0 then
        return "нет картинок"
    end
    return ("%d/%d · <Tab>/<S-Tab> листать · q закрыть"):format(self.index, #self.list)
end

function View:_render_winbar()
    vim.wo[self.win].winbar = table.concat({
        hl.wrap("JupyterWinBar", " " .. common.escape_status(self.label or "картинка")),
        "%=",
        hl.wrap("JupyterWinBarInfo", common.escape_status(self:status())),
        hl.wrap("JupyterWinBar", " "),
    })
end

function View:close()
    self:_direct_clear()
    if self:is_open() then
        local win = self.win
        self.win = nil
        pcall(vim.api.nvim_win_close, win, true)
    end
    self.win = nil
    self:_closed()
end

---Вкладки больше нет: снять свою картинку и отдать экран окну вывода. Ровно один раз,
---как бы ни закрыли — q или :tabclose.
function View:_closed()
    if not self._open then
        return
    end
    self._open = false
    self:_direct_clear()
    if self.images then
        self.images:clear(self.buf)
        self.nvim_shown = false
    end
    if self.on_close then
        self.on_close()
    end
end

---@return table<string, fun()>
function View:get_actions()
    return {
        image_next = function() self:step(1) end,
        image_prev = function() self:step(-1) end,
        close = function() self:close() end,
    }
end

return M
