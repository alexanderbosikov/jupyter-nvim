-- Картинка напрямую по протоколу kitty, с масштабом на стороне терминала.
--
-- Исключение из правила «картинки целиком на image.nvim» (ARCHITECTURE.md §4.4), и только
-- для вкладки картинок. image.nvim подгоняет png под размер окна ImageMagick'ом: на
-- графике 2352×754, растянутом на окно, это ~200 мс перекодирования плюс декодирование
-- большого файла терминалом — полсекунды на каждый показ и каждое листание. Протокол же
-- умеет «нарисуй в N колонок» (`c=`/`r=`): исходный png масштабирует сам терминал, и
-- показ стоит единицы миллисекунд. Проверено в Ghostty под herdr.
--
-- Отсюда и цена: геометрию считаем сами — где окно на экране, сколько пикселей в ячейке,
-- какая сторона упрётся раньше. Поэтому только там, где это надёжно: терминал с
-- протоколом kitty и без tmux (под tmux нужен passthrough и смещение панели — это
-- image.nvim умеет, мы нет). В остальных случаях вкладка рисует через image.nvim.

local M = {}

---Можно ли рисовать напрямую. Терминал узнаём по окружению: запросить его из nvim
---синхронно нечем. herdr (0.9.5) подменяет TERM_PROGRAM на свой, но переменные Ghostty
---остаются — по ним и узнаём Ghostty под herdr.
---@return boolean
function M.available()
    if #vim.api.nvim_list_uis() == 0 or vim.env.TMUX then
        return false
    end
    local program = vim.env.TERM_PROGRAM or ""
    if program == "herdr" then
        return vim.env.GHOSTTY_RESOURCES_DIR ~= nil
    end
    return vim.env.KITTY_WINDOW_ID ~= nil or program == "ghostty" or program == "WezTerm"
end

-- Куда писать: в tty тем же путём, что image.nvim (fd 1). Через vim.v.stderr размещение
-- картинки до herdr не доходило — проверено.
local tty

---@param payload string
function M.send(payload)
    if #vim.api.nvim_list_uis() == 0 then
        return -- headless: терминала нет, а stdout читает прогонщик тестов
    end
    tty = tty or vim.uv.new_tty(1, false)
    if tty then
        pcall(tty.write, tty, payload)
    end
end

---Размер ячейки в пикселях. nil, если терминал его не сообщает (xpixel = 0).
---@return number|nil cell_width
---@return number|nil cell_height
function M.cell_size()
    local ok, ffi = pcall(require, "ffi")
    if not ok then
        return nil
    end
    pcall(ffi.cdef, [[
        typedef struct { unsigned short row, col, xpixel, ypixel; } jupyter_winsize;
        int ioctl(int, unsigned long, ...);
    ]])
    local request = vim.fn.has("mac") == 1 and 0x40087468 or 0x5413 -- TIOCGWINSZ
    local size = ffi.new("jupyter_winsize")
    if ffi.C.ioctl(1, request, size) ~= 0 or size.xpixel == 0 or size.col == 0 then
        return nil
    end
    return size.xpixel / size.col, size.ypixel / size.row
end

---Размер png из заголовка: ширина и высота лежат в IHDR, байты 17–24.
---@param path string
---@return integer|nil width
---@return integer|nil height
function M.png_size(path)
    local f = io.open(path, "rb")
    if not f then
        return nil
    end
    local head = f:read(24)
    f:close()
    if not head or #head < 24 or head:sub(2, 4) ~= "PNG" then
        return nil
    end
    local function u32(at)
        local a, b, c, d = head:byte(at, at + 3)
        return ((a * 256 + b) * 256 + c) * 256 + d
    end
    return u32(17), u32(21)
end

---Вписать картинку в область: во всю ширину или во всю высоту, смотря что упрётся
---раньше, и целиком. Чистая функция — геометрия проверяется тестом без терминала.
---@param img { w: number, h: number } пиксели картинки
---@param area { cols: integer, rows: integer } ячейки области
---@param cell { w: number, h: number }|nil пиксели ячейки; nil — неизвестны
---@return { cols: integer|nil, rows: integer|nil, col_offset: integer }
---  задаётся одна сторона, вторую терминал выводит из пропорций
function M.fit(img, area, cell)
    if not cell then
        -- без размера ячейки высоту не проверить: во всю ширину, и пусть терминал решает
        return { cols = area.cols, col_offset = 0 }
    end
    local by_width = (area.cols * cell.w) / img.w
    local by_height = (area.rows * cell.h) / img.h
    if by_width <= by_height then
        return { cols = area.cols, col_offset = 0 }
    end
    -- упёрлись в высоту: ширина выходит меньше окна — ставим по центру
    local cols = math.min(area.cols, math.ceil(img.w * by_height / cell.w))
    return { rows = area.rows, col_offset = math.floor((area.cols - cols) / 2) }
end

---Последовательности показа картинки: передать файл, встать в позицию, разместить.
---@param id integer id картинки в терминале
---@param path string
---@param screen { row: integer, col: integer } 1-based позиция левого верхнего угла
---@param fit table из M.fit
---@return string
function M.place_sequence(id, path, screen, fit)
    local size = (fit.cols and (",c=" .. fit.cols) or "") .. (fit.rows and (",r=" .. fit.rows) or "")
    return table.concat({
        -- a=t: передать, t=f: файлом (байты не идут через tty), f=100: png
        ("\27_Ga=t,t=f,f=100,i=%d,q=2;%s\27\\"):format(id, vim.base64.encode(path)),
        "\27[s", -- курсор nvim сохранить: размещение встаёт в позицию курсора
        ("\27[%d;%dH"):format(screen.row, screen.col + fit.col_offset),
        -- C=1: курсор не двигать, иначе nvim дорисует свой экран со сдвигом
        ("\27_Ga=p,i=%d,p=1,q=2,C=1%s\27\\"):format(id, size),
        "\27[u",
    })
end

---Удалить картинку с данными из терминала.
---@param id integer
---@return string
function M.delete_sequence(id)
    return ("\27_Ga=d,d=I,i=%d,q=2\27\\"):format(id)
end

return M
