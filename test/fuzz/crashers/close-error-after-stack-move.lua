-- fuzz diff: pcall stored the error a `__close` handler raised into the
-- stack it indexed before calling the handler, which grew the stack.
-- Printed "false function: 0x..."; the reference prints "false in close".
local a, b, c, d
print(pcall(function()
  local x <close> = setmetatable({}, {__close = function() error('in close', 0) end})
  error('body', 0)
end))
