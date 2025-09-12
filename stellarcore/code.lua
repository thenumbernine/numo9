-- title = Stellar Core
-- saveid = stellarcore
-- author = Chris Moore
-- description = classic "Asteroids" but with proper spherical universes, and interconnections with neighboring universes.

--#include ext/range.lua
--#include numo9/matstack.lua
--#include vec/vec2.lua
--#include vec/vec3.lua
--#include vec/quat.lua

math.randomseed(tstamp())
local sqrt_1_2 = math.sqrt(.5)

--modeIndex = 0	screenSize = vec2(256, 256)
modeIndex = 42	screenSize = vec2(480, 270)
mode(modeIndex)


-- https://math.stackexchange.com/a/1586185/206369
randomSphereSurface = ||do
	local phi = math.acos(2 * math.random() - 1) - math.pi / 2
	local lambda = 2 * math.pi * math.random()
	return math.cos(phi) * math.cos(lambda),
		math.cos(phi) * math.sin(lambda),
		math.sin(phi)
end

randomPos=||do
	local x,y,z = randomSphereSurface()
	local qx, qy, qz, qw = quat_fromAngleAxisUnit(math.random() * math.pi, x,y,z)
	return quat_mul(
		qx, qy, qz, qw,
		quat_fromAngleAxisUnit(math.random() * 2 * math.pi, 1, 0, 0)
	)
end

randomVel=||do
	local x,y,z = randomSphereSurface()
	return quat(x,y,z,0)
end


local gravConst = .1
local nextSphereColor = 1

local Sphere = class()
Sphere.init=|:,args|do
	self.pos = vec3(args.pos)
	self.radius = args!.radius
	self.portals = table()
	self.objs = table()			-- only attach objs to one sphere -- their .sphere -- and test all portals spheres for inter-sphere interactions
	self.color = nextSphereColor
	nextSphereColor += 1
end
Sphere.update=|:|do
	local objs = self.objs
	-- do updates
	for i=#objs,1,-1 do
		local o = objs[i]
		-- do update
		o:update()
		-- remove dead
		if o.dead then objs:remove(i) end
	end
	-- do inter-object interactions (touch, forces, etc)
	for i=1,#objs-1 do
		local o = objs[i]
		if not o.dead then
			local ozx, ozy, ozz = quat_zAxis(o.pos:unpack())
			local omass = o:calcMass()
			for i2=i+1,#objs do
				local o2 = objs[i2]
				if not o2.dead then
					local o2mass = o2:calcMass()
					local o2zx, o2zy, o2zz = quat_zAxis(o2.pos:unpack())
					-- check touch
					local dist = math.acos(
						vec3_dot(ozx, ozy, ozz, o2zx, o2zy, o2zz)
					) * self.radius
					if dist < (o.size + o2.size) then
						if o.touch then o:touch(o2) end
						if not o.dead and not o2.dead then
							if o2.touch then o2:touch(o) end
						end
						if o.dead then break end
					end

					-- apply a force towards each object ...
					if o.useGravity and o2.useGravity then
						local midsize = .5 * (o.size + o2.size)
						local mu = gravConst * math.min(
							1 / (dist * dist),
							dist / (midsize * midsize * midsize)
						)
						local rhsx, rhsy, rhsz = vec3_unit(
							vec3_cross(ozx, ozy, ozz, o2zx, o2zy, o2zz)
						)
						o.vel.x += rhsx * mu * o2mass
						o.vel.y += rhsy * mu * o2mass
						o.vel.z += rhsz * mu * o2mass
						o2.vel.x -= rhsx * mu * omass
						o2.vel.y -= rhsy * mu * omass
						o2.vel.z -= rhsz * mu * omass
					end
				end
			end
		end
	end
end


local dt = 1/60

drawTri = |pos, fwd, size, color| do
	local rightx = -fwd.y
	local righty = fwd.x
	line(pos.x+size*fwd.x, pos.y+size*fwd.y, pos.x+size*(rightx - fwd.x), pos.y+size*(righty - fwd.y), color)
	line(pos.x+size*fwd.x, pos.y+size*fwd.y, pos.x+size*(-rightx - fwd.x), pos.y+size*(-righty - fwd.y), color)
end


viewPos = quat()
viewSphere = startSphere

