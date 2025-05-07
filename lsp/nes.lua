---@type vim.lsp.Config
return {
    cmd = function(dispatchers)
        local server = require("nes.lsp.server").new(dispatchers)
        return server:new_public_client()
    end,
    root_dir = vim.uv.cwd(),
    capabilities = {
        workspace = { workspaceFolders = true },
    },
}
