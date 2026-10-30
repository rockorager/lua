-- Syntax and compile errors: load returns nil and the message.
local cases = {
  "x = = 1", "local x <foo> = 1", "goto l1; local x; ::l1:: print(x)",
  "for i=1 do end", "x = 'abc", "function f() return ... end",
  "return 1 +", "a.b:c = 1", "(a) = 1", "a, b() = 1, 2", "f() = 1",
  "if x then", "while true do", "repeat x = 1", "for i in x", "do",
  "function f(", "function f(a,", "function f(...,a) end", "function (x) end",
  "local function end", "local 1 = 2", "x = {1, 2", "x = {[1] = }",
  "x = }", "break", "goto nowhere", "::a:: ::a::", "do ::a:: end ::a::",
  "local x <const> = 1; x = 2", "local x <close>, y <close> = 1, 2",
  "global x <close>", "global x; local function f() y = 1 end",
  "global<const> x = 1; x = 2", "global *; local x = y", "global function f() end f = 1",
  "return return", "x = 1 1", "x = ...", "local t = {...}",
  "print('a' .. )", "x = #", "x = not", "x = 1 .. 2 ..", "a.1 = 2",
  "a:b", "a:b.c()", "x = function", "return (1", "return [=[ abc",
  "x = 0x", "x = 3..2", "x = '\\q'", "x = '\\300'", "x = \"\\u{110000000}\"",
  "\1 = 2", "\255a = 1", "x = @", "local x = 1 local x <const> = 2 x = 3",
  "for i = 1, 2 do i = 3 end", "for k, v in pairs({}) do k = 1 end",
  "local a <const> = {} a.x = 1 a = 2", "goto continue; local x = 1; ::continue::",
  "do goto l end local x ::l::", "repeat local x; goto l; local y ::l:: until x == 1",
  "local function f() return end ::l:: goto l2", "return 1;;",
  "local x = 1;;; return x", "f{} {} \"\" ''", "x = a.b.c.d:e(f)(g)[h]",
  "local t = {[1]=1, [2]=2; 3, 4,}", "local a, b, c = (f())",
  "global x, y <const> = 1", "global <const> *", "global function f.g() end",

}
for _, c in ipairs(cases) do
  local f, msg = load(c, "=chunk")
  print(f and "ok" or msg)
end
for _, c in ipairs(cases) do
  local f, msg = load(c)
  print(f and "ok" or msg)
end
print(load("x = = 1", "@file.lua"))
print(load("x = 1\nx = 1\nx = 1\nx = = 2"))
print(load("--[[\n\n\n]] x = = 2", "=lines"))
print(load("local x = [[\n\n]] .. y y", "=lines"))
