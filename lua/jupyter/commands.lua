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
