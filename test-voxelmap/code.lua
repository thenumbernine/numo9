-- title = Voxelmap Test
-- saveid = test-voxelmap
-- author = Chris Moore

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
-- ALREADY INCLUDED: --#include ext/class.lua
vec2_add=|ax,ay,bx,by|(ax+bx, ay+by)
vec2_sub=|ax,ay,bx,by|(ax-bx, ay-by)
vec2_lenSq=|x,y|x^2+y^2
vec2_len=|x,y|math.sqrt(x^2+y^2)
vec2_unit=|x,y|do
	local l = vec2_len(x,y)
	local s = 1 / math.max(1e-15, l)
	return x*s, y*s, l
end
vec2_scale=|s,x,y|(s*x, s*y)
vec2_dot=|ax,ay,bx,by| ax*bx + ay*by
-- cplx exp ... TODO replace vec2.exp with this
vec2_exp=|r,theta|(r*math.cos(theta),r*math.sin(theta))
-- cplx log
vec2_log=|x,y|do
	local logr = math.log((vec2_len(x,y)))
	return logr, math.atan2(y,x)
end

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
			v.x = x.x or x[1] or error("can't read x coord")
			v.y = x.y or x[2] or error("can't read y coord")
		else
			assert(x, "can't read set input")
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
	distSq=|a,b| ((a.x-b.x)^2 + (a.y-b.y)^2),
	dist=|a,b| math.sqrt(vec2.distSq(a,b)),
	distL1=|a,b| math.abs(a.x-b.x) + math.abs(a.y-b.y),
	unit=|v,res|do
		local s = 1 / math.max(1e-15, v:len())
		if res then
			return res:set(v.x * s, v.y * s)
		else
			return vec2(v.x * s, v.y * s)
		end
	end,

	-- these slightly break compat with vec2_exp and vec2_log above which are like cplx exp and log
	exp=|theta| vec2(math.cos(theta), math.sin(theta)),
	angle=|v| math.atan2(v.y, v.x),

	cross=|a,b| a.x * b.y - a.y * b.x,	-- or :det() maybe
	cplxmul = |a,b| vec2(a.x * b.x - a.y * b.y, a.x * b.y + a.y * b.x),
	__unm=|v| vec2(-v.x, -v.y),
	__add=|a,b| vec2(vec2_getvalue(a, 1) + vec2_getvalue(b, 1), vec2_getvalue(a, 2) + vec2_getvalue(b, 2)),
	__sub=|a,b| vec2(vec2_getvalue(a, 1) - vec2_getvalue(b, 1), vec2_getvalue(a, 2) - vec2_getvalue(b, 2)),
	__mul=|a,b| vec2(vec2_getvalue(a, 1) * vec2_getvalue(b, 1), vec2_getvalue(a, 2) * vec2_getvalue(b, 2)),
	__div=|a,b| vec2(vec2_getvalue(a, 1) / vec2_getvalue(b, 1), vec2_getvalue(a, 2) / vec2_getvalue(b, 2)),
	__mod=|a,b| vec2(vec2_getvalue(a, 1) % vec2_getvalue(b, 1), vec2_getvalue(a, 2) % vec2_getvalue(b, 2)),
	__eq=|a,b| a.x == b.x and a.y == b.y,
	__tostring=|v| '{'..v.x..','..v.y..'}',
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
-- ALREADY INCLUDED: --#include ext/class.lua

-- component-based
vec3_add=|ax,ay,az,bx,by,bz|(ax+bx, ay+by, az+bz)
vec3_sub=|ax,ay,az,bx,by,bz|(ax+bx, ay+by, az-bz)
vec3_neg=|x,y,z|(-x,-y,-z)
vec3_scale=|s,x,y,z|(s*x, s*y, s*z)
vec3_dot=|ax,ay,az, bx,by,bz| ax*bx + ay*by + az*bz
vec3_cross=|ax,ay,az, bx,by,bz| (
	ay*bz - az*by,
	az*bx - ax*bz,
	ax*by - ay*bx
)
vec3_lenSq=|x,y,z|x^2+y^2+z^2
vec3_len=|x,y,z|math.sqrt(x^2+y^2+z^2)
vec3_unit=|x,y,z|do
	local l = vec3_len(x,y,z)
	local s = 1 / math.max(1e-15, l)
	return x*s, y*s, z*s, l
end
vec3_toSpherical=|x,y,z|do
	local r = vec3_len(x,y,z)
	local theta = math.acos(z / r)
	local phi = math.atan2(y, x)
	return r,theta,phi
end
vec3_fromSpherical=|r,theta,phi|do
	local sinTheta, cosTheta = math.sin(theta), math.cos(theta)
	local sinPhi, cosPhi = math.sin(phi), math.cos(phi)
	local x = r * cosPhi * sinTheta
	local y = r * sinPhi * sinTheta
	local z = r * cosTheta
	return x, y, z
