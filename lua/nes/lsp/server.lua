local Methods = vim.lsp.protocol.Methods

---@class nes.DocumentState
---@field original lsp.TextDocumentItem
---@field current lsp.TextDocumentItem
---@field pending_edits? nes.InlineEdit[]
---@field last_applied? integer

---@alias nes.Workspace table<string, nes.DocumentState>

---@alias nes.MethodHandler fun(server:nes.Server, params: any, callback?: fun(lsp.ResponseError?, any), message_id?: integer)

---@alias nes.InlineEditFilter  fun(edit: lsp.TextEdit): boolean

---@class nes.Server
---@field dispatchers vim.lsp.rpc.Dispatchers
---@field private _workspace nes.Workspace
---@field private _initialized boolean
---@field private _client_initialized boolean
---@field private _running boolean
---@field private _filters nes.InlineEditFilter[]
---@field private _inflights table<integer, fun()>
---@field private _next_message_id integer
---@field private _handlers table<string, nes.MethodHandler>
local Server = {}
Server.__index = Server

---@type lsp.ServerCapabilities
local capabilities = {
    textDocumentSync = 1,
    workspace = {
        workspaceFolders = {
            supported = true,
            changeNotifications = true,
        },
    },
}

---@param dispatchers vim.lsp.rpc.Dispatchers
---@return nes.Server
function Server.new(dispatchers)
    local self = setmetatable({
        dispatchers = dispatchers,
        _workspace = {},
        _next_message_id = 1,
        _initialized = false,
        _running = true,
        _inflights = {},
        _filters = {
            -- no more than 3 lines edit
            function(edit)
                return edit.range["end"].line - edit.range.start.line < 3
            end,
            function(edit)
                return #vim.split(edit.newText, "\n") < 3
            end,
        },
        _handlers = {
            [Methods.initialize] = Server.on_initialize,
            [Methods.initialized] = Server.on_initialized,
            [Methods.textDocument_didOpen] = Server.on_did_open,
            [Methods.textDocument_didSave] = Server.on_did_save,
            [Methods.textDocument_didChange] = Server.on_did_change,
            [Methods.textDocument_didClose] = Server.on_did_close,
            [Methods.dollar_cancelRequest] = Server.on_cancel_request,

            ["textDocument/copilotInlineEdit"] = Server.on_inline_edit,
        },
    }, Server)
    return self
end

---@return vim.lsp.rpc.PublicClient
function Server:new_public_client()
    return {
        request = function(...)
            return self:request(...)
        end,
        notify = function(...)
            return self:notify(...)
        end,
        is_closing = function()
            return self:is_closing()
        end,
        terminate = function()
            self:terminate()
        end,
    }
end

--- Receives a request from the LSP client
---
---@param method vim.lsp.protocol.Method | string The invoked LSP method
---@param params table? Parameters for the invoked LSP method
---@param callback fun(err: lsp.ResponseError?, result: any) Callback to invoke
---@param notify_reply_callback? fun(message_id: integer) Callback to invoke as soon as a request is no longer pending
---@return boolean success `true` if request could be sent, `false` if not
---@return integer? message_id if request could be sent, `nil` if not
function Server:request(method, params, callback, notify_reply_callback)
    notify_reply_callback = notify_reply_callback or function() end

    local handler = self._handlers[method]
    if not handler then
        vim.notify("No handler for method: " .. method, vim.log.levels.WARN)
        return false
    end
    local message_id = self:new_message_id()

    vim.schedule(function()
        handler(
            self,
            params,
            vim.schedule_wrap(function(err, result)
                callback(err, result)
                if not err then
                    notify_reply_callback(message_id)
                end
            end),
            message_id
        )
    end)
    return true, message_id
end

--- Receives a notification from the LSP client.
---@param method string The invoked LSP method
---@param params table? Parameters for the invoked LSP method
---@return boolean
function Server:notify(method, params)
    method = method
    params = params
    local handler = self._handlers[method]
    if not handler then
        vim.notify("No handler for method: " .. method, vim.log.levels.WARN)
        return false
    end
    vim.schedule(function()
        handler(self, params, function() end)
    end)
    return true
end

---@return boolean
function Server:is_closing()
    return false
end

function Server:terminate()
    self._running = false
    self._workspace = nil
end

