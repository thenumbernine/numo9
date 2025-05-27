local m = 0
local numModes = 50
local sx, sy = 1, 1
update=||do
	cls()
	local x, y, ssx, ssy = mouse()
	sx += ssx
	sy += ssy
	local bl = key'mouse_left'
	if keyp'mouse_left' then
		m += 1
		m %= numModes
		mode(m)
	elseif keyp'mouse_right' then
		m -= 1
		m %= numModes
		mode(m)
	end
	spr(bl and 0 or 1, 
		x, y,
		1, 1,
		nil, nil,
		nil, nil,
		sx, sy)
	text('mode '..m, x - 8, y + 8)
end