end

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
	__unm=|v| vec3(-v.x, -v.y, -v.z),
	__add=|a,b| vec3(vec3_getvalue(a, 1) + vec3_getvalue(b, 1), vec3_getvalue(a, 2) + vec3_getvalue(b, 2), vec3_getvalue(a, 3) + vec3_getvalue(b, 3)),
	__sub=|a,b| vec3(vec3_getvalue(a, 1) - vec3_getvalue(b, 1), vec3_getvalue(a, 2) - vec3_getvalue(b, 2), vec3_getvalue(a, 3) - vec3_getvalue(b, 3)),
	__mul=|a,b| vec3(vec3_getvalue(a, 1) * vec3_getvalue(b, 1), vec3_getvalue(a, 2) * vec3_getvalue(b, 2), vec3_getvalue(a, 3) * vec3_getvalue(b, 3)),
	__div=|a,b| vec3(vec3_getvalue(a, 1) / vec3_getvalue(b, 1), vec3_getvalue(a, 2) / vec3_getvalue(b, 2), vec3_getvalue(a, 3) / vec3_getvalue(b, 3)),
	__eq=|a,b| a.x == b.x and a.y == b.y and a.z == b.z,
	__tostring=|v| '{'..v.x..','..v.y..','..v.z..'}',
	__concat=string.concat,
	clone=|v| vec3(v),
	set=|v,x,y,z|do
		if type(x) == 'table' then
			v.x = x.x or x[1] or error("can't read x coord")
			v.y = x.y or x[2] or error("can't read y coord")
			v.z = x.z or x[3] or error("can't read z coord")
		else
			assert(x, "can't read set input")
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
	clamp=|v,a,b|do
		local mins = a
		local maxs = b
		if type(a) == 'table' and a.min and a.max then
			mins = a.min
			maxs = a.max
		end
		v.x = math.clamp(v.x, vec3_getvalue(mins, 1), vec3_getvalue(maxs, 1))
		v.y = math.clamp(v.y, vec3_getvalue(mins, 2), vec3_getvalue(maxs, 2))
		v.z = math.clamp(v.z, vec3_getvalue(mins, 3), vec3_getvalue(maxs, 3))
		return v
	end,
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
	cross=|a,b| vec3(vec3_cross(a.x, a.y, a.z, b.x, b.y, b.z)),
	lenSq=|v| v:dot(v),
	len=|v| math.sqrt(v:lenSq()),
	distSq=|a,b| ((a.x-b.x)^2 + (a.y-b.y)^2 + (a.z-b.z)^2),
	dist=|a,b| math.sqrt(vec3.distSq(a,b)),
	distL1=|a,b| math.abs(a.x-b.x) + math.abs(a.y-b.y) + math.abs(a.z-b.z),
	unit=|v,res|do
		local s = 1 / math.max(1e-15, v:len())
		return res
			and res:set(v.x * s, v.y * s, v.z * s)
			or vec3(v.x * s, v.y * s, v.z * s)
	end,
	toSpherical=|v,res|res
		and res:set(vec3_toSpherical(v:unpack()))
		or vec3(vec3_toSpherical(v:unpack())),
	fromSpherical=|v,res|res
		and res:set(vec3_fromSpherical(v:unpack()))
		or vec3(vec3_fromSpherical(v:unpack())),
}

----------------------- END vec/vec3.lua  -----------------------
----------------------- BEGIN numo9/matstack.lua-----------------------
--[[
There's only one stack, you can push/pop mv and proj onto it willy nilly
--]]
assert.eq(ramsize'modelMat', 16*4, "expected modelMat to be 32bit")	-- need to assert this for my peek/poke push/pop. need to peek/poke vs writing to app.ram directly so it is net-reflected.
assert.eq(ramsize'viewMat', 16*4, "expected viewMat to be 32bit")
assert.eq(ramsize'projMat', 16*4, "expected projMat to be 32bit")

local modelMatAddr = ramaddr'modelMat'
local viewMatAddr = ramaddr'viewMat'
local projMatAddr = ramaddr'projMat'
assert.eq(modelMatAddr + ramsize'modelMat', viewMatAddr)
assert.eq(viewMatAddr + ramsize'viewMat', projMatAddr)

modelMatrixIndex = 0
viewMatrixIndex = 1
projMatrixIndex = 2

local matstack=table()
local matpush=|matrixIndex|do
	matrixIndex = matrixIndex or 0
	local t={}
	for i=0,15 do
		t[i+1] = peekf(modelMatAddr + (i << 2 | matrixIndex << 6))
	end
	matstack:insert(t)
end

local matpop=|matrixIndex|do
	matrixIndex = matrixIndex or 0
	local t = matstack:remove()
	if not t then return end
	for i=0,15 do
		pokef(modelMatAddr + (i << 2 | matrixIndex << 6), t[i+1])
	end
end

----------------------- END numo9/matstack.lua  -----------------------
----------------------- BEGIN numo9/lights.lua-----------------------
-- ALREADY INCLUDED: --#include ext/class.lua
-- ALREADY INCLUDED: --#include vec/vec2.lua
-- ALREADY INCLUDED: --#include vec/vec3.lua
-- ALREADY INCLUDED: --#include numo9/matstack.lua	-- modelMatrixIndex etc


