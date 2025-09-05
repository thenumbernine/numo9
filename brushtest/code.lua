-- title = BrushTest
-- author = Chris Moore
-- description = brush/brushmap test.
-- editTilemap.sheetBlobIndex = 0
-- editTilemap.draw16Sprites = true
-- editBrushmap.draw16Sprites = true


-- brushes defined in this table
local _9patch = |x,y,w,h,bx,by| do
	-- corners
	if x == 0 and y == 0 then
		return 2
	elseif x == w-1 and y == 0 then
		return 2 | (2 << 13)
	elseif x == w-1 and y == h-1 then
		return 2 | (4 << 13)
	elseif x == 0 and y == h-1 then
		return 2 | (6 << 13)
	-- edges
	elseif y == 0 then
		return 4
	elseif x == w-1 then
		return 4 | (2 << 13)
	elseif y == h-1 then
		return 4 | (4 << 13)
	elseif x == 0 then
		return 4 | (6 << 13)
	-- center
	else
		return 6
	end
end
numo9_brushes = {
--[[ ex: checkerboard
	|x,y,w,h,bx,by| do
		return ((x & 1) ~ (y & 1)) << 1	-- checkerboard, 16x16
	end,
--]]
-- [[ ex: 9-patch
	_9patch,
--]]
-- [[ 9-patch as well
	|...| _9patch(...) + 64,
--]]
-- [[ stamp
	|x,y| (((x & 3) << 1) | (((y & 3) + 2) << 6)),
--]]
}

blitbrushmap()
update=||do
	map(0,0,32,32,0,0,0,true,0)
end
