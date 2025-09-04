-- title = BrushTest
-- author = Chris Moore
-- description = brush/brushmap test.
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
		if (x==0 or x==w-1) and (y==0 or y==h-1) then
			return 0, x==w-1, y==h-1
		end
		-- edges
		if x==0 or x==w-1 or y==0 or y==h-1 then
			return 2, y==h-1	-- TODO rot bit ...
		end
		-- center
		return 66
	end,
--]]
}