-- light system object
Lights = {}
do
	-- how many lights to use
	-- must be less than max lights,
	--  which is hard coded to the ram size ...
	-- tell user somehow ... offsetof struct after lights?
	--  or make it a 'light' blob?
	Lights.numLightsAddr = ramaddr'numLights'
	Lights.count = 0

	-- TODO this is in numo9/rom.lua
	-- gotta think of a way of how to provide it to ramaddr / ramsize
	-- or some kind of reflection access for the structs
	-- I really don't want to expose pointers to the ROM API layer ...
	Lights.lightStructSize = 0xc8
	Lights.lightEnabledOffset = 0x00 -- size=0x01 type=unsigned char
	Lights.lightRegionOffset = 0x02 -- size=0x08 type=unsigned short [4]
	Lights.lightAmbientColorOffset = 0x0c -- size=0x0c type=float [3]
	Lights.lightDiffuseColorOffset = 0x18 -- size=0x0c type=float [3]
	Lights.lightSpecularColorOffset = 0x24 -- size=0x10 type=float [4]
	Lights.lightDistAttenOffset = 0x34 -- size=0x0c type=float [3]
	Lights.lightCosAngleRangeOffset = 0x40 -- size=0x08 type=float [2]
	Lights.lightViewMatOffset = 0x48 -- size=0x40 type=float [16]
	Lights.lightProjMatOffset = 0x88 -- size=0x40 type=float [16]

	-- values of lightEnabledOffset, also in numo9/rom.lua:
	Lights.LIGHT_ENABLED_UPDATE_DEPTH_TEX = 1
	Lights.LIGHT_ENABLED_UPDATE_CALCS = 2


	-- TODO rect allocator
	-- do everything in 128x128 blocks?
	-- allocate by this:
	Lights.lightmapWidth = peekw(ramaddr'lightmapWidth')
	Lights.lightmapHeight = peekw(ramaddr'lightmapHeight')

	Lights.lightsAddr = ramaddr'lights'
	Lights.lightAddrEnd = Lights.lightsAddr + ramsize'lights'
	Lights.maxLights = (Lights.lightAddrEnd - Lights.lightsAddr) / Lights.lightStructSize	-- TODO match RAM somehow, or use blobs'light' size TODO
	assert.eq((Lights.lightAddrEnd - Lights.lightsAddr) % Lights.lightStructSize, 0, 'lightsAddr block not aligned to light size')
	assert.eq(Lights.lightsAddr + Lights.maxLights * Lights.lightStructSize, Lights.lightAddrEnd)

	Lights.lightSubSize = 128	-- 128 x 128 subregions in our uber-lightmap
	Lights.lightmapWidthInSubRegions = math.floor(Lights.lightmapWidth / Lights.lightSubSize)
	Lights.lightmapHeightInSubRegions = math.floor(Lights.lightmapHeight / Lights.lightSubSize)

	-- make sure we use no more than we have subregion room for
	do
		local maxLightSubRegions = Lights.lightmapWidthInSubRegions * Lights.lightmapHeightInSubRegions
		if Lights.maxLights > maxLightSubRegions then
			trace('!!! mem maxLights is '..Lights.maxLights..' but subregion only has room for '..maxLightSubRegions)
			Lights.maxLights = maxLightSubRegions
		end
	end

	-- w,h = width and height in our subregion units (128x128)
	-- current allocation scheme is intentionally poor.
	-- it's made for 1x1 unit subregions.
	--  it'll just inc by x, then if it overflows it'll increment y
	-- so if you do this on w,h > 1 (like the skylight) then don't expect it to work for any more lights than this.
	Lights.new = |:,w,h|do
		if self.count >= self.maxLights then
			trace'!!! light overflow'
			return
		end

		w = w or 1
		h = h or 1
		local lightAddr = self.lightsAddr + self.count * self.lightStructSize
		self.count += 1
		local x = self.lightmapRegionCurX
		local y = self.lightmapRegionCurY
		self.lightmapRegionCurX += w
		if self.lightmapRegionCurX >= self.lightmapWidthInSubRegions then
			self.lightmapRegionCurX = 0
			self.lightmapRegionCurY += h
		end
		return lightAddr,
			x * self.lightSubSize,
			y * self.lightSubSize,
			w * self.lightSubSize,
			h * self.lightSubSize
	end

	-- for now, one giant map
	-- TODO eventually make it use a bunch of 128x128 blocks like point lights below do
	-- for now this will overwrite any dir lights (or vice versa)
	Lights.makeSunLight = |:,stagesize|do
		local lightAddr, lx, ly, lw, lh = Lights:new(self.lightmapWidthInSubRegions, self.lightmapHeightInSubRegions)

		-- TODO using mat for our light math causes tri buf flushes and mat dirty bit flags ... meh?
		matpush(projMatrixIndex)
		matpush(viewMatrixIndex)	-- push the view mat

		matident(projMatrixIndex)
		local orthoSize = .5 * stagesize:len()	-- max diagonal
		local znear, zfar = -4, 2 * orthoSize
		matortho(-orthoSize, orthoSize, -orthoSize, orthoSize, znear, zfar)	-- projMatrixIndex by default

		matident(viewMatrixIndex)
		-- negative rotation because inverse for view transform
		-- angle starts looking down i.e. towards z- (cuz opengl)
		-- tilting up 45 degrees means its still tilted at a pitch down of 45 degrees.
		matrot(-math.rad(45), 1, 0, 0, viewMatrixIndex)	-- initial view angle is straight down ...
		-- cam starts looking along y+ so 45 to the right
		matrot(-math.rad(-45), 0, 0, 1, viewMatrixIndex)
		local fwdx = -peekf(ramaddr'viewMat' + 2*4)	 -- -.5
		local fwdy = -peekf(ramaddr'viewMat' + 6*4)	-- .5
		local fwdz = -peekf(ramaddr'viewMat' + 10*4)	-- -math.sqrt(2)
		-- position the light a way from the center.
		-- ortho can do +- z ranges, but the light calcs still look at light view mat pos
		-- a TODO could be using a lightpos vec4 instead of calculating it from the light view matrix
		-- this would provide better directional lights (set w=0)
		--  but would mean more redundant variables for the cart programmer to correlate.
		mattrans(
			-(.5 * stagesize.x - orthoSize * fwdx),
			-(.5 * stagesize.y - orthoSize * fwdy),
			-(.5 * stagesize.z - orthoSize * fwdz),
			viewMatrixIndex)

		poke(lightAddr + self.lightEnabledOffset, 0xff)	-- light is enabled for depth-write and for surface-calculations

		memcpy(lightAddr + self.lightViewMatOffset, ramaddr'viewMat', 64)	-- matrix #1
		memcpy(lightAddr + self.lightProjMatOffset, ramaddr'projMat', 64)	-- matrix #2

		matpop(viewMatrixIndex)
		matpop(projMatrixIndex)

		-- is per-light ambient color dumb?
		pokef(lightAddr + self.lightAmbientColorOffset, 0)
		pokef(lightAddr + self.lightAmbientColorOffset+4, 0)
		pokef(lightAddr + self.lightAmbientColorOffset+8, 0)
		pokef(lightAddr + self.lightDiffuseColorOffset, 1)
		pokef(lightAddr + self.lightDiffuseColorOffset+4, 1)
		pokef(lightAddr + self.lightDiffuseColorOffset+8, 1)
		pokef(lightAddr + self.lightSpecularColorOffset, .3)
		pokef(lightAddr + self.lightSpecularColorOffset+4, .2)
		pokef(lightAddr + self.lightSpecularColorOffset+8, .1)
		pokef(lightAddr + self.lightSpecularColorOffset+12, 30)
		pokef(lightAddr + self.lightDistAttenOffset, 1)	-- constant / global attenuation
		pokef(lightAddr + self.lightDistAttenOffset+4, 0)
		pokef(lightAddr + self.lightDistAttenOffset+8, 0)
		pokef(lightAddr + self.lightCosAngleRangeOffset, -2)	-- set cos angle range to [-2,-1] so all values map to 1
		pokef(lightAddr + self.lightCosAngleRangeOffset+4, -1)

		-- subimage/viewport on the lightmap
		pokew(lightAddr + self.lightRegionOffset, lx)
		pokew(lightAddr + self.lightRegionOffset+2, ly)
		pokew(lightAddr + self.lightRegionOffset+4, lw)
		pokew(lightAddr + self.lightRegionOffset+6, lh)
	end


	-- static, singleton, class for object
	local MakeLight = class()
	Lights.MakeLight = MakeLight
	MakeLight.znear = .01
	MakeLight.zfar = 10
	MakeLight.ambient = vec3(.4, .3, .2)
	MakeLight.diffuse = vec3(1, 1, 1)
	MakeLight.specular = vec3(.6, .5, .4)
	MakeLight.shininess = 30
	MakeLight.distAtten = vec3(.7, 0, .01)	-- quadratic attenuation
	MakeLight.cosAngleRange = vec2(-2, -1)		-- don't set equal so we don't get divide-by-zero
	MakeLight.tanHalfFOV = 1 -- math.tan(math.rad(.5 * 90))	-- used for 90 degrees
	MakeLight.go = |:, x,y,z| do
		local znear, zfar, tanHalfFOV = self.znear, self.zfar, self.tanHalfFOV
		matpush(projMatrixIndex)	-- push proj mat
		matpush(viewMatrixIndex)	-- push view mat
		-- set up a torch point light at the player
		-- TODO lightmap block allocation system ...
		for lightIndex=0,self.numSides-1 do
			local lightAddr, lx, ly, lw, lh = Lights:new()
			-- TODO using mat for our light math causes tri buf flushes and mat dirty bit flags ... meh?

			poke(lightAddr + Lights.lightEnabledOffset, 0xff)
			-- subimage/viewport on the lightmap
			pokew(lightAddr + Lights.lightRegionOffset, lx)
			pokew(lightAddr + Lights.lightRegionOffset+2, ly)
			pokew(lightAddr + Lights.lightRegionOffset+4, lw)
			pokew(lightAddr + Lights.lightRegionOffset+6, lh)

			matident(projMatrixIndex)
			matfrustum(
				-tanHalfFOV * znear,
				tanHalfFOV * znear,
				-tanHalfFOV * znear,
				tanHalfFOV * znear,
				znear,
				zfar)	-- matfrustum sets projMatrixIndex by default

			matident(viewMatrixIndex)
			self:sideTransform(lightIndex)
			mattrans(-x, -y, -z, viewMatrixIndex)

			memcpy(lightAddr + Lights.lightViewMatOffset, ramaddr'viewMat', 64)	-- matrix #1
			memcpy(lightAddr + Lights.lightProjMatOffset, ramaddr'projMat', 64)	-- matrix #2

			pokef(lightAddr + Lights.lightAmbientColorOffset, self.ambient.x)
			pokef(lightAddr + Lights.lightAmbientColorOffset+4, self.ambient.y)
			pokef(lightAddr + Lights.lightAmbientColorOffset+8, self.ambient.z)
			pokef(lightAddr + Lights.lightDiffuseColorOffset, self.diffuse.x)
			pokef(lightAddr + Lights.lightDiffuseColorOffset+4, self.diffuse.y)
			pokef(lightAddr + Lights.lightDiffuseColorOffset+8, self.diffuse.z)
			pokef(lightAddr + Lights.lightSpecularColorOffset, self.specular.x)
			pokef(lightAddr + Lights.lightSpecularColorOffset+4, self.specular.y)
			pokef(lightAddr + Lights.lightSpecularColorOffset+8, self.specular.z)
			pokef(lightAddr + Lights.lightSpecularColorOffset+12, self.shininess)
			pokef(lightAddr + Lights.lightDistAttenOffset, self.distAtten.x)
			pokef(lightAddr + Lights.lightDistAttenOffset+4, self.distAtten.y)
			pokef(lightAddr + Lights.lightDistAttenOffset+8, self.distAtten.z)
			pokef(lightAddr + Lights.lightCosAngleRangeOffset, self.cosAngleRange.x)
			pokef(lightAddr + Lights.lightCosAngleRangeOffset+4, self.cosAngleRange.y)
		end
		matpop(viewMatrixIndex)	-- pop view mat
		matpop(projMatrixIndex)	-- pop proj mat
	end

	-- cube point light
	local MakePointCubeLight = MakeLight:subclass()
	Lights.MakePointCubeLight = MakePointCubeLight
	MakePointCubeLight.numSides = 6
	MakePointCubeLight.sideTransform = |:, lightIndex| do
		if lightIndex < 4 then
			matrot(-math.rad(90), 1, 0, 0, viewMatrixIndex)	-- initial view angle is straight down ...
			matrot(-math.rad(lightIndex * 90), 0, 0, 1, viewMatrixIndex)
		elseif lightIndex == 4 then	-- down
			-- init dir is down
		elseif lightIndex == 5 then	-- up
			matrot(-math.rad(180), 1, 0, 0, viewMatrixIndex)
		end
	end
	Lights.makePointLight = |...|do
		MakePointCubeLight:go(...)
	end


	-- point light but with 4 sides
	-- this has overlap, but I could batch light depth test calcs and skip on testing redundant lights (i.e. 1 in 6 of a cube light, or 1 in 4 of a tetrad light)
	local MakePointTetrahedronLight = MakeLight:subclass()
	Lights.MakePointTetrahedronLight = MakePointTetrahedronLight
	MakePointTetrahedronLight.numSides = 4
	--MakePointTetrahedronLight.tanHalfFOV = math.tan(.5 * math.acos(-1/3))	-- -1/3 is the dot product of normalized tetrahedron vertices ... still just gives me sqrt(2)
	MakePointTetrahedronLight.tanHalfFOV = 3	-- oops but that wasnt enough so I just set it to 3
	MakePointTetrahedronLight.sideTransform = |:, lightIndex| do
		if lightIndex == 3 then
			-- identity
		else	-- 0-2, rotate down acos(-1/3) = 1.910633236249 radians, then rotate around by 120 each
			matrot(-math.rad(109), 1, 0, 0, viewMatrixIndex)	-- rotate up by 109 degrees
			matrot(-math.rad(lightIndex * 120), 0, 0, 1, viewMatrixIndex)	-- rotate around by 120 degrees
		end
	end
	Lights.makePointLightTetrahedron = |...| do
		MakePointTetrahedronLight:go(...)
	end



	-- TODO spotlight angle attenuation (min/max angle)
	local MakeSpotLight = class()
	Lights.MakeSpotLight = MakeSpotLight
	MakeSpotLight.ambient = vec3(.4, .3, .2)
	MakeSpotLight.diffuse = vec3(1, 1, 1)
	MakeSpotLight.specular = vec3(.6, .5, .4)
	MakeSpotLight.shininess = 30
	-- [[ quadratic distance attenuation
	MakeSpotLight.distAtten = vec3(.7, 0, .1)
	--]]
	--[[ no distance attenuation
	MakeSpotLight.distAtten = vec3(1, 0, 0)
	--]]
	MakeSpotLight.go = |:, x,y,z, yawAngle, pitchAngle, spotOuterAngle, spotInnerAngle|do
		-- set up a torch point light at the player
		-- TODO lightmap block allocation system ...
		local lightAddr, lx, ly, lw, lh = Lights:new()

		-- TODO using mat for our light math causes tri buf flushes and mat dirty bit flags ... meh?
		matpush(projMatrixIndex)
		matpush(viewMatrixIndex)	-- push the view mat

		matident(projMatrixIndex)
		local tanHalfFOV = math.tan(math.rad(spotOuterAngle))
		local znear, zfar = .01, 10	-- light znear/zfar
		matfrustum(
			-tanHalfFOV * znear,
			tanHalfFOV * znear,
			-tanHalfFOV * znear,
			tanHalfFOV * znear,
			znear, zfar)	-- projMatrixIndex by default

		matident(viewMatrixIndex)
		matrot(-math.rad(90 + pitchAngle), 1, 0, 0, viewMatrixIndex)	-- initial view angle is straight down ...
		matrot(-math.rad(yawAngle), 0, 0, 1, viewMatrixIndex)

		mattrans(-x, -y, -z, viewMatrixIndex)

		poke(lightAddr + Lights.lightEnabledOffset, 0xff)		-- light is enabled for depth-write and for surface-calculations

		memcpy(lightAddr + Lights.lightViewMatOffset, ramaddr'viewMat', 64)	-- matrix #1
		memcpy(lightAddr + Lights.lightProjMatOffset, ramaddr'projMat', 64)	-- matrix #2

		matpop(viewMatrixIndex)
		matpop(projMatrixIndex)

		pokef(lightAddr + Lights.lightAmbientColorOffset, self.ambient.x)
		pokef(lightAddr + Lights.lightAmbientColorOffset+4, self.ambient.y)
		pokef(lightAddr + Lights.lightAmbientColorOffset+8, self.ambient.z)
		pokef(lightAddr + Lights.lightDiffuseColorOffset, self.diffuse.x)
		pokef(lightAddr + Lights.lightDiffuseColorOffset+4, self.diffuse.y)
		pokef(lightAddr + Lights.lightDiffuseColorOffset+8, self.diffuse.z)
		pokef(lightAddr + Lights.lightSpecularColorOffset, self.specular.x)
		pokef(lightAddr + Lights.lightSpecularColorOffset+4, self.specular.y)
		pokef(lightAddr + Lights.lightSpecularColorOffset+8, self.specular.z)
		pokef(lightAddr + Lights.lightSpecularColorOffset+12, self.shininess)
		pokef(lightAddr + Lights.lightDistAttenOffset, self.distAtten.x)
		pokef(lightAddr + Lights.lightDistAttenOffset+4, self.distAtten.y)
		pokef(lightAddr + Lights.lightDistAttenOffset+8, self.distAtten.z)
		pokef(lightAddr + Lights.lightCosAngleRangeOffset, math.cos(math.rad(spotOuterAngle)))
		pokef(lightAddr + Lights.lightCosAngleRangeOffset+4, math.cos(math.rad(spotInnerAngle)))

		-- subimage/viewport on the lightmap
		pokew(lightAddr + Lights.lightRegionOffset, lx)
		pokew(lightAddr + Lights.lightRegionOffset+2, ly)
		pokew(lightAddr + Lights.lightRegionOffset+4, lw)
		pokew(lightAddr + Lights.lightRegionOffset+6, lh)
	end
	Lights.makeSpotLight = |...| MakeSpotLight:go(...)

	Lights.beginFrame = |:|do
		-- reset light counters
		self.count = 0
		Lights.lightmapRegionCurX = 0
		Lights.lightmapRegionCurY = 0
	end

	Lights.endFrame = |:|do
		pokew(self.numLightsAddr, self.count)
	end
