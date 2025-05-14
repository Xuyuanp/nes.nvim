local M = {}

function M.notify(text, opts)
    opts = opts or {}
    opts.title = "[NES] " .. (opts.title or "")
    opts.level = opts.level or vim.log.levels.INFO
    vim.notify(text, opts.level, { title = opts.title })
end

---@class nes.util.Curl
local Curl = {}

function Curl.request(method, url, opts)
    opts = opts or {}
    local bin = opts.binary or "curl"
    local args = { bin, "-sSL", url, "-X", method }
    for key, value in pairs(opts.headers or {}) do
        table.insert(args, "-H")
        table.insert(args, key .. ": " .. value)
    end
    if opts.body then
        table.insert(args, "-d")
        table.insert(args, "@-")
    end
    return vim.system(args, {
        stdin = opts.body,
        text = true,
        timeout = opts.timeout,
        env = opts.env,
        stdout = opts.stdout,
        stderr = opts.stderr,
    }, opts.on_exit)
end

function Curl.get(url, opts)
    return Curl.request("GET", url, opts)
end

function Curl.post(url, opts)
    return Curl.request("POST", url, opts)
end

M.Curl = Curl

---@param a string
---@param b string
---@param opts? {line_offset?: integer, diff?: vim.diff.Opts}
---@return lsp.TextEdit[]
function M.text_edits_from_diff(a, b, opts)
    local res = {}

    local old_lines = vim.split(a, "\n", { plain = true })
    local new_lines = vim.split(b, "\n", { plain = true })

    opts = opts or {}
    opts.line_offset = opts.line_offset or 0
    opts.diff = opts.diff
        or {
            ignore_cr_at_eol = true,
            ignore_whitespace_change_at_eol = true,
            ignore_blank_lines = true,
            ignore_whitespace = true,
        }
    opts.diff.algorithm = "minimal"
    opts.diff.on_hunk = function(start_a, count_a, start_b, count_b)
        -- no change
        if count_a == 0 and count_b == 0 then
            return
        end

        if count_a > 0 then
            if count_b == 0 then
                -- delete lines
                local edit = {
                    range = {
                        start = { line = opts.line_offset + start_a - 1, character = 0 },
                        ["end"] = {
                            line = opts.line_offset + start_a - 1 + count_a,
                            character = 0,
                        },
                    },
                    newText = "",
                }
                table.insert(res, edit)
                return
            end
            if count_a == 1 and count_b == 1 then
                -- try inline edit
                local inline_edit = M._calculate_inline_edit(old_lines[start_a], new_lines[start_b])
                if inline_edit then
                    local edit = {
                        range = {
                            start = { line = opts.line_offset + start_a - 1, character = inline_edit.start_col },
                            ["end"] = { line = opts.line_offset + start_a - 1, character = inline_edit.end_col },
                        },
                        newText = inline_edit.text,
                    }
                    table.insert(res, edit)
                    return
                end
            end

            -- replace lines
            local edit = {
                range = {
                    start = { line = opts.line_offset + start_a - 1, character = 0 },
                    ["end"] = {
                        line = opts.line_offset + start_a - 1 + count_a - 1,
                        character = #old_lines[start_a + count_a - 1],
                    },
                },
                newText = table.concat(vim.list_slice(new_lines, start_b, start_b + count_b - 1), "\n"),
            }
            table.insert(res, edit)
            return
        end
        if count_b > 0 then
            if start_a == 0 then
                local edit = {
                    range = {
                        start = { line = opts.line_offset, character = 0 },
                        ["end"] = {
                            line = opts.line_offset,
                            character = 0,
                        },
                    },
                    newText = "\n" .. table.concat(vim.list_slice(new_lines, start_b, start_b + count_b - 1), "\n"),
                }
                table.insert(res, edit)
                return
            end
            -- add lines
            local edit = {
                range = {
                    start = { line = opts.line_offset + start_a - 1, character = #old_lines[start_a] },
                    ["end"] = {
                        line = opts.line_offset + start_a - 1,
                        character = #old_lines[start_a],
                    },
                },
                newText = "\n" .. table.concat(vim.list_slice(new_lines, start_b, start_b + count_b - 1), "\n"),
            }
            table.insert(res, edit)
            return
        end

        assert(false, "unreachable")
    end

    vim.diff(a, b, opts.diff)

    return res
end

---@private
---@class InlineEdit
---@field start_col integer 0-indexed
---@field end_col integer 0-indexed
---@field text string

---generated by gemini-2.5-pro
---@param a string a single line string
---@param b string a single line string
---@return InlineEdit? inline_edit only returns if the edit is a single add/delete of a contiguous block
function M._calculate_inline_edit(a, b)
    -- If the strings are identical, there's no edit.
    if a == b then
        return nil
    end

    local len_a = #a
    local len_b = #b

    -- Find the length of the common prefix (0-indexed length)
    local prefix_len = 0
    local min_len = math.min(len_a, len_b)
    while prefix_len < min_len and a:sub(prefix_len + 1, prefix_len + 1) == b:sub(prefix_len + 1, prefix_len + 1) do
        prefix_len = prefix_len + 1
    end

    -- Find the length of the common suffix after the prefix (0-indexed length)
    local suffix_len = 0
    -- Loop backwards from the end, ensuring we don't overlap with the prefix already found
    -- We compare characters from the end of string `a` and string `b`.
    -- The index calculation `len - suffix_len` gives the 1-based index from the start.
    -- We need to ensure this index is greater than the prefix_len (0-indexed).
    -- `len - suffix_len > prefix_len` is equivalent to `len - prefix_len > suffix_len`.
    while
        suffix_len < len_a - prefix_len
        and suffix_len < len_b - prefix_len
        and a:sub(len_a - suffix_len, len_a - suffix_len) == b:sub(len_b - suffix_len, len_b - suffix_len)
    do
        suffix_len = suffix_len + 1
    end

    -- Check if the differing parts are contiguous and cover the entire difference.
    -- If the total length of the matched prefix and suffix is greater than the length
    -- of either string, it means the prefix and suffix overlap or meet exactly
    -- within one or both strings.
    -- If they meet exactly (prefix_len + suffix_len == len_a and prefix_len + suffix_len == len_b)
    -- and the strings are different, it implies a change exactly at the junction point(s)
    -- or a simple replacement, which is not considered a single "add/delete a substring"
    -- in the sense of adding/removing a block of text between common parts.
    if prefix_len + suffix_len > len_a or prefix_len + suffix_len > len_b then
        return nil -- Not a simple single add/delete of a contiguous block
    end

    -- Extract the differing middle parts (using 1-based indexing for string.sub)
    -- The middle part starts *after* the prefix and ends *before* the suffix.
    local middle_start_idx = prefix_len + 1 -- 1-based index
    local middle_end_idx_a = len_a - suffix_len -- 1-based index
    local middle_end_idx_b = len_b - suffix_len -- 1-based index

    local middle_a = a:sub(middle_start_idx, middle_end_idx_a)
    local middle_b = b:sub(middle_start_idx, middle_end_idx_b)

    -- Analyze the middle parts to determine the type of edit
    if middle_a == "" and middle_b ~= "" then
        -- Case: Addition (a -> b by adding middle_b)
        -- The addition happens at the position after the prefix.
        -- start_col is the 0-indexed position *before* the added text.
        -- end_col is the 0-indexed position *after* the added text (same as start for insertion).
        return {
            start_col = prefix_len, -- 0-indexed column where addition starts
            end_col = prefix_len, -- 0-indexed column where addition ends (exclusive)
            text = middle_b, -- The text that was added
        }
    elseif middle_a ~= "" and middle_b == "" then
        -- Case: Deletion (a -> b by deleting middle_a)
        -- The deletion spans from the end of the prefix to the start of the suffix in 'a'.
        -- start_col is the 0-indexed position of the first character deleted.
        -- end_col is the 0-indexed position *after* the last character deleted in the original string 'a'.
        return {
            start_col = prefix_len, -- 0-indexed column where deletion starts
            end_col = len_a - suffix_len, -- 0-indexed column where deletion ends (exclusive, relative to 'a')
            text = "",
        }
    else
        -- Case: Both middle parts are non-empty (replacement or multiple changes)
        -- Case: Both middle parts are empty (covered by initial a == b check, or implies prefix/suffix covers everything but strings are different, handled by validity check above)
        return nil -- Not a simple single add/delete
    end
end

return M
