-- title = BrushTest
-- author = Chris Moore
-- description = brush/brushmap test.
-- editTilemap.sheetBlobIndex = 0
-- editTilemap.draw16Sprites = true
-- editBrushmap.draw16Sprites = true


-- brushes defined in this table
numo9_brushes = {
--[[ ex: checkerboard
	|x,y,w,h,bx,by| do
		return ((x & 1) ~ (y & 1)) << 1	-- checkerboard, 16x16
	end,
--]]
-- [[ ex: 9-patch
	|x,y,w,h,bx,by| do
		-- corners
		if x == 0 and y == 0 then
			return 0
		elseif x == w-1 and y == 0 then
			return 0 | (2 << 13)
		elseif x == w-1 and y == h-1 then
			return 0 | (4 << 13)
		elseif x == 0 and y == h-1 then
			return 0 | (6 << 13)
		end
		-- edges
		if y == 0 then
			return 2
		elseif x == w-1 then
			return 2 | (2 << 13)
		elseif y == h-1 then
			return 2 | (4 << 13)
		elseif x == 0 then
			return 2 | (6 << 13)
		end
		-- center
		return 66
	end,
--]]
}
