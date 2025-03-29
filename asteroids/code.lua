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

isa=[cl,o]o.isaSet[cl]
classmeta = {__call=[cl,...]do
	local o=setmetatable({},cl)
	return o, o?:init(...)
end}
class=[...]do
	local t=table(...)
	t.super=...
	t.__index=t
	t.subclass=class
	t.isaSet=table(table{...}:mapi([cl]cl.isaSet):unpack()):setmetatable(nil)
	t.isaSet[t]=true
	t.isa=isa
	setmetatable(t,classmeta)
	return t
end

local vec2 = class()
vec2.init=[:,...]do
	if select('#', ...) == 0 then
		self.x = 0
		self.y = 0
	else
		self.x, self.y = ...
	end
end
vec2.clone = [v] vec2(v.x, v.y)
vec2.exp = [theta] vec2(math.cos(theta), math.sin(theta))
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

local dt = 1/60

drawTri = [pos, fwd, size, color] do
	local rightx = -fwd.y
	local righty = fwd.x
	line(pos.x+size*fwd.x, pos.y+size*fwd.y, pos.x+size*(rightx - fwd.x), pos.y+size*(righty - fwd.y), color)
	line(pos.x+size*fwd.x, pos.y+size*fwd.y, pos.x+size*(-rightx - fwd.x), pos.y+size*(-righty - fwd.y), color)
end

objs = table()
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
	self.pos.x += 128
	self.pos.y += 128
	self.pos.x %= 256
	self.pos.y %= 256
	self.pos.x -= 128
	self.pos.y -= 128
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
	mattrans(self.pos.x, self.pos.y)
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
	mattrans(self.pos.x, self.pos.y)
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
	self.nextShootTime = time() + .3
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
	mattrans(self.pos.x, self.pos.y)
	line(self.size*(fwd.x+rightx), self.size*(fwd.y+righty), self.size*(rightx - fwd.x), self.size*(righty - fwd.y), self.color)
	line(self.size*(rightx-fwd.x), self.size*(righty-fwd.y), self.size*(-rightx - fwd.x), self.size*(-righty - fwd.y), self.color)
	line(self.size*(-rightx - fwd.x), self.size*(-righty - fwd.y), self.size*(fwd.x-rightx), self.size*(fwd.y-righty), self.color)
	line(self.size*(fwd.x-rightx), self.size*(fwd.y-righty), self.size*(fwd.x+rightx), self.size*(fwd.y+righty), self.color)
	matpop()

	Rock.super.update(self)
end

player = PlayerShip()
--[[
EnemyShip{
	pos=vec2(50,0),
	vel=vec2(0,30),
}
--]]
for i=1,5 do
	Rock{
		pos=vec2(math.random(), math.random())*256,
		vel=vec2.exp(math.random()*2*math.pi) * 10,
		angle = math.random() * 2 * math.pi,
		rot = math.random() * 2 * 20,
	}
end

update=[]do
	matident()	-- TODO cls() needs matident() manually set ...
	cls()
	matident()
	mattrans(128, 128)

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
