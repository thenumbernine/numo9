--#include ext/class.lua
--#include ext/range.lua
--#include vec/vec2.lua

math.randomseed(tstamp())

dt = 1/60
-- [[
mode'480x270x8bppIndex' -- do string setters not work?
screenSize = vec2(480, 270)
--]]
--[[
mode(0)
screenSize = vec2(256, 256)
--]]

radiusForIndex = |i| 5*i
colorForIndex = |i| 0xFF & (i + 1)

density = 1

Piece=class()
Piece.init=|:,args|do
	self.index = args!.index
	self.pos = vec2(screenSize.x/2, 0)
	self.vel = vec2(0,0)
end
Piece.getRadius=|:| radiusForIndex(self.index)
Piece.getColor=|:| colorForIndex(self.index)
Piece.getMass=|:| density * math.pi * self:getRadius()^2
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

local grav = 120
local planes = table{
	{normal=vec2(1,0), negDist=-vec2(1,0):dot(vec2(0,0))},
	{normal=vec2(-1,0), negDist=-vec2(-1,0):dot(vec2(screenSize.x,0))},
	{normal=vec2(0,-1), negDist=-vec2(0,-1):dot(vec2(0,screenSize.y))},
}

local epsilon = 1e-7

points = 0

cursorSpeed = 120
cursorX = screenSize.x / 2
update=||do
	cls()
	if btn'left' then
		cursorX -= cursorSpeed * dt
	end
	if btn'right' then
		cursorX += cursorSpeed * dt
	end
	if btnp'up' then
		mattrans(0, cursorSpeed * dt, 0)
	end
	if btnp'down' then
		mattrans(0, -cursorSpeed * dt, 0)
	end
	if btnp'b' then
		makeNextPiece()
	end

	cursorX = math.clamp(cursorX, nextPiece:getRadius(), screenSize.x - nextPiece:getRadius())
	nextPiece.pos.x = cursorX

	line(1,0,0,screenSize.y,12)
	line(1,screenSize.y,screenSize.x,screenSize.y,12)
	line(screenSize.x,screenSize.y,screenSize.x,0,12)

	for _,piece in ipairs(pieces) do
		piece:draw()
	end

	-- draw next piece last on top of everything else
	nextPiece:draw()

