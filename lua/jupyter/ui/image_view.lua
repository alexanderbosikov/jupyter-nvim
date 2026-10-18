-- Картинки прогона во всю вкладку — пара к постраничной таблице (ui/table.lua).
--
-- В окне вывода картинка делит место с текстом, а image.nvim ещё и режет её по своему
-- max_height_window_percentage. Здесь вкладка отдана одной картинке целиком: лимиты
-- размера передаются свои, на 100% окна. <Tab>/<S-Tab> листают картинки ячейки, а за
-- последней — ячейки с картинками дальше по ноутбуку, как <Tab> в таблице.
--
-- Рисует тот же экземпляр jupyter.images, что и окно вывода: снятие картинок у
-- image.nvim глобальное, и два владельца снимали бы друг у друга. Поэтому после закрытия
-- окно вывода надо перерисовать — это делает on_close.

local common = require("jupyter.ui.common")
local hl = require("jupyter.highlight")

local M = {}

M.DEFAULT_KEYS = {
    { mode = "n", key = "<Tab>", action = "image_next" },
    { mode = "n", key = "<S-Tab>", action = "image_prev" },
    { mode = "n", key = "q", action = "close" },
}

---@class jupyter.ImageView
local View = {}
View.__index = View

---@param opts table images (jupyter.Images), keys, on_step, on_close
function M.new(opts)
    return setmetatable({
        images = opts.images,
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
    end
    self:render()
end

function View:render()
    if not self:is_open() then
        return
    end
    local path = self.list[self.index]
    -- одна пустая строка-якорь: картинка рисуется под ней и занимает всё окно
    common.set_lines(self.buf, { "" })
    self:_render_winbar()
    if self.images and path then
        self.images:show_all({ { path = path, row = 0 } }, self.win, self.buf, {
            max_width_window_percentage = 100,
            max_height_window_percentage = 100,
        })
    end
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
    if self.images then
        self.images:clear(self.buf)
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
