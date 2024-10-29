-- ported from https://github.com/nesbox/TIC-80/wiki/btnp
local x=120
local y=80
cls(12)
function update()
	if btnp(0,0,60,6) then y-=10 end
    if btnp(1,0,60,6) then y+=10 end
    if btnp(2,0,60,6) then x-=10 end
    if btnp(3,0,60,6) then x+=10 end
	rect(x,y,10,10,8)
	local x,y,sx,sy = mouse()
	if sx ~= 0 or sy ~= 0 then trace(sx,sy) end
end
