local new_set = MiniTest.new_set
local eq = MiniTest.expect.equality

local T = new_set()

---@private
---@alias Case.Args {a: string, b: string, opts?: table}

---@private
---@alias Case.Expected lsp.TextEdit[]

---@private
---@alias Case [Case.Args, Case.Expected]

T["text_edits_from_diff"] = new_set()

---@type table<string, Case>
local cases = {
    ["no change"] = {
        {
            a = "aaa",
            b = "aaa",
        },
        {},
    },
    ["replace single line"] = {
        {
            a = "prefix\naaa\nsuffix",
            b = "prefix\nbbb\nsuffix",
        },
        {
            {
                range = {
                    start = { line = 1, character = 0 },
                    ["end"] = { line = 1, character = 3 },
                },
                newText = "bbb",
            },
        },
    },
    ["less to more"] = {
        {
            a = "prefix\naaa\nsuffix",
            b = "prefix\nbbb\nccc\nsuffix",
        },
        {
            {
                range = {
                    start = { line = 1, character = 0 },
                    ["end"] = { line = 1, character = 3 },
                },
                newText = "bbb\nccc",
            },
        },
    },
    ["more to less"] = {
        {
            a = "prefix\naaa\nbbb\nsuffix",
            b = "prefix\nccc\nsuffix",
        },
        {
            {
                range = {
                    start = { line = 1, character = 0 },
                    ["end"] = { line = 2, character = 3 },
                },
                newText = "ccc",
            },
        },
    },
    ["delete lines"] = {
        {
            a = "prefix\naaa\nbbb\nsuffix",
            b = "prefix\nsuffix",
        },
        {
            {
                range = {
                    start = { line = 1, character = 0 },
                    ["end"] = { line = 3, character = 0 },
                },
                newText = "",
            },
        },
    },
    ["add lines"] = {
        {
            a = "prefix\nsuffix",
            b = "prefix\naaa\nbbb\nsuffix",
        },
        {
            {
                range = {
                    start = { line = 0, character = 6 },
                    ["end"] = { line = 0, character = 6 },
                },
                newText = "\naaa\nbbb",
            },
        },
    },
    ["no suffix"] = {
        {
            a = "prefix\n",
            b = "prefix\naaa\nbbb",
        },
        {
            {
                range = {
                    start = { line = 0, character = 6 },
                    ["end"] = { line = 0, character = 6 },
                },
                newText = "\naaa\nbbb",
            },
        },
    },
    ["line offset"] = {
        {
            a = "prefix\naaa\nsuffix",
            b = "prefix\nbbb\nsuffix",
            opts = { line_offset = 10 },
        },
        {
            {
                range = {
                    start = { line = 11, character = 0 },
                    ["end"] = { line = 11, character = 3 },
                },
                newText = "bbb",
            },
        },
    },
    ["inline add"] = {
        {
            a = "prefix\naaaccc\nsuffix",
            b = "prefix\naaabbbccc\nsuffix",
        },
        {
            {
                range = {
                    start = { line = 1, character = 3 },
                    ["end"] = { line = 1, character = 3 },
                },
                newText = "bbb",
            },
        },
    },
    ["inline delete"] = {
        {
            a = "prefix\naaabbbccc\nsuffix",
            b = "prefix\naaaccc\nsuffix",
        },
        {
            {
                range = {
                    start = { line = 1, character = 3 },
                    ["end"] = { line = 1, character = 6 },
                },
                newText = "",
            },
        },
    },
}

do
    for name, case in pairs(cases) do
        T["text_edits_from_diff"][name] = function()
            local args, expected = unpack(case)
            local actual = require("nes.util").text_edits_from_diff(args.a, args.b, args.opts)
            eq(actual, expected)
        end
    end
end

return T
