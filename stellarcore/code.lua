-- title = Stellar Core
-- saveid = stellarcore
-- author = Chris Moore
-- description = classic "Asteroids" but with proper spherical universes, and interconnections with neighboring universes.

----------------------- BEGIN ext/range.lua-----------------------
local range=|a,b,c|do
	local t = table()
	if c then
		for x=a,b,c do t:insert(x) end
	elseif b then
		for x=a,b do t:insert(x) end
	else
		for x=1,a do t:insert(x) end
	end
	return t
end
----------------------- END ext/range.lua-----------------------

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

-- component based ... where to put this ...
vec2_lenSq=|x,y|x^2+y^2
vec2_len=|x,y|math.sqrt(x^2+y^2)

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

-- component-based
vec3_dot_comp=|ax,ay,az, bx,by,bz| ax*bx + ay*by + az*bz
vec3_cross_comp=|ax,ay,az, bx,by,bz| (
	ay*bz - az*by,
	az*bx - ax*bz,
	ax*by - ay*bx
)
vec3_len_comp=|x,y,z|math.sqrt(x^2 + y^2 + z^2)
vec3_unit_comp=|x,y,z|do
	local s = 1 / math.max(1e-15, vec3_len_comp(x,y,z))
	return x*s, y*s, z*s
end
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
	cross=|a,b| vec3(vec3_cross_comp(a.x, a.y, a.z, b.x, b.y, b.z)),
	len=|v| math.sqrt(v:lenSq()),
	distSq = |a,b| ((a.x-b.x)^2 + (a.y-b.y)^2 + (a.z-b.z)^2),
	unit=|v,res|do
		local s = 1 / math.max(1e-15, v:len())
		return res
			and res:set(v.x * s, v.y * s, v.z * s)
			or vec3(v.x * s, v.y * s, v.z * s)
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

quat_scale_comp=|s, x,y,z,w|(x*s, y*s, z*s, w*s)	-- scale comes first
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

-- assumes |x,y,z|=1
-- assumes theta in [0,2*pi)
quat_fromAngleAxisUnit_comp=|x,y,z,theta|do
	local cosHalfTheta = math.cos(.5 * theta)
	local sinHalfTheta = math.sqrt(1 - cosHalfTheta^2)
	return x * sinHalfTheta, y * sinHalfTheta, z * sinHalfTheta, cosHalfTheta

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

quat_xAxis_comp=|x,y,z,w|(
	1 - 2 * (y * y + z * z),
	2 * (x * y + z * w),
	2 * (x * z - w * y)
)
quat.xAxis = |q, res| res
	and res:set(quat_xAxis_comp(q:unpack()))
	or vec3(quat_xAxis_comp(q:unpack()))

quat_yAxis_comp=|x,y,z,w|(
	2 * (x * y - w * z),
	1 - 2 * (x * x + z * z),
	2 * (y * z + w * x)
)
quat.yAxis = |q, res| res
	and res:set(quat_yAxis_comp(q:unpack()))
	or vec3(quat_yAxis_comp(q:unpack()))

quat_zAxis_comp=|x,y,z,w|(
	2 * (x * z + w * y),
	2 * (y * z - w * x),
	1 - 2 * (x * x + y * y)
)
quat.zAxis = |q, res| res
	and res:set(quat_zAxis_comp(q:unpack()))
	or vec3(quat_zAxis_comp(q:unpack()))

quat.axis = |q, res| res
	and res:set(q.x, q.y, q.z)
	or vec3(q.x, q.y, q.z)

quat.rotate = |:, v, res| do
	local v4 = self * quat(v.x, v.y, v.z, 0) * self:conj()
	return v4:axis(res)
end

quat.conj = |:, res|
	((res or quat()):set(-self.x, -self.y, -self.z, self.w))

