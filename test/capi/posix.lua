-- luaposix's posix.stdio on io handles: the cases of its
-- spec/posix_stdio_spec.yaml, which needs specl, plus fileno on files io
-- opened. Run by `just capi-test` on our C-API lua and the reference.

local stdio = require "posix.stdio"
local unistd = require "posix.unistd"
local fcntl = require "posix.fcntl"
local stat = require "posix.sys.stat"

-- fileno of io's handles.
assert(stdio.fileno(io.stdout) == unistd.STDOUT_FILENO)
print("fileno", stdio.fileno(io.stdin), stdio.fileno(io.stdout), stdio.fileno(io.stderr))
local name = os.tmpname()
local f = assert(io.open(name, "w"))
f:write("buffered, ")
assert(f:flush())
print("raw write", unistd.write(stdio.fileno(f), "raw\n"))
f:close()
print(io.open(name):read("a"))

-- fdopen duplicates a stream.
local out = stdio.fdopen(unistd.dup(unistd.STDOUT_FILENO), "w")
print(io.type(out), type(out))
print(out:write("writing to fdopen(stdout)\n") == out)
assert(out:flush())
print("close", out:close())

-- It closes an open stream.
local path = name .. ".delete.me"
unistd.unlink(path)
local fd = assert(fcntl.open(path, fcntl.O_WRONLY + fcntl.O_CREAT + fcntl.O_EXCL, stat.S_IRUSR + stat.S_IWUSR))
local g = assert(stdio.fdopen(fd, "w"))
g:write("via fdopen ", 42, "\n")
print("close", g:close())
print(io.type(g), pcall(g.write, g, "x"))
print(io.open(path):read("a"))
unistd.unlink(path)

-- Reading a pipe through io.
local r, w = unistd.pipe()
local rf = stdio.fdopen(r, "r")
unistd.write(w, "line one\nline two\n3.25 rest")
unistd.close(w)
print(rf:read("l"), rf:read("L"), rf:read("n"), rf:read("a"))
print("close", rf:close())

-- A stream nobody closes is closed by the collector.
do
  local h = stdio.fdopen(unistd.dup(unistd.STDOUT_FILENO), "w")
  h:write("collected\n")
end
collectgarbage()

-- rename.
print("rename", stdio.rename(name, name .. ".renamed"))
print(select(3, io.open(name)), io.open(name .. ".renamed") ~= nil)
os.remove(name .. ".renamed")
print("done")
