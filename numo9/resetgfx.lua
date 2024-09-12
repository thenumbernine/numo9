--[[
TODO maybe move this into a numo9/rom.lua file
and put in that file the ROM and RAM struct defs
and all the spritesheet / tilemap specs
--]]
local table = require 'ext.table'
local Image = require 'image'

-- when I say 'reverse' i mean reversed order of bitfields
-- when opengl says 'reverse' it means reversed order of reading hex numbers or something stupid
function rgb888revto5551(rgba)
	local r = bit.band(bit.rshift(rgba, 16), 0xff)
	local g = bit.band(bit.rshift(rgba, 8), 0xff)
	local b = bit.band(rgba, 0xff)
	local abgr = bit.bor(
		bit.rshift(r, 3),
		bit.lshift(bit.rshift(g, 3), 5),
		bit.lshift(bit.rshift(b, 3), 10),
		bit.lshift(1, 15)	-- hmm always on?  used only for blitting screen?  why not just do 565 or something?  why even have a restriction at all, why not just 888?
	)
	assert(abgr >= 0 and abgr <= 0xffff, ('%x'):format(abgr))
	return abgr
end

local function resetFont(rom)
	local spriteSheetSize = require 'numo9.app'.spriteSheetSize
	
	-- paste our font letters one bitplane at a time ...
	-- TODO just hardcode this resource in the code?
	local spriteSheetPtr = rom.spriteSheet	-- uint8_t*
	local fontImg = Image'font.png'
	local srcx, srcy = 0, 0
	local dstx, dsty = 0, 0
	local function inc2d(x, y, w, h)
		x = x + 8
		if x < w then return x, y end
		x = 0
		y = y + 8
		if y < h then return x, y end
	end
	for i=0,255 do
		local b = bit.band(i, 7)
		local mask = bit.bnot(bit.lshift(1, b))
		for by=0,7 do
			for bx=0,7 do
				local srcp = fontImg.buffer
					+ srcx + bx
					+ fontImg.width * (
						srcy + by
					)
				local dstp = spriteSheetPtr
					+ dstx + bx
					+ spriteSheetSize.x * (
						dsty + by
					)
				dstp[0] = bit.bor(
					bit.band(mask, dstp[0]),
					bit.lshift(srcp[0], b)
				)
			end
		end
		srcx, srcy = inc2d(srcx, srcy, fontImg.width, fontImg.height)
		if not srcx then break end
		if b == 7 then
			dstx, dsty = inc2d(dstx, dsty, spriteSheetSize.x, spriteSheetSize.y)
			if not dstx then break end
		end
	end
end

local function resetPalette(rom)
	local ptr = rom.palette	-- uint16_t*
	for i,c in ipairs(
		--[[ garbage colors
		function(i)
			return math.floor(math.random() * 0xffff)
		end
		--]]
		-- [[ builtin palette
		table{
			-- tic80
			0x000000,
			0x562b5a,
			0xa44654,
			0xe08260,
			0xf7ce82,
			0xb7ed80,
			0x60b46c,
			0x3b7078,
			0x2b376b,
			0x415fc2,
			0x5ca5ef,
			0x93ecf5,
			0xf4f4f4,
			0x99afc0,
			0x5a6c84,
			0x343c55,
			-- https://en.wikipedia.org/wiki/List_of_software_palettes
			0x000000,
			0x75140c,
			0x377d22,
			0x807f26,
			0x00097a,
			0x75197c,
			0x367e7f,
			0xc0c0c0,
			0x7f7f7f,
			0xe73123,
			0x74f84b,
			0xfcfa53,
			0x001ef2,
			0xe63bf3,
			0x71f7f9,
			0xfafafa,
			-- ega palette: https://moddingwiki.shikadi.net/wiki/EGA_Palette
			0x000000,
			0x0000AA,
			0x00AA00,
			0x00AAAA,
			0xAA0000,
			0xAA00AA,
			0xAA5500,
			0xAAAAAA,
			0x555555,
			0x5555FF,
			0x55FF55,
			0x55FFFF,
			0xFF5555,
			0xFF55FF,
			0xFFFF55,
			0xFFFFFF,
		}:mapi(rgb888revto5551)
		--]]
		:sub(1, 256)	-- make sure we don't iterate across too many colors and ptr goes oob ...
	) do
		ptr[0] = c
		ptr = ptr + 1
	end
end

return {
	resetFont = resetFont,
	resetPalette = resetPalette,
}
