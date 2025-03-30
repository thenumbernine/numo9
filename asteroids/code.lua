local matAddr = ffi.offsetof('RAM', 'mvMat')
local matstack=table()
local matpush=[]do
	local t={}
	for i=0,15 do
		t[i+1] = peekl(matAddr + (i<<2))
	end
	matstack:insert(t)
end
local matpop=[]do
	local t = matstack:remove(1)
	if not t then return end
	for i=0,15 do
		pokel(matAddr + (i<<2), t[i+1])
	end
end

--#include ext/class.lua

local vec2 = class()
vec2.init=[:,...]do
	if select('#', ...) == 0 then
		self.x = 0
		self.y = 0
	else
		self.x, self.y = ...
	end
end
vec2.set = [a,b] do a.x=b.x a.y=b.y return a end
vec2.clone = [v] vec2(v.x, v.y)
vec2.unpack = [v] (v.x, v.y)
vec2.__unm = [v] vec2(-v.x, -v.y)
vec2.__add = [a,b] vec2(a.x+b.x, a.y+b.y)
vec2.__sub = [a,b] vec2(a.x-b.x, a.y-b.y)
vec2.__mul = [a,b] do
	if type(a) == 'number' then
		return vec2(a*b.x, a*b.y)
	elseif type(b) == 'number' then
		return vec2(a.x*b, a.y*b)
	else
		-- outer? inner? cross? dot ...
		return a:dot(b)
	end
end
vec2.__tostring = [v] '{'..tostring(v.x)..', '..tostring(v.y)..'}'
vec2.__concat = string.concat
vec2.exp = [theta] vec2(math.cos(theta), math.sin(theta))
vec2.cross = [a,b] a.x * b.y - a.y * b.x
vec2.dot = [a,b] a.x * b.x + a.y * b.y
vec2.lenSq = [v] v:dot(v)
vec2.distSq = [a,b] ((a.x-b.x)^2 + (a.y-b.y)^2)
vec2.len = [v] math.sqrt(v:lenSq())
vec2.unit = [v] v * (1 / math.max(1e-15, v:len()))

local Quat = class()
Quat.init=[:,...]do
	if select('#', ...) == 0 then
		self.x, self.y, self.z, self.w = 0, 0, 0, 1
	else
		self.x, self.y, self.z, self.w = ...
	end
end
Quat.set = [:,o] do 
	self.x, self.y, self.z, self.w = o:unpack() 
	return self 
end
Quat.unpack = [q] (q.x, q.y, q.z, q.w)
Quat.mul = [q, r, res] do
	if not res then res = Quat() end
	local a = (q.w + q.x) * (r.w + r.x)
	local b = (q.z - q.y) * (r.y - r.z)
	local c = (q.x - q.w) * (r.y + r.z)
	local d = (q.y + q.z) * (r.x - r.w)
	local e = (q.x + q.z) * (r.x + r.y)
	local f = (q.x - q.z) * (r.x - r.y)
	local g = (q.w + q.y) * (r.w - r.z)
	local h = (q.w - q.y) * (r.w + r.z)
	return res:set(
		a - .5 * ( e + f + g + h),
		-c + .5 * ( e - f + g - h),
		-d + .5 * ( e - f - g + h),
		b + .5 * (-e - f + g + h))
end
Quat.__mul = Quat.mul
Quat.__div = [a,b] a * b:conjugate() / b:lenSq()

Quat.epsilon = 1e-15
Quat.toAngleAxis = [:, res] do
	res = res or Quat()

	local cosom = math.clamp(self.w, -1, 1)

	local halfangle = math.acos(cosom)
	local scale = math.sin(halfangle)

	if scale >= -self.epsilon and scale <= self.epsilon then
		return res:set(0,0,1,0)
	end
	scale = 1 / scale
	return res:set(
		self.x * scale,
		self.y * scale,
		self.z * scale,
		halfangle * 2)
end

-- TODO epsilon-test this?  so no nans?
Quat.fromAngleAxis = [:, res] do
	local x, y, z, theta = self:unpack()
	local vlen = math.sqrt(x*x + y*y + z*z)
	local costh = math.cos(theta / 2)
	local sinth = math.sin(theta / 2)
	local vscale = sinth / vlen
	return (res or Quat()):set(x * vscale, y * vscale, z * vscale, costh)
end

Quat.xAxis = [q, res] 
	((res or vec3()):set(
		1 - 2 * (q.y * q.y + q.z * q.z),
		2 * (q.x * q.y + q.z * q.w),
		2 * (q.x * q.z - q.w * q.y)))

