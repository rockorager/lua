-- Messages the VM and Thread.zig produce, which still differ from the
-- reference; each line names what it checks.
local function try(f, ...) print(pcall(f, ...)) end
try(function() return 1 // 0 end)                       -- "attempt to divide by zero"
try(function() return 1 % 0 end)                        -- "attempt to perform 'n%%0'"
try(function() local t = {} t[nil] = 1 end)             -- "table index is nil"
try(function() return undefined_global + 1 end)         -- variable name: global 'undefined_global'
try(function() local t = {} return t.x.y end)           -- variable name: field 'x'
try(function() local s; s() end)                        -- variable name: local 's'
try(function() return ("x") .. {} end)                  -- concatenate a table value
-- chunk id: source text of exactly 45 bytes gets "..."
print(pcall(load("local s = 'xxxxxxxxxxxxxxxxxxxxxxxx' error(s)")))
