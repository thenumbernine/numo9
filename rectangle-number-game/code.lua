math.randomseed(tstamp())
class = require 'ext.class'
range = require 'ext.range'
vec2 = require 'vec.vec2'
box2 = require 'vec.box2'
getScreenSize = require 'numo9.screen'.getScreenSize

-- randomize palette?
do
	-- do I still want these last 16 palette?
	poke(ramaddr'textFgColor', 0xc)
	poke(ramaddr'textBgColor', 0)

	local palAddr = blobaddr'palette'
	for i=16,255 do
		local color = require 'vec.vec3'()
			:map(|| math.random())
			:unit() * 31
		pokew(
			palAddr+(i<<1),
			color.x
			| (color.y << 5)
			| (color.z << 10)
			| 0x8000
		)
	end
end

-- [[ beginner?
boardSize = vec2(8, 8)
numPieces = 8
--]]
--[[ expert?
boardSize = vec2(20, 20)
numPieces = 64
--]]
--[[ super-expert?
boardSize = vec2(40, 40)
numPieces = 1024
--]]

mode(-1)

boardBBox = box2(vec2(1,1), boardSize)

red = 2
green = 7


-- tx1 ty1 tx2 ty2 in tiles
boardRect = |tx1,ty1,tx2,ty2,border, ...|do
	border ??= nil
	local x = tileSize * (tx1 - 1) + border
	local y = tileSize * (ty1 - 1) + border
	local w = tileSize * (tx2 - tx1 + 1) - 2 * border - 2
	local h = tileSize * (ty2 - ty1 + 1) - 2 * border - 2
	rect(x,y,w,h,...)
	rectb(x,y,w,h,12)
end


Rect=class()
Rect.init=|:,args|do
	self.bbox = args!.bbox:clone()
	self.color = args.color
end
Rect.clone=|:| Rect(self)
Rect.size=|:| self.bbox:size()+1
Rect.area=|:| self:size():product()
Rect.draw=|:|do
	local b = self.bbox
	boardRect(b.min.x, b.min.y, b.max.x, b.max.y, 2, self.color)
end

