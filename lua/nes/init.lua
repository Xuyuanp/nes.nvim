local M = {}

local ns_id = vim.api.nvim_create_namespace("nes")

local SystemPrompt = [[
Keep your answers short and impersonal.
The programmer will provide you with a set of recently viewed files, their recent edits, and a snippet of code that is being actively edited.

When helping the programmer, your goals are:
- Make only the necessary changes as indicated by the context.
- Avoid unnecessary rewrites and make only the necessary changes, using ellipses to indicate partial code where appropriate.
- Ensure all specified additions, modifications, and new elements (e.g., methods, parameters, function calls) are included in the response.
- Adhere strictly to the provided pattern, structure, and content, including matching the exact structure and formatting of the expected response.
- Maintain the integrity of the existing code while making necessary updates.
- Provide complete and detailed code snippets without omissions, ensuring all necessary parts such as additional classes, methods, or specific steps are included.
- Keep the programmer on the pattern that you think they are on.
- Consider what edits need to be made next, if any.

When responding to the programmer, you must follow these rules:
- Only answer with the updated code. The programmer will copy and paste your code as is in place of the programmer's provided snippet.
- Match the expected response exactly, even if it includes errors or corruptions, to ensure consistency.
- Do not alter method signatures, add or remove return values, or modify existing logic unless explicitly instructed.
- The current cursor position is indicated by <|cursor|>. You MUST keep the cursor position the same in your response.
- DO NOT REMOVE <|cursor|>.
- You must ONLY reply using the tag: <next-version>.
]]

local UserPromptTemplate = [[
These are the files I'm working on, before I started making changes to them:
<original_code>
%s:
%s
</original_code>

This is a sequence of edits that I made on these files, starting from the oldest to the newest:
<edits_to_original_code>
```
---%s:
+++%s:
%s
```
</edits_to_original_code>

Here is the piece of code I am currently editing in %s:

<current-version>
```%s
%s
```
</current-version>

Based on my most recent edits, what will I do next? Rewrite the code between <current-version> and </current-version> based on
what I will do next. Do not skip any lines. Do not be lazy.
]]

---@class nes.Context
---@field bufnr number
---@field cursor [integer, integer]
---@field original_code string
---@field edits string
---@field current_version table
---@field filename string
---@field filetype string
local Context = {}
Context.__index = Context

---@return nes.Context
function Context.new(bufnr)
	local filename = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(bufnr), ":")
	local original_code = vim.fn.readfile(filename)
	local current_version = Context.get_current_version(bufnr)
	local self = {
		bufnr = bufnr,
		cursor = current_version.cursor,
		original_code = table.concat(
			vim.iter(original_code)
				:enumerate()
				:map(function(i, line)
					return string.format("%d│%s", i, line)
				end)
				:totable(),
			"\n"
		),
		edits = vim.diff(
			table.concat(original_code, "\n"),
			table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), "\n"),
			{ algorithm = "minimal" }
		),
		filename = filename,
		current_version = current_version,
		filetype = vim.bo[bufnr].filetype,
	}
	setmetatable(self, Context)
	return self
end

function Context:payload()
	-- copy from vscode
	return {
		messages = {
			{
				role = "system",
				content = SystemPrompt,
			},
			{
				role = "user",
				content = UserPromptTemplate:format(
					self.filename,
					self.original_code,
					self.filename,
					self.filename,
					self.edits,
					self.filename,
					self.filetype,
					self.current_version.text
				),
			},
		},
		model = "copilot-nes-v",
		temperature = 0,
		top_p = 1,
		prediction = {
			type = "content",
			content = string.format(
				"<next-version>\n```%s\n%s\n```\n</next-version>",
				self.filetype,
				self.current_version.text
			),
		},
		n = 1,
		stream = true,
		snippy = {
			enabled = false,
		},
	}
end

