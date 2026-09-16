--[[
draw tilemaps
cycle with 'a' button
--]]
matscale(.5, .5)
tilemapIndex = 0
tilemapMax = 4
update=||do
	if btnp'a' or btnp'b' then tilemapIndex += 1 end
	if btnp'x' or btnp'y' then tilemapIndex -= 1 end
	tilemapIndex %= tilemapMax
	tilemap(0,0, 32,32, 0,0, 0,false,0, tilemapIndex)
	text('tilemap '..tilemapIndex, 0, 0)
	text('tget(0,0)='..tget(tilemapIndex, 0, 0), 0, 8)

	elli(
		math.cos(time()) * 120 + 128 - 8,
		math.sin(time()) * 120 + 128 - 8,
		16, 16
	)

	for k,m in ipairs{
		'modelMat',
		'viewMat',
		'projMat',
	} do
		for i=0,3 do
			for j=0,3 do
				text(
					tostring(peekf(
						ramaddr'viewMat'+((i|(j<<2))<<2)
					)),
					24*j,
					24 + 8*(i + 4 * (k-1))
				)
			end
		end
	end
end