end

----------------------- END numo9/lights.lua  -----------------------
----------------------- BEGIN numo9/screen.lua-----------------------
getScreenSize=|| (tonumber(peekw(ramaddr'screenWidth')), tonumber(peekw(ramaddr'screenHeight')))

getAspectRatio=||do
	local w, h = getScreenSize()
	return w / h
end

----------------------- END numo9/screen.lua  -----------------------

mode(0xff)	-- NativexRGB565
--mode(0)		-- 256x256xRGB565
--mode(43)	-- 480x270xRGB332
--mode(18)	-- 336x189xRGB565
HD2DFlags = 0xff

-- this is post-projection transform so good luck with that
pokef(ramaddr'dofFocalDist', 10)
pokef(ramaddr'dofFocalRange', 2)
pokef(ramaddr'dofAperature', .3)	-- how much to multiply depth-dist to get blur amount
pokef(ramaddr'dofBlurMax', 10)


local player
local playerCoins = 0

local voxelTypeEmpty = 0xffffffff
local voxelTypeBricks = 0x42
local voxelTypeQuestionHit= 0x48
local voxelTypeQuestionCoin = 0x44
local voxelTypeQuestionMushroom = 0x84
local voxelTypeQuestionVine = 0xc4
local voxelTypeGoomba = 0x50000940
local voxelTypeBeetle = 0x50000980

