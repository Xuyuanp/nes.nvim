local M = {}

---@alias nes.api.Callback fun(err?: any, output?: string)

---@class nes.api.chat_completions.Message
---@field role 'system' | 'assistant' | 'user'
---@field content string

---@class nes.api.Client
---@field call fun(messages: nes.api.chat_completions.Message[], callback: nes.api.Callback): fun()

---@return nes.api.Client
function M.new_client(opts)
    opts = opts or require("nes").configs.provider
    local provider_name = opts.name or "copilot"

    local ok, provider_cls = pcall(require, "nes.api." .. provider_name)
    if not ok then
        error("Invalid provider name: " .. provider_name)
    end
    local provider = provider_cls.new(opts[provider_name] or {})

    return {
        call = function(messages, callback)
            return provider:call(messages, callback)
        end,
    }
end

return M
