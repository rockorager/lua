-- fuzz diff: `th.stack[dest] = try callTm(...)` took the destination's
-- address before the call, which grew the stack, so the result went to
-- the freed stack. Printed 0 then 1; the reference prints 1 twice.
local function show(v) print(v) end
for l = 1, 2 do local x = 1 show('0' + 1, 0 .. '', 0, 0 .. '') x = 2 end
