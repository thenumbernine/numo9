-- divide 8 cuz font size is 8
local w, h = getScreenSize()
local UISize = (vec2(w,h)/8-vec2(0,4)):floor()
UI=class{
	size=UISize,
	bbox=box2(1, UISize),
	center=(UISize/2):ceil(),
	-- used for both game and ui
	drawBorder=|:,b|do
		local mins = b.min
		local maxs = b.max
		for x=mins.x+1,maxs.x-1 do
			if mins.y >= 1 and mins.y <= ui.size.y then
				con.locate(x, mins.y)
				con.write'\151'	--'-'
			end
			if maxs.y >= 1 and maxs.y <= ui.size.y then
				con.locate(x, maxs.y)
				con.write'\156'	--'-'
			end
		end
		for y=mins.y+1,maxs.y-1 do
			if mins.x >= 1 and mins.x <= ui.size.x then
				con.locate(mins.x, y)
				con.write'\153'	--'|'
			end
			if maxs.x >= 1 and maxs.x <= ui.size.x then
				con.locate(maxs.x, y)
				con.write'\154'	--'|'
			end
		end
		local minmax = {mins, maxs}
		local asciicorner = {{'\150','\155'},{'\152','\157'}}
		for x=1,2 do
			for y=1,2 do
				local v = vec2(minmax[x].x, minmax[y].y)
				if ui.bbox:contains(v) then
					con.locate(v:unpack())
					con.write(asciicorner[x][y])	--'+'
				end
			end
		end
	end,
	fillBox=|:,b|do
		b = box2(b):clamp(ui.bbox)
		for y=b.min.y,b.max.y do
			con.locate(b.min.x, y)
			con.write((' '):rep(b.max.x - b.min.x + 1))
		end
	end,
}
ui=UI()
