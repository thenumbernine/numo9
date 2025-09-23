-- title = suika-demake
-- saveid = suika
-- author = Chris Moore

--#include ext/class.lua
--#include ext/range.lua
--#include vec/vec2.lua

--dt = 1/60
dt = 1/30
screenSize = vec2(256, 256)

radiusForIndex=range(10):mapi(|i| 2*i + 10)
colorForIndex=range(10):mapi(|i| i + 1)

Piece=class()
Piece.init=|:,args|do
	self.index = args!.index
	self.pos = vec2(screenSize.x/2, 0)
	self.vel = vec2(0,0)
end
Piece.getRadius=|:| radiusForIndex[self.index]
Piece.getColor=|:| colorForIndex[self.index]
Piece.draw=|:|do
	local radius = self:getRadius()
	local x,y,w,h = 
		self.pos.x-radius,
		self.pos.y-radius,
		2*radius,
		2*radius
	elli(x,y,w,h,self:getColor())
	local white = 12
	ellib(x,y,w,h,white)
end

pieces = table()
makeNextPiece=||do
	pieces:insert(nextPiece)
	nextPiece = Piece{index=math.random(1,5)}
end
makeNextPiece()

local grav = vec2(0, 60)
local planes = table{
	{normal=vec2(1,0), negDist=-vec2(1,0):dot(vec2(0,0))},
	{normal=vec2(-1,0), negDist=-vec2(-1,0):dot(vec2(screenSize.x,0))},
	{normal=vec2(0,-1), negDist=-vec2(0,-1):dot(vec2(0,screenSize.y))},
}

local epsilon = 1e-7

cursorSpeed = 60
cursorX = screenSize.x / 2
update=||do
	cls()
	if btn'left' then
		cursorX -= cursorSpeed * dt
	end
	if btn'right' then
		cursorX += cursorSpeed * dt
	end
	if btnp'b' then
		makeNextPiece()
	end

	cursorX = math.clamp(cursorX, 0, screenSize.x)
	nextPiece.pos.x = cursorX
	nextPiece:draw()

	for _,piece in ipairs(pieces) do
		piece:draw()
	end