-- v = quat
-- returns x,y, qx, qy, qz, qw
-- where x,y are the point in 2D (centered at 0,0)
-- and q_i is the quaternion after transforming to be relative to viewPos
quatTo2D = |vx, vy, vz, vw|do
	vx, vy, vz, vw = quat_mul(
		-viewPos.x, -viewPos.y, -viewPos.z, viewPos.w,
		vx, vy, vz, vw
	)
	local posx, posy, posz = quat_zAxis(vx, vy, vz, vw)
	local len2sq = vec2_lenSq(posx, posy)
	if len2sq < 1e-20 then
		return 0, 0,	-- pos2d
			0, 0, -sqrt_1_2, sqrt_1_2	-- fwd quat
	end
	local s = math.acos(posz) * viewSphere.radius / math.sqrt(len2sq)
	return posx * s, posy * s,	-- pos2d
		vx, vy, vz, vw	-- fwd quat
end

-- v = quat
-- does mat transforms
transformQuatTo2D = |vx,vy,vz,vw| do
	local pos2dx, pos2dy, vx, vy, vz, vw = quatTo2D(vx,vy,vz,vw)
	mattrans(pos2dx, pos2dy)

	-- cos/sin -> atan -> cos/sin ... plz just do a matmul
	local fwdx, fwdy, fwdz = quat_yAxis(vx, vy, vz, vw)
	local len2sq = vec2_lenSq(fwdx, fwdy)
	if len2sq < 1e-20 then return end
	local s = 1/math.sqrt(len2sq)
	matrotcs(fwdx * s, fwdy * s, 0, 0, 1)
end


local Object = class()
Object.pos = quat()
Object.vel = quat(0,0,0,0)	-- pure-quat with vector = angular momentum
Object.size = 5
Object.color = 12
Object.accel = 50
Object.rot = 5
Object.density = 1
Object.calcMass = |:| math.pi * self.size^2 * self.density
Object.useGravity = true
Object.init=|:,args|do
	if args then
		for k,v in pairs(args) do self[k] = v end
	end
	self.sphere.objs:insert(self)
	self.pos = (args and args.pos or self.pos):clone()
	self.vel = (args and args.vel or self.vel):clone()
end
Object.draw=|:|do
	matpush()
	transformQuatTo2D(self.pos:unpack())

	matscale(self.size / 4, self.size / 4)
	mattrans(-4, -4)
	spr(0, 0, 0, 1, 1)

	matpop()
end
Object.update=|:|do
	--[[
	sphere radius = self.sphere.radius in meters
	vel is in meters ... so max dist = 2 pi self.sphere.radius ...
	so if vel's magnitude is distance ... then it shoulds rotate by (self.sphere.radius * 2 pi / vel) radians
	quat integral:
	qdot = 1/2 w * q
	w = (wv, 0) = angular velocity as pure-quaternion
	--]]
	local dposx, dposy, dposz, dposw = quat_scale(
		.5 * dt / self.sphere.radius,
		quat_mul(
			self.vel.x, self.vel.y, self.vel.z, self.vel.w,
			self.pos:unpack()
		)
	)
	self.pos.x += dposx
	self.pos.y += dposy
	self.pos.z += dposz
	self.pos.w += dposw
	local sSq = quat_lenSq(self.pos:unpack())
	if sSq > 1e-20 then
		local is = 1 / math.sqrt(sSq)
		self.pos.x *= is
		self.pos.y *= is
		self.pos.z *= is
		self.pos.w *= is
	else
		self.pos.x, self.pos.y, self.pos.z, self.pos.w = 0, 0, 0, 1
	end
end

local Shot = Object:subclass()
Shot.speed = 300
Shot.size = 1
Shot.useGravity = false
Shot.init=|:,args|do
	Shot.super.init(self, args)
	self.endTime = args?.endTime
end
Shot.draw=|:|do
	--[[
	matpush()
	transformQuatTo2D(self.pos:unpack())
	rect(-1, -1, 2, 2, self.color)
	matpop()
	--]]
	-- [[
	local x, y = quatTo2D(self.pos:unpack())
	rect(x-1, y-1, 2, 2, self.color)
	--]]
end
Shot.update=|:|do
	Shot.super.update(self)
	if time() > self.endTime then self.dead = true end
