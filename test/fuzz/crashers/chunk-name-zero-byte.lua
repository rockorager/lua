-- fuzz diff: a chunk name kept the bytes after a zero; lua_load takes it
-- as a C string. The reference prints [string "x"].
print(load("x\0y"))
