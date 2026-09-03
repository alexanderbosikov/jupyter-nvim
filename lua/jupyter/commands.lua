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
    cmd("JupyterStatus", function()
        local s = api.status()
        vim.notify(("jupyter.nvim: ядро %s · в очереди %d · ячеек %d"):format(s.state, s.queued, s.cells))
    end, { desc = "состояние ядра" })
end

return M
