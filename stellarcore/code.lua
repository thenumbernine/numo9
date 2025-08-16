-- title = Stellar Core
-- saveid = stellarcore
-- author = Chris Moore
-- description = classic "Asteroids" but with proper spherical universes, and interconnections with neighboring universes.
----------------------- BEGIN numo9/matstack.lua-----------------------
assert.eq(ramsize'mvMat', 16*4, "expected mvmat to be 32bit")	-- need to assert this for my peek/poke push/pop. need to peek/poke vs writing to app.ram directly so it is net-reflected.
local matAddr = ramaddr'mvMat'
local matstack=table()
local matpush=||do
	local t={}
	for i=0,15 do
		t[i+1] = peekf(matAddr + (i<<2))
	end
	matstack:insert(t)
end
local matpop=||do
	local t = matstack:remove(1)
	if not t then return end
	for i=0,15 do
		pokef(matAddr + (i<<2), t[i+1])
	end
end

----------------------- END numo9/matstack.lua  -----------------------
----------------------- BEGIN ext/class.lua-----------------------
local isa=|cl,o|o.isaSet[cl]
local classmeta = {__call=|cl,...|do
	local o=setmetatable({},cl)
	return o, o?:init(...)
end}
local class
class=|...|do
	local t=table(...)
	t.super=...
	--t.supers=table{...}
	t.__index=t
	t.subclass=class
	t.isaSet=table(table{...}
		:mapi(|cl|cl.isaSet)
		:unpack()
	):setmetatable(nil)
	t.isaSet[t]=true
	t.isa=isa
	setmetatable(t,classmeta)
	return t
end

----------------------- END ext/class.lua  -----------------------
----------------------- BEGIN vec/vec2.lua-----------------------
local vec2_getvalue=|x, dim|do
	if type(x) == 'number' then return x end
	if type(x) == 'table' then
		if dim==1 then
			x=x.x
		elseif dim==2 then
			x=x.y
		else
			x=nil
		end
		if type(x)~='number' then
			error("expected a table of numbers, got a table with index "..dim.." of "..type(x))
		end
		return x
	end
	error("tried to vec2_getvalue from an unknown type "..type(x))
end

local vec2
vec2=class{
	fields = table{'x', 'y'},
	init=|v,x,y|do
		if x then
			if y then
				v:set(x,y)
			else
				v:set(x,x)
			end
		else
			v:set(0,0)
		end
	end,
	clone=|v| vec2(v),
	set=|v,x,y|do
		if type(x) == 'table' then
			v.x = x.x or x[1] or error("idk")
			v.y = x.y or x[2] or error("idk")
		else
			assert(x, "idk")
			v.x = x
			if y then
				v.y = y
			else
				v.y = x
			end
		end
		return v
	end,
	unpack=|v|(v.x, v.y),
	sum=|v| v.x + v.y,
	product=|v| v.x * v.y,
	clamp=|v,a,b|do
		local mins = a
		local maxs = b
		if type(a) == 'table' and a.min and a.max then
			mins = a.min
			maxs = a.max
		end
		v.x = math.clamp(v.x, vec2_getvalue(mins, 1), vec2_getvalue(maxs, 1))
		v.y = math.clamp(v.y, vec2_getvalue(mins, 2), vec2_getvalue(maxs, 2))
		return v
	end,
	map=|v,f|do
		v.x = f(v.x, 1)
		v.y = f(v.y, 2)
		return v
	end,
	floor=|v|v:map(math.floor),
	ceil=|v|v:map(math.ceil),
	l1Length=|v| math.abs(v.x) + math.abs(v.y),
	lInfLength=|v| math.max(math.abs(v.x), math.abs(v.y)),
	dot=|a,b| a.x * b.x + a.y * b.y,
	lenSq=|v| v:dot(v),
	len=|v| math.sqrt(v:lenSq()),
	distSq = |a,b| ((a.x-b.x)^2 + (a.y-b.y)^2),
	unit=|v,res|do
		local s = 1 / math.max(1e-15, v:len())
		if res then
			return res:set(v.x * s, v.y * s)
		else
			return vec2(v.x * s, v.y * s)
		end
	end,
	exp=|theta| vec2(math.cos(theta), math.sin(theta)),
	cross=|a,b| a.x * b.y - a.y * b.x,	-- or :det() maybe
	cplxmul = |a,b| vec2(a.x * b.x - a.y * b.y, a.x * b.y + a.y * b.x),
	__unm=|v| vec2(-v.x, -v.y),
	__add=|a,b| vec2(vec2_getvalue(a, 1) + vec2_getvalue(b, 1), vec2_getvalue(a, 2) + vec2_getvalue(b, 2)),
	__sub=|a,b| vec2(vec2_getvalue(a, 1) - vec2_getvalue(b, 1), vec2_getvalue(a, 2) - vec2_getvalue(b, 2)),
	__mul=|a,b| vec2(vec2_getvalue(a, 1) * vec2_getvalue(b, 1), vec2_getvalue(a, 2) * vec2_getvalue(b, 2)),
	__div=|a,b| vec2(vec2_getvalue(a, 1) / vec2_getvalue(b, 1), vec2_getvalue(a, 2) / vec2_getvalue(b, 2)),
	__eq=|a,b| a.x == b.x and a.y == b.y,
	__tostring=|v| v.x..','..v.y,
	__concat=string.concat,
}

