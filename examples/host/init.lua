-- Configuration: plain assignments the host reads into a Zig struct.
config = {
  font_size = 14,
  theme = "light",
  keybinds = {
    { key = "ctrl+t", action = "new_tab" },
    { key = "ctrl+w", action = "close_tab" },
  },
}

-- A plugin: a window from the host, and handlers for key presses.
local win = host.window(80, 24)
host.log("opened " .. tostring(win))

host.on_key(function(key)
  local w, h = win:size()
  if key == "ctrl+plus" then
    win:resize(w + 10, h)
    return "resized to " .. table.concat({ win:size() }, "x")
  elseif key == "shrink" then
    win:resize(0, h)
  end
end)

host.on_key(function(key)
  if key == "boom" then error("plugin failed on " .. key) end
end)
