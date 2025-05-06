local Context = require("nes.context")

local M = {}

---@type nes.api.Client?
local api_client

---@param filename string
---@param original_code string
---@param current_code string
---@param cursor [integer, integer] (1,0)-indexed (row, col)
---@param lang string
---@return fun() cancel
function M.fetch_suggestions(filename, original_code, current_code, cursor, lang, callback)
    if current_code == original_code then
        callback({})
        return function() end
    end
    local ctx = Context.new(filename, original_code, current_code, cursor, lang)
    local payload = ctx:payload()

    if not api_client then
        api_client = require("nes.api").new_client()
    end

    return api_client.call(
        payload.messages,
        vim.schedule_wrap(function(err, stdout)
            if err then
                require("nes.util").notify(vim.inspect(err), { level = vim.log.levels.ERROR })
                callback({})
                return
            end
            local next_version = vim.trim(stdout)
            assert(next_version)
            local edits = ctx:generate_edits(next_version) or {}
            callback(edits)
        end)
    )
end

return M
