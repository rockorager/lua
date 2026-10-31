-- io and os against the process: the standard streams, popen, execute, and
-- the flushing os.exit does.
if arg[1] == "child" then
  local f = io.open(arg[2], "w")
  f:write("a file flushed by os.exit\n")
  io.output(arg[2] .. ".out")
  io.write("the default output flushed by os.exit\n")
  io.stdout:write("child stdout\n")
  os.exit(5)
end
if arg[1] == "args" then
  print(select("#", ...), ...)
  return
end

io.write("a") print("b") io.stderr:write("to stderr\n") io.write("c\n")
io.stdout:setvbuf("no") io.write("unbuffered ") io.stderr:write("interleaved\n")
io.stdout:setvbuf("full")
print(io.type(io.stdin), io.type(io.stdout), select(2, io.stdout:close()))

local p = io.popen("printf 'one\\ntwo\\n'; exit 3")
print(p:read("l"), p:read("L"), p:read("l"), p:close())
p = io.popen("cat", "w")
print(io.type(p), p:write("written through a pipe\n") == p, p:close())
print(os.execute("exit 7"))
print(os.execute("kill -s TERM $$"))
print(os.execute("true"), os.execute())
print(io.popen("exit 129"):close())

local name = os.tmpname()
print(os.execute(string.format("%q %q child %q", arg[-1], arg[0], name)))
print(io.open(name):read("a") .. io.open(name .. ".out"):read("a"))
print(os.remove(name), os.remove(name .. ".out"))

-- The standalone lua passes the script #arg arguments, through __len and
-- truncated to a C int, as lua.c's luaL_len does.
local function args(len)
  local init = "setmetatable(arg, {__len = function() return " .. len .. " end})"
  local p = io.popen(string.format("%q -e %q %q args x 2>&1", arg[-1], init, arg[0]))
  io.write(p:read("a"))
  print(p:close())
end
args(4)
args("2^32 + 1")
args(2.5)
args(2000000)