local dt = 1/60
local epsilon = 1e-7
local grav = -dt
local maxFallVel = -.8

local view = {
	-- 0 degrees = y+ is forward, x+ is right
	yaw = 90,
	destYaw = 90,
	tiltUpAngle = -20,
	followDist = 7,
	pos = vec3(),
}
view.update = |:, width, height, player|do
	-- setup proj matrix
	matident(2)
	local ar = width / height
	local zn, zf = .01, 100
	matfrustum(-zn * ar, zn * ar, -zn, zn, zn, zf)	-- projection

	-- setup view matrix
	matident(1)
	local deltaAngle = self.destYaw - self.yaw
	if math.abs(deltaAngle) > 1 then
		self.yaw += .1 * deltaAngle
	else
		self.destYaw %= 360
		self.yaw = self.destYaw
	end

	local viewPitchRad = math.rad(90 + self.tiltUpAngle)	-- 90 = up to horizon
	local cosPitch = math.cos(viewPitchRad)
	local sinPitch = math.sin(viewPitchRad)
	matrotcs(cosPitch, sinPitch, -1, 0, 0, 1)	-- view pitch = inverse-rotate x-axis
	local viewYawRad = math.rad(self.yaw - 90)
	self.cosYaw = math.cos(viewYawRad)
	self.sinYaw = math.sin(viewYawRad)
	matrotcs(self.cosYaw, self.sinYaw, 0, 0, -1, 1)	-- view yaw = inverse-rotate negative-z-axis
	self.pos.x = player.pos.x - self.followDist * sinPitch * -self.sinYaw
	self.pos.y = player.pos.y - self.followDist * sinPitch * self.cosYaw
	self.pos.z = player.pos.z + self.followDist * cosPitch
	mattrans(-self.pos.x, -self.pos.y, -self.pos.z, 1)	-- view = inverse-translate

	matident()