-- TODO order this like buttons ... right down left up ... so it's related to bitflags and so it follows exp map angle ...
-- tempting to do right left down up, i.e. x+ x- y+ y-, because that extends dimensions better
-- but as it is this way, we are 1:1 with the exponential-map, so there.
local dirvecs = table{
	[0] = vec2(1,0),
	[1] = vec2(0,1),
	[2] = vec2(-1,0),
	[3] = vec2(0,-1),
}
local opposite = {[0]=2,3,0,1}	-- opposite = [x]x~2
local dirForName = {right=0, down=1, left=2, up=3}

----------------------- END vec/vec2.lua  -----------------------
----------------------- BEGIN vec/vec3.lua-----------------------
local vec3_getvalue=|x, dim|do
	if type(x) == 'number' then return x end
	if type(x) == 'table' then
		if dim==1 then
			x=x.x
		elseif dim==2 then
			x=x.y
		elseif dim==3 then
			x=x.z
		else
			x=nil
		end
		if type(x)~='number' then
			error("expected a table of numbers, got a table with index "..dim.." of "..type(x))
		end
		return x
	end
	error("tried to vec3_getvalue from an unknown type "..type(x))
end

-- tempting to template/generate this code ....
local vec3
vec3=class{
	fields = table{'x', 'y', 'z'},
	init=|v,x,y,z|do
		if x then
			v:set(x,y,z)
		else
			v:set(0,0,0)
		end
	end,
	clone=|v| vec3(v),
	set=|v,x,y,z|do
		if type(x) == 'table' then
			v.x = x.x or x[1] or error("idk")
			v.y = x.y or x[2] or error("idk")
			v.z = x.z or x[3] or error("idk")
		else
			assert(x, "idk")
			v.x = x
			if y then
				v.y = y
				v.z = z or 0
			else
				v.y = x
				v.z = x
			end
		end
		return v
	end,
	unpack=|v| (v.x, v.y, v.z),
	sum=|v| v.x + v.y + v.z,
	product=|v| v.x * v.y * v.z,
	map=|v,f|do
		v.x = f(v.x, 1)
		v.y = f(v.y, 2)
		v.z = f(v.z, 3)
		return v
	end,
	floor=|v|v:map(math.floor),
	ceil=|v|v:map(math.ceil),
	l1Length=|v| math.abs(v.x) + math.abs(v.y) + math.abs(v.z),
	lInfLength=|v| math.max(math.abs(v.x), math.abs(v.y), math.abs(v.z)),
	dot=|a,b| a.x * b.x + a.y * b.y + a.z * b.z,
	lenSq=|v| v:dot(v),
	cross=|a,b| vec3(a.y*b.z-a.z*b.y, a.z*b.x-a.x*b.z, a.x*b.y-a.y*b.x),
	len=|v| math.sqrt(v:lenSq()),
	distSq = |a,b| ((a.x-b.x)^2 + (a.y-b.y)^2 + (a.z-b.z)^2),
	unit=|v,res|do
		local s = 1 / math.max(1e-15, v:len())
		if res then
			return res:set(v.x * s, v.y * s, v.z * s)
		else
			return vec3(v.x * s, v.y * s, v.z * s)
		end
	end,
	__unm=|v| vec3(-v.x, -v.y, -v.z),
	__add=|a,b| vec3(vec3_getvalue(a, 1) + vec3_getvalue(b, 1), vec3_getvalue(a, 2) + vec3_getvalue(b, 2), vec3_getvalue(a, 3) + vec3_getvalue(b, 3)),
	__sub=|a,b| vec3(vec3_getvalue(a, 1) - vec3_getvalue(b, 1), vec3_getvalue(a, 2) - vec3_getvalue(b, 2), vec3_getvalue(a, 3) - vec3_getvalue(b, 3)),
	__mul=|a,b| vec3(vec3_getvalue(a, 1) * vec3_getvalue(b, 1), vec3_getvalue(a, 2) * vec3_getvalue(b, 2), vec3_getvalue(a, 3) * vec3_getvalue(b, 3)),
	__div=|a,b| vec3(vec3_getvalue(a, 1) / vec3_getvalue(b, 1), vec3_getvalue(a, 2) / vec3_getvalue(b, 2), vec3_getvalue(a, 3) / vec3_getvalue(b, 3)),
	__eq=|a,b| a.x == b.x and a.y == b.y and a.z == b.z,
	__tostring=|v| v.x..','..v.y..','..v.z,
	__concat=string.concat,
}

----------------------- END vec/vec3.lua  -----------------------
----------------------- BEGIN vec/quat.lua-----------------------
local quat = class()
quat.init=|:,...|do
	if select('#', ...) == 0 then
		self.x, self.y, self.z, self.w = 0, 0, 0, 1
	else
		self.x, self.y, self.z, self.w = ...
	end
end
-- static:
quat.fromVec3=|v| quat(v.x, v.y, v.z, 0)
quat.set = |:,x,y,z,w| do
	if type(x) == 'table' then
		self.x, self.y, self.z, self.w = x:unpack()
	else
		self.x, self.y, self.z, self.w = x,y,z,w
	end
	return self
