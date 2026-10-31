-- io handles shared with a C module (stream.c): run on our C-API lua and
-- the reference with the same stream.so, output compared.

local stream = require "stream"

local name = os.tmpname()

-- Lua and C write through one FILE, so one buffer keeps their order.
local f = assert(io.open(name, "w"))
f:write("lua1 ")
print("c wrote", stream.write(f, "c1 "))
f:write("lua2\n")
print("tell", stream.tell(f), f:seek())
assert(f:close())
print(io.open(name):read("a"))

-- Reading shares the position.
f = assert(io.open(name))
print(f:read(4), stream.read(f, 4), f:read("l"), f:read("l"))
print("fileno above stderr", stream.fileno(f) > 2)
f:close()
print(pcall(stream.fileno, f))

-- The standard files are C's.
print("std", stream.fileno(io.stdin), stream.fileno(io.stdout), stream.fileno(io.stderr))
print("isstd", stream.isstd(io.stdin), stream.isstd(io.stdout), stream.isstd(io.stderr))
io.write("io.write then ")
stream.write(io.stdout, "C fwrite then ")
print("print, in order")

-- A handle the module made around its own FILE, closed by its own
-- function.
local r, w = stream.pipe()
local rf, wf = stream.fdopen(r, "r"), stream.fdopen(w, "w")
print(io.type(rf), io.type(wf), tostring(wf):match("^file %(") ~= nil)
assert(wf:write("one\n", 2, "\nthree"))
assert(wf:flush())
print("close", wf:close())
print(io.type(wf), tostring(wf), "closes", stream.closes())
print(pcall(wf.write, wf, "x"))
local lines = {}
for l in rf:lines() do lines[#lines + 1] = l end
print(#lines, table.concat(lines, "|"))
print("close", rf:close(), "closes", stream.closes())

-- io.output and io.lines on such a handle.
r, w = stream.pipe()
rf, wf = stream.fdopen(r, "r"), stream.fdopen(w, "w")
local out = io.output()
io.output(wf)
io.write("via io.write\n")
io.output(out)
io.close(wf)
print(rf:read("L"), rf:read("a"))
io.input(rf)
print(io.read("n"))
io.input(io.stdin)
rf:close()
print("closes", stream.closes())

-- The collector closes a module's handle with its function.
do
  local h = stream.fdopen(stream.dup(1), "w")
  h:write("written before collection\n")
end
collectgarbage()
collectgarbage()
print("closes after collection", stream.closes())

-- A to-be-closed module handle.
do
  local h <close> = stream.fdopen(stream.dup(1), "w")
  h:write("to be closed\n")
end
print("closes after block", stream.closes())

-- A close function that raises: the error reaches Lua, and the handle is
-- closed.
local bad = stream.fdopen(stream.dup(1), "w", true)
local ok, msg = pcall(bad.close, bad)
print(ok, msg, io.type(bad), stream.closes())

-- A module reading a handle Lua opened in each mode.
for _, mode in ipairs { "r", "r+", "w", "a", "w+b" } do
  local h = assert(io.open(name, mode))
  print(mode, stream.tell(h), h:seek("end") >= 0)
  h:close()
end
local p = io.popen("echo popen", "r")
print("popen fileno", stream.fileno(p) > 2, p:read("l"), p:close())

local t = io.tmpfile()
t:write("tmp")
print("tmpfile", stream.tell(t), stream.fileno(t) > 2)
t:close()

os.remove(name)
print("done")
