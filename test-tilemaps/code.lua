--[[
draw tilemaps
cycle with 'a' button
--]]
tilemapIndex = 0
tilemapMax = 4
update=||do
	if btnp'a' or btnp'b' then tilemapIndex += 1 end
	if btnp'x' or btnp'y' then tilemapIndex -= 1 end
	tilemapIndex %= tilemapMax
	tilemap(0,0, 32,32, 0,0, 0,false,0, tilemapIndex)
	text('tilemap '..tilemapIndex, 0, 0)
	text('tget(0,0)='..tget(tilemapIndex, 0, 0), 0, 8)
end
