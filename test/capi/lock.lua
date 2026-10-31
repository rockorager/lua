-- luafilesystem's setmode, lock, and unlock on a file io opened, which
-- they read as luaL_Stream; its own tests do not lock. Run by
-- `just capi-test` on our C-API lua and the reference.
local lfs = require "lfs"
local name = os.tmpname()
local f = assert(io.open(name, "w"))
print(lfs.setmode(f, "binary"))
print(lfs.lock(f, "w"))
f:write("locked\n")
print(lfs.unlock(f))
print(lfs.lock(f, "r"))
print(lfs.unlock(f))
print(lfs.lock(f, "w", 2, 3), lfs.unlock(f, 2, 3))
f:close()
print(pcall(lfs.lock, f, "w"))
print(pcall(lfs.setmode, f, "binary"))
print(pcall(lfs.lock, io.stdin, "x"))
print(io.open(name):read("a"))
os.remove(name)