end
quat.clone = |q| quat(q.x, q.y, q.z, q.w)
quat.unpack = |q| (q.x, q.y, q.z, q.w)
quat.__add = |q,r,res| do
	res = res or quat()
	return res:set(q.x + r.x, q.y + r.y, q.z + r.z, q.w + r.w)
end
quat.__sub = |q,r,res| do
	res = res or quat()
	return res:set(q.x - r.x, q.y - r.y, q.z - r.z, q.w - r.w)
end

quat_mul_comp=|qx,qy,qz,qw, rx,ry,rz,rw|do
	local a = (qw + qx) * (rw + rx)
	local b = (qz - qy) * (ry - rz)
	local c = (qx - qw) * (ry + rz)
	local d = (qy + qz) * (rx - rw)
	local e = (qx + qz) * (rx + ry)
	local f = (qx - qz) * (rx - ry)
	local g = (qw + qy) * (rw - rz)
	local h = (qw - qy) * (rw + rz)
	return 
		a - .5 * ( e + f + g + h),
		-c + .5 * ( e - f + g - h),
		-d + .5 * ( e - f - g + h),
		b + .5 * (-e - f + g + h)
end

quat.mul = |q, r, res| do
	if not res then res = quat() end
	if type(q) == 'number' then
		return res:set(q * r.x, q * r.y, q * r.z, q * r.w)
	elseif type(r) == 'number' then
		return res:set(q.x * r, q.y * r, q.z * r, q.w * r)
	end
	return res:set(quat_mul_comp(q.x, q.y, q.z, q.w, r.x, r.y, r.z, r.w))
end

quat.__mul = quat.mul
quat.__div = |a,b| a * b:conj() / b:lenSq()

quat.epsilon = 1e-15
quat.toAngleAxis = |:, res| do
	res = res or quat()

	local cosangle = math.clamp(self.w, -1, 1)

	local halfangle = math.acos(cosangle)
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
quat.fromAngleAxis = |:, res| do
	local x, y, z, theta = self:unpack()
	local vlen = math.sqrt(x*x + y*y + z*z)
	local costh = math.cos(theta / 2)
	local sinth = math.sin(theta / 2)
	local vscale = sinth / vlen
	return (res or quat()):set(x * vscale, y * vscale, z * vscale, costh)
end

quat.xAxis = |q, res| do
	res = res or vec3()
	res:set(
		1 - 2 * (q.y * q.y + q.z * q.z),
		2 * (q.x * q.y + q.z * q.w),
		2 * (q.x * q.z - q.w * q.y))
	return res
end
quat.yAxis = |q, res| do
	res = res or vec3()
	res:set(
		2 * (q.x * q.y - q.w * q.z),
		1 - 2 * (q.x * q.x + q.z * q.z),
		2 * (q.y * q.z + q.w * q.x))
	return res
end
quat.zAxis = |q, res| do
	res = res or vec3()
	res:set(
		2 * (q.x * q.z + q.w * q.y),
		2 * (q.y * q.z - q.w * q.x),
		1 - 2 * (q.x * q.x + q.y * q.y))
	return res
end
quat.axis = |q, res| do
	res = res or vec3()
	res:set(q.x, q.y, q.z)
	return res
end

quat.rotate = |:, v, res| do
	local v4 = self * quat(v.x, v.y, v.z, 0) * self:conj()
	return v4:axis(res)
end

quat.conj = |:, res|
	((res or quat()):set(-self.x, -self.y, -self.z, self.w))


quat.dot = |a,b| a.x * b.x + a.y * b.y + a.z * b.z + a.w * b.w
quat.normSq = |q| quat.dot(q,q)
quat.unit = |:, res, eps| do
	eps = eps or quat.epsilon
	res = res or quat()
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
quat.__eq=|a,b| a.x == b.x and a.y == b.y and a.z == b.z and a.w == b.w
quat.__tostring=|v| v.x..','..v.y..','..v.z..','..v.w
quat.__concat=string.concat

-- make a rotation from v1 to v2
quat.vectorRotateToAngleAxis = |v1, v2|do
	v1 = v1:clone():unit()
	v2 = v2:clone():unit()
	local costh = v1:dot(v2)
	local eps = 1e-9
	if math.abs(costh) > 1 - eps then return 0,0,1,0 end
	local theta = math.acos(math.clamp(costh,-1,1))
	local v3 = v1:cross(v2):unit()
	return v3.x, v3.y, v3.z, theta
end
quat.vectorRotate=|v1,v2|do
	local x,y,z,th = quat.vectorRotateToAngleAxis(v1,v2)
	return quat(x,y,z,th):fromAngleAxis()
end

quat.matrot=|q|do
--[[	
	local x,y,z,th = q:toAngleAxis():unpack()
	matrot(th, x, y, z)
--]]	
-- [[
	local coshalfangle = q.w	-- [-1,1] <-> cos(theta) for theta in [0, pi]
	local sinhalfangle = math.sqrt(1 - coshalfangle^2)	-- [0,1]
	if sinhalfangle > 1e-20 then
		local il = 1/sinhalfangle
		local cosangle = coshalfangle^2 - sinhalfangle^2
		local sinangle = 2 * sinhalfangle * coshalfangle
		matrotcs(cosangle, sinangle, q.x * il, q.y * il, q.z * il)
	end
--]]
end

----------------------- END vec/quat.lua-----------------------
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
	return quat(x,y,z, math.random() * math.pi) * quat(0, 0, 1, math.random() * 2 * math.pi)