quat_len_comp=|x,y,z,w|math.sqrt(x^2 + y^2 + z^2 + w^2)

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
-- assume both axii are unit already
quat_vectorRotateUnit_comp=|ax,ay,az,bx,by,bz|do
	local cosTheta = ax*bx + ay*by + az*bz
	if math.abs(cosTheta) > 1 - 1e-9 then
		return 0,0,0,1
	end
	local sinTheta = math.sqrt(1 - cosTheta^2)
	local invSinTheta = 1 / sinTheta
	local cx = (ay * bz - az * by) * invSinTheta
	local cy = (az * bx - ax * bz) * invSinTheta
	local cz = (ax * by - ay * bx) * invSinTheta
	local sinHalfTheta = math.sqrt(.5 * (1 - cosTheta))
	local cosHalfTheta = math.sqrt(.5 * (1 + cosTheta))
	return cx * sinHalfTheta, cy * sinHalfTheta, cz * sinHalfTheta, cosHalfTheta
end

-- make a rotation from v1 to v2
-- returns result in angle-axis form
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

-- make a rotation from v1 to v2
quat.vectorRotate=|v1,v2|do
	local x,y,z,th = quat.vectorRotateToAngleAxis(v1,v2)
	return quat(x,y,z,th):fromAngleAxis()
end

quat_matrot_comp=|x,y,z,w|do
	local coshalfangle = w	-- [-1,1] <-> cos(theta) for theta in [0, pi]
	local sinhalfangle = math.sqrt(1 - coshalfangle^2)	-- [0,1]
	if sinhalfangle <= 1e-20 then return end
	local il = 1/sinhalfangle
	local cosangle = coshalfangle^2 - sinhalfangle^2
	local sinangle = 2 * sinhalfangle * coshalfangle
	matrotcs(cosangle, sinangle, x * il, y * il, z * il)
end
quat.matrot=|q| quat_matrot_comp(q:unpack())

