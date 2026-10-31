-- What `just order` runs after `lua -e ''` to find the functions a short
-- script calls first: the common parts of the base, string, table, math,
-- and os libraries, closures, metatables, and errors.
local t = {}
for i = 1, 200 do
  t[#t + 1] = string.format("%d:%s", i, ("x"):rep(i % 7))
end
table.sort(t)
local s = table.concat(t, ",")
local n = 0
for w in s:gmatch("%d+") do
  n = n + tonumber(w)
end
local words = {}
for k, v in pairs({ a = 1, b = 2 }) do
  words[#words + 1] = k .. "=" .. tostring(v)
end
for _, v in ipairs(t) do
  if v:find(":xx", 1, true) then
    n = n + #v:upper() + #v:sub(2, 3)
  end
end
local ok, e = pcall(error, { code = 1 })
local mt = { __index = function(_, k) return k * 2 end }
local u = setmetatable({}, mt)
local f = function(a, ...) return select("#", ...) + a end
print(n, (s:gsub("x", "y")), ok, type(e), u[21], f(1, 2, 3), math.floor(3.7), math.max(1, 2),
  os.time() > 0, os.clock() >= 0, tostring(1.5), #words, string.byte("A"), string.char(66))