end
Shot.touch=|:,other|do
	if other == self.shooter then return end

	if Ship:isa(other) then
		if other ~= player then	-- TODO player hit
			self.dead = true
			other.dead = true
		end
	end

	if Rock:isa(other) then
		if other.size > other.sizeS then
			-- make new rocks
			local oldvel = other.vel
			local newrocks=7
			for i=1,newrocks do
				local piece = Rock{
					sphere = other.sphere,
					pos = other.pos
						* quat(quatRotZX(
							2 * math.pi * i / newrocks,
							math.random() * other.size / self.sphere.radius
						)),
					--rot = math.random() * 2 * 20,	-- TODO conserve this too?	-- TODO is this used?
					size = other.size == other.sizeL
						and (math.random(2) == 1 and other.sizeM or other.sizeS)
						or other.sizeS,
				}
				piece.vel = oldvel + randomVel() * .2 * vec3_len(oldvel:unpack())
			end
		end
		other.dead = true
		self.dead = true
	end
end

Ship = Object:subclass()
Ship.nextShootTime = 0
Ship.health = 10
Ship.init=|:,args|do
	Ship.super.init(self, args)
	self.healthMax = self.health
end
Ship.update = |:| do
	self.health += .01
	self.health = math.clamp(self.health, 0, self.healthMax)
	Ship.super.update(self)
end
Ship.draw=|:|do
	matpush()
	transformQuatTo2D(self.pos:unpack())

	--[[ vector
	local fwd = vec2(0,-1)
	drawTri(vec2(), fwd, self.size, self.color)
	if self.thrust then
		drawTri(-3 * fwd, -fwd, .5 * self.size, 9)
	end
	Ship.super.draw(self)	-- TODO super call outside pop...
	--]]
	-- [[ sprite
	matscale(self.size / 8, self.size / 8)
	mattrans(-8, -8)
	spr(2, 0, 0, 2, 2)
	if self.thrust then
		mattrans(4, 16)
		spr(1, 0, 0, 1, 1)
	end
	--]]

	matpop()
end
Ship.shoot = |:|do
	if self.nextShootTime > time() then return end
	self.nextShootTime = time() + 1/15

	local xAxisx, xAxisy, xAxisz = quat_xAxis(self.pos:unpack())
	Shot{
		sphere = self.sphere,
		pos = self.pos:clone(),
		vel = quat(
			self.vel.x + xAxisx * Shot.speed,
			self.vel.y + xAxisy * Shot.speed,
			self.vel.z + xAxisz * Shot.speed,
			0),
		shooter = self,
		endTime = time() + 1,
	}
end

--[[
on the sphere surface:
x = right
y = fwd
z = up
--]]
PlayerShip = Ship:subclass()
PlayerShip.update = |:| do
	self.thrust = nil
	local selfPos = self.pos
	local dy = 0
	if btn('up',0) then dy += 1 end
	if btn('down',0) then dy -= 1 end
	if dy ~= 0 then
		-- dy==+1 = rotate on right axis = go fwd
		local s = dy * dt * self.accel
		local xAxisx, xAxisy, xAxisz = quat_xAxis(selfPos:unpack())
		self.vel.x += xAxisx * s
		self.vel.y += xAxisy * s
		self.vel.z += xAxisz * s
		self.thrust = true
	end
	if btn('left',0) then
		--[[ use inertia?
		self.vel += quat.fromVec3(self.pos:zAxis() * (-dt * self.rot))
		--]]
		-- [[ or instant turn?
		local th = -.5 * dt * self.rot
		local sin_halfth = math.sin(th)
		local cos_halfth = math.cos(th)
		selfPos.x, selfPos.y, selfPos.z, selfPos.w = quat_mul(
			selfPos.x, selfPos.y, selfPos.z, selfPos.w,
			0, 0, sin_halfth, cos_halfth
		)
		--]]
	end
	if btn('right',0) then
		--[[ use inertia?
		self.vel += quat.fromVec3(self.pos:zAxis() * (dt * self.rot))
		--]]
		-- [[ or instant turn?
		local th = .5 * dt * self.rot
		local sin_halfth = math.sin(th)
		local cos_halfth = math.cos(th)
		selfPos.x, selfPos.y, selfPos.z, selfPos.w = quat_mul(
			selfPos.x, selfPos.y, selfPos.z, selfPos.w,
			0, 0, sin_halfth, cos_halfth
		)
		--]]
	end
	if btn('y',0) then
		self:shoot()
	end

	PlayerShip.super.update(self)
end

