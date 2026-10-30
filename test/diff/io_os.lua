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