Quat.yAxis = [q, res]
	((res or vec3()):set(
		2 * (q.x * q.y - q.w * q.z),
		1 - 2 * (q.x * q.x + q.z * q.z),
		2 * (q.y * q.z + q.w * q.x)))

Quat.zAxis = [q, res]
		((res or vec3()):set(
			2 * (q.x * q.z + q.w * q.y),
			2 * (q.y * q.z - q.w * q.x),
			1 - 2 * (q.x * q.x + q.y * q.y)))

Quat.rotate = [:, v, res] do
	local v4 = self * Quat(v.x, v.y, v.z, 0) * self:conjugate()
	return (res or vec3()):set(v4.x, v4.y, v4.z)
end

Quat.conjugate = [:, res]
	((res or Quat()):set(-self.x, -self.y, -self.z, self.w))

Quat.normalize = [:, res, eps] do
	eps = eps or Quat.epsilon
	res = res or Quat()
	local lenSq = self:normSq()
	if lenSq < eps*eps then
		return res:set(0,0,0,1)
	end
	local invlen = 1 / math.sqrt(lenSq)
	return res:set(
		self.x * invlen,
		self.y * invlen,
		self.z * invlen,
		self.w * invlen)
end


--worldSize = 256
worldSize = 128			-- one screen size
--worldSize = 64		-- too small

local dt = 1/60

drawTri = [pos, fwd, size, color] do
	local rightx = -fwd.y
	local righty = fwd.x
	line(pos.x+size*fwd.x, pos.y+size*fwd.y, pos.x+size*(rightx - fwd.x), pos.y+size*(righty - fwd.y), color)
	line(pos.x+size*fwd.x, pos.y+size*fwd.y, pos.x+size*(-rightx - fwd.x), pos.y+size*(-righty - fwd.y), color)
end

objs = table()

getViewPos = [v] do
	local relpos = v - viewPos
	if relpos.x < -worldSize then 
		relpos.x += 2*worldSize
	elseif relpos.x > worldSize then 
		relpos.x -= 2*worldSize
	end
	if relpos.y < -worldSize then 
		relpos.y += 2*worldSize
	elseif relpos.y > worldSize then 
		relpos.y -= 2*worldSize
	end
	return relpos + viewPos
end

local Object = class()
Object.pos = vec2()
Object.vel = vec2()
Object.size = 5
Object.color = 12
Object.angle = 0
Object.accel = 50
Object.rot = 5
Object.density = 1
Object.init=[:,args]do
	objs:insert(self)
	if args then
		for k,v in pairs(args) do self[k] = v end
	end
	self.pos = self.pos:clone()
	self.vel = self.vel:clone()
end
Object.update=[:]do
	self.pos += dt * self.vel

	self.angle %= 2 * math.pi
	self.pos.x += worldSize
	self.pos.y += worldSize
	self.pos.x %= 2*worldSize
	self.pos.y %= 2*worldSize
	self.pos.x -= worldSize
	self.pos.y -= worldSize
end

local Shot = Object:subclass()
Shot.speed = 300
Shot.size = 1
Shot.init=[:,args]do
	Shot.super.init(self, args)
	self.endTime = args?.endTime
end
Shot.update=[:]do
	Shot.super.update(self)

	matpush()
	mattrans(getViewPos(self.pos):unpack())
	rect(-1, -1, 3, 3, self.color)
	matpop()

	if time() > self.endTime then self.dead = true end
end
Shot.touch=[:,other]do
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
			local mom = other.vel * other:calcMass()
			local perturb1 = vec2.exp(math.random() * 2 * math.pi) * 2000
			local perturb2 = vec2.exp(math.random() * 2 * math.pi) * 2000
			for s1=-1,1,2 do
				for s2=-1,1,2 do
					local newmom = .25 * mom + s1 * perturb1 + s2 * perturb2
					local piece = Rock{
						pos = self.pos,
						angle = math.random() * 2 * math.pi,	-- TODO conserve this too
						rot = math.random() * 2 * 20,			-- and this?
						size = other.size == other.sizeL and other.sizeM or other.sizeS,
					}
					piece.vel = newmom * (1 / piece:calcMass())
				end
			end
		end
		other.dead = true
		self.dead = true
	end
end

