---@class nes.api.adapter.Codecompanion
---@field private _adapter table
---@field private _client table
local Codecompanion = {}
Codecompanion.__index = Codecompanion

---@return nes.api.adapter.Codecompanion
function Codecompanion.new(opts)
    opts = opts or {}
    opts.adapter = opts.adapter or "openai"

    local adapter = require("codecompanion.adapters").resolve(opts.adapter)
    adapter.features.tokens = false

    local settings = adapter:map_schema_to_params(adapter:make_from_schema())
    local client = require("codecompanion.http").new({ adapter = settings })

    local self = {
        _adapter = adapter,
        _client = client,
    }
    return setmetatable(self, Codecompanion)
end

---@param messages nes.api.chat_completions.Message[]
---@param callback nes.api.Callback
---@return fun() cancel
function Codecompanion:call(messages, callback)
    local output = {}
    local job = self._client:request(messages, {
        callback = function(err, data)
            if err or not data then
                return
            end
            local result = self._adapter.handlers.chat_output(self._adapter, data)
            if result and result.status == "success" then
                table.insert(output, result.output.content)
            end
        end,
        done = function()
            callback(nil, table.concat(output, ""))
        end,
    }, { bufnr = 0, strategy = "nes" })
    return function()
        if job then
            job:shutdown(-1, 114)
            job = nil
        end
    end
end

return Codecompanion
