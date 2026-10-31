-- fuzz diff: setmetatable with one argument returned the table; the
-- reference raises "bad argument #2 to 'setmetatable' (nil or table
-- expected, got no value)".
print(pcall(setmetatable, {}))