Ship = Object:subclass()
Ship.nextShootTime = 0
Ship.update=[:]do
	local fwd = vec2.exp(self.angle)
	matpush()
	mattrans(getViewPos(self.pos):unpack())
	drawTri(vec2(), fwd, self.size, self.color)

	if self.thrust then
		drawTri(-3 * fwd, -fwd, .5 * self.size, 9)
	end
	self.thrust = nil

	matpop()

	Ship.super.update(self)
end
Ship.shoot = [:]do
	if self.nextShootTime > time() then return end
	self.nextShootTime = time() + .2
	local fwd = vec2.exp(self.angle)
	Shot{
		pos = self.pos:clone(),
		vel = self.vel + Shot.speed * fwd,
		shooter = self,
		endTime = time() + 1,
	}
end

PlayerShip = Ship:subclass()
PlayerShip.update = [:] do
	local fwd = vec2.exp(self.angle)
	if btn(0,0) then self.vel += fwd * dt * self.accel self.thrust=true end
	if btn(1,0) then self.vel -= fwd * dt * self.accel self.thrust=true end
	if btn(2,0) then self.angle -= dt * self.rot end
	if btn(3,0) then self.angle += dt * self.rot end
	if btn(7,0) then self:shoot() end

	PlayerShip.super.update(self)
end

EnemyShip = Ship:subclass()
EnemyShip.update = [:]do
	local toPlayer = (player.pos - self.pos):unit()
	local fwd = vec2.exp(self.angle)
	local sinth = toPlayer:cross(fwd)
	if math.abs(sinth) < math.rad(30) then
	elseif sinth > 0 then
		self.angle -= dt * self.rot
	elseif sinth < 0 then
		self.angle += dt * self.rot
	end

	self.thrust = true
	self.vel += fwd * dt * self.accel

	PlayerShip.super.update(self)
end

Rock = Object:subclass()
Rock.density = 1
Rock.sizeL = 20
Rock.sizeM = 10
Rock.sizeS = 5
Rock.size = Rock.sizeL
Rock.color = 13
Rock.calcMass = [:] math.pi * self.size^2 * self.density
Rock.update=[:]do
	local fwd = vec2.exp(self.angle)

	local rightx = -fwd.y
	local righty = fwd.x
	matpush()
	mattrans(getViewPos(self.pos):unpack())
	line(self.size*(fwd.x+rightx), self.size*(fwd.y+righty), self.size*(rightx - fwd.x), self.size*(righty - fwd.y), self.color)
	line(self.size*(rightx-fwd.x), self.size*(righty-fwd.y), self.size*(-rightx - fwd.x), self.size*(-righty - fwd.y), self.color)
	line(self.size*(-rightx - fwd.x), self.size*(-righty - fwd.y), self.size*(fwd.x-rightx), self.size*(fwd.y-righty), self.color)
	line(self.size*(fwd.x-rightx), self.size*(fwd.y-righty), self.size*(fwd.x+rightx), self.size*(fwd.y+righty), self.color)
	matpop()

	Rock.super.update(self)
end

player = PlayerShip()
-- [[
EnemyShip{
	pos=vec2(50,0),
	vel=vec2(0,30),
}
--]]
for i=1,5 do
	Rock{
		pos=vec2.exp(math.random()*2*math.pi) * worldSize * .5,
		vel=vec2.exp(math.random()*2*math.pi) * 10,
		angle = math.random() * 2 * math.pi,
		rot = math.random() * 2 * 20,
	}
end

viewPos = vec2()
viewAngle = 0
update=[]do
	matident()	-- TODO cls() needs matident() manually set ...
	cls()
	matident()
	mattrans(128, 128)	-- screen center
	matrot(-viewAngle)
	mattrans(-viewPos.x, -viewPos.y)
	if player then 
		viewPos:set(player.pos)
		viewAngle = player.angle + .5 * math.pi
	end

	-- screen boundary for debugging
	rectb(-worldSize,-worldSize,2*worldSize,2*worldSize,1)

	for i=#objs,1,-1 do
		local o = objs[i]
		-- do update
		o:update()
		-- remove dead
		if o.dead then objs:remove(i) end
	end
	for i=1,#objs-1 do
		local o = objs[i]
		if not o.dead then
			for i2=i+1,#objs do
				local o2 = objs[i2]
				if not o2.dead then
					-- check touch
					local distSq = vec2.distSq(o.pos, o2.pos)
					if distSq < (o.size + o2.size)^2 then
						if o.touch then o:touch(o2) end
						if not o.dead and not o2.dead then
							if o2.touch then o2:touch(o) end
						end
						if o.dead then break end
					end
				end
			end
		end
	end
end
