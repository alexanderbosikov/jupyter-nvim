-- Подсветка winbar'ов: контраст от Normal, смысл от Diagnostic*, переживание смены темы.

local highlight = require("jupyter.highlight")
local output = require("jupyter.ui.output")

local function fg(name)
    return vim.api.nvim_get_hl(0, { name = name, link = false }).fg
end

describe("группы", function()
    before_each(function()
        highlight._forget()
        for name in pairs(highlight.GROUPS) do
            pcall(vim.api.nvim_set_hl, 0, name, {})
        end
    end)

    it("основной текст берёт контраст от Normal", function()
        vim.api.nvim_set_hl(0, "Normal", { fg = "#c8d0e0", bg = "#101014" })
        vim.api.nvim_set_hl(0, "WinBar", { fg = "#404050", bg = "#181820" })

        highlight.setup()

        assert.equals(fg("Normal"), fg("JupyterWinBar"), "текст не должен быть тусклее Normal")
        assert.are_not.equals(fg("WinBar"), fg("JupyterWinBar"))
        assert.equals(
            vim.api.nvim_get_hl(0, { name = "WinBar", link = false }).bg,
            vim.api.nvim_get_hl(0, { name = "JupyterWinBar", link = false }).bg,
            "фон остаётся winbar'овским"
        )
    end)

    it("статусы берут смысловые цвета темы", function()
        vim.api.nvim_set_hl(0, "DiagnosticOk", { fg = "#79b360" })
        vim.api.nvim_set_hl(0, "DiagnosticError", { fg = "#c05a5a" })
        vim.api.nvim_set_hl(0, "DiagnosticWarn", { fg = "#c2a04a" })

        highlight.setup()

        assert.equals(fg("DiagnosticOk"), fg("JupyterWinBarOk"))
        assert.equals(fg("DiagnosticError"), fg("JupyterWinBarError"))
        assert.equals(fg("DiagnosticWarn"), fg("JupyterWinBarWarn"))
    end)

    it("без Diagnostic* берёт запасную группу", function()
        for _, name in ipairs({ "DiagnosticOk", "DiagnosticError", "DiagnosticWarn", "DiagnosticInfo" }) do
            pcall(vim.api.nvim_set_hl, 0, name, {})
        end
        vim.api.nvim_set_hl(0, "String", { fg = "#60a060" })

        highlight.setup()

        assert.equals(fg("String"), fg("JupyterWinBarOk"))
    end)

    it("переопределяется после смены темы", function()
        local group = vim.api.nvim_create_augroup("jupyter.highlight.test", { clear = true })
        vim.api.nvim_set_hl(0, "Normal", { fg = "#111111" })
        highlight.attach(group)
        assert.equals(fg("Normal"), fg("JupyterWinBar"))

        vim.api.nvim_set_hl(0, "Normal", { fg = "#eeeeee" })
        vim.api.nvim_exec_autocmds("ColorScheme", { group = group })

        assert.equals(fg("Normal"), fg("JupyterWinBar"))
        vim.api.nvim_del_augroup_by_id(group)
    end)

    it("ручное переопределение переживает смену темы", function()
        local group = vim.api.nvim_create_augroup("jupyter.highlight.test2", { clear = true })
        vim.api.nvim_set_hl(0, "Normal", { fg = "#111111" })
        highlight.attach(group)

        -- пользователь задал свой цвет уже после setup
        vim.api.nvim_set_hl(0, "JupyterWinBar", { fg = "#abcdef" })
        vim.api.nvim_set_hl(0, "Normal", { fg = "#eeeeee" })
        vim.api.nvim_set_hl(0, "DiagnosticOk", { fg = "#00ff7f" })
        vim.api.nvim_exec_autocmds("ColorScheme", { group = group })

        -- нетронутая группа за темой следует
        assert.equals(0x00ff7f, fg("JupyterWinBarOk"), "нетронутое должно обновиться")

        assert.equals(0xabcdef, fg("JupyterWinBar"), "свой цвет затирать нельзя")
        vim.api.nvim_del_augroup_by_id(group)
    end)

    it("группа статуса зависит от исхода прогона", function()
        assert.equals("JupyterWinBarOk", highlight.for_status("ok"))
        assert.equals("JupyterWinBarError", highlight.for_status("error"))
        assert.equals("JupyterWinBarWarn", highlight.for_status("aborted"))
        assert.equals("JupyterWinBarInfo", highlight.for_status("running"))
        assert.equals("JupyterWinBarOk", highlight.for_status(nil))
    end)

    it("wrap ставит маркер группы и не трогает пустое", function()
        assert.equals("%#JupyterWinBar#текст", highlight.wrap("JupyterWinBar", "текст"))
        assert.equals("", highlight.wrap("JupyterWinBar", ""))
    end)
end)

describe("winbar drawer'а", function()
    it("несёт маркеры групп и уцелевшее экранирование процента", function()
        local out = output.new({ size = 8, stale = function() return true end })
        out:show({
            cell_id = "a3f9",
            run_id = 1,
            status = "error",
            error = { code = "Err%or" },
            lines = { "x" },
        })

        local winbar = vim.wo[out.win].winbar

        assert.is_truthy(winbar:find("%%#JupyterWinBar#"), "нет группы основного текста")
        assert.is_truthy(winbar:find("%%#JupyterWinBarError#"), "статус ошибки должен быть красным")
        assert.is_truthy(winbar:find("%%#JupyterWinBarWarn#"), "предупреждение о коде — жёлтым")
        assert.is_truthy(winbar:find("Err%%%%or", 1, false), "процент в тексте всё ещё удвоен")
        out:close()
    end)
end)
