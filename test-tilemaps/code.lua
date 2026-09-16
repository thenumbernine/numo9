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

 for _,m in ipairs{
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
     64*j, 24 + 8*(i + 5 * _))
   end
  end
 end

end
