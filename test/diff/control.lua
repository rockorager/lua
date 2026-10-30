-- Control flow, loops, goto, and numeric edge cases.
for i = 1, 3 do print("i", i) end
for i = 3, 1, -1 do print("down", i) end
for i = 1, 2, 0.5 do print("f", i) end
for i = 1.0, 3 do print("fi", i) end
for i = math and 1 or 1, 0 do print("never") end
for i = 9223372036854775805, 9223372036854775807 do print("big", i) end
for i = -9223372036854775806, -9223372036854775808, -1 do print("small", i) end
print(pcall(function() for i = 1, 10, 0 do end end))
print(pcall(function() for i = 1, "x" do end end))
print(pcall(function() for i = {}, 1 do end end))

local n = 0
while true do n = n + 1 if n > 5 then break end end
print("n", n)
repeat local m = n; n = n - 1 until m <= 2
print("n", n)

for i = 1, 3 do
  for j = 1, 3 do
    if j == 2 then goto continue end
    print(i, j)
    ::continue::
  end
end

do
  local k = 0
  ::top::
  k = k + 1
  if k < 3 then goto top end
  print("k", k)
end

local t = {}
for i = 1, 3 do
  local x = i
  t[i] = function() return x end
  if i == 2 then goto skip end
  x = x * 10
  ::skip::
end
print(t[1](), t[2](), t[3]())

local function classify(x)
  if x < 0 then return "neg" elseif x == 0 then return "zero" elseif x < 10 then return "small" else return "big" end
end
print(classify(-1), classify(0), classify(5), classify(50))

print(1 and 2, nil and 1, false or "x", nil or false, not nil, not 0)
local a, b = 3, nil
print(a and b or "d", a or b, b or a, a and a > 2, b and b > 2)
print(1 < 2, 1 <= 1, 2 > 1, "a" < "b", "abc" < "abd", 1 == 1.0, 2^53 == 2^53 + 1)
print(7 // 2, -7 // 2, 7 % 3, -7 % 3, 7 % -3, 7.5 // 2, -7.5 % 2, 1 / 0, -1 / 0)
print(3 & 5, 3 | 5, 3 ~ 5, ~0, 1 << 62, 1 << 64, -1 >> 1, 2^10, 10 / 2)
print(1.0 // 0, -1 % 0.0)
print(0x7fffffffffffffff + 1, math_mininteger_missing or -0x8000000000000000)
print(1e15, 1e16, 123456789012345678, 0.1, 1/3, -0.0, 100, 100.0, 2^63, -2^63)
print(5 // 0.0, -5 // 0.0, 0/0 ~= 0/0)