end

randomVel=||do
	local x,y,z = randomSphereSurface()
	return quat(x,y,z,0)
end


local nextSphereColor = 1

local Sphere = class()
Sphere.init=|:,args|do
	self.pos = vec3(args.pos)
	self.radius = args!.radius
	self.touching = table()
	self.objs = table()			-- only attach objs to one sphere -- their .sphere -- and test all touching spheres for inter-sphere interactions
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
	-- do touches
	for i=1,#objs-1 do
		local o = objs[i]
		if not o.dead then
			for i2=i+1,#objs do
				local o2 = objs[i2]
				if not o2.dead then
					-- check touch
					local dist = math.acos(o.pos:zAxis():dot(o2.pos:zAxis())) * math.sqrt(o.sphere.radius * o2.sphere.radius)
					if dist < (o.size + o2.size) then
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


local dt = 1/60

drawTri = |pos, fwd, size, color| do
	local rightx = -fwd.y
	local righty = fwd.x
	line(pos.x+size*fwd.x, pos.y+size*fwd.y, pos.x+size*(rightx - fwd.x), pos.y+size*(righty - fwd.y), color)
	line(pos.x+size*fwd.x, pos.y+size*fwd.y, pos.x+size*(-rightx - fwd.x), pos.y+size*(-righty - fwd.y), color)
end


viewPos = quat()
viewSphere = startSphere

-- [[
-- v = quat
-- returns vec2
--[=[
do
	local viewPosConj = quat()
	local v2 = quat()
	local pos = vec3()
	local pos2d = vec2()
	quatTo2D = |v|do
		viewPos:conj(viewPosConj)
		quat.mul(viewPosConj, v, v2)	-- v2 = viewPosConj * v
		v2:zAxis(pos)
		pos2d:set(pos.x, pos.y)
		local len2 = pos2d:len()
		if len2 < 1e-15 then
			-- hmm before when I didn't return a quat but instead just bailed out, it looked better...
			return 0, 0, quat(0,0, -sqrt_1_2, sqrt_1_2)
		end
		local s = math.acos(pos.z) * viewSphere.radius / len2
		pos2d.x *= s
		pos2d.y *= s
		return pos2d.x, pos2d.y, v2
	end
end
--]=]
-- [=[
do
	local viewPosConj = quat()	-- TODO cache this
	local v2 = quat()
	local pos = vec3()
	local pos2d = vec2()
	quatTo2D = |v|do
		viewPos:conj(viewPosConj)
		quat.mul(viewPosConj, v, v2)
		v2:zAxis(pos)
		-- TODO reuse this but it's used outside so don't return it
		pos2d:set(pos.x, pos.y)
		local len2 = pos2d:len()
		if len2 < 1e-15 then
			-- hmm before when I didn't return a quat but instead just bailed out, it looked better...
			return 0, 0, v2:set(0,0, -sqrt_1_2, sqrt_1_2)
		end
		pos2d *= math.acos(pos.z) * viewSphere.radius / len2
		return pos2d.x, pos2d.y, v2
	end
end
--]=]
--[=[
quatTo2D = |v|do
	v = viewPos:conj() * v
	local pos = v:zAxis()
	local pos2d = vec2(pos.x, pos.y)
	local len2 = pos2d:len()
	if len2 < 1e-15 then
		-- hmm before when I didn't return a quat but instead just bailed out, it looked better...
		return 0, 0, quat(0,0, -sqrt_1_2, sqrt_1_2)
	end
	pos2d *= math.acos(pos.z) * viewSphere.radius / len2
	return pos2d.x, pos2d.y, v
end
--]=]

-- v = quat
-- does mat transforms
do
	local vy = vec3()
	local fwd = vec2()
	transformQuatTo2D = |v| do
		local pos2dx, pos2dy, v = quatTo2D(v)
		mattrans(pos2dx, pos2dy)

		-- cos/sin -> atan -> cos/sin ... plz just do a matmul
		v:yAxis(vy)
		vec2.unit(vy, fwd)
		matrotcs(fwd.x, fwd.y, 0, 0, 1)
	end
end
--]]
--[[
-- v = quat
-- does mat transforms
transformQuatTo2D = |v| do
	v = viewPos:conj() * v
	local pos = v:zAxis()
	local pos2d = vec2(pos.x, pos.y)
	local len2 = pos2d:len()
	if len2 < 1e-15 then return vec2(), v end
	pos2d *= math.acos(pos.z) * viewSphere.radius / len2
	mattrans(pos2d.x, pos2d.y)

	-- cos/sin -> atan -> cos/sin ... plz just do a matmul
	local fwd = vec2.unit(v:yAxis())
	matrotcs(fwd.x, fwd.y)
end
--]]

local Object = class()
Object.pos = quat()
Object.vel = quat(0,0,0,0)	-- pure-quat with vector = angular momentum
Object.size = 5
Object.color = 12
Object.accel = 50
Object.rot = 5
Object.density = 1
Object.calcMass = |:| math.pi * self.size^2 * self.density
Object.init=|:,args|do
	if args then
		for k,v in pairs(args) do self[k] = v end
	end
	self.sphere.objs:insert(self)
	self.pos = (args and args.pos or self.pos):clone()
	self.vel = (args and args.vel or self.vel):clone()