--trace'begin integration'
	-- update system as a whole ...
	-- find smallest timestep until intersection
	local remainingDt = dt
	local collisionTries = 0
	repeat
		collisionTries += 1
		-- determine maximum step before collision
		local stepDt = remainingDt
		local collisionPiece, collisionPiece2, collisionPlane
		for pieceIndex,piece in ipairs(pieces) do
			-- sphere/plane intersection, what move fraction hits each wall...
			-- ray pt: pos + vel * stepDt
			-- dist from plane: dist = (pt - planept) . planeN
			-- ray dist from plane = radius: radius = (pos + vel * stepDt - planePt) . planeN
			-- (radius - (pos . planeN - planePt . planeN) / (vel . planeN) = stepDt
			for _,plane in ipairs(planes) do
				local denom = piece.vel:dot(plane.normal)
				local planeDist = plane.normal:dot(piece.pos) + plane.negDist
				if math.abs(denom) >= epsilon
				and piece.vel:dot(plane.normal) < -epsilon
				then
					-- if our movestep touches the wall within [0,dt] ...
					local wallDt = (piece:getRadius() - planeDist) / denom
					if wallDt >= 0 and wallDt < stepDt then
						stepDt = wallDt
						collisionPiece = piece
						collisionPiece2 = nil
						collisionPlane = plane
					end
				end
			end
		end
		-- test sphere/sphere collisions
		-- TODO when pieces merge, they can cause it to lock up in here via constant stepDt==0 evaoluation ...
		for i=1,#pieces-1 do
			local a = pieces[i]
			for j=i+1,#pieces do
				local b = pieces[j]
				-- |(pa + va * stepDt) - (pb + vb * stepDt)|^2 = (ra + rb)^2
				-- (pb - pa + (vb - va) * stepDt)^2 = (ra + rb)^2
				-- p = pb - pa
				-- v = vb - va
				-- r^2 = (ra + rb)^2
				-- (p + v * stepDt)^2 = r^2
				-- p.p + 2 * p.v * stepDt + v.v * stepDt^2 = r^2
				-- v.v * stepDt^2 + 2 * p.v * stepDt + p.p - r^2 = 0
				-- stepDt = (-b +- sqrt(b^2 - 4 * a * c)) / (2 * a)
				local dvelx, dvely = vec2_sub(b.vel.x, b.vel.y, a.vel.x, a.vel.y)
				local dposx, dposy = vec2_sub(b.pos.x, b.pos.y, a.pos.x, a.pos.y)
				local coeffA = vec2_lenSq(dvelx, dvely)		-- always non-negative
				if coeffA > 0 then
					local coeffB = 2 * vec2_dot(dvelx, dvely, dposx, dposy)
					local coeffC = vec2_lenSq(dposx, dposy) - (a:getRadius() + b:getRadius())^2
					local discr = coeffB^2 - 4 * coeffA * coeffC
					if discr > 0 then
						local sqrtDiscr = math.sqrt(discr)
						-- coeffA >= 0, so dt1 <= dt2
						local dt1 = (-coeffB - sqrtDiscr) / (2 * coeffA)	-- entering sphere collision
						--local dt2 = (-coeffB + sqrtDiscr) / (2 * coeffA)	-- exiting sphere collision ... don't bother?
						if dt1 >= 0 and dt1 < stepDt then
							stepDt = dt1
							collisionPiece = a
							collisionPiece2 = b
							collisinPlane = nil
						end
					end
				end
			end
		end

--trace('integrating', stepDt, '#pieces', #pieces)
		-- now integrate
		for _,piece in ipairs(pieces) do
			piece.pos.x += piece.vel.x * stepDt
			piece.pos.y += piece.vel.y * stepDt
		end

		-- resolve collisions
		-- TODO give them an epsilon for static collision and then solve linear system for resting positions
		if collisionPiece then
			local restitution = .1
			if collisionPlane then
--trace('hit wall', collision.normal, collision.dist)
				local piece = collisionPiece
				local plane = collisionPlane
				local normal = plane.normal
				local planeDist = piece.pos:dot(normal) + plane.negDist
				local dv = piece.vel:dot(normal) * (1 + restitution)
				piece.vel.x -= normal.x * dv
				piece.vel.y -= normal.y * dv
			else
--trace('hit pieces', collision.pieceIndex, collision.pieceIndex2)
				local a = collisionPiece
				local b = collisionPiece2
				local aMass = a:getMass()
				local bMass = b:getMass()
				local dposx, dposy = vec2_sub(b.pos.x, b.pos.y, a.pos.x, a.pos.y)	-- from a towards b
				local amomx, amomy = vec2_scale(aMass, a.vel.x, a.vel.y)
				local bmomx, bmomy = vec2_scale(bMass, b.vel.x, b.vel.y)
				local dmomx, dmomy = vec2_sub(bmomx, bmomy, amomx, amomy)	-- b's vel from a's perspective
				local normalx, normaly = vec2_unit(dposx, dposy)

				local dv = vec2_dot(normalx, normaly, dmomx, dmomy) * (1 + restitution)
				local dav = -dv / aMass
				local dbv = dv / bMass
				a.vel.x -= normalx * dav
				a.vel.y -= normaly * dav
				b.vel.x -= normalx * dbv
				b.vel.y -= normaly * dbv
			end
		end

		-- ok so in most best integrators we'd resolve all collisions before proceeding...
		-- meh, I don't want things to get stuck, and I'm too lazy to do the full proper static forces solver
		-- make sure we advance 10% of whats left and let the penalty force take care of the rest.
		stepDt = math.max(remainingDt * .1, stepDt)

		remainingDt -= stepDt
	until remainingDt == 0
	-- or collisionTries > 10 -- insted of just testing tries
--trace('integration took', collisionTries, 'tries')
	-- if we did have 5 steps at stepDt==0 then something is stuck and something is wrong ...
	triesTextWidth = triesTextWidth or 0
	triesTextWidth = text(tostring(collisionTries), screenSize.x - triesTextWidth, 0)

	-- now integrate grvity
	for _,piece in ipairs(pieces) do
		piece.vel.y += grav * dt
	end

	-- also add any penalty constraints for interpenetration
	local penalty = 3
	for _,piece in ipairs(pieces) do
		for _,plane in ipairs(planes) do
			local normal = plane.normal
			local planeDist = normal:dot(piece.pos) + plane.negDist
			if -piece:getRadius() + epsilon < planeDist and planeDist < piece:getRadius() - epsilon then
				-- if we're going into the plane then zero the normal component
				if piece.vel:dot(normal) < 0 then
					local dv = piece.vel:dot(normal)
					piece.vel.x -= normal.x * dv
					piece.vel.y -= normal.y * dv
				end
				piece.vel.x += normal.x * penalty
				piece.vel.y += normal.y * penalty
			end
		end
	end
	for i=#pieces-1,1,-1 do
		local a = pieces[i]
		for j=#pieces,i+1,-1 do
			local b = pieces[j]
			local dposx, dposy = vec2_sub(b.pos.x, b.pos.y, a.pos.x, a.pos.y)
			local distSq = vec2_lenSq(dposx, dposy)
			if distSq <= (a:getRadius() + b:getRadius() + 2)^2 then
				if a.index == b.index then
					pieces:remove(j)
					a.pos.x = .5 * (a.pos.x + b.pos.x)
					a.pos.y = .5 * (a.pos.y + b.pos.y)
					local aMass = a:getMass()
					local bMass = b:getMass()
					local invDenom = 1 / (aMass + bMass)
					local ca = aMass * invDenom
					local cb = bMass * invDenom
					a.vel.x = a.vel.x * ca + b.vel.x * cb
					a.vel.y = a.vel.y * ca + b.vel.y * cb
					points += 2 * a.index
					a.index += 1
					break
				end
				-- otherwise ... still apply a penalty force to them
				if distSq > 0 then
					local dist = math.sqrt(distSq)
					local normalx, normaly = vec2_scale(1/dist, dposx, dposy)	-- is b's collision normal
					local a_normal = vec2_dot(a.vel.x, a.vel.y, normalx, normaly)
					if a_normal > 0 then	-- because a's normal is -normal, so use > instead of <
						a.vel.x -= normalx * a_normal
						a.vel.y -= normaly * a_normal
					end
					a.vel.x -= normalx * penalty
					a.vel.y -= normaly * penalty
					local b_normal = vec2_dot(b.vel.x, b.vel.y, normalx, normaly)
					if b_normal < 0 then
						b.vel.x -= normalx * b_normal
						b.vel.y -= normaly * b_normal
					end
					b.vel.x += normalx * penalty
					b.vel.y += normaly * penalty
				end
			end
		end
	end

	text(tostring(points))
end