EnemyShip = Ship:subclass()
EnemyShip.thrust = true
-- [[
EnemyShip.update = |:|do
	local selfPos = self.pos
	local zAxisx, zAxisy, zAxisz = quat_zAxis(selfPos:unpack())

	-- TODO dirToPlayer = zAxis cross (zAxis cross player_zAxis) ... double-cross-product ...
	-- ... and then it's used a 3rd time to calculate sin(theta) ...
	local dirToPlayerx, dirToPlayery, dirToPlayerz = vec3_unit(vec3_cross(
		zAxisx, zAxisy, zAxisz,
		vec3_cross(
			zAxisx, zAxisy, zAxisz,
			quat_zAxis(player.pos:unpack())
		)
	))

	-- find the shortest rotation from us to player
	-- compare its geodesic to our 'fwd' dir
	-- turn if needed
	local sinth = vec3_dot(
		zAxisx, zAxisy, zAxisz,
		vec3_cross(
			dirToPlayerx, dirToPlayery, dirToPlayerz,
			quat_yAxis(selfPos:unpack())
		)
	)
	if math.abs(sinth) < math.rad(30) then
	elseif sinth > 0 then
		--self.vel += quat.fromVec3(selfPos:zAxis() * (dt * self.rot))
		local th = -.5 * dt * self.rot
		local sin_halfth = math.sin(th)
		local cos_halfth = math.cos(th)
		-- TODO optimized mul-z-rhs
		selfPos.x, selfPos.y, selfPos.z, selfPos.w = quat_mul(
			selfPos.x, selfPos.y, selfPos.z, selfPos.w,
			0, 0, sin_halfth, cos_halfth
		)
	elseif sinth < 0 then
		--self.vel += quat.fromVec3(selfPos:zAxis() * (-dt * self.rot))
		local th = .5 * dt * self.rot
		local sin_halfth = math.sin(th)
		local cos_halfth = math.cos(th)
		selfPos.x, selfPos.y, selfPos.z, selfPos.w = quat_mul(
			selfPos.x, selfPos.y, selfPos.z, selfPos.w,
			0, 0, sin_halfth, cos_halfth
		)
	end

	local s = dt * self.accel
	local xAxisx, xAxisy, xAxisz = quat_xAxis(self.pos:unpack())
	self.vel.x += xAxisx * s
	self.vel.y += xAxisy * s
	self.vel.z += xAxisz * s

	EnemyShip.super.update(self)
end
--]]

Rock = Object:subclass()
--[[ with 20 rocks per break this looks good but gets too slow too fast on my old crappy laptop
Rock.sizeL = 50
Rock.sizeM = 10
Rock.sizeS = 2
--]]
-- [[
Rock.sizeL = 50
Rock.sizeM = 20
Rock.sizeS = 7
--]]
Rock.size = Rock.sizeL
Rock.color = 13
Rock.touch = |:,other|do
	if Ship:isa(other) then
do return end
		-- TODO bounce
		local selfMass = self:calcMass()
		local otherMass = other:calcMass()
		local totalMass = selfMass + otherMass
		local selfAngMom = self.vel * selfMass
		local otherAngMom = other.vel * otherMass
		do -- if selfAngMom:dot(otherAngMom) < 0 then
			local totalAngMom = selfAngMom + otherAngMom
			local totalAngMomUnit = totalAngMom:clone():unit()

			self.vel = totalAngMom * (selfMass / totalMass)
			--self.vel -= 2 * totalAngMomUnit * self.vel:dot(totalAngMomUnit)
			--self.vel *= .1
			self.vel -= quat.fromVec3(self.pos:zAxis()) * self.vel:axis():dot(self.pos:zAxis())

			other.vel = totalAngMom * (otherMass / totalMass)
			--other.vel -= 2 * totalAngMomUnit * other.vel:dot(totalAngMomUnit)
			--other.vel *= .1
			other.vel -= quat.fromVec3(other.pos:zAxis()) * other.vel:axis():dot(other.pos:zAxis())

			other.health -= .1
		end
	end
end
Rock.draw=|:|do
	matpush()
	transformQuatTo2D(self.pos:unpack())
	--[[ vector
	local fwd = vec2(0,1)
	local rightx = -fwd.y
	local righty = fwd.x
	line(self.size*(fwd.x+rightx), self.size*(fwd.y+righty), self.size*(rightx - fwd.x), self.size*(righty - fwd.y), self.color)
	line(self.size*(rightx-fwd.x), self.size*(righty-fwd.y), self.size*(-rightx - fwd.x), self.size*(-righty - fwd.y), self.color)
	line(self.size*(-rightx - fwd.x), self.size*(-righty - fwd.y), self.size*(fwd.x-rightx), self.size*(fwd.y-righty), self.color)
	line(self.size*(fwd.x-rightx), self.size*(fwd.y-righty), self.size*(fwd.x+rightx), self.size*(fwd.y+righty), self.color)
	Rock.super.draw(self)	-- TODO super call outside pop...
	--]]
	--[[ rect in sprite coords
	rectb(-self.size, -self.size, 2*self.size, 2*self.size, self.color)
	--]]
	-- [[ sprite
	matscale(self.size / 32, self.size / 32)
	mattrans(-32, -32)
	spr(64, 0, 0, 8, 8)
	--]]
	matpop()
