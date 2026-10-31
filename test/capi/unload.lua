-- When C libraries are closed (unload.c): the modules' userdata live
-- until the state closes, so their finalizers run then.
Keep = { require "unload1", require "unload2" }
print("loaded both")
