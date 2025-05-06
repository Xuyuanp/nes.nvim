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
- Avoid adding unnecessary text, such as comments.
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
---@field cursor [integer, integer] (1,0)-indexed
---@field original_code string
---@field edits string
---@field current_version table
---@field filename string
---@field filetype string
local Context = {}
Context.__index = Context

---@param filename string
---@param original_code string
---@param current_code string
---@param cursor [integer, integer] (row, col), (1,0)-indexed
---@param lang string
---@return nes.Context
function Context.new(filename, original_code, current_code, cursor, lang)
    local self = {
        cursor = cursor,
        original_code = table.concat(
            vim.iter(vim.split(original_code, "\n", { plain = true }))
                :enumerate()
                :map(function(i, line)
                    return string.format("%d│%s", i, line)
                end)
                :totable(),
            "\n"
        ),
        edits = vim.diff(original_code, current_code, { algorithm = "minimal" }),
        filename = filename,
        current_version = Context._get_current_version(current_code, cursor),
        filetype = lang,
    }
    setmetatable(self, Context)
    ---@diagnostic disable-next-line: return-type-mismatch
    return self
end

function Context:payload()
    return {
        messages = {
            {
                role = "system",
                content = SystemPrompt,
            },
            {
                role = "user",
                content = self:user_prompt(),
            },
        },
        prediction = {
            type = "content",
            content = string.format(
                "<next-version>\n```%s\n%s\n```\n</next-version>",
                self.filetype,
                self.current_version.text
            ),
        },
    }
end

---@return string
function Context:user_prompt()
    return UserPromptTemplate:format(
        self.filename,
        self.original_code,
        self.filename,
        self.filename,
        self.edits,
        self.filename,
        self.filetype,
        self.current_version.text
    )
end

function Context._get_current_version(text, cursor)
    local row, col = cursor[1] - 1, cursor[2]
    local lines = vim.split(text, "\n", { plain = true })
    local start_row = math.max(row - 20, 0)
    local end_row = math.min(row + 20, #lines)
    local start_col = 0
    local end_col = lines[end_row]:len()

    local before_cursor_lines = vim.list_slice(lines, start_row + 1, row)
    local after_cursor_lines = vim.list_slice(lines, row + 2, end_row + 1)
    local before_cursor_text = lines[row + 1]:sub(1, col)
    local after_cursor_text = lines[row + 1]:sub(col + 1)

    local res = {
        cursor = cursor,
        start_row = start_row,
        end_row = end_row,
        start_col = start_col,
        end_col = end_col,
        text = string.format(
            "%s%s<|cursor|>%s%s",
            #before_cursor_lines > 0 and (table.concat(before_cursor_lines, "\n") .. "\n") or "",
            before_cursor_text,
            after_cursor_text,
            #after_cursor_lines > 0 and ("\n" .. table.concat(after_cursor_lines, "\n")) or ""
        ),
    }
    return res
end

---@return lsp.TextEdit[]?
function Context:generate_edits(next_version)
    if not vim.startswith(next_version, "<next-version>") then
        return
    end
    local old_version = self.current_version.text:gsub("<|cursor|>", "")

    -- have to ignore the cursor tag, because the response doesn't have it most of the time, even if I force it in system prompt
    next_version = next_version:gsub("<|cursor|>", "")
    local new_lines = vim.split(next_version, "\n")
    if vim.startswith(new_lines[1], "<next-version>") then
        table.remove(new_lines, 1)
    end
    if vim.startswith(new_lines[1], "```") then
        table.remove(new_lines, 1)
    end
    if #new_lines > 0 and vim.startswith(new_lines[#new_lines], "</next-version>") then
        table.remove(new_lines, #new_lines)
    end
    if #new_lines > 0 and vim.startswith(new_lines[#new_lines], "```") then
        table.remove(new_lines, #new_lines)
    end
    next_version = table.concat(new_lines, "\n")

    return require("nes.util").text_edits_from_diff(old_version, next_version, {
        line_offset = self.current_version.start_row,
    })
end

return Context
