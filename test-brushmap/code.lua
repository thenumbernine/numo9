-- title = BrushTest
-- author = Chris Moore
-- description = brush/brushmap test.
-- editTilemap.draw16Sprites = true
-- editBrushmap.draw16Sprites = true

mode(0)
matident(0)
matident(1)
matident(2)
matortho(0,256,256,0)
cls()

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

-- [[ test blitbrushmap() works
blitbrushmap()
update=||do
	tilemap(0,0,32,32,0,0,0,true)
end
--]]
--[[ test blitbrush() works
local brushmapAddr = blobaddr'brushmap'
local brushmapSize = blobsize'brushmap'
assert.eq(brushmapSize % 10, 0)
for i=0,brushmapSize-10,10 do
	local addr = brushmapAddr+i
	blitbrush(
		peekw(addr) & 0x1fff,	-- brush index
		0,						-- tilemap index
		peekw(addr+2),			-- x
		peekw(addr+4),			-- y
		peekw(addr+6),			-- tiles wide
		peekw(addr+8),			-- tiles high
		peekw(addr) >> 13)		-- orientation
end
update=||do
	tilemap(0,0,32,32,0,0,0,true)
end
--]]
--[[ test drawbrush() works
local brushmapAddr = blobaddr'brushmap'
local brushmapSize = blobsize'brushmap'
assert.eq(brushmapSize % 10, 0)
update=||do
	for i=0,brushmapSize-10,10 do
		local addr = brushmapAddr+i
		drawbrush(
			peekw(addr) & 0x1fff,	-- brush index
			peekw(addr+2) << 4,	-- screen x
			peekw(addr+4) << 4,	-- screen y
			peekw(addr+6),	-- tiles wide
			peekw(addr+8),	-- tiles high
			peekw(addr) >> 13,	-- orientation
			true)
	end
end
--]]
