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
local ffi = require 'ffi'
local Image = require 'image'
local sdl = require 'sdl'
local sdlGetError = require 'sdl.assert'.sdlGetError

local M = {}

M.text = function(...)
	local copying = select('#', ...) > 0
	local tocopy = ...
	if copying then
		tocopy = tostring(tocopy)
		assert(sdl.SDL_SetClipboardText(tocopy))
	else
		if not sdl.SDL_HasClipboardText() then return end
		local text = sdl.SDL_GetClipboardText()
		if text == ffi.null then
			-- bother with the error?
			local error = sdlGetError()
			return nil, error
		end

		-- uhmm, can we have null terms in the string? no for SDL I guess?
		-- libclip wins this round.
		return ffi.string(text)
	end
end

M.image = function(...)
	local copying = select('#', ...) > 0
	local tocopy = ...
	if copying then
		assert(Image:isa(tocopy), "can't paste image, it's not an image")
		-- TODO SDL_SetClipboardData
	else
		-- TODO SDL_GetClipboardData
	end
end

return M
--]]
