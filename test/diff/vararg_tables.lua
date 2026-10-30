-- Named vararg tables (`...t`) and `...` reading them.
local function f(...t) return t.n, t[1], t[2], t[3] end
print(f()) print(f(1)) print(f(1, nil, 3))
local function g(a, ...t) t[1] = "changed"; return a, ... end
print(g(1, 2, 3))
local function h(...t) local function inner() return t end return inner() end
print(h(5, 6).n)
local function k(...) return select('#', ...), ... end
print(k(nil, nil))
local function v(...) local a, b = ... return a, b, ... end
print(v(1, 2, 3))
local function w(...t) return t[select('#', ...)] end
print(w(7, 8, 9))
local function hidden(...t) return t.n, t[2] end
print(hidden("a", "b"))
local function mod(...t) t.n = 1; return ... end
print(mod(1, 2, 3))
local function bad(...t) t.n = "x"; return ... end
print(pcall(bad, 1, 2))
local function tail(...) return select(2, ...) end
print(tail(1, 2, 3))
local function cnt(...) local t = {...} return #t end
print(cnt(1, 2, 3, 4))
