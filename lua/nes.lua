local M = {
    configs = {
        provider = {
            name = "copilot",
        },
    },
}

function M.setup(opts)
    local _ = opts or {}
    M.configs = vim.tbl_deep_extend("force", M.configs, opts or {})

    vim.lsp.enable("nes", true)
end

setmetatable(M, {
    __index = function(_, key)
        if vim.startswith(key, "_") then
            -- hide private function
            return
        end
        local core = require("nes.core")
        if core[key] then
            return core[key]
        end
    end,
})

return M