end

Portal = Object:subclass()
Portal.useGravity=false
Portal.init=|:,args|do
	Portal.super.init(self, args)
	self.sphere.portals:insert(self)
end
Portal.draw=|:|do
	local n = 24
	local angle = self.size / self.sphere.radius
	local q = self.pos
	local cx, cy = quatTo2D(q:unpack())
	local px, py = quatTo2D(
		quat_mul(
			q.x, q.y, q.z, q.w,
			quatRotX(angle)
		)
	)
	for i=1,n do
		local th = 2 * math.pi * i / n
		local x, y = quatTo2D(
			quat_mul(
				q.x, q.y, q.z, q.w,
				quatRotZX(th, angle)
			)
		)
		line(px, py, x, y, 12)
		tri(px, py, x, y, cx, cy, 0)
		px, py = x, y
	end
end
Portal.touch=|:,other|do
	if Portal:isa(other) then return end

	local other_zAxisx, other_zAxisy, other_zAxisz = quat_zAxis(other.pos:unpack())	-- 'up'

	-- [[ if we're moving away then ignore
	local self_zAxisx, self_zAxisy, self_zAxisz = quat_zAxis(self.pos:unpack())	-- 'up'
	local other_velfwdx, other_velfwdy, other_velfwdz = vec3_cross(
		other.vel.x, other.vel.y, other.vel.z,
		other_zAxisx, other_zAxisy, other_zAxisz
	)	-- movement dir
	if vec3_dot(
		other_velfwdx, other_velfwdy, other_velfwdz,
		self_zAxisx, self_zAxisy, self_zAxisz
	) < 0 then return end
	--]]

	callbacks:insert(function()
		-- ... then transfer spheres
		local nextPortalPos = self.nextPortal.pos
		other.pos:set(quat_mul(
			nextPortalPos.x, nextPortalPos.y, nextPortalPos.z, nextPortalPos.w,
			quat_mul(
				-self.pos.x, -self.pos.y, -self.pos.z, self.pos.w,
				other.pos:unpack()
			)
		))
		--other.pos *= quat(0,0,1,0)

		-- project out z-axis to get rid of twisting ...
		local other_zAxisx, other_zAxisy, other_zAxisz = quat_zAxis(other.pos:unpack())	-- 'up'
		local vel_dot_zAxis = vec3_dot(
			other_zAxisx, other_zAxisy, other_zAxisz,
			other.vel:unpack()
		)
		other.vel.x -= other_zAxisx * vel_dot_zAxis
		other.vel.y -= other_zAxisy * vel_dot_zAxis
		other.vel.z -= other_zAxisz * vel_dot_zAxis

		other.sphere.objs:removeObject(other)
		other.sphere = self.nextPortal.sphere
		other.sphere.objs:insert(other)
	end)
end

-- start spheres

local buildRocks = |sphere|do
	-- TODO don't spawn any inside any portals
	EnemyShip{
		sphere = sphere,
		pos = quat(1,0,0,0),
	}

	for i=1,5 do
		Rock{
			sphere = sphere,
			pos = quat(randomPos()),
			vel = randomVel() * 10,
			rot = math.random() * 2 * 20,	-- is this used?
		}
	end
end


local stars = range(2000):mapi(|| {
	--pos = quat(randomPos()),
	pos = quat(randomPos()) * (1 + 3 * math.random()^3),
	--pos = quat(randomPos()) * (math.random() * 2 - 1),
	--pos = quat(randomPos()) * math.random(),
	--[[
	pos = (||do
		local x,y,z = randomSphereSurface()
		return quat(quat_mul(
			x,y,z, math.random() * math.pi,
			0, 0, 1, math.random() * 2 * math.pi
		))
	end)(),
	--]]
	color = math.random(1,15),
})
spheres = table()
callbacks = table()

local startSphere = Sphere{
	pos = vec3(0,0,0),
	--pos = vec3(128,0,0),
	--radius = 256 / (2 * math.pi),
	--radius = 128 / (2 * math.pi),
	--radius = 1000,	-- works
	--radius = 256,
	radius = 200,	-- good
	--radius = 128,	-- good
	--radius = 64,
	--radius = 64 / (2 * math.pi),
}
buildRocks(startSphere)
spheres:insert(startSphere)

