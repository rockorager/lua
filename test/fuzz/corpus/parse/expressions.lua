local a, b, c = 1, 2.5, "3"
local t = {a = {b = {c = function(self, ...) return select('#', ...) end}}}
print(a + b * c ^ 2 // 3 % 4 - -a, a .. b .. c, #t, t.a.b:c(1, 2, 3))
print(a < b, a <= b, a == b, a ~= b, a > b, a >= b, not a, a and b or c)
print(a & 3 | 4 ~ 5 << 1 >> 2, ~a, (function(...) return ... end)(a, b, c))
while a < 10 do a = a + 1 if a == 5 then break end end
repeat local z = a a = a - 1 until z < 3
if a then elseif b then else end
