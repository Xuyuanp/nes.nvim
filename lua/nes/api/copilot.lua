local nvim_version = vim.version()
local Curl = require("nes.util").Curl

---@private
---@class ApiToken
---@field token string
---@field endpoints {proxy: string?, api: string}
---@field expires_at integer

---@class nes.api.adapter.Copilot
---@field private _opts? table
---@field private _oauth_token? string
---@field private _api_token? ApiToken
local Copilot = {}
Copilot.__index = Copilot

local default_opts = {
    token_endpoint = "https://api.github.com/copilot_internal/v2/token",
    params = {
        model = "copilot-nes-v",
        temperature = 0,
        top_p = 1,
        n = 1,
        stream = true,
        snippy = {
            enabled = false,
        },
    },
}

---@return nes.api.adapter.Copilot
function Copilot.new(opts)
    opts = vim.tbl_deep_extend("force", default_opts, opts or {})
    local self = {
        _opts = opts,
    }
    setmetatable(self, Copilot)
    return self
end

---@private
---@param messages nes.api.chat_completions.Message[]
---@return table
function Copilot:_payload(messages)
    local payload = vim.deepcopy(self._opts.params)
    payload.messages = messages
    return payload
end

---@private
---@return string?
function Copilot:_get_oauth_token()
    if self._oauth_token then
        return self._oauth_token
    end

    local config_dir = vim.env.XDG_CONFIG_HOME or vim.fs.joinpath(vim.env.HOME, "/.config")

    local config_paths = {
        "github-copilot/apps.json",
        "github-copilot/hosts.json",
    }

    for _, path in pairs(config_paths) do
        local config_path = vim.fs.joinpath(config_dir, path)
        if vim.uv.fs_stat(config_path) then
            local data = vim.fn.readfile(config_path, "")
            if vim.islist(data) then
                data = table.concat(data, "\n")
            end
            local apps = vim.json.decode(data)
            for key, value in pairs(apps) do
                if vim.startswith(key, "github.com") then
                    self._oauth_token = value.oauth_token
                    return self._oauth_token
                end
            end
        end
    end
end

---@private
---@param cb fun(err: string?, api_token?: ApiToken)
function Copilot:_with_token(cb)
    if self._api_token and self._api_token.expires_at > os.time() + 5 then
        cb(nil, self._api_token)
        return
    end

    local oauth_token = self:_get_oauth_token()
    if not oauth_token then
        cb("OAuth token not found")
        return
    end

    return Curl.get(self._opts.token_endpoint, {
        headers = {
            Authorization = "Bearer " .. oauth_token,
            ["Accept"] = "application/json",
            ["User-Agent"] = "vscode-chat/dev",
        },
        on_exit = function(out)
            if out.code ~= 0 then
                cb(out.stderr or out.stdout or ("code: " .. out.code))
                return
            end
            self._api_token = vim.json.decode(out.stdout)
            cb(nil, self._api_token)
        end,
    })
end

function Copilot:_call(base_url, api_key, messages, callback)
    return Curl.post(base_url .. "/chat/completions", {
        headers = {
            Authorization = "Bearer " .. api_key,
            ["User-Agent"] = "vscode-chat/dev",
            ["Content-Type"] = "application/json",
            ["Copilot-Integration-Id"] = "vscode-chat",
            ["editor-version"] = ("Neovim/%d.%d.%d"):format(nvim_version.major, nvim_version.minor, nvim_version.patch),
            ["editor-plugin-version"] = "nes/0.1.0",
        },
        body = vim.json.encode(self:_payload(messages)),
        on_exit = function(out)
            if out.code ~= 0 then
                callback({ message = out.stderr or ("code: " .. out.code) })
                return
            end

            local stdout = out.stdout

            if not self._opts.params.stream then
                local rsp = vim.json.decode(stdout)
                if rsp.choices and rsp.choices[1] then
                    local choice = rsp.choices[1]
                    if choice.message and choice.message.content then
                        callback(nil, choice.message.content)
                    else
                        callback({ message = "No content in response" })
                    end
                else
                    callback({ message = "Invalid response format" })
                end
                return
            end

            local lines = vim.split(stdout, "\n", { plain = true })
            local chunks = {}
            for _, line in ipairs(lines) do
                line = vim.trim(line)
                if line ~= "" then
                    if vim.startswith(line, "data: ") then
                        line = line:sub(7)
                    end
                    if line ~= "[DONE]" then
                        table.insert(chunks, line)
                    end
                end
            end
            local json_chunks = string.format("[%s]", table.concat(chunks, ","))
            local ok, events = pcall(vim.json.decode, json_chunks)
            if not ok then
                callback({ message = "Failed to decode json: " .. (events or "unknown error") })
                return
            end

            local output = ""
            for _, event in ipairs(events) do
                if event.choices and event.choices[1] then
                    local choice = event.choices[1]
                    if choice.delta and choice.delta.content then
                        output = output .. choice.delta.content
                    end
                end
            end
            callback(nil, output)
        end,
    })
end

---@param messages nes.api.chat_completions.Message[]
---@param callback nes.api.Callback
---@return fun() cancel
function Copilot:call(messages, callback)
    local job
    job = self:_with_token(vim.schedule_wrap(function(err, api_token)
        job = nil
        if err then
            callback(err)
            return
        end
        --TODO: deal with nil api_token

        local base_url = api_token.endpoints.proxy or api_token.endpoints.api
        job = self:_call(base_url, api_token.token, messages, callback)
    end))
    return function()
        if job then
            job:kill(-1)
            job = nil
        end
    end
end

return Copilot