-- TODO build a maze or something
do
	local lastSphere = startSphere
	for i=0,9 do
		local newOfs = vec3()
		newOfs[vec3.fields[(i%3)+1]] = lastSphere.radius * 1.99
		local newSphere = Sphere{
			pos = lastSphere.pos + newOfs,
			radius = lastSphere.radius,
		}
		buildRocks(newSphere)
		spheres:insert(newSphere)
		lastSphere = newSphere
	end
end

-- build portals table
for i=1,#spheres-1 do
	local si = spheres[i]
	for j=i+1,#spheres do
		local sj = spheres[j]
		if (si.pos - sj.pos):len() < si.radius + sj.radius then
			local delta = sj.pos - si.pos
			local dist = delta:len()	-- distance between spheres
			local unitDelta = delta / dist
			local intCircDist = .5 * dist * (1 - (sj.radius^2 - si.radius^2) / dist^2)
			local cosAngleI = math.clamp(intCircDist / si.radius, -1, 1)
			local cosAngleJ = math.clamp((dist - intCircDist) / sj.radius, -1, 1)
			local pi = Portal{
				sphere = si,
				pos = quat(quat_vectorRotateUnit(0,0,1, unitDelta:unpack())),
				size = math.acos(cosAngleI) * si.radius,
			}
			local pj = Portal{
				sphere = sj,
				pos = quat(quat_vectorRotateUnit(0,0,1, (-unitDelta):unpack())),
				size = math.acos(cosAngleJ) * sj.radius,
			}
			pi.nextPortal = pj
			pj.nextPortal = pi
		end
	end
end


-- start level

player = PlayerShip{
	sphere = startSphere,
	--sphere = spheres:last(),
}


update=||do
	cls()
	matident()

	do
