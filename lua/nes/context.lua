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

---@class CurrentVersion
---@field text string

---@class Context
---@field filename string
---@field original_code string
---@field edits string
---@field filetype string
---@field current_version CurrentVersion

---@class Message
---@field role string
---@field content string

---@class Payload
---@field messages Message[]
---@field model string
---@field temperature number
---@field top_p number
---@field prediction {type: string, content: string}
---@field n number
---@field stream boolean
---@field snippy {enabled: boolean}

---@return Payload
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

return Context
