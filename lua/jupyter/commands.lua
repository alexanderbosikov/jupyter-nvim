-- Пользовательские команды. Тонкая обёртка над публичным API: логики здесь нет,
-- чтобы то же самое можно было позвать из своих мапов без команд вообще.

local M = {}

---@param api table модуль jupyter
function M.setup(api)
    local function cmd(name, fn, opts)
        vim.api.nvim_create_user_command(name, fn, opts or {})
    end

    cmd("JupyterStart", function() api.ensure_started() end, { desc = "поднять ядро для этого буфера" })
    cmd("JupyterRun", function() api.run_cell() end, { desc = "выполнить ячейку под курсором" })
    cmd("JupyterRunAll", function() api.run_all() end, { desc = "выполнить все ячейки" })
    cmd("JupyterRunBelow", function() api.run_below() end, { desc = "выполнить с текущей ячейки и ниже" })
    cmd("JupyterInterrupt", function() api.interrupt() end, { desc = "прервать выполнение" })
    cmd("JupyterRestart", function() api.restart() end, { desc = "перезапустить ядро" })
    cmd("JupyterOutput", function() api.toggle_output() end, { desc = "показать или скрыть вывод" })
    cmd("JupyterStop", function() api.detach(vim.api.nvim_get_current_buf()) end, { desc = "погасить ядро" })
    cmd("JupyterTable", function() api.open_table() end, { desc = "постраничный просмотр таблицы" })
    cmd("JupyterLog", function() api.show_log() end, { desc = "журнал сайдкара и состояний ядра" })
    cmd("JupyterClearImages", function()
        if not api.clear_images() then
            vim.notify("jupyter.nvim: сессии для этого буфера нет", vim.log.levels.WARN)
        end
    end, { desc = "снять все картинки" })
    cmd("JupyterToc", function() api.show_toc() end, { desc = "оглавление ноутбука" })
    cmd("JupyterSplit", function() api.split_cell() end, { desc = "разрезать ячейку по курсору" })
    cmd("JupyterMerge", function() api.merge_cell() end, { desc = "склеить со следующей ячейкой" })
    cmd("JupyterMoveUp", function() api.move_cell_up() end, { desc = "переставить ячейку выше" })
    cmd("JupyterMoveDown", function() api.move_cell_down() end, { desc = "переставить ячейку ниже" })
    cmd("JupyterToMarkdown", function() api.cell_to_markdown() end, { desc = "ячейку в markdown" })
    cmd("JupyterToCode", function() api.cell_to_code() end, { desc = "markdown под курсором в код" })
    cmd("JupyterCellArgs", function(a)
        api.cell_args(a.args)
    end, { nargs = "*", desc = "параметры магики ячейки: df_name=orders" })
    cmd("JupyterRelease", function()
        api.release()
    end, { desc = "отпустить ядро: выйти, оставив его жить" })
    cmd("JupyterAttach", function()
        api.attach()
    end, { desc = "подключиться к ядру от прошлой сессии" })
    cmd("JupyterOrphans", function(a)
        api.orphans(a.bang)
    end, { bang = true, desc = "ядра без хозяина: показать, с ! — снять" })
    cmd("JupyterRepaint", function() api.repaint() end, { desc = "перерисовать статусы ячеек" })
    cmd("JupyterRunPrev", function() api.prev_run() end, { desc = "предыдущий прогон этой ячейки" })
    cmd("JupyterRunNext", function() api.next_run() end, { desc = "следующий прогон этой ячейки" })
    cmd("JupyterHistory", function() api.reload_history() end, { desc = "перечитать историю прогонов" })
    cmd("JupyterStatus", function()
        local s = api.status()
        vim.notify(("jupyter.nvim: ядро %s · в очереди %d · ячеек %d · в истории %d прогонов по %d ячейкам")
            :format(s.state, s.queued, s.cells, s.history_runs, s.history_cells))
    end, { desc = "состояние ядра" })
end

return M