end

local bounceZVel = 0

local objs = table()

local Object = class()
Object.size = vec3(.5, .5, .5)
Object.walking = false
Object.angle = 0
Object.jumpTime = -1
Object.onground = true
Object.walkSpeed = 7
Object.init = |:, args| do
	objs:insert(self)
	self.pos = vec3(args.pos)
	self.vel = vec3(args.vel)
end
Object.draw = |:|do
	matpush()
	mattrans(self.pos:unpack())
	drawvoxel(self.voxelCode)
	matpop()
end
Object.update = |:|do
	-- TODO what about falling vs walking?
	self.walking = self.vel.x ~= 0 or self.vel.y ~= 0

	local newX = self.pos.x + self.vel.x * dt
	local newY = self.pos.y + self.vel.y * dt
	local newZ = self.pos.z	-- don't test jumping/falling yet...

	if self.walking then
		local stepHeight = .25 + epsilon
		local hitXY, hitZ
		local inewZ = math.floor(newZ)
		for testZ=inewZ-1,inewZ+1 do
			if vget(voxelBlob, newX, newY, testZ) ~= voxelTypeEmpty then
				local z = testZ + 1 + epsilon
				if newZ > z then
				elseif newZ > z - stepHeight then
					newZ = z
					hitZ = true
				else
					hitXY = true
				end
			end
		end
		if hitXY then
			-- dont move in xy direction
		elseif hitZ then
			self.pos:set(newX, newY, newZ)
		else
			self.pos:set(newX, newY, newZ)
		end
		self.onground = false
	end
	if self.jumpTime then
		local jumpDuration = .2
		local jumpVel = .24
		if time() < self.jumpTime + jumpDuration and btn'b' then
			self.onground = false
			self.vel.z = jumpVel
		else
			self.jumpTime = nil
		end
	end

	if not self.onground then
		if self.vel.z > maxFallVel then
			self.vel.z = math.max(maxFallVel, self.vel.z + grav)
		end
		self.pos.z += self.vel.z
		if self.pos.z < 0 then
			self.pos.z = 0
			self.vel.z = 0
			self.onground = true
		else
			local inewZ = math.floor(self.pos.z)
			for testZ = inewZ-1, inewZ+1 do
				local voxelType = vget(voxelBlob, self.pos.x, self.pos.y, testZ)
				if voxelType ~= voxelTypeEmpty then
					if testZ > self.pos.z and self.vel.z > 0 then	-- test bottom of blocks for hitting underneath
						local z = testZ - epsilon
						if self.vel.z > 0
						and self.pos.z + 1 > z -- self.size.z > z
						then
							self.pos.z = z - epsilon - 1 --  - self.size.z
							self.vel.z = -epsilon
							self.jumpTime = nil
							-- hit block
							local voxelInfo = voxelInfos[voxelType]
							if voxelInfo then
								voxelInfo:hitUnder(self.pos.x, self.pos.y, testZ)
							end
						end
					else	-- test top of blocks for falling on
						local z = testZ + 1 + epsilon
						if self.vel.z < 0
						and self.pos.z < z
						then
							self.pos.z = z
							self.vel.z = 0
							self.jumpTime = nil
							self.onground = true
						end
					end
				end
			end
		end
	end

	for _,obj in ipairs(objs) do
		if obj ~= self then
			if math.abs(self.pos.x - obj.pos.x) < self.size.x + obj.size.x
			and math.abs(self.pos.y - obj.pos.y) < self.size.y + obj.size.y
			and math.abs(self.pos.z - obj.pos.z) < self.size.z + obj.size.z
			then
				if self.pos.z > obj.pos.z + obj.size.z
				and self.vel.z - obj.vel.z < 0
				then
					-- landed on its head
					obj?:jumpedOn(self)
				elseif math.abs(self.pos.z - obj.pos.z) < self.size.z + obj.size.z
				then
					-- hit its side
					obj?:hitSide(self)
				end
			end
		end
	end
