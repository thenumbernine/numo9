-- title = BrushTest
-- author = Chris Moore
-- description = brush/brushmap test.
-- editTilemap.draw16Sprites = true
-- editBrushmap.draw16Sprites = true


-- brushes defined in this table
local _9patch = |x,y,w,h,bx,by|
	-- corners
	x == 0 and y == 0 and 2
	or x == w-1 and y == 0 and 2 | (2 << 13)
	or x == w-1 and y == h-1 and 2 | (4 << 13)
	or x == 0 and y == h-1 and 2 | (6 << 13)
	-- edges
	or y == 0 and 4
	or x == w-1 and 4 | (2 << 13)
	or y == h-1 and 4 | (4 << 13)
	or x == 0 and 4 | (6 << 13)
	-- center
	or 6
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
	tilemap(0,0,32,32,0,0,0,true)
end