end
Object.draw2D=|:|do
	matpush()
	transformQuatTo2D(self.pos)

	matscale(self.size / 4, self.size / 4)
	mattrans(-4, -4)
	spr(0, 0, 0, 1, 1)

	matpop()
end
Object.draw3D=|:|do
	matpush()
	mattrans(self.sphere.pos:unpack())
	self.pos:matrot()
	mattrans(0, 0, self.sphere.radius)

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
	self.lastPos = self.pos:clone()

	local dpos = (.5 * dt / (self.sphere.radius
--		* 2 * math.pi
	)) * self.vel * self.pos
	self.pos = (self.lastPos + dpos):unit()

	-- [[ here, if from/to crosses a sphere-touch boundary then move spheres
	local zAxis = self.pos:zAxis()	-- 'up'
	local velfwd = self.vel:axis():cross(zAxis) -- :unit()	-- movement dir
	-- [=[
	local unitvelfwd = velfwd:clone():unit()
	self.showIsTouching = false
	line3d(
		self.sphere.pos.x + self.sphere.radius * zAxis.x,
		self.sphere.pos.y + self.sphere.radius * zAxis.y,
		self.sphere.pos.z + self.sphere.radius * zAxis.z,

		self.sphere.pos.x + self.sphere.radius * zAxis.x + 16 * unitvelfwd.x,
		self.sphere.pos.y + self.sphere.radius * zAxis.y + 16 * unitvelfwd.y,
		self.sphere.pos.z + self.sphere.radius * zAxis.z + 16 * unitvelfwd.z,

		12
	)
	--]=]
	local ptOnSphere = self.sphere.pos + zAxis * self.sphere.radius
	for _,touch in ipairs(self.sphere.touching) do
		if zAxis:dot(touch.unitDelta) > touch.cosAngle
		and velfwd:dot(touch.midpoint - ptOnSphere) > 0
		then
			self.showIsTouching = true
			-- [[ .. then transfer spheres
			local dpos = quat.vectorRotate(
				zAxis,
				self.sphere.pos + self.sphere.radius * zAxis - touch.sphere.pos
			)
			self.pos = dpos * self.pos
			-- project out z-axis to get rid of twisting ...
			self.vel -= quat.fromVec3(self.pos:zAxis()) * self.vel:axis():dot(self.pos:zAxis())
			self.sphere.objs:removeObject(self)
			self.sphere = touch!.sphere
			self.sphere.objs:insert(self)
			break
			--]]
		end
	end
	--]]
end

local Shot = Object:subclass()
Shot.speed = 300
Shot.size = 1
Shot.init=|:,args|do
	Shot.super.init(self, args)
	self.endTime = args?.endTime
end
Shot.draw2D=|:|do
	matpush()
	transformQuatTo2D(self.pos)

	rect(-1, -1, 2, 2, self.color)

	matpop()
