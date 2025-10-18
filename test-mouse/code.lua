--#include ext/range.lua

local m = 0
local modes = range(0,49):append{255}
local sx, sy = 1, 1
update=||do
	cls()
	local x, y, ssx, ssy = mouse()
	sx += ssx
	sy += ssy
	local bl = key'mouse_left'
	if keyp'mouse_left' then
		m += 1
		m %= #modes
		mode(modes[m+1])
	elseif keyp'mouse_right' then
		m -= 1
		m %= #modes
		mode(modes[m+1])
	end
	spr(bl and 0 or 1, 
		x, y,
		nil, nil, nil,	-- tilesWide, tilesHigh, orientation2D,
		sx, sy
	)
	text('mode '..modes[m+1], x - 8, y + 8)
end