end

local Beetle = Object:subclass()
Beetle.chaseDist = 5
Beetle.walkSpeed = 2
Beetle.draw = |:, ...| do
	if not self.leaveShellTime then
		self.voxelCode = voxelTypeBeetle + ((math.floor(time() * 5) & 1) << 1)
	end
	Beetle.super.draw(self, ...)
end
Beetle.update = |:, ...| do
	if self.kicked then
		Beetle.super.update(self, ...)
		return
	end
	if self.leaveShellTime then
		if time() > self.leaveShellTime then
			self.leaveShellTime = nil
			self.voxelCode = voxelTypeBeetle
		end
		return
	end
	if player then
		local delta = player.pos - self.pos
		if vec3_lenSq(delta:unpack()) < self.chaseDist*self.chaseDist  then
			vec2.set(self.vel, vec2_scale(self.walkSpeed, vec2_unit(delta.x, delta.y)))
			self.vel.z = 0
		end
	end
	Beetle.super.update(self, ...)
end
Beetle.jumpedOn = |:,other| do
	if not Player:isa(other) then return end
	
	if self.voxelCode == voxelTypeBeetle + 4 then
		-- jumped on while in shell ...
		if not self.kicked then
			self.kicked = true
			local kickSpeed = 10
			local delta = player.pos - self.pos
			vec2.set(self.vel, vec2_scale(kickSpeed, vec2_unit(delta:unpack())))
			self.vel.z = 0
		else
			self.kicked = false
		end
	else
		-- walking around ...
		self.voxelCode = voxelTypeBeetle + 4
		self.leaveShellTime = time() + 5
		other.jumpTime = time()
		other.vel.z = bounceZVel
	end
end
Beetle.hitSide = |:,other|do
	if self.voxelCode == voxelTypeBeetle + 4 then
		if self.kicked then
			-- hit by a kicked shell ... other takes damage
		else
			-- hit by a stationary shell ... kick it
			self.kicked = true
		end
	else
		-- not in shell? other takes damage
	end
end

local Goomba = Object:subclass()
Goomba.chaseDist = 5
Goomba.walkSpeed = 2
Goomba.draw = |:, ...| do
	if not self.squashedTime then
		self.voxelCode = voxelTypeGoomba + ((math.floor(time() * 5) & 1) << 1)
	end
	Goomba.super.draw(self, ...)
end
Goomba.update = |:, ...| do
	if self.squashedTime then
		if time() > self.squashedTime then
			self.remove = true
		end
		return
	end
	if player then
		local delta = player.pos - self.pos
		if vec3_lenSq(delta:unpack()) < self.chaseDist*self.chaseDist  then
			vec2.set(self.vel, vec2_scale(self.walkSpeed, vec2_unit(delta.x, delta.y)))
			self.vel.z = 0
		end
	end
	Goomba.super.update(self, ...)
end
Goomba.jumpedOn = |:, other| do
	if self.squashedTime then return end
	if not Player:isa(other) then return end
	self.voxelCode = voxelTypeGoomba + 4
	self.squashedTime = time() + 1
	self.voxelCode = voxelTypeGoomba + 4
	other.jumpTime = time()
	other.vel.z = bounceZVel
end

Player = Object:subclass()
Player.draw = |:|do
	matpush()
	mattrans(self.pos:unpack())
	matrotcs(view.cosYaw, view.sinYaw, 0, 0, 1)
	matrotcs(0, 1, 1, 0, 0)
	matscale(1/16, -1/16, 1/16)
	local sprIndex
	if not self.onground and self.vel.z > 0 then
		sprIndex = 10
	elseif self.walking then
		sprIndex = math.floor(time() * 7) & 3
		if sprIndex == 3 then sprIndex = 1 end
		sprIndex <<= 1
		sprIndex += 2
	else
		sprIndex = 2
	end
	local hflip = (self.angle - (view.yaw + 45)) % 360 < 180 and 1 or 0
	spr(sprIndex, -8, -16, 2, 2, hflip)
	matpop()
