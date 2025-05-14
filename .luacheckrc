-- vim: ft=lua tw=80

stds.nvim = {
    read_globals = { "jit" },
}
std = "lua51+nvim"

-- Don't report unused self arguments of methods.
self = false

-- Rerun tests only if their modification time changed.
cache = true

ignore = {
    "631", -- max_line_length
    "212/_.*", -- unused argument, for vars with "_" prefix
    "214", -- used variable with unused hint ("_" prefix)
    "581", -- negation of a relational operator- operator can be flipped (not for tables)
}

-- Global objects defined by the C code
read_globals = {
    "vim",
}
