--[[
This is going to serve as an abstraction to libclip & c-bindings & luajit bindings now that SDL3 has clipboard support...
--]]

-- [[ using libclip:
-- of the libclip API I'm only using:
-- clip.text() as getter/setter
-- clip.image() as RGBA 8bpp getter/setter
return require 'clip'
--]]

--[[ using SDL3:
--]]
