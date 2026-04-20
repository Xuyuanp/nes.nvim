local Context = require("nes.context")

local M = {}

local ns_id = vim.api.nvim_create_namespace("nes")
local hl_ns_id = vim.api.nvim_create_namespace("nes_highlight")

---@class nes.EditSuggestionUI
---@field preview_winnr? integer
---@field added_extmark_id? integer
---@field deleted_extmark_id? integer

---@class nes.EditSuggestion
---@field text_edit lsp.TextEdit
---@field ui? nes.EditSuggestionUI

---@class nes.BufState
---@field line_offset integer
---@field suggestions nes.EditSuggestion[]
---@field accepted_cursor? [integer, integer]

---@class nes.Apply.Opts
---@field jump? boolean | { hl_timeout: integer? } auto jump to the end of the new edit
---@field trigger? boolean auto trigger the next edit suggestion

---@private
---@param bufnr integer
---@param suggestion_ui nes.EditSuggestionUI
function M._dismiss_suggestion_ui(bufnr, suggestion_ui)
	pcall(vim.api.nvim_win_close, suggestion_ui.preview_winnr, true)
	pcall(vim.api.nvim_buf_del_extmark, bufnr, ns_id, suggestion_ui.added_extmark_id)
	pcall(vim.api.nvim_buf_del_extmark, bufnr, ns_id, suggestion_ui.deleted_extmark_id)
end

