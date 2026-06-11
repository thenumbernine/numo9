class = require 'ext.class'
range = require 'ext.range'
vec2 = require 'vec.vec2'
box2 = require 'vec.box2'

boardSize = vec2(7, 7)
tileSize = 24

-- get our soln
rects = table()
do
	-- map from x,y to what rect it touches
	local rectAtPos = range(boardSize.x):mapi(|i| range(boardSize.y):mapi(|j| {}))
	while true do
		-- refresh cellsLeft based on rectAtPos ...
		local cellsLeft = table()
		for j=1,boardSize.y do
			for i=1,boardSize.x do
				if not rectAtPos[i][j].rect then
					cellsLeft:insert(vec2(i,j))
				end
			end
		end
		if #cellsLeft == 0 then break end
		-- pick a random empty cell
		local mins = cellsLeft:pickRandom()
print('mins', mins)
		local maxs = mins:clone()
		-- pick a random width it accomodates
		for i=mins.x,boardSize.x do
			if rectAtPos[i][mins.y].rect then
				break
			else
				maxs.x = i
			end
		end
print('maxs.x found', maxs.x)
		maxs.x = math.random(mins.x, maxs.x)
print('maxs.x picked', maxs.x)
		-- pick a random height it accomodates
		for j=mins.y,boardSize.y do
			-- if any are solid then fail
			local found
			for ii=mins.x,maxs.x do
				if rectAtPos[ii][j].rect then
					found = true
					break
				end
			end
			if found then break end
			maxs.y = j
		end
print('maxs.y found', maxs.y)
		maxs.y = math.random(mins.y, maxs.y)
print('maxs.y picked', maxs.y)
		-- insert the new rect
		local r = box2(mins, maxs)
print('inserting', r)
		rects:insert(r)
		for j=mins.y,maxs.y do
			for i=mins.x,maxs.x do
				--assert(not rectAtPos[i][j].rect)
				if rectAtPos[i][j].rect then
print('FAILED - two rects at one place - new touches', rectAtPos[i][j].rect)
					goto DONE
				end
				rectAtPos[i][j].rect = r
			end
		end
	end
end
::DONE::

update=||do
	cls()
	blend(1)
	for i,r in ipairs(rects) do
		local x = tileSize * r.min.x
		local y = tileSize * r.min.y
		local w = tileSize * (r.max.x - r.min.x + 1) - 2
		local h = tileSize * (r.max.y - r.min.y + 1) - 2
		rect(x, y, w, h, i)
		rectb(x, y, w, h, 12)
	end
	blend(-1)
	local x, y = mouse()
	text('x', x - 4, y - 4)
end