function Server:new_message_id()
    local id = self._next_message_id
    self._next_message_id = self._next_message_id + 1
    return id
end

---@param params lsp.InitializeParams
function Server:on_initialize(params, callback)
    local _ = params
    ---@type lsp.InitializeResult
    local result = {
        capabilities = capabilities,
        serverInfo = {
            name = "nes",
            version = "0.1.0",
        },
    }
    self._initialized = true
    vim.schedule(function()
        self.dispatchers.server_request(Methods.window_logMessage, { type = 3, message = "NES initialized" })
    end)
    callback(nil, result)
end

---@param params lsp.InitializedParams
function Server:on_initialized(params, callback)
    local _ = params
    self._client_initialized = true
    callback()
end

---@param params lsp.DidOpenTextDocumentParams
function Server:on_did_open(params, callback)
    self._workspace[params.textDocument.uri] = {
        original = params.textDocument,
        current = vim.deepcopy(params.textDocument),
    }
    callback()
end

---@param params lsp.DidSaveTextDocumentParams
function Server:on_did_save(params, callback)
    local state = self._workspace[params.textDocument.uri]
    if not state then
        callback({ code = 1, message = "no state" })
        return
    end
    state.original = vim.deepcopy(state.current)
    self._workspace[params.textDocument.uri] = state
    callback()
end

---@param params lsp.DidChangeTextDocumentParams
function Server:on_did_change(params, callback)
    local state = self._workspace[params.textDocument.uri]
    if not state then
        callback({ code = 1, message = "no state" })
        return
    end
    state.current.version = params.textDocument.version
    state.current.text = params.contentChanges[1].text

    state.pending_edits = nil
    state.last_applied = nil

    self._workspace[params.textDocument.uri] = state
    callback()
end

---@param params lsp.DidCloseTextDocumentParams
function Server:on_did_close(params, callback)
    self._workspace[params.textDocument.uri] = nil
    callback()
end

---@param params lsp.CancelParams
function Server:on_cancel_request(params, callback)
    local cancel = self._inflights[params.id] or function() end
    cancel()

    callback()
end

---@class nes.InlineEditParams : lsp.TextDocumentPositionParams
---@field version integer

---@class nes.InlineEdit: lsp.TextEdit
---@field command? lsp.Command
---@field text string
---@field textDocument lsp.VersionedTextDocumentIdentifier

---@param params nes.InlineEditParams
function Server:on_inline_edit(params, callback, message_id)
    for msg_id, cancel in pairs(self._inflights) do
        cancel()
        self._inflights[msg_id] = nil
    end

    local state = self._workspace[params.textDocument.uri]
    if not state then
        callback({ code = 1, message = "no state" })
        return
    end

    local version = state.current.version

    local pending = state.pending_edits or {}
    local last_applied = state.last_applied or 0
    local next_edit = pending[last_applied + 1]

    if next_edit then
        callback(nil, { edits = { next_edit } })
        state.last_applied = last_applied + 1
        return
    end

    state.pending_edits = nil
    state.last_applied = nil

    local cursor = { params.position.line + 1, params.position.character }
    local filename = vim.fn.fnamemodify(vim.uri_to_fname(state.original.uri), ":")
    local cancel = require("nes.core").fetch_suggestions(
        filename,
        state.original.text,
        state.current.text,
        cursor,
        state.original.languageId,
        ---@param edits lsp.TextEdit[]
        function(edits)
            self._inflights[message_id] = nil

            if version ~= state.current.version then
                -- drop outdated suggestions
                callback(nil, { edits = {} })
                return
            end
            ---@type nes.InlineEdit[]
            local inline_edits = {}
            for _, edit in ipairs(edits) do
                local ok = true
                for _, filter in ipairs(self._filters) do
                    if not filter(edit) then
                        ok = false
                        break
                    end
                end

                if ok then
                    table.insert(inline_edits, {
                        range = edit.range,
                        text = edit.newText,
                        newText = edit.newText,
                        textDocument = {
                            uri = state.current.uri,
                            version = state.current.version,
                        },
                    } --[[@as nes.InlineEdit]])
                end
            end
            state.pending_edits = inline_edits
            state.last_applied = 0
            callback(nil, { edits = { inline_edits[1] } })
        end
    )

    self._inflights[message_id] = cancel
end

return Server
