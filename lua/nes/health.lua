local M = {}

function M.check()
    vim.health.start("System")
    local required_binaries = { "curl" }
    for _, name in ipairs(required_binaries) do
        if vim.fn.executable(name) == 0 then
            vim.health.error(name .. " is not installed")
        else
            vim.health.ok(name .. " is installed")
        end
    end
end

return M
