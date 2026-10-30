-- Closures, upvalues, and varargs.
local function counter()
  local n = 0
  return function() n = n + 1 return n end
end
local c1, c2 = counter(), counter()
print(c1(), c1(), c2(), c1())

local fs = {}
for i = 1, 5 do fs[i] = function() return i end end
print(fs[1](), fs[3](), fs[5]())

local acc = {}
local j = 1
while j <= 3 do
  local k = j * 10
  acc[j] = function() k = k + 1 return k end
  j = j + 1
end
print(acc[1](), acc[1](), acc[2](), acc[3]())

local function va(...)
  local a, b = ...
  return select('#', ...), a, b, ...
end
print(va())
print(va(1))
print(va(1, nil, 3))
print((va(1, 2, 3)))

local function pack(...) return {n = select('#', ...), ...} end
local t = pack(1, nil, 3, nil)
print(t.n, t[1], t[2], t[3], t[4])

local function tail(n) if n == 0 then return "done" end return tail(n - 1) end
print(tail(100000))

local function sum(...)
  local s = 0
  for i = 1, select('#', ...) do s = s + select(i, ...) end
  return s
end
print(sum(1, 2, 3, 4.5))

local function outer()
  local x = 1
  local function mid()
    local function inner() x = x + 1 return x end
    return inner
  end
  return mid(), function() return x end
end
local inc, get = outer()
inc() inc()
print(get())

do
  local a, b, c = 1, 2
  print(a, b, c)
  a, b = b, a
  print(a, b)
  local t2 = {1, 2}
  local i = 1
  i, t2[i] = i + 1, 20
  print(i, t2[1], t2[2])
end

local function multi() return 1, 2, 3 end
print(multi(), multi())
print({multi(), multi()}[4], #{multi(), multi()})
print((multi()))
local x, y, z, w = multi()
print(x, y, z, w)