--trace'begin integration'
	-- update system as a whole ...
	-- find smallest timestep until intersection
	local remainingDt = dt
	local tries = 0
	repeat
		tries += 1
		-- determine maximum step before collision
		local stepDt = remainingDt
		local collision
		for pieceIndex,piece in ipairs(pieces) do
			-- sphere/plane intersection, what move fraction hits each wall...
			-- ray pt: pos + vel * stepDt
			-- dist from plane: dist = (pt - planept) . planeN
			-- ray dist from plane = radius: radius = (pos + vel * stepDt - planePt) . planeN
			-- (radius - (pos . planeN - planePt . planeN) / (vel . planeN) = stepDt
			for _,plane in ipairs(planes) do
				local denom = piece.vel:dot(plane.normal)
				local planeDist = plane.normal:dot(piece.pos) + plane.negDist
				--[[ if we are already interpenetrating the wall ...
				if -piece:getRadius() + epsilon < planeDist and planeDist < piece:getRadius() - epsilon then
					stepDt = 0
					collision = {pieceIndex = pieceIndex, plane = plane}
				else
				--]]
					if math.abs(denom) < epsilon then
						--[[ remove normal component completely?
						piece.vel -= denom * piece.vel
						--]]
						--[[ push away from wall
						if -piece.radius <= planeDist and planeDist <= piece.radius then
							piece.pos += plane.normal * (piece.radius - planeDist)
						end
						--]]
					elseif piece.vel:dot(plane.normal) < 0 then
						-- if our movestep touches the wall within [0,dt] ...
						local wallDt = (piece:getRadius() - planeDist) / denom
						if wallDt >= 0 and wallDt < stepDt then	
							stepDt = wallDt
							collision = {pieceIndex = pieceIndex, plane = plane}
						end
					end
				--end
			end
		end
		-- test sphere/sphere collisions
		for i=1,#pieces-1 do
			local pieceA = pieces[i]
			for j=i+1,#pieces do
				local pieceB = pieces[j]
				-- |(pa + va * stepDt) - (pb + vb * stepDt)|^2 = (ra + rb)^2
				-- (pb - pa + (vb - va) * stepDt)^2 = (ra + rb)^2
				-- p = pb - pa
				-- v = vb - va
				-- r^2 = (ra + rb)^2
				-- (p + v * stepDt)^2 = r^2
				-- p.p + 2 * p.v * stepDt + v.v * stepDt^2 = r^2
				-- v.v * stepDt^2 + 2 * p.v * stepDt + p.p - r^2 = 0
				-- stepDt = (-b +- sqrt(b^2 - 4 * a * c)) / (2 * a)
				local v = pieceB.vel - pieceA.vel
				local p = pieceB.pos - pieceA.pos
				local a = v:dot(v)		-- always non-negative
				if a > 0 then
					local b = 2 * v:dot(p)
					local c = p:dot(p) - (pieceA:getRadius() + pieceB:getRadius())^2
					local discr = b^2 - 4 * a * c
					if discr > 0 then
						local sqrtDiscr = math.sqrt(discr)
						-- a >= 0, so dt1 <= dt2
						local dt1 = (-b - sqrtDiscr) / (2 * a)	-- entering sphere collision
						--local dt2 = (-b + sqrtDiscr) / (2 * a)	-- exiting sphere collision ... don't bother?
						if dt1 >= 0 and dt1 < stepDt then
							stepDt = dt1
							collision = {
								pieceIndex = i,
								pieceIndex2 = j,
							}
						end
					end
				end
			end
		end
	
--trace('integrating', stepDt, '#pieces', #pieces)
		-- now integrate
		for _,piece in ipairs(pieces) do
			piece.pos += piece.vel * stepDt
		end

		-- resolve collisions
		-- TODO give them an epsilon for static collision and then solve linear system for resting positions
		if collision then
			local restitution = .1
			if collision.plane then
--trace('hit wall', collision.normal, collision.dist)				
				local piece = pieces[collision.pieceIndex]
				local plane = collision.plane
				local normal = plane.normal
				local planeDist = piece.pos:dot(normal) + plane.negDist
				--[[
				piece.pos += normal * (piece.radius - planeDist)
				--]]
				piece.vel -= normal * piece.vel:dot(normal) * (1 + restitution)
				--[[ extra penalty for interpenetration?
				if -piece:getRadius() + epsilon < planeDist and planeDist < piece:getRadius() - epsilon then
					local penalty = 1e-1
					piece.vel += normal * penalty
				end
				--]]
			else
--trace('hit pieces', collision.pieceIndex, collision.pieceIndex2)				
				local a = pieces[collision.pieceIndex]
				local b = pieces[collision.pieceIndex2]
				if a.index == b.index then
					pieces:remove(collision.pieceIndex2)
					a.index += 1
				else
					local deltaPos = b.pos - a.pos	-- from a towards b
					local deltaVel = b.vel - a.vel	-- b's vel from a's perspective
					local normal = deltaPos:unit()
					a.vel += normal * deltaVel:dot(normal) * (1 + restitution)
					b.vel -= normal * deltaVel:dot(normal) * (1 + restitution)
				end
			end
		end

		remainingDt -= stepDt
	until remainingDt == 0
--trace('integration took', tries, 'tries')

	-- now integrate grvity
	for _,piece in ipairs(pieces) do
		piece.vel += grav * dt
	end

	-- also add any penalty constraints for interpenetration
	local penalty = 3
	for _,piece in ipairs(pieces) do
		for _,plane in ipairs(planes) do
			local planeDist = plane.normal:dot(piece.pos) + plane.negDist
			if -piece:getRadius() + epsilon < planeDist and planeDist < piece:getRadius() - epsilon then
				if piece.vel:dot(plane.normal) < 0 then
					piece.vel:set(0,0)
				end
				piece.vel += plane.normal * penalty
			end
		end
	end
end