--[[ dither
		local rows = screenSize.y
		for y=0,rows-1 do
			local frac = ((y+1) / rows)^(1/4)
			fillp( (1 << math.floor(math.clamp(frac, 0, 1) * 16)) - 1 )
			rect(0, y, screenSize.x, 1, 14)
		end
		fillp(0)
--]]
-- [[ not dither
--]]
	end
	cls(nil, true)

	if player then
		viewSphere = player.sphere
		viewPos:set(player.pos)
	end

	local viewDistScale = 1.5
	local viewTanFov = 2

	mattrans(screenSize.x / 2, screenSize.y / 2)	-- screen center

	--[[ sphere background -- draw lines ...
	do
		local idiv=60
		local jdiv=30
		local idivstep = 5
		local jdivstep = 5
		local corner=|i,j|do
			local u = i / idiv * math.pi * 2
			local v = j / jdiv * math.pi
			return quatTo2D(quatRotZX(u, v))
		end
		for i=0,idiv,idivstep do
			local px, py = corner(i,0)
			for j=1,jdiv do
				local x, y = corner(i,j)
				if px * x + py * y > 0 then
					line(px, py, x, y, viewSphere.color)
				end
				px, py = x, y
			end
		end
		for j=0,jdiv,jdivstep do
			local px, py = corner(0,j)
			for i=1,idiv do
				local x, y = corner(i,j)
				if px * x + py * y > 0 then
					line(px, py, x, y, viewSphere.color)
				end
				px, py = x, y
			end
		end
	end
	--]]
	--[[ sphere background -- draw star background or something -- tile the screen (this'd be good for if I let you use custom shaders in carts..)
	do
		local idiv=30
		local jdiv=15
		local corner=|i,j|do
			local x = (i / idiv - .5) * screenSize.x
			local y = (j / jdiv - .5) * screenSize.y
			local posxunit, posyunit, s = vec2_unit(x, y)
			local th = s / viewSphere.radius
			local posz = math.cos(th)
			local len2 = math.sin(th)
			local posx, posy = posxunit * len2, posyunit * len2
			-- now we have z-axis, ... get lat/lon from it?
			posx, posy, posz = quat_rotate(
				posx, posy, posz,
				viewPos:unpack()
			)
			local r, theta, phi = vec3(posx, posy, posz):toSpherical():unpack()
			phi %= 2 * math.pi
			local u, v = phi / (2*math.pi) * 256, theta / math.pi * 128 + 128

			-- TODO convert to quat then pull towards black hole then convert back to uv
			-- or store the from/to map or something

			return x, y, u, v
		end
		for i=0,idiv-1 do
			for j=0,jdiv-1 do
				local x1,y1,u1,v1 = corner(i,j)
				local x2,y2,u2,v2 = corner(i,j+1)
				local x3,y3,u3,v3 = corner(i+1,j+1)
				local x4,y4,u4,v4 = corner(i+1,j)
				ttri3d(
					x1,y1,0,u1,v1,
					x2,y2,0,u2,v2,
					x3,y3,0,u3,v3)
				ttri3d(
					x3,y3,0,u3,v3,
					x4,y4,0,u4,v4,
					x1,y1,0,u1,v1)
			end
		end
	end
	--]]
	-- [[ sphere background -- draw star background or something -- iterate sphere
	do
		local tri = |
			x1,y1,u1,v1,
			x2,y2,u2,v2,
			x3,y3,u3,v3
		|do
			local dx12 = x2 - x1
			local dy12 = y2 - y1
			local dx23 = x3 - x2
			local dy23 = y3 - y2
			if dx12 * dy23 - dx23 * dy12 > 0 then
				ttri3d(
					x1,y1,0,u1,v1,
					x2,y2,0,u2,v2,
					x3,y3,0,u3,v3)
			end
		end
		local idiv=30
		local jdiv=15
		local corner=|i,j|do
			local u = i / idiv
			local v = j / jdiv
			local x, y = quatTo2D(quatRotZX(u * 2 * math.pi, v * math.pi))
			return x, y, 256*u, 128+128*v
		end
		for i=0,idiv-1 do
			for j=0,jdiv-1 do
				local x1,y1,u1,v1 = corner(i,j)
				local x2,y2,u2,v2 = corner(i,j+1)
				local x3,y3,u3,v3 = corner(i+1,j+1)
				local x4,y4,u4,v4 = corner(i+1,j)
				tri(
					x1,y1,u1,v1,
					x2,y2,u2,v2,
					x3,y3,u3,v3)
				tri(
					x3,y3,u3,v3,
					x4,y4,u4,v4,
					x1,y1,u1,v1)
			end
		end
	end
	--]]

	-- [[ draw stars?
	for _,star in ipairs(stars) do
		local x, y = quatTo2D(star.pos:unpack())
		rect(x, y, 1, 1, star.color)
	end
	--]]

	-- [[ draw 2d on surface view
	for _,o in ipairs(viewSphere.objs) do
		o:draw()
	end
	--]]

	--[=[ draw polar coordinates, and distort by metric around portals
	do
		local grid_r_step = 30
		local grid_rmax = 360
		local rings = range(math.ceil(grid_rmax/grid_r_step)):mapi(||table())
		for phi=0,359 do
			local x,y,z,w = quat_mul(
				viewPos.x, viewPos.y, viewPos.z, viewPos.w,
				quatRotZ(math.rad(phi)))

			local dlambda = 1
			local gl_u_r = 1
			local gl_u_phi = 0
			local grid_r_index=1
			for grid_r=1,grid_rmax do
				local zx, zy, zz = quat_zAxis(x,y,z,w)	-- pos of the photon
				local xx, xy, xz = quat_xAxis(x,y,z,w)	-- right axis of ray
				local yx, yy, yz = quat_yAxis(x,y,z,w)	-- fwd axis of ray

				-- convert gl_u to 3D u
				local gl_u_r_x, gl_u_r_y, gl_u_r_z = vec3_scale(gl_u_r, yx, yy, yz)
				local gl_u_x, gl_u_y, gl_u_z = vec3_add(
					gl_u_r_x, gl_u_r_y, gl_u_r_z,
					vec3_scale(gl_u_phi, vec3_neg(xx, xy, xz))	-- phi=0 is fwd, so phi=90deg is left = -right
				)
				-- [==[
				for _,p in ipairs(viewSphere.portals) do
					local a_r = 0
					local a_phi = 0

					-- size / event-horizon
					local R = p.size
					-- pos of portal
					local pzx, pzy, pzz = quat_zAxis(p.pos:unpack())
					-- rot axis from photon to portal (at photon)
					local pxx, pxy, pxz = vec3_unit(vec3_cross(zx, zy, zz, pzx, pzy, pzz))
					-- fwd axis from portal to photon (at photon)
					local pyx, pyy, pyz = vec3_unit(vec3_cross(pzx, pzy, pzz, pxx, pxy, pxz))

					-- convert 3D u to p_u
					local p_u_phi = vec3_dot(gl_u_x, gl_u_y, gl_u_z, vec3_neg(pxx, pxy, pxz))
					local p_u_r = vec3_dot(gl_u_x, gl_u_y, gl_u_z, pyx, pyy, pyz)
					local p_u_z = vec3_dot(gl_u_x, gl_u_y, gl_u_z, pzx, pzy, pzz)

-- [===[
					-- radial distance from the wormhole
					local r = math.acos(vec3_dot(zx, zy, zz, pzx, pzy, pzz)) * viewSphere.radius
					-- angle between rotation & quat-to-black-hole-axis == angle difference to the black hole
					local p_sin_phi = vec3_dot(pzx, pzy, pzz, vec3_cross(pxx, pxy, pxz, xx, xy, xz))
					local p_phi = math.asin(p_sin_phi)
					--[[ Schwarzschild-anholonomic-normalized geodesic
					dr += f / r * dr * dphi				-- -conn^r_φφ dφ^2
					dphi += -f / r * dr * dphi			-- -conn^φ_φr dφ dr
					--]]
					--[[ Morris-Thorne geodesic
					local l = math.sqrt(r^2 + R^2)
					local u_l = r * p_u_r / l
					a_phi += -l / math.sqrt(r^2 + R^2) * u_l * p_u_phi	-- Gamma^phi_l_phi
					local dl = l * p_u_phi * p_u_phi					-- Gamma^l_phi_phi
					--local dl = r dr / l
					a_r += dl * l / math.sqrt(l^2 - R^2)
					--]]
					--[[ Morris-Thorne but maybe l is r ...
					a_r += r * p_u_phi * p_u_phi
					a_phi -= r / math.sqrt(r^2 + R^2) * p_u_r * p_u_phi	-- Gamma^phi_l_phi
					--[[ metric
					dr *= f
					dphi -= p_phi/r
					--]]

					-- integrate a -> u
					p_u_r += a_r * dlambda
					p_u_phi += a_phi * dlambda
--]===]

					-- convert back to 3D
					local p_u_phi_x, p_u_phi_y, p_u_phi_z = vec3_scale(p_u_phi, vec3_neg(pxx, pxy, pxz))
					local p_u_r_x, p_u_r_y, p_u_r_z = vec3_scale(p_u_r, pyx, pyy, pyz)
					local p_u_z_x, p_u_z_y, p_u_z_z = vec3_scale(p_u_z, pzx, pzy, pzz)
					gl_u_x, gl_u_y, gl_u_z = vec3_add(
						p_u_phi_x, p_u_phi_y, p_u_phi_z,
						vec3_add(
							p_u_r_x, p_u_r_y, p_u_r_z,
							p_u_z_x, p_u_z_y, p_u_z_z
						)
					)
					-- and then back to quat int args
					gl_u_r = vec3_dot(gl_u_x, gl_u_y, gl_u_z, yx, yy, yz)
					gl_u_phi = vec3_dot(gl_u_x, gl_u_y, gl_u_z, vec3_neg(xx, xy, xz))
				end
				--]==]
				-- integrate u -> pos
				x,y,z,w = quat_mul(x,y,z,w, quatRotX(gl_u_r / viewSphere.radius * dlambda))
				x,y,z,w = quat_mul(x,y,z,w, quatRotZ(gl_u_phi * dlambda))

				if grid_r % grid_r_step == 0 then
					rings[grid_r_index]:insert{quatTo2D(x,y,z,w)}
					grid_r_index += 1
				end
			end
		end
		for _,ring in ipairs(rings) do
			assert.len(ring, 360)
			for i=1,#ring-1 do
				line(ring[i][1], ring[i][2], ring[i+1][1], ring[i+1][2], 12)
			end
		end
	end
	--]=]

	-- update all ... or just those on our sphere ... or just those within 2 or 3 spheres?
	-- TODO check portal between sphere eventually. .. but that means tracking pos on multiple spheres ...
	viewSphere:update()
	-- [[ update portals spheres too (but not all spheres)
	-- how about just every so often if at all?
	if time() == math.floor(time()) then
		for _,portal in ipairs(viewSphere.portals) do
			portal.nextPortal.sphere:update()
		end
	end
	--]]

	for i=#callbacks,1,-1 do
		callbacks[i]()
		callbacks[i] = nil
	end

	-- draw gui
	cls(nil, true)
	if player then
		matident()
		rect(0, screenSize.y-10, player.health/player.healthMax*screenSize.x, 10, 16+9)
	end
end
