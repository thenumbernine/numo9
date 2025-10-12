--#include ext/range.lua

-- i could store resolution in the RAM, but nah, just rtfm
local modes = range(0,49):append{255}

update=||do
	cls()
	t=time()

	local m = tonumber((t % #modes) // 1)
	mode(modes[m+1])
	local w, h = 
		peekw(ramaddr'screenWidth'),
		peekw(ramaddr'screenHeight')

	local x1, y1 = 
		w * (math.cos(t * .4) * .5 + .5),
		h * (math.sin(t * .5) * .5 + .5)
	local x2, y2 = 
		w * (math.cos(t * .6) * .5 + .5),
		h * (math.sin(t * .7) * .5 + .5)
	local xmin = math.min(x1, x2)
    local ymin = math.min(y1, y2)
	--ellib(	TODO bugs in ellipse border when not a circle
	elli(
		xmin,
		ymin,
		math.max(x1, x2) - xmin,
		math.max(y1, y2) - ymin,
		t * 3)

	local xmid = .5 * (x1 + x2)
	local ymid = .5 * (y1 + y2)
	
	local w, h = text('mode '..modes[m+1], -999, -999)
	mattrans(xmid, ymid)
	matrot(t)
	mattrans(- .5 * w, - 4)
	text('mode '..modes[m+1])
	matident()
end