end
Player.update = |:, ...|do

	self.vel.x = 0
	self.vel.y = 0
	-- hold y + dir to rotate camera
	if btn'x' then
		if btnp'left' then
			view.destYaw += 90
		elseif btnp'right' then
			view.destYaw -= 90
		end
	else
		local speed = btn'y' and self.walkSpeed * 1.5 or self.walkSpeed
		if btn'up' then
			self.vel.x += -view.sinYaw * speed
			self.vel.y += view.cosYaw * speed
			self.angle = view.yaw + 90
			self.angle %= 360
		end
		if btn'down' then
			self.vel.x -= -view.sinYaw * speed
			self.vel.y -= view.cosYaw * speed
			self.angle = view.yaw - 90
			self.angle %= 360
		end
		if btn'left' then
			self.vel.x -= view.cosYaw * speed
			self.vel.y -= view.sinYaw * speed
			self.angle = view.yaw + 180
			self.angle %= 360
		end
		if btn'right' then
			self.vel.x += view.cosYaw * speed
			self.vel.y += view.sinYaw * speed
			self.angle = view.yaw
		end
	end

	-- test jump here before walking because walking clears onground flag for the sake of testing falling off ledges
	if self.onground and btnp'b' then
		self.jumpTime = time()
	end

	Player.super.update(self, ...)
end


voxelInfos = {
	[voxelTypeBricks] = {
		hitUnder = |:, x,y,z|do
			-- TODO particles
			vset(0, x, y, z, voxelTypeEmpty)
		end,
	},
	[voxelTypeQuestionCoin] = {
		hitUnder = |:, x,y,z|do
			vset(0, x, y, z, voxelTypeQuestionHit)
			playerCoins += 1
		end,
	},
	[voxelTypeQuestionMushroom] = {
		hitUnder = |:, x,y,z|do
			vset(0, x, y, z, voxelTypeQuestionHit)
			-- TODO give mushroom
		end,
	},
	[voxelTypeQuestionVine] = {
		hitUnder = |:, x,y,z|do
			vset(0, x, y, z, voxelTypeQuestionHit)
			-- TODO give something else idk
		end,
	},
	[voxelTypeGoomba] = {
		spawn = |:, pos|do
			Goomba{
				pos=pos,
			}
		end,
	},
	[voxelTypeBeetle] = {
		spawn = |:, pos|do
			Beetle{
				pos=pos,
			}
		end,
	},
}

player = Player{
	pos = vec3(2.5, 2.5, 1),
}

-- init stage:
local voxelBlob = 0
local voxelmapAddr = blobaddr('voxelmap', voxelBlob)
local voxelmapSizeX = peekl(voxelmapAddr)
local voxelmapSizeY = peekl(voxelmapAddr + 4)
local voxelmapSizeZ = peekl(voxelmapAddr + 8)
for z=0,voxelmapSizeZ-1 do
	for y=0,voxelmapSizeY-1 do
		for x=0,voxelmapSizeX-1 do
			local voxelInfo = voxelInfos[vget(voxelBlob, x, y, z)]
			if voxelInfo and voxelInfo.spawn then
				voxelInfo:spawn(vec3(x,y,z))
				vset(voxelBlob, x,y,z,voxelTypeEmpty)
			end
		end
	end
end


-- sizes of our UI overlay wrt text
local textwidth = 32 * 8
local textheight = textwidth

update=||do
	poke(ramaddr'HD2DFlags', 0)
	cls(33)

	-- draw skyl
	-- assume we are still in ortho matrix setup from the end of last frame
	local width, height = getScreenSize()
	spr(
		1024,							-- spriteIndex
		0, 0, 							-- screenX, screenY
		32, 32,							-- tilesWide, tilesHigh
		0,								-- orientation2D
		textwidth/256, textheight/256	-- scaleX, scaleY
	)
	
	-- you gotta set HD2DFlags with lighting first
	-- before clearing the depth buffer next....
	poke(ramaddr'HD2DFlags', HD2DFlags)	

	-- clear depth.
	-- make sure lighting flags are set.
	cls(nil, true)

	view:update(width, height, player)

	voxelmap()

	for _,obj in ipairs(objs) do
		obj:update()
		obj:draw()
	end
	for i=#objs,1,-1 do
		if objs[i].remove then objs:remove(i) end
	end

-- [[ use default for now.
	pokew(ramaddr'numLights', 1)
--]]
--[[
	Lights.MakeLight.znear = 1
	Lights.MakeLight.zfar = 100
	Lights.MakeLight.diffuse:set(2,2,2)
	Lights.MakeLight.specular:set(2,2,2)
	Lights.MakeLight.shininess = 1
	Lights.MakeLight.distAtten:set(1,0,0)
	Lights:beginFrame()
	-- now come this is only shining down?  where are my 6 transform sides?
	Lights.makePointLight(view.pos:unpack())
	Lights:endFrame()
--]]

	-- end-of-frame, after view has been captured, do ortho and draw text
	-- but disable light flags before clearing depth or else it'll clear the light depth too
	poke(ramaddr'HD2DFlags', 0)

	cls(nil, true)
	-- [[
	--poke(ramaddr'HD2DFlags', 2)	-- if you want the gui text to cast a shadow...
	textheight = textwidth * height / width
	matident(0)
	matident(1)
	matident(2)
	matortho(0, textwidth, textheight, 0)
	text(tostring('Cx '..playerCoins), 0, 0, 220, 219)
	--]]

	--poke(ramaddr'HD2DFlags', 0)		-- set neither
	--poke(ramaddr'HD2DFlags', 0x80)	-- set DoF
	--poke(ramaddr'HD2DFlags', 0x40)		-- set HDR
	--poke(ramaddr'HD2DFlags', 0xC0)	-- set HDR and DoF
	poke(ramaddr'HD2DFlags', HD2DFlags)
end
