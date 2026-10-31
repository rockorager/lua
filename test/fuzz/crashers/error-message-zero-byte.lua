-- fuzz diff: lua printed a message past its zero byte; lua.c prints it
-- with "%s", so "lua: <file>:4: a", then the traceback.
error("a\0b")
