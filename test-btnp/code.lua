-- ported from https://github.com/nesbox/TIC-80/wiki/btnp
local x=120
local y=80
cls(12)
color = 2
update=||do
	-- [[ do numbers work?
    if btnp(0,0,60,6) then x+=10 end	-- right
    if btnp(1,0,60,6) then y+=10 end	-- down
    if btnp(2,0,60,6) then x-=10 end	-- left
	if btnp(3,0,60,6) then y-=10 end	-- up
	--]]
	--[[ do names work? yes
    if btnp('right',0,60,6) then x+=10 end
    if btnp('down',0,60,6) then y+=10 end
    if btnp('left',0,60,6) then x-=10 end
	if btnp('up',0,60,6) then y-=10 end
	--]]
	
	if btnp(4) then color = 2 end
	if btnp(5) then color = 4 end
	if btnp(6) then color = 6 end
	if btnp(7) then color = 8 end

	rect(x,y,10,10,color)
	local x,y,sx,sy = mouse()
	if sx ~= 0 or sy ~= 0 then trace(sx,sy) end
end
