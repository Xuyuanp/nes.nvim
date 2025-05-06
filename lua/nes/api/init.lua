local M = {}

---@alias nes.api.Callback fun(err?: any, output?: string)

---@class nes.api.chat_completions.Message
---@field role 'system' | 'assistant' | 'user'
---@field content string

---@class nes.api.Client
---@field call fun(messages: nes.api.chat_completions.Message[], callback: nes.api.Callback): fun()

---@return nes.api.Client
function M.new_client(opts)
    opts = opts or {}
    local adapter = require("nes.api.copilot").new(opts)
    -- local adapter = require("nes.api.codecompanion").new({
    --     adapter = function()
    --         return require("codecompanion.adapters").extend("openai_compatible", {
    --             name = "nes",
    --             formatted_name = "Nes",
    --             env = {
    --                 api_key = "OPENROUTER_API_KEY",
    --                 url = "https://openrouter.ai/api",
    --             },
    --             schema = {
    --                 model = {
    --                     default = "google/gemini-2.5-flash-preview",
    --                     -- default = "openai/gpt-4o-mini",
    --                 },
    --             },
    --         })
    --     end,
    -- })
    return {
        call = function(messages, callback)
            return adapter:call(messages, callback)
        end,
    }
end

return M
