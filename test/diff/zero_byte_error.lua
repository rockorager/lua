-- lua.c prints a message with "%s", so the message, and the traceback
-- luaL_traceback builds on it, stop at a zero byte (found by fuzzing).
error("before\0after")