end
Shot.draw3D=|:|do
	matpush()
	mattrans(self.sphere.pos:unpack())
	mattrans((self.pos:zAxis() * self.sphere.radius):unpack())

	rect(-1, -1, 2, 2, self.color)

	matpop()
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
			local angmom = other.vel * other:calcMass()
			local perturb1 = randomVel() * 2000
			local perturb2 = randomVel() * 2000
			for s1=-1,1,2 do
				local half_th1 = .25 * s1 * other.size / (self.sphere.radius
				--	* 2 * math.pi
				)
				local sin_half_th1 = math.sin(half_th1)
				local cos_half_th1 = math.sqrt(1 - sin_half_th1^2)
				for s2=-1,1,2 do
					local half_th2 = .25 * s2 * other.size / (self.sphere.radius
					--	* 2 * math.pi
					)
					local sin_half_th2 = math.sin(half_th2)
					local cos_half_th2 = math.sqrt(1 - sin_half_th2^2)
					local newangmom = .25 * angmom + s1 * perturb1 + s2 * perturb2
					local piece = Rock{
						sphere = other.sphere,
						pos = other.pos
							* quat(sin_half_th1, 0, 0, cos_half_th1)
							* quat(0, sin_half_th2, 0, cos_half_th2),
						--rot = math.random() * 2 * 20,	-- TODO conserve this too?	-- TODO is this used?
						size = other.size == other.sizeL and other.sizeM or other.sizeS,
					}
					piece.vel = newangmom * (1 / piece:calcMass())
				end
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
Ship.draw2D=|:|do
	local fwd = vec2(0,-1)
	matpush()
	transformQuatTo2D(self.pos)

	--[[ vector
	drawTri(vec2(), fwd, self.size, self.color)
	if self.thrust then
		drawTri(-3 * fwd, -fwd, .5 * self.size, 9)
	end
	Ship.super.draw2D(self)	-- TODO super call outside pop...
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
Ship.draw3D=|:|do
	matpush()
	mattrans(self.sphere.pos:unpack())

	self.pos:matrot()
	mattrans(0, 0, self.sphere.radius)

	matscale(self.size / 8, self.size / 8)
	mattrans(-8, -8)
	spr(2, 0, 0, 2, 2)
	--[[
	if self.showIsTouching then
		rect(0,0,16,16,12+16)
	end
	--]]
	if self.thrust then
		mattrans(4, 16)
		spr(1, 0, 0, 1, 1)
	end
	matpop()
end
Ship.shoot = |:|do
	if self.nextShootTime > time() then return end
	self.nextShootTime = time() + .2
	Shot{
		sphere = self.sphere,
		pos = self.pos:clone(),
		vel = self.vel + quat.fromVec3(self.pos:xAxis() * (Shot.speed)),
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
	if btn('up',0) then
		-- rotate on right axis = go fwd
		self.vel += quat.fromVec3(self.pos:xAxis() * (dt * self.accel))
		self.thrust = true
	end
	if btn('down',0) then
		self.vel += quat.fromVec3(self.pos:xAxis() * (-dt * self.accel))
		self.thrust = true
	end
	if btn('left',0) then
		--[[ use inertia?
		self.vel += quat.fromVec3(self.pos:zAxis() * (-dt * self.rot))
		--]]
		-- [[ or instant turn?
		local sin_halfth = math.sin(-.5 * dt * self.rot)
		local cos_halfth = math.sqrt(1 - sin_halfth^2) 
		self.pos *= quat(0, 0, sin_halfth, cos_halfth)
		--]]
	end
	if btn('right',0) then
		--[[ use inertia?
		self.vel += quat.fromVec3(self.pos:zAxis() * (dt * self.rot))
		--]]
		-- [[ or instant turn?
		local sin_halfth = math.sin(.5 * dt * self.rot)
		local cos_halfth = math.sqrt(1 - sin_halfth^2) 
		self.pos *= quat(0, 0, sin_halfth, cos_halfth)
		--]]
	end
	if btn('y',0) then
		self:shoot()
	end
	if btnp'a' then
		drawMethod += 1
		drawMethod %= 3
	end

	PlayerShip.super.update(self)
end

EnemyShip = Ship:subclass()
EnemyShip.thrust = true
-- [[
EnemyShip.update = |:|do
	local axisToPlayer = self.pos:zAxis():cross(player.pos:zAxis()):unit()
	local dirToPlayer = self.pos:zAxis():cross(axisToPlayer):unit()
	local dirFwd = self.pos:yAxis()
	-- find the shortest rotation from us to player
	-- compare its geodesic to our 'fwd' dir
	-- turn if needed
	local sinth = dirToPlayer:cross(dirFwd):dot(self.pos:zAxis())
	if math.abs(sinth) < math.rad(30) then
	elseif sinth > 0 then
		--self.vel += quat.fromVec3(self.pos:zAxis() * (dt * self.rot))
		local sin_halfth = math.sin(-.5 * dt * self.rot)
		local cos_halfth = math.sqrt(1 - sin_halfth^2) 
		self.pos *= quat(0, 0, sin_halfth, cos_halfth)
	elseif sinth < 0 then
		--self.vel += quat.fromVec3(self.pos:zAxis() * (-dt * self.rot))
		local sin_halfth = math.sin(.5 * dt * self.rot)
		local cos_halfth = math.sqrt(1 - sin_halfth^2) 
		self.pos *= quat(0, 0, sin_halfth, cos_halfth)
	end

	self.vel += quat.fromVec3(self.pos:xAxis() * (dt * self.accel))

	PlayerShip.super.update(self)
end
--]]

Rock = Object:subclass()
Rock.sizeL = 20
Rock.sizeM = 10
Rock.sizeS = 5
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

			--self.pos:set(self.lastPos)
			self.vel = totalAngMom * (selfMass / totalMass)
			--self.vel -= 2 * totalAngMomUnit * self.vel:dot(totalAngMomUnit)
			--self.vel *= .1
			self.vel -= quat.fromVec3(self.pos:zAxis()) * self.vel:axis():dot(self.pos:zAxis())

			--other.pos:set(other.lastPos)
			other.vel = totalAngMom * (otherMass / totalMass)
			--other.vel -= 2 * totalAngMomUnit * other.vel:dot(totalAngMomUnit)
			--other.vel *= .1
			other.vel -= quat.fromVec3(other.pos:zAxis()) * other.vel:axis():dot(other.pos:zAxis())

			other.health -= .1
		end
	end
end
Rock.draw2D=|:|do
	matpush()
	transformQuatTo2D(self.pos)
	--[[ vector
	local fwd = vec2(0,1)
	local rightx = -fwd.y
	local righty = fwd.x
	line(self.size*(fwd.x+rightx), self.size*(fwd.y+righty), self.size*(rightx - fwd.x), self.size*(righty - fwd.y), self.color)
	line(self.size*(rightx-fwd.x), self.size*(righty-fwd.y), self.size*(-rightx - fwd.x), self.size*(-righty - fwd.y), self.color)
	line(self.size*(-rightx - fwd.x), self.size*(-righty - fwd.y), self.size*(fwd.x-rightx), self.size*(fwd.y-righty), self.color)
	line(self.size*(fwd.x-rightx), self.size*(fwd.y-righty), self.size*(fwd.x+rightx), self.size*(fwd.y+righty), self.color)
	Rock.super.draw2D(self)	-- TODO super call outside pop...
	--]]
	-- [[ sprite
	rectb(-self.size, -self.size, 2*self.size, 2*self.size, self.color)
	--]]
	matpop()
end
Rock.draw3D=|:|do
	matpush()
	mattrans(self.sphere.pos:unpack())
	self.pos:matrot()
	mattrans(0, 0, self.sphere.radius)

	rectb(-self.size, -self.size, 2*self.size, 2*self.size, self.color)

	matpop()
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
			pos = randomPos(),
			vel = randomVel() * 10,
			rot = math.random() * 2 * 20,	-- is this used?
		}
	end
end


local spheres = table()

local startSphere = Sphere{
	--pos = vec3(0,0,0),
	pos = vec3(128,0,0),
	--radius = 256 / (2 * math.pi),
	--radius = 128 / (2 * math.pi),
	--radius = 256,
	radius = 200,
	--radius = 128,
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

-- build touching table
for i=1,#spheres-1 do
	local si = spheres[i]
	for j=i+1,#spheres do
		local sj = spheres[j]
		if (si.pos - sj.pos):len() < si.radius + sj.radius then
			local delta = sj.pos - si.pos
			local dist = delta:len()	-- distance between spheres
			local unitDelta = delta / dist
			local intCircDist = .5 * dist * (1 - (sj.radius^2 - si.radius^2) / dist^2)
			local midpoint = si.pos + unitDelta * intCircDist
			local intCircRad = math.sqrt(sj.radius^2 - intCircDist^2)
			local cosAngleI = math.clamp(intCircDist / si.radius, -1, 1)
			local cosAngleJ = math.clamp((dist - intCircDist) / sj.radius, -1, 1)
			si.touching:insert{
				sphere = sj,
				delta = delta,
				unitDelta = unitDelta,
				dist = dist,
				intCircDist = intCircDist,
				intCircRad = intCircRad,
				midpoint = midpoint,
				angle = math.acos(cosAngleI),
				cosAngle = cosAngleI,
			}
			sj.touching:insert{
				sphere = si,
				delta = -delta,
				unitDelta = -unitDelta,
				dist = dist,
				intCircDist = dist - intCircDist,
				intCircRad = intCircRad,
				midpoint = midpoint,
				angle = math.acos(cosAngleJ),
				cosAngle = cosAngleJ,
			}
		end
	end
end


-- start level

player = PlayerShip{
	sphere = startSphere,
	--sphere = spheres:last(),
}


-- returns a quat of a z-rotation times an x-rotation
quatRotZX_comp=|thz,thx|do
	local cos_halfthz = math.cos(.5 * thz)
	local sin_halfthz = math.sqrt(1 - cos_halfthz^2)
	local cos_halfthx = math.cos(.5 * thx)
	local sin_halfthx = math.sqrt(1 - cos_halfthx^2)
	return 
		cos_halfthz * sin_halfthx,
		sin_halfthz * sin_halfthx,
		sin_halfthz * cos_halfthx,
		cos_halfthz * cos_halfthx
end



drawMethod = 2
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
	if drawMethod == 2 then
		-- [[ draw2D 2d on surface view
		-- screen boundary for debugging
		mattrans(screenSize.x / 2, screenSize.y / 2)	-- screen center
		--[=[
		local r = viewSphere.radius * 2 * math.pi
		ellib(-r, -r, 2*r, 2*r, 12)
		--]=]
		for _,o in ipairs(viewSphere.objs) do
			o:draw2D()
		end
		--]]

		-- [[ draw portals in 2D mode
		--local n = 10
		local n = 60
		for _,touch in ipairs(viewSphere.touching) do
			local touchSphere = touch.sphere
			local delta = touch.delta
			
			local q1 = quat.vectorRotate(vec3(0,0,1), delta)
			
			local firstptx, firstpty
			local lastptx, lastpty
			for i=1,n do
				local th = 2 * math.pi * (i - .5) / n
				--[=[
				local cos_halfth = math.cos(.5 * th)
				local sin_halfth = math.sqrt(1 - cos_halfth^2)
				
				local cos_halftouchangle = math.cos(.5 * touch.angle)
				local sin_halftouchangle = math.sqrt(1 - cos_halftouchangle^2)
				
				--[[
				local q2 = quat(0,0,sin_halfth, cos_halfth)
				local q3 = quat(sin_halftouchangle,0,0,cos_halftouchangle)
				local q23 = q2 * q3
				--]]
				-- [[ (z2 k + w2) * (x3 i + w3)
				-- = (z2 k + w2) x3 i + (z2 k + w2) w3
				-- = z2 x3 k i + w2 x3 i + z2 w3 k + w2 w3
				-- = w2 x3 i + z2 x3 j + z2 w3 k + w2 w3
				-- = cos_halfth sin_halftouchangle i + sin_halfth sin_halftouchangle j + sin_halfth cos_halftouchangle k + cos_halfth cos_halftouchangle
				local q23 = quat(
					cos_halfth * sin_halftouchangle,
					sin_halfth * sin_halftouchangle,
					sin_halfth * cos_halftouchangle,
					cos_halfth * cos_halftouchangle
				)
				--]]
				--]=]
				-- [=[
				local q23 = quat(quatRotZX_comp(th, touch.angle))
				--]=]

				local ptx, pty = quatTo2D(q1 * q23)
				if not firstptx then
					firstptx = ptx
					firstpty = pty
				end
				if lastptx then
					line(lastptx, lastpty, ptx, pty, 12)
				end
				lastptx = ptx
				lastpty = pty
			end
			line(lastptx, lastpty, firstptx, firstpty, 12)
		end
		--]]
		-- [[ draw a circle where our sphere boundary should be
		do
			local idiv=60
			local jdiv=30
			local idivstep = 5
			local jdivstep = 5
			local corner=|i,j|do
				local u = i / idiv * math.pi * 2
				local v = j / jdiv * math.pi
				--[==[
				local cos_halfu = math.cos(.5 * u)
				local sin_halfu = math.sqrt(1 - cos_halfu^2)
				
				local cos_halfv = math.cos(.5 * v)
				local sin_halfv = math.sqrt(1 - cos_halfv^2)
				
				return quatTo2D(
					--[=[
					quat(0,0,sin_halfu, cos_halfu)
					* quat(sin_halfv,0,0,cos_halfv)
					--]=]
					-- [=[ work done above
					quat(
						cos_halfu * sin_halfv,
						sin_halfu * sin_halfv,
						sin_halfu * cos_halfv,
						cos_halfu * cos_halfv
					)
					--]=]
				)
				--]==]
				-- [==[
				return quatTo2D(quat(quatRotZX_comp(u, v)))
				--]==]
			end
			for i=0,idiv,idivstep do
				local prevptx, prevpty = corner(i,0)
				for j=1,jdiv do
					local ptx, pty = corner(i,j)
					if prevptx * ptx + prevpty * pty > 0 then
						line(prevptx, prevpty, ptx, pty, viewSphere.color)
					end
					prevptx = ptx
					prevpty = pty
				end
			end
			for j=0,jdiv,jdivstep do
				local prevptx, prevpty = corner(0,j)
				for i=1,idiv do
					local ptx, pty = corner(i,j)
					if prevptx * ptx + prevpty * pty > 0 then
						line(prevptx, prevpty, ptx, pty, viewSphere.color)
					end
					prevptx = ptx
					prevpty = pty
				end
			end
		end
		--]]
	else
		-- [[ draw3D view
		-- TODO lines aren't working so well with frustum

		-- projection
		local zn, zf = .1 * viewSphere.radius, 3 * viewSphere.radius
		matfrustum(-zn * viewTanFov, zn * viewTanFov, -zn * viewTanFov, zn * viewTanFov, zn, zf)

		-- view
		mattrans(0, 0, -viewDistScale * viewSphere.radius)
		if drawMethod == 0 then
			viewPos:conj():matrot()
		end
		mattrans(-viewSphere.pos.x, -viewSphere.pos.y, -viewSphere.pos.z)

		-- model
		for _,o in ipairs(viewSphere.objs) do
			o:draw3D()
		end
		--]]

		-- [[ draw portals as circles between spheres
		for _,touch in ipairs(viewSphere.touching) do
			local touchSphere = touch.sphere
			matpush()
			mattrans(viewSphere.pos.x, viewSphere.pos.y, viewSphere.pos.z)
			
			quat.vectorRotate(vec3(0,0,1), touch.unitDelta):matrot()
			
			-- what'touchSphere the intersection plane distance?
			local dist = touch.dist
			local intCircDist = touch.intCircDist
			local intCircRad = touch.intCircRad
			mattrans(0, 0, intCircDist)
			ellib(-intCircRad, -intCircRad, 2*intCircRad, 2*intCircRad, 12)
			matpop()
		end
		--]]
		-- [[ draw a circle where our sphere boundary should be
		for _,s in ipairs(spheres) do
			local idiv=10
			local jdiv=5
			local corner=|i,j|do
				local u = i / idiv * math.pi * 2
				local v = j / jdiv * math.pi
				return s.radius * math.cos(u) * math.sin(v) + s.pos.x,
						s.radius * math.sin(u) * math.sin(v) + s.pos.y,
						s.radius * math.cos(v) + s.pos.z
			end
			local quad = |i1,j1, i2,j2, i3,j3, i4,j4|do
				local x1,y1,z1 = corner(i1,j1)
				local x2,y2,z2 = corner(i2,j2)
				local x3,y3,z3 = corner(i3,j3)
				--local x4,y4,z4 = corner(i4,j4)
				line3d(x1,y1,z1, x2,y2,z2, s.color)
				line3d(x2,y2,z2, x3,y3,z3, s.color)
				--line3d(x3,y3,z3, x4,y4,z4, s.color)
				--line3d(x4,y4,z4, x1,y1,z1, s.color)
			end
			for i=0,idiv-1 do
				for j=0,jdiv-1 do
					quad(i,j, i+1,j, i+1,j+1, i,j+1)
				end
			end
			-- TODO calc this properly ... based on viewTanFov, viewDistScale, and screenSize, viewSphere.radius
			--local r = viewSphere.radius * viewDistScale / viewTanFov * 1.15
			--ellib(screenSize.x*.5 - r, screenSize.y*.5 - r, 2*r, 2*r, 12)
		end
		--]]
	end


	-- update all ... or just those on our sphere ... or just those within 2 or 3 spheres?
	-- TODO check touch between sphere eventually. .. but that means tracking pos on multiple spheres ...
	--local objs = table()
	viewSphere:update()
	--objs:append(viewSphere.objs)
	for _,touch in ipairs(viewSphere.touching) do
		touch.sphere:update()
		--objs:append(touch.sphere.objs)
	end

	-- draw gui
	cls(nil, true)
	if player then
		matident()
		rect(0, screenSize.y-10, player.health/player.healthMax*screenSize.x, 10, 16+9)
	end
end
