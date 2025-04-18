local curl = require("plenary.curl")

local nvim_version = vim.version()

local M = {}

local _oauth_token
local _api_token

local function get_oauth_token()
	if _oauth_token then
		return _oauth_token
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
					_oauth_token = value.oauth_token
					return _oauth_token
				end
			end
		end
	end
end

local function get_api_token()
	if _api_token and _api_token.expires_at > os.time() + 60000 then
		return _api_token
	end

	local oauth_token = get_oauth_token()
	if not oauth_token then
		error("OAuth token not found")
	end

	local request = curl.get("https://api.github.com/copilot_internal/v2/token", {
		headers = {
			Authorization = "Bearer " .. oauth_token,
			["Accept"] = "application/json",
			["User-Agent"] = "vscode-chat/dev",
		},
		on_error = function(err)
			error("token request error: " .. err)
		end,
	})
	_api_token = vim.json.decode(request.body)
	return _api_token
end

function M.call(payload, callback)
	local api_token = get_api_token()
	local base_url = api_token.endpoints.proxy or api_token.endpoints.api

	local output = ""

	local _request = curl.post(base_url .. "/chat/completions", {
		headers = {
			Authorization = "Bearer " .. api_token.token,
			["User-Agent"] = "vscode-chat/dev",
			["Content-Type"] = "application/json",
			["Copilot-Integration-Id"] = "vscode-chat",
			["editor-version"] = ("Neovim/%d.%d.%d"):format(nvim_version.major, nvim_version.minor, nvim_version.patch),
			["editor-plugin-version"] = "nes/0.1.0",
		},
		on_error = function(err)
			error("api request error: " .. err)
		end,
		body = vim.json.encode(payload),
		stream = function(_, chunk)
			if not chunk then
				return
			end
			if vim.startswith(chunk, "data: ") then
				chunk = chunk:sub(6)
			end
			if chunk == "[DONE]" then
				return
			end
			local ok, event = pcall(vim.json.decode, chunk)
			if not ok then
				return
			end
			if event and event.choices and event.choices[1] then
				local choice = event.choices[1]
				if choice.delta and choice.delta.content then
					output = output .. choice.delta.content
				end
			end
		end,
		callback = function()
			callback(output)
		end,
	})
end

function M.debug()
	vim.print(get_api_token())
end

return M