-- returns a quat of a z-rotation times an x-rotation
-- I did this often enough that I put it in its own method
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
	local qx, qy, qz, qw = quat_fromAngleAxisUnit_comp(x,y,z, math.random() * math.pi)
	return quat_mul_comp(
		qx, qy, qz, qw,
		quat_fromAngleAxisUnit_comp(1, 0, 0, math.random() * 2 * math.pi)
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
	-- do inter-object interactions (touch, forces, etc)
	for i=1,#objs-1 do
		local o = objs[i]
		if not o.dead then
			local ozx, ozy, ozz = quat_zAxis_comp(o.pos:unpack())
			local omass = o:calcMass()
			for i2=i+1,#objs do
				local o2 = objs[i2]
				if not o2.dead then
					local o2mass = o2:calcMass()
					local o2zx, o2zy, o2zz = quat_zAxis_comp(o2.pos:unpack())
					-- check touch
					local dist = math.acos(
						vec3_dot_comp(ozx, ozy, ozz, o2zx, o2zy, o2zz)
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
						local gdist = math.max(dist, 1)
						local mu = gravConst / (gdist * gdist)
						local rhsx, rhsy, rhsz = vec3_unit_comp(
							vec3_cross_comp(ozx, ozy, ozz, o2zx, o2zy, o2zz)
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
	vx, vy, vz, vw = quat_mul_comp(
		-viewPos.x, -viewPos.y, -viewPos.z, viewPos.w,
		vx, vy, vz, vw
	)
	local posx, posy, posz = quat_zAxis_comp(vx, vy, vz, vw)
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
	local fwdx, fwdy, fwdz = quat_yAxis_comp(vx, vy, vz, vw)
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
Object.draw2D=|:|do
	matpush()
	transformQuatTo2D(self.pos:unpack())

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
	local dposx, dposy, dposz, dposw = quat_scale_comp(
		(.5 * dt / (self.sphere.radius
--			* 2 * math.pi
		)),
		quat_mul_comp(
			self.vel.x, self.vel.y, self.vel.z, self.vel.w,
			self.pos:unpack()
		)
	)
	self.pos.x += dposx
	self.pos.y += dposy
	self.pos.z += dposz
	self.pos.w += dposw
	local s = quat_len_comp(self.pos:unpack())
	if s > 1e-20 then
		local is = 1 / s
		self.pos.x *= is
		self.pos.y *= is
		self.pos.z *= is
		self.pos.w *= is
	else
		self.pos.x, self.pos.y, self.pos.z, self.pos.w = 0, 0, 0, 1
	end

	-- [[ here, if from/to crosses a sphere-touch boundary then move spheres
	local zAxisx, zAxisy, zAxisz = quat_zAxis_comp(self.pos:unpack())	-- 'up'
	local velfwdx, velfwdy, velfwdz = vec3_cross_comp(
		self.vel.x, self.vel.y, self.vel.z,
		zAxisx, zAxisy, zAxisz
	)	-- movement dir

	local ptOnSpherex = self.sphere.pos.x + zAxisx * self.sphere.radius
	local ptOnSpherey = self.sphere.pos.y + zAxisy * self.sphere.radius
	local ptOnSpherez = self.sphere.pos.z + zAxisz * self.sphere.radius
	-- [=[
	local unitvelfwdx, unitvelfwdy, unitvelfwdz = vec3_unit_comp(velfwdx, velfwdy, velfwdz)
	self.showIsTouching = false
	line3d(
		ptOnSpherex,
		ptOnSpherey,
		ptOnSpherez,
		ptOnSpherex + 16 * unitvelfwdx,
		ptOnSpherey + 16 * unitvelfwdy,
		ptOnSpherez + 16 * unitvelfwdz,
		12
	)
	--]=]
	for _,touch in ipairs(self.sphere.touching) do
		if vec3_dot_comp(
			zAxisx, zAxisy, zAxisz,
			touch.unitDelta:unpack()
		) > touch.cosAngle then
			if vec3_dot_comp(
				velfwdx, velfwdy, velfwdz,

				touch.midpoint.x - ptOnSpherex,
				touch.midpoint.y - ptOnSpherey,
				touch.midpoint.z - ptOnSpherez
			) > 0 then
				self.showIsTouching = true
				-- [[ .. then transfer spheres
				local newZAxisx = ptOnSpherex - touch.sphere.pos.x
				local newZAxisy = ptOnSpherey - touch.sphere.pos.y
				local newZAxisz = ptOnSpherez - touch.sphere.pos.z
				newZAxisx, newZAxisy, newZAxisz = vec3_unit_comp(newZAxisx, newZAxisy, newZAxisz)
				local dposx, dposy, dposz, dposw = quat_vectorRotateUnit_comp(
					zAxisx, zAxisy, zAxisz,
					newZAxisx, newZAxisy, newZAxisz
				)
				self.pos.x, self.pos.y, self.pos.z, self.pos.w = quat_mul_comp(
					dposx, dposy, dposz, dposw,
					self.pos:unpack()
				)

				-- project out z-axis to get rid of twisting ...
				local zAxisx, zAxisy, zAxisz = quat_zAxis_comp(self.pos:unpack())	-- 'up'
				local vel_dot_zAxis = vec3_dot_comp(
					zAxisx, zAxisy, zAxisz,
					self.vel:unpack()
				)
				self.vel.x -= zAxisx * vel_dot_zAxis
				self.vel.y -= zAxisy * vel_dot_zAxis
				self.vel.z -= zAxisz * vel_dot_zAxis

				self.sphere.objs:removeObject(self)
				self.sphere = touch.sphere
				self.sphere.objs:insert(self)
				break
				--]]
			end
		end
	end
	--]]
end

local Shot = Object:subclass()
Shot.speed = 300
Shot.size = 1
Shot.useGravity = false
Shot.init=|:,args|do
	Shot.super.init(self, args)
	self.endTime = args?.endTime
end
Shot.draw2D=|:|do
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
Shot.draw3D=|:|do
	local zAxisx, zAxisy, zAxisz = quat_zAxis_comp(self.pos:unpack())
	local sphere = self.sphere
	local spherePos = sphere.pos
	local sphereRadius = sphere.radius
	local pos3dx = spherePos.x + zAxisx * sphereRadius
	local pos3dy = spherePos.y + zAxisy * sphereRadius
	local pos3dz = spherePos.z + zAxisz * sphereRadius

	--[[
	matpush()
	mattrans(x, y, z)
	rect(-1, -1, 2, 2, self.color)
	matpop()
	--]]
	-- [[
	rect(pos3dx-1, pos3dy-1, 2, 2, self.color)	-- do we need a z for anything?
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
						* quat(quatRotZX_comp(
							2 * math.pi * i / newrocks,
							math.random() * other.size / self.sphere.radius
						)),
					--rot = math.random() * 2 * 20,	-- TODO conserve this too?	-- TODO is this used?
					size = other.size == other.sizeL
						and (math.random(2) == 1 and other.sizeM or other.sizeS)
						or other.sizeS,
				}
				piece.vel = oldvel + randomVel() * .2 * vec3_len_comp(oldvel:unpack())
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
	matpush()
	transformQuatTo2D(self.pos:unpack())

	--[[ vector
	local fwd = vec2(0,-1)
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
	self.nextShootTime = time() + 1/15

	local xAxisx, xAxisy, xAxisz = quat_xAxis_comp(self.pos:unpack())
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
		local xAxisx, xAxisy, xAxisz = quat_xAxis_comp(selfPos:unpack())
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
		local sin_halfth = math.sin(-.5 * dt * self.rot)
		local cos_halfth = math.sqrt(1 - sin_halfth^2)
		selfPos.x, selfPos.y, selfPos.z, selfPos.w = quat_mul_comp(
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
		local sin_halfth = math.sin(.5 * dt * self.rot)
		local cos_halfth = math.sqrt(1 - sin_halfth^2)
		selfPos.x, selfPos.y, selfPos.z, selfPos.w = quat_mul_comp(
			selfPos.x, selfPos.y, selfPos.z, selfPos.w,
			0, 0, sin_halfth, cos_halfth
		)
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
	local selfPos = self.pos
	local zAxisx, zAxisy, zAxisz = quat_zAxis_comp(selfPos:unpack())

	-- TODO dirToPlayer = zAxis cross (zAxis cross player_zAxis) ... double-cross-product ...
	-- ... and then it's used a 3rd time to calculate sin(theta) ...
	local dirToPlayerx, dirToPlayery, dirToPlayerz = vec3_unit_comp(vec3_cross_comp(
		zAxisx, zAxisy, zAxisz,
		vec3_cross_comp(
			zAxisx, zAxisy, zAxisz,
			quat_zAxis_comp(player.pos:unpack())
		)
	))

	-- find the shortest rotation from us to player
	-- compare its geodesic to our 'fwd' dir
	-- turn if needed
	local sinth = vec3_dot_comp(
		zAxisx, zAxisy, zAxisz,
		vec3_cross_comp(
			dirToPlayerx, dirToPlayery, dirToPlayerz,
			quat_yAxis_comp(selfPos:unpack())
		)
	)
	if math.abs(sinth) < math.rad(30) then
	elseif sinth > 0 then
		--self.vel += quat.fromVec3(selfPos:zAxis() * (dt * self.rot))
		local sin_halfth = math.sin(-.5 * dt * self.rot)
		local cos_halfth = math.sqrt(1 - sin_halfth^2)
		-- TODO optimized mul-z-rhs
		selfPos.x, selfPos.y, selfPos.z, selfPos.w = quat_mul_comp(
			selfPos.x, selfPos.y, selfPos.z, selfPos.w,
			0, 0, sin_halfth, cos_halfth
		)
	elseif sinth < 0 then
		--self.vel += quat.fromVec3(selfPos:zAxis() * (-dt * self.rot))
		local sin_halfth = math.sin(.5 * dt * self.rot)
		local cos_halfth = math.sqrt(1 - sin_halfth^2)
		selfPos.x, selfPos.y, selfPos.z, selfPos.w = quat_mul_comp(
			selfPos.x, selfPos.y, selfPos.z, selfPos.w,
			0, 0, sin_halfth, cos_halfth
		)
	end

	local s = dt * self.accel
	local xAxisx, xAxisy, xAxisz = quat_xAxis_comp(self.pos:unpack())
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
Rock.draw2D=|:|do
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
	Rock.super.draw2D(self)	-- TODO super call outside pop...
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
		return quat(quat_mul_comp(
			x,y,z, math.random() * math.pi,
			0, 0, 1, math.random() * 2 * math.pi
		))
	end)(),
	--]]
	color = math.random(1,15),
})
local spheres = table()

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
				return quatTo2D(quatRotZX_comp(u, v))
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
		-- [[ sphere background -- draw star background or something ... 
		cls(nil, true)
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
				local x, y = quatTo2D(quatRotZX_comp(u * 2 * math.pi, v * math.pi))
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

		-- [[ draw portals in 2D mode
		local n = 30
		for _,touch in ipairs(viewSphere.touching) do
			local touchSphere = touch.sphere

			local q1x, q1y, q1z, q1w = quat_vectorRotateUnit_comp(
				0,0,1,
				touch.unitDelta:unpack()
			)

			local px, py = quatTo2D(
				quat_mul_comp(
					q1x, q1y, q1z, q1w,
					quatRotZX_comp(0, touch.angle)
				)
			)
			for i=1,n do
				local th = 2 * math.pi * (i - .5) / n
				local x, y = quatTo2D(
					quat_mul_comp(
						q1x, q1y, q1z, q1w,
						quatRotZX_comp(th, touch.angle)
					)
				)
				line(px, py, x, y, 12)
				px, py = x, y
			end
		end
		--]]

		-- [[ draw stars?
		for _,star in ipairs(stars) do
			local x, y = quatTo2D(star.pos:unpack())
			rect(x, y, 1, 1, star.color)
		end
		--]]
		
		-- [[ draw2D 2d on surface view
		for _,o in ipairs(viewSphere.objs) do
			o:draw2D()
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
			quat_matrot_comp(-viewPos.x, -viewPos.y, -viewPos.z, viewPos.w)
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

			quat_matrot_comp(
				quat_vectorRotateUnit_comp(
					0,0,1,
					touch.unitDelta:unpack()
				)
			)

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
			--local idiv,jdiv=60,30
			--local idivstep,jdivstep = 5,5
			local idiv,jdiv=10,5
			local idivstep,jdivstep = 1,1
			local corner=|i,j|do
				local u = i / idiv * math.pi * 2
				local v = j / jdiv * math.pi
				return s.radius * math.cos(u) * math.sin(v) + s.pos.x,
						s.radius * math.sin(u) * math.sin(v) + s.pos.y,
						s.radius * math.cos(v) + s.pos.z
			end
			for i=0,idiv,idivstep do
				local px, py, pz = corner(i,0)
				for j=1,jdiv do
					local x, y, z = corner(i,j)
					if vec3_dot_comp(px,py,pz, x,y,z) > 0 then
						line3d(px, py, pz, x, y, z, s.color)
					end
					px, py, pz = x, y, z
				end
			end
			for j=0,jdiv,jdivstep do
				local px, py, pz = corner(0,j)
				for i=1,idiv do
					local x, y, z = corner(i,j)
					if vec3_dot_comp(px,py,pz, x,y,z) > 0 then
						line3d(px, py, pz, x, y, z, s.color)
					end
					px,py,pz = x,y,z
				end
			end
		end
		--]]
	end


	-- update all ... or just those on our sphere ... or just those within 2 or 3 spheres?
	-- TODO check touch between sphere eventually. .. but that means tracking pos on multiple spheres ...
	viewSphere:update()
	-- [[ update touching spheres too (but not all spheres)
	-- how about just every so often if at all?
	if time() == math.floor(time()) then
		for _,touch in ipairs(viewSphere.touching) do
			touch.sphere:update()
		end
	end
	--]]

	-- draw gui
	cls(nil, true)
	if player then
		matident()
		rect(0, screenSize.y-10, player.health/player.healthMax*screenSize.x, 10, 16+9)
	end
end