function Context.get_current_version(bufnr)
	local cursor = vim.api.nvim_win_get_cursor(0)
	local row, col = cursor[1] - 1, cursor[2]
	local start_row = row - 20
	if start_row < 0 then
		start_row = 0
	end
	local end_row = row + 20
	if end_row >= vim.api.nvim_buf_line_count(bufnr) then
		end_row = vim.api.nvim_buf_line_count(bufnr) - 1
	end
	local end_col = vim.api.nvim_buf_get_lines(bufnr, end_row, end_row + 1, false)[1]:len()

	local before_cursor = vim.api.nvim_buf_get_text(bufnr, start_row, 0, row, col, {})
	local after_cursor = vim.api.nvim_buf_get_text(bufnr, row, col, end_row, end_col, {})
	return {
		cursor = cursor,
		start_row = start_row,
		end_row = end_row,
		text = string.format("%s<|cursor|>%s", table.concat(before_cursor, "\n"), table.concat(after_cursor, "\n")),
	}
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
	if vim.endswith(new_lines[#new_lines], "</next-version>") then
		table.remove(new_lines, #new_lines)
	end
	if vim.endswith(new_lines[#new_lines], "```") then
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
	if not chunks or #chunks == 0 then
		return
	end
	local next_edit = chunks[1]
	local start_row = ctx.current_version.start_row
	local start_a, count_a = next_edit[1], next_edit[2]
	local start_b, count_b = next_edit[3], next_edit[4]

	---@type lsp.TextEdit
	local text_edit = {
		range = {
			start = {
				line = start_row + start_a,
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
		text_edit.range["start"].line = start_row + start_a - 1
		text_edit.range["end"].line = start_row + start_a + count_a - 1
		-- delete lines
		vim.api.nvim_buf_set_extmark(ctx.bufnr, ns_id, start_row + start_a - 1, 0, {
			hl_group = "NesDelete",
			end_line = start_row + start_a + count_a - 1,
		})
	else
		text_edit.range["end"].line = start_row + start_a
	end

	if count_b > 0 then
		-- add lines
		local virt_lines = {}
		local added_lines = {}
		for i = start_b, start_b + count_b - 1 do
			table.insert(virt_lines, {
				{ "", "Normal" },
			})
			table.insert(added_lines, new_lines[i])
		end
		text_edit.newText = table.concat(added_lines, "\n") .. "\n"

		local line = start_row + start_a - 1
		if count_a > 0 then
			line = line + count_a - 1
		end
		-- tricky part:
		-- 1. set empty virtual lines to offset the content of the rest
		-- 2. open a borderless floating window to show the added lines
		-- 3. use treesitter to highlight the added lines
		vim.api.nvim_buf_set_extmark(ctx.bufnr, ns_id, line, 0, {
			virt_lines = virt_lines,
		})

		local preview_bufnr = vim.api.nvim_create_buf(false, true)
		vim.api.nvim_buf_set_lines(preview_bufnr, 0, -1, false, added_lines)
		vim.bo[preview_bufnr].modifiable = false
		vim.bo[preview_bufnr].buflisted = false
		vim.bo[preview_bufnr].bufhidden = "wipe"
		vim.bo[preview_bufnr].filetype = ctx.filetype

		local win_id = vim.fn.win_findbuf(ctx.bufnr)[1]
		local offset = vim.fn.getwininfo(win_id)[1].textoff
		local preview_winnr = vim.api.nvim_open_win(preview_bufnr, false, {
			relative = "cursor",
			width = vim.o.columns - offset,
			height = #added_lines,
			row = text_edit.range["end"].line - ctx.current_version.cursor[1] + 1,
			col = 0,
			style = "minimal",
			border = "none",
		})
		vim.wo[preview_winnr].number = false
		vim.wo[preview_winnr].winhighlight = "Normal:NesAdd"
		vim.wo[preview_winnr].winblend = 0

		vim.b[ctx.bufnr].preview_winnr = preview_winnr
	end

	-- sometimes copilot returns duplicated code
	local current = vim.trim(
		table.concat(
			vim.api.nvim_buf_get_lines(
				ctx.bufnr,
				text_edit.range.start.line,
				text_edit.range.start.line + count_b,
				false
			),
			"\n"
		)
	)
	if current == vim.trim(text_edit.newText) then
		M.clear_suggestion(ctx.bufnr)
		return
	end

	vim.b[ctx.bufnr].nes = text_edit

	vim.api.nvim_create_autocmd({ "CursorMoved", "CursorMovedI" }, {
		buffer = ctx.bufnr,
		once = true,
		desc = "[NES] auto clear next edit",
		callback = function()
			M.clear_suggestion(ctx.bufnr)
		end,
	})
end

---@class nes.Apply.Opts
---@field jump? boolean auto jump to the end of the new edit
---@field trigger? boolean auto trigger the next edit suggestion

---@param bufnr? integer
---@param opts? nes.Apply.Opts
function M.apply_suggestion(bufnr, opts)
	opts = opts or {}

	bufnr = bufnr and bufnr > 0 and bufnr or vim.api.nvim_get_current_buf()
	local nes = vim.b[bufnr].nes
	if not nes then
		return
	end

	vim.lsp.util.apply_text_edits({ vim.b[bufnr].nes }, bufnr, "utf-8")
	M.clear_suggestion(bufnr)

	if opts.jump then
		if nes.newText then
			local lines = vim.split(nes.newText, "\n")
			local start_line = nes.range.start.line
			vim.api.nvim_win_set_cursor(0, { start_line + #lines - 1, #lines[#lines - 1] })
		end
	end

	if opts.trigger then
		vim.schedule(function()
			M.get_suggestion(bufnr)
		end)
	end
end

function M.get_suggestion(bufnr)
	bufnr = bufnr and bufnr > 0 and bufnr or vim.api.nvim_get_current_buf()
	local ctx = Context.new(bufnr)
	local payload = ctx:payload()
	require("nes.api").call(payload, function(stdout)
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

function M.clear_suggestion(bufnr)
	bufnr = bufnr and bufnr > 0 and bufnr or vim.api.nvim_get_current_buf()
	vim.api.nvim_buf_clear_namespace(bufnr, ns_id, 0, -1)
	vim.b[bufnr].nes = nil
	if vim.b[bufnr].preview_winnr then
		pcall(vim.api.nvim_win_close, vim.b[bufnr].preview_winnr, true)
		vim.b[bufnr].preview_winnr = nil
	end
end

function M.setup(opts)
	opts = opts or {}

	-- setup highlights
	local diff_add = vim.api.nvim_get_hl(0, { name = "@diff.plus", link = false })
	local diff_del = vim.api.nvim_get_hl(0, { name = "@diff.minus", link = false })
	vim.api.nvim_set_hl(0, "NesAdd", { bg = string.format("#%x", diff_add.fg), default = true })
	vim.api.nvim_set_hl(0, "NesDelete", { bg = string.format("#%x", diff_del.fg), default = true })
end

return M