---@private
---@param bufnr integer
---@param line_offset integer
---@param suggestion nes.EditSuggestion
---@param opts? nes.Apply.Opts
---@return integer offset
---@return [integer, integer]? new_cursor if jump is true
function M._apply_suggestion(bufnr, line_offset, suggestion, opts)
	opts = opts or {}
	local text_edit = vim.deepcopy(suggestion.text_edit)
	text_edit.range.start.line = text_edit.range.start.line + line_offset
	text_edit.range["end"].line = text_edit.range["end"].line + line_offset

	-- apply the text edit
	vim.lsp.util.apply_text_edits({ text_edit }, bufnr, "utf-8")

	if suggestion.ui then
		M._dismiss_suggestion_ui(bufnr, suggestion.ui)
	end

	local deleted_lines_count = text_edit.range["end"].line - text_edit.range.start.line
	local added_lines = vim.split(text_edit.newText, "\n")
	local added_lines_count = text_edit.newText == "" and 0 or #added_lines - 1

	local new_cursor
	if opts.jump and added_lines_count > 0 then
		local start_line = text_edit.range.start.line
		new_cursor = { start_line + added_lines_count, #added_lines[#added_lines - 1] }
		vim.api.nvim_win_set_cursor(0, new_cursor)

		local hl_timeout = type(opts.jump) == "table" and opts.jump.hl_timeout or 800

		if hl_timeout > 0 then
			vim.defer_fn(function()
				vim.hl.range(bufnr, hl_ns_id, "NesApply", {
					start_line,
					0,
				}, {
					start_line + added_lines_count,
					#added_lines[#added_lines - 1],
				}, { timeout = hl_timeout })
			end, 10)
		end
	end

	return added_lines_count - deleted_lines_count, new_cursor
end

---@private
---@param bufnr integer
---@param state nes.BufState
---@return nes.BufState
function M._apply_next_suggestion(bufnr, state, opts)
	if not state.suggestions or #state.suggestions == 0 then
		return state
	end
	local suggestion = state.suggestions[1]
	local offset, new_cursor = M._apply_suggestion(bufnr, state.line_offset, suggestion, opts)

	state.accepted_cursor = new_cursor
	state.line_offset = state.line_offset + offset
	table.remove(state.suggestions, 1)
	return state
end

---@private
---@param bufnr integer
---@param state nes.BufState
---@return nes.BufState
function M._display_next_suggestion(bufnr, state)
	local win_id = vim.fn.win_findbuf(bufnr)[1]
	if not state.suggestions or #state.suggestions == 0 then
		return state
	end
	local suggestion = state.suggestions[1]
	if suggestion.ui then
		return state
	end

	local ui = {}
	local deleted_lines_count = suggestion.text_edit.range["end"].line - suggestion.text_edit.range.start.line
	if deleted_lines_count > 0 then
		ui.deleted_extmark_id =
			vim.api.nvim_buf_set_extmark(bufnr, ns_id, state.line_offset + suggestion.text_edit.range.start.line, 0, {
				hl_group = "NesDelete",
				end_line = state.line_offset + suggestion.text_edit.range["end"].line,
			})
	end
	local added_lines = vim.split(suggestion.text_edit.newText, "\n")
	local added_lines_count = suggestion.text_edit.newText == "" and 0 or #added_lines - 1
	if added_lines_count > 0 then
		local virt_lines = {}
		for _i = 1, added_lines_count do
			table.insert(virt_lines, {
				{ "", "Normal" },
			})
		end
		local line = state.line_offset + suggestion.text_edit.range.start.line + deleted_lines_count - 1

		-- tricky part:
		-- 1. set empty virtual lines to offset the content of the rest
		-- 2. open a borderless floating window to show the added lines
		-- 3. use treesitter to highlight the added lines
		ui.added_extmark_id = vim.api.nvim_buf_set_extmark(bufnr, ns_id, line, 0, {
			virt_lines = virt_lines,
		})

		local preview_bufnr = vim.api.nvim_create_buf(false, true)
		vim.api.nvim_buf_set_lines(preview_bufnr, 0, -1, false, added_lines)
		vim.bo[preview_bufnr].modifiable = false
		vim.bo[preview_bufnr].buflisted = false
		vim.bo[preview_bufnr].bufhidden = "wipe"
		vim.bo[preview_bufnr].filetype = vim.bo[bufnr].filetype

		local cursor = vim.api.nvim_win_get_cursor(win_id)
		local win_width = vim.api.nvim_win_get_width(win_id)
		local offset = vim.fn.getwininfo(win_id)[1].textoff
		local preview_winnr = vim.api.nvim_open_win(preview_bufnr, false, {
			relative = "cursor",
			width = win_width - offset,
			height = #added_lines - 1,
			row = state.line_offset + suggestion.text_edit.range["end"].line - cursor[1] + 1,
			col = 0,
			style = "minimal",
			border = "none",
		})
		vim.wo[preview_winnr].number = false
		vim.wo[preview_winnr].winhighlight = "Normal:NesAdd"
		vim.wo[preview_winnr].winblend = 0

		ui.preview_winnr = preview_winnr
	end

	suggestion.ui = ui
	state.suggestions[1] = suggestion

	vim.api.nvim_create_autocmd({ "CursorMoved", "CursorMovedI" }, {
		buffer = bufnr,
		callback = function()
			if not vim.b.nes_state then
				return true
			end

			local accepted_cursor = vim.b.nes_state.accepted_cursor
			if accepted_cursor then
				local cursor = vim.api.nvim_win_get_cursor(win_id)
				if cursor[1] == accepted_cursor[1] and cursor[2] == accepted_cursor[2] then
					return
				end
			end

			M.clear_suggestion(bufnr)
			return true
		end,
	})

	return state
end

---@param ctx nes.Context
---@param next_version string
local function parse_suggestion(ctx, next_version)
	-- force clear the suggestion first, in case of duplicated request
	M.clear_suggestion(ctx.bufnr)

	if not vim.startswith(next_version, "<next-version>") then
		vim.print("not found")
		return
	end
	local old_version = ctx.current_version.text:gsub("<|cursor|>", "")

	-- have to ignore the cursor tag, because the response doesn't have it most of the time, even if I force it in system prompt
	next_version = next_version:gsub("<|cursor|>", "")
	local new_lines = vim.split(next_version, "\n")
	if vim.startswith(new_lines[1], "<next-version>") then
		table.remove(new_lines, 1)
	end
	if vim.startswith(new_lines[1], "```") then
		table.remove(new_lines, 1)
	end
	if vim.startswith(new_lines[#new_lines], "</next-version>") then
		table.remove(new_lines, #new_lines)
	end
	if vim.startswith(new_lines[#new_lines], "```") then
		table.remove(new_lines, #new_lines)
	end
	next_version = table.concat(new_lines, "\n")

	local chunks = vim.diff(old_version, next_version, {
		algorithm = "minimal",
		ignore_cr_at_eol = true,
		ignore_whitespace_change_at_eol = true,
		ignore_blank_lines = true,
		ignore_whitespace = true,
		result_type = "indices",
	})
	assert(type(chunks) == "table", "nes: invalid diff result")
	if not chunks or #chunks == 0 then
		return
	end

	local state = { line_offset = ctx.current_version.start_row, suggestions = {} }
	for _, next_edit in ipairs(chunks) do
		local start_a, count_a = next_edit[1], next_edit[2]
		local start_b, count_b = next_edit[3], next_edit[4]

		---@type lsp.TextEdit
		local text_edit = {
			range = {
				start = {
					line = start_a,
					character = 0,
				},
				["end"] = {
					line = 0, -- leave it empty for now
					character = 0,
				},
			},
			newText = "",
		}

		if count_a > 0 then
			text_edit.range["start"].line = start_a - 1
			text_edit.range["end"].line = start_a + count_a - 1
		else
			text_edit.range["end"].line = start_a
		end
		if count_b > 0 then
			local added_lines = {}
			for i = start_b, start_b + count_b - 1 do
				table.insert(added_lines, new_lines[i])
			end
			text_edit.newText = table.concat(added_lines, "\n") .. "\n"
		end
		table.insert(state.suggestions, { text_edit = text_edit })
	end

	state = M._display_next_suggestion(ctx.bufnr, state)
	vim.b[ctx.bufnr].nes_state = state
end

---@param bufnr? integer
function M.get_suggestion(bufnr)
	bufnr = bufnr and bufnr > 0 and bufnr or vim.api.nvim_get_current_buf()
	local ctx = Context.new(bufnr)
	local payload = ctx:payload()
	require("nes.api").call(payload, function(stdout)
    -- __AUTO_GENERATED_PRINT_VAR_START__
    print([==[M.get_suggestion#(anon) stdout:]==], vim.inspect(stdout)) -- __AUTO_GENERATED_PRINT_VAR_END__
		local next_version = vim.trim(stdout)
		assert(next_version)
		if not vim.startswith(next_version, "<next-version>") then
			return
		end
		vim.schedule(function()
			parse_suggestion(ctx, next_version)
		end)
	end)
end

---@param bufnr? integer
---@param opts? nes.Apply.Opts
function M.apply_suggestion(bufnr, opts)
	opts = opts or {}

	bufnr = bufnr and bufnr > 0 and bufnr or vim.api.nvim_get_current_buf()

	local state = vim.b[bufnr].nes_state
	if not state then
		return
	end
	local new_state = M._apply_next_suggestion(bufnr, state, opts)
	vim.b[bufnr].nes_state = new_state
	if #new_state.suggestions > 0 then
		-- vim.schedule(function()
		vim.b[bufnr].nes_state = M._display_next_suggestion(bufnr, new_state)
		-- end)
	elseif opts.trigger then
		vim.schedule(function()
			M.get_suggestion(bufnr)
		end)
	end
end

---@param bufnr? integer
function M.clear_suggestion(bufnr)
	bufnr = bufnr and bufnr > 0 and bufnr or vim.api.nvim_get_current_buf()
	vim.api.nvim_buf_clear_namespace(bufnr, ns_id, 0, -1)
	local state = vim.b[bufnr].nes_state
	if not state then
		return
	end

	for _, suggestion in ipairs(state.suggestions) do
		if suggestion.ui then
			M._dismiss_suggestion_ui(bufnr, suggestion.ui)
		end
	end
	vim.b[bufnr].nes_state = nil
end

return M
