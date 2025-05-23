mode(42)

local sx, sy = 1, 1
update=[]do
	local x, y, ssx, ssy = mouse()
	sx += ssx
	sy += ssy
	local bl = key'mouse_left'
	spr(bl and 0 or 1, 
		x - 4, y - 4,
		1, 1,
		nil, nil,
		nil, nil,
		sx, sy)
end
