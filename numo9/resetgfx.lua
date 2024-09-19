--[[
TODO maybe move this into a numo9/rom.lua file
and put in that file the ROM and RAM struct defs
and all the spritesheet / tilemap specs
Or rename this to gfx.lua and put more GL stuff in it?
--]]
local table = require 'ext.table'
local assertlt = require 'ext.assert'.lt
local Image = require 'image'

local App = require 'numo9.app'
local spriteSheetSize = App.spriteSheetSize
local spriteSize = App.spriteSize

-- r,g,b,a is 8bpp
-- result is 5551 16bpp
local function rgba8888_4ch_to_5551(r,g,b,a)
	return bit.bor(
		bit.band(0x001f, bit.rshift(r, 3)),
		bit.band(0x03e0, bit.lshift(g, 2)),
		bit.band(0x7c00, bit.lshift(b, 7)),
		a == 0 and 0 or 0x8000
	)
end

-- rgba5551 is 16bpp 
-- result is r,g,b,a 8bpp
local function rgba5551_to_rgba8888_4ch(rgba5551)
	return
		bit.lshift(bit.band(rgba5551, 0x1F), 3),
		bit.lshift(bit.band(bit.rshift(rgba5551, 5), 0x1F), 3),
		bit.lshift(bit.band(bit.rshift(rgba5551, 10), 0x1F), 3),
		bit.band(1, bit.rshift(rgba5551, 15)) == 0 and 0 or 0xff
end

-- when I say 'reverse' i mean reversed order of bitfields
-- when opengl says 'reverse' it means reversed order of reading hex numbers or something stupid
local function argb8888revto5551(rgba)
	local a = bit.band(bit.rshift(rgba, 24), 0xff)
	local r = bit.band(bit.rshift(rgba, 16), 0xff)
	local g = bit.band(bit.rshift(rgba, 8), 0xff)
	local b = bit.band(rgba, 0xff)
	return rgba8888_4ch_to_5551(r,g,b,a)
end

local function resetFontOnSheet(spriteSheetPtr)
	local spriteSheetSize = require 'numo9.app'.spriteSheetSize

	-- paste our font letters one bitplane at a time ...
	-- TODO just hardcode this resource in the code?
	local fontImg = Image'font.png'
	local srcx, srcy = 0, 0
	-- store on the last row
	local dstx, dsty = 0, spriteSheetSize.y - spriteSize.y
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
		assertlt(srcx, fontImg.width)
		assertlt(srcy, fontImg.height)
		assertlt(dstx, spriteSheetSize.x)
		assertlt(dsty, spriteSheetSize.y)
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
--DEBUG:print('copied letter from', srcx, srcy,'to', dstx, dsty)
		srcx, srcy = inc2d(srcx, srcy, fontImg.width, fontImg.height)
		if not srcx then break end
		if b == 7 then
			dstx, dsty = inc2d(dstx, dsty, spriteSheetSize.x, spriteSheetSize.y)
			if not dstx then break end
		end
	end
end
local function resetFont(rom)
	return resetFontOnSheet(rom.spriteSheet)	-- uint8_t*
end

-- TODO every time App calls this, make sure its palTex.dirtyCPU flag is set
-- it would be here but this is sometimes called by n9a as well
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
			0x00000000,
			0xff562b5a,
			0xffa44654,
			0xffe08260,
			0xfff7ce82,
			0xffb7ed80,
			0xff60b46c,
			0xff3b7078,
			0xff2b376b,
			0xff415fc2,
			0xff5ca5ef,
			0xff93ecf5,
			0xfff4f4f4,
			0xff99afc0,
			0xff5a6c84,
			0xff343c55,
			-- https://en.wikipedia.org/wiki/List_of_software_palettes
			0x00000000,
			0xff75140c,
			0xff377d22,
			0xff807f26,
			0xff00097a,
			0xff75197c,
			0xff367e7f,
			0xffc0c0c0,
			0xff7f7f7f,
			0xffe73123,
			0xff74f84b,
			0xfffcfa53,
			0xff001ef2,
			0xffe63bf3,
			0xff71f7f9,
			0xfffafafa,
			-- ega palette: https://moddingwiki.shikadi.net/wiki/EGA_Palette
			0x00000000,
			0xff0000AA,
			0xff00AA00,
			0xff00AAAA,
			0xffAA0000,
			0xffAA00AA,
			0xffAA5500,
			0xffAAAAAA,
			0xff555555,
			0xff5555FF,
			0xff55FF55,
			0xff55FFFF,
			0xffFF5555,
			0xffFF55FF,
			0xffFFFF55,
			0xffFFFFFF,
		}:mapi(argb8888revto5551)
		
		--]]
		:rep(16)	-- make sure it fills 0-255
		:sub(1, 240)	-- make sure we don't iterate across too many colors and ptr goes oob ...
		:append(table{
			-- editor palette
			0x00000000,
			0xff562b5a,
			0xffa44654,
			0xffe08260,
			0xfff7ce82,
			0xffb7ed80,
			0xff60b46c,
			0xff3b7078,
			0xff2b376b,
			0xff415fc2,
			0xff5ca5ef,
			0xff93ecf5,
			0xfff4f4f4,
			0xff99afc0,
			0xff5a6c84,
			0xff343c55,
		}:mapi(argb8888revto5551))
	) do
		ptr[0] = c
		ptr = ptr + 1
	end
end

return {
	argb8888revto5551 = argb8888revto5551,
	rgba5551_to_rgba8888_4ch = rgba5551_to_rgba8888_4ch,
	rgba8888_4ch_to_5551 = rgba8888_4ch_to_5551,
	resetFont = resetFont,
	resetFontOnSheet = resetFontOnSheet,
	resetPalette = resetPalette,
}
