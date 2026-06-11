math.randomseed(tstamp())
class = require 'ext.class'
range = require 'ext.range'
vec2 = require 'vec.vec2'
box2 = require 'vec.box2'

boardSize = vec2(8, 8)
boardBBox = box2(vec2(1,1), boardSize)
tileSize = 24

-- ??fixme?
red = 3
green = 7

Rect=class()
Rect.init=|:,bbox|do
	self.bbox = bbox:clone()
end

-- get our soln - start with one giant rect
solnRects = table{Rect(boardBBox)}
local numPieces = 8
for try=1,math.huge do
	if #solnRects >= numPieces then break end
	local r = solnRects:pickRandom()
	--local i = vec2.fields:pickRandom()
	local i = vec2.fields[(try%2)+1]
	local rsize = r.bbox:size()+1	-- ... inclusive-size ...
	if rsize[i] > 1 then
		local r2 = Rect(r.bbox)
		local mid = math.random(r.bbox.min[i], r.bbox.max[i]-1)
		r.bbox.max[i] = mid
		r2.bbox.min[i] = mid+1
		solnRects:insert(r2)
	end
end
-- for each rect, choose a point and share its area
areaForCell = {}
for _,r in ipairs(solnRects) do
	r.showPos = vec2(
		math.random(r.bbox.min.x, r.bbox.max.x),
		math.random(r.bbox.min.y, r.bbox.max.y)
	)
	r.area = (r.bbox:size()+1):product()
	areaForCell[r.showPos.x] ??= {}
	areaForCell[r.showPos.x][r.showPos.y] = r.area
end

userRects = table()

update=||do
	cls()

	local mouseX, mouseY = mouse()
	local mouseTilePos = || vec2(math.floor(mouseX / tileSize), math.floor(mouseY / tileSize))

	blend(1)
	for y=1,boardSize.y do
		for x=1,boardSize.x do
			rect(tileSize * x, tileSize * y, tileSize - 2, tileSize - 2, 8)
			rectb(tileSize * x, tileSize * y, tileSize - 2, tileSize - 2, 12)
		end
	end
	for i,r in ipairs(solnRects) do
		--[[ show answer
		local x = tileSize * r.bbox.min.x
		local y = tileSize * r.bbox.min.y
		local w = tileSize * (r.bbox.max.x - r.bbox.min.x + 1) - 2
		local h = tileSize * (r.bbox.max.y - r.bbox.min.y + 1) - 2
		rect(x, y, w, h, i)
		rectb(x, y, w, h, 12)
		--]]
		local s = tostring(r.area)
		text(s, tileSize * (r.showPos.x + .5) - 8*#s/2, tileSize * (r.showPos.y + .5) - 4)
	end

	-- show user-created boxes
	for i,r in ipairs(userRects) do
		local b = r.bbox
		local x = tileSize * b.min.x + 2
		local y = tileSize * b.min.y + 2
		local w = tileSize * (b.max.x - b.min.x + 1) - 6
		local h = tileSize * (b.max.y - b.min.y + 1) - 6
		rect(x, y, w, h, i)
		rectb(x, y, w, h, 12)

	end

	-- show user-creating bbox
	if pressPos then
		local dragPos = mouseTilePos():clamp(boardBBox)
		local b = box2(pressPos):stretch(dragPos)
		local x = tileSize * b.min.x + 2
		local y = tileSize * b.min.y + 2
		local w = tileSize * (b.max.x - b.min.x + 1) - 6
		local h = tileSize * (b.max.y - b.min.y + 1) - 6
		local area = (b:size()+1):product()
		-- b's color is green if it touches one showPos and the areas match
		-- b's color is red otherwise (and throw it away upon release?)
		local foundArea
		newRectColor = nil
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
		rect(x, y, w, h, newRectColor)
		rectb(x, y, w, h, 12)
	end

	blend(-1)

	text('X', mouseX - 4, mouseY - 4)

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
			userRects:insert{bbox=b}
		end
		pressPos = nil
		newRectColor = nil
	end
end