newGame=||do
	-- get our soln - start with one giant rect
	solnRects = table{Rect{bbox=boardBBox}}
	for try=1,math.huge do
		if #solnRects >= numPieces then break end

		-- linear pick-random
		--local r = solnRects:pickRandom()
		-- quadratic pick-random to favor table start <-> larger boxes
		local ri = 1 + math.floor(math.random() * math.random() * #solnRects)

		local r = solnRects[ri]:clone()
		local rsize = r:size()
		--local i = vec2.fields:pickRandom()	-- random axis
		--local i = vec2.fields[(try%2)+1]		-- alternating axis
		-- weight axis by each dimension, so larger gets divided more often
		local i = math.random() * (rsize.x + rsize.y) < rsize.x and 'x' or 'y'
		if rsize[i] > 1 then
			local r2 = r:clone()
			-- hmm maybe todo weight random towards middle than ends?
			local mid = math.random(r.bbox.min[i], r.bbox.max[i]-1)
			r.bbox.max[i] = mid
			r2.bbox.min[i] = mid+1
			if r:area() > 1 and r2:area() > 1 then
				-- out with old
				solnRects:remove(ri)
				-- insert new boxes
				solnRects:insert(r)
				solnRects:insert(r2)
				-- sort boxes by area, largest to smallest
				solnRects:sort(|a,b| a:area() > b:area())
			end
		end
	end
	-- for each rect, choose a point and share its area
	areaForCell = {}
	for i,r in ipairs(solnRects) do
		r.color = i
		r.showPos = vec2(
			math.random(r.bbox.min.x, r.bbox.max.x),
			math.random(r.bbox.min.y, r.bbox.max.y)
		)
		--[[ push away from edges to make things tough
		if r.showPos.x == 1 and r.bbox.max.x > 1 then r.showPos.x += 1 end
		if r.showPos.y == 1 and r.bbox.max.y > 1 then r.showPos.y += 1 end
		if r.showPos.x == boardSize.x and r.bbox.min.x < boardSize.x then r.showPos.x -= 1 end
		if r.showPos.y == boardSize.y and r.bbox.min.y < boardSize.y then r.showPos.y -= 1 end
		--]]
		r.area = (r.bbox:size()+1):product()
		areaForCell[r.showPos.x] ??= {}
		areaForCell[r.showPos.x][r.showPos.y] = r.area
	end

	userRects = table()

	-- state vars
	youWonTime = nil
	pressPos = nil
	newRectColor = nil
	nextColor = 0
end

newGame()

update=||do
	local screenWidth, screenHeight = getScreenSize()
	tileSize = screenHeight / boardSize.y
	cls()

	local mouseX, mouseY = mouse()
	local mouseTilePos = || vec2(
		math.floor(mouseX / tileSize) + 1,
		math.floor(mouseY / tileSize) + 1
	)

	blend(1)
	for y=1,boardSize.y do
		for x=1,boardSize.x do
			boardRect(x,y,x,y,0,8)
		end
	end

	-- show cheat boxes
	if btn'a' then
		for _,r in ipairs(solnRects) do
			r:draw()
		end
	end

	-- show user-created boxes
	for i,r in ipairs(userRects) do
		r:draw()
	end

	-- show user-creating bbox
	if pressPos then
		local dragPos = mouseTilePos():clamp(boardBBox)
		local b = box2(pressPos):stretch(dragPos)
		local x = tileSize * (b.min.x-1) + 2
		local y = tileSize * (b.min.y-1) + 2
		local w = tileSize * (b.max.x - b.min.x + 1) - 6
		local h = tileSize * (b.max.y - b.min.y + 1) - 6
		local area = (b:size()+1):product()
		-- b's color is green if it touches one showPos and the areas match
		-- b's color is red otherwise (and throw it away upon release?)
		local foundArea
		newRectColor = nil
		for _,r in ipairs(userRects) do
			if r.bbox:touches(b) then
				newRectColor = red
				goto done
			end
		end
		for j=b.min.y,b.max.y do
			for i=b.min.x,b.max.x do
				local cellArea = areaForCell?[i]?[j]
				if cellArea then
					if foundArea then
						newRectColor = red
						goto done
					end
					foundArea = cellArea
				end
			end
		end
::done::
		if not newRectColor then
			newRectColor = foundArea == area and green or red
		end
		boardRect(b.min.x, b.min.y, b.max.x, b.max.y, 2, newRectColor)
	end

	blend(-1)

	for i,r in ipairs(solnRects) do
		local s = tostring(r.area)
		text(
			s,
			tileSize * (r.showPos.x - .5) - 8*#s/2,
			tileSize * (r.showPos.y - .5) - 4,
			nil,
			nil,
			tileSize/16,
			tileSize/16
		)
	end

	text('X', mouseX - 4, mouseY - 4)

	if youWonTime then
		text('YOU WON', 20, 100, 12, -1, 5, 5)
		if time() - youWonTime > 10 then
			newGame()
		end
		return
	end

	if keyp'mouse_left' then
		pressPos = mouseTilePos()
		if not boardBBox:contains(pressPos) then
			pressPos = nil
		end
		for i,r in ipairs(userRects) do
			if r.bbox:contains(pressPos) then
				userRects:remove(i)
				pressPos = nil
				break
			end
		end
	elseif keyr'mouse_left' then
		local releasePos = mouseTilePos():clamp(boardBBox)
		if pressPos
		and newRectColor == green
		then
			local b = box2(pressPos):stretch(releasePos)
			-- b's color is green if it touches one showPos and the areas match
			-- b's color is red otherwise (and throw it away upon release?)
			userRects:insert(Rect{bbox=b, color=nextColor+:=1})
			local notAllCovered
			for j=1,boardSize.y do
				for i=1,boardSize.x do
					if not userRects:find(nil, |r| r.bbox:contains(vec2(i,j))) then
						notAllCovered = true
						goto done2
					end
				end
			end
::done2::
			if not notAllCovered then
				youWonTime = time()
			end
		end
		pressPos = nil
		newRectColor = nil
	end
end
