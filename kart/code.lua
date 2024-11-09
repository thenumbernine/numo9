--[[
TODO
- ... multi "bank" rendering ... hmm
	and how to do that with 64 players at once ...
	it's easy with just 4players ...
- also add sounds
- track nodes are a bit off with the finish line
- multiplayer needs to track foreign conns and place clientViewObjs in their local screens accordingly
- rendering needs to move to draw()

How did SMK do it?
one character uses ...
12 frames x distances 1-3 x 32x32 = 576 tiles
8 frames x distances 4-5 x 24x24 = 144 tiles ... total 720
4 frames x distances 6-8 x 16x16 = 48 tiles  ... total 768
3 frames x distance 9 x 8x16 = 6 tiles       ... total 774
2 frames x distance 10-11 x 8x8 = 4 tiles    ... total 778
{lookback1 lookback2 turn cry cheer} x 32x32 = 80 tiles ... total 858
and i'll ignore the flat and cheer sprites ...
... a single 256x256 sheet has 1024 tiles ... it's close to one sheet per character.

sprites from https://www.spriters-resource.com/submitter/NICKtendoDS/
--]]

local palAddr = ffi.offsetof('RAM', 'bank') + ffi.offsetof('ROM', 'palette')
local matAddr = ffi.offsetof('RAM', 'mvMat')
assert.eq(ffi.sizeof(ffi.cast('RAM*',0).mvMat), 16*4, "expected mvmat to be 32bit")	-- need to assert this for my peek/poke push/pop. need to peek/poke vs writing to app.ram directly so it is net-reflected.

local windowWidth, windowHeight = 256, 256

math.randomseed(tstamp())

local colors = {
	black = 0x00,
	white = 0x70,
	clear = 0xff,
}

local sprites = {
	ralph = {16, 8, 8},
	ItemBox = {24, 4, 4},
	colorcloud = {28, 4, 4},
	banana = {272, 2, 2},
	cloudkill = {274, 2, 2},
	colorspray = {276, 2, 2},
	greenshell = {278, 2, 2},
	handtofoot = {280, 2, 2},
	mushroom = {282, 2, 2},
	redshell = {284, 2, 2},
	vandegraaf = {336, 2, 2},
	outline = {338, 2, 2},
}

-- kart sprites
-- divided into 180'.  flip the sprite to get the other 180'
local spriteIndexForAngle = {
	0, 4, 8, 12,
	128+0, 128+4, 128+8, 128+12,
	256+0, 256+4, 256+8, 256+12,
}

local palPush = {}
for i=0,255 do
	palPush[i] = peekw(palAddr+(i<<1))
end

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

--[[ not helping
-- also isn't netplay compat cuz it directly accesses app.ram
local projmat={}
local function applyprojmat()
	-- lhs mul the stored projmat
	-- matrices are stored in column-major

	local a0, a1, a2, a3, a4, a5, a6, a7, a8, a9, a10, a11, a12, a13, a14, a15 = projmat[1+0]/65536, projmat[1+1]/65536, projmat[1+2]/65536, projmat[1+3]/65536, projmat[1+4]/65536, projmat[1+5]/65536, projmat[1+6]/65536, projmat[1+7]/65536, projmat[1+8]/65536, projmat[1+9]/65536, projmat[1+10]/65536, projmat[1+11]/65536, projmat[1+12]/65536, projmat[1+13]/65536, projmat[1+14]/65536, projmat[1+15]/65536
	local b0, b1, b2, b3, b4, b5, b6, b7, b8, b9, b10, b11, b12, b13, b14, b15 = ram.mvMat[0]/65536, ram.mvMat[1]/65536, ram.mvMat[2]/65536, ram.mvMat[3]/65536, ram.mvMat[4]/65536, ram.mvMat[5]/65536, ram.mvMat[6]/65536, ram.mvMat[7]/65536, ram.mvMat[8]/65536, ram.mvMat[9]/65536, ram.mvMat[10]/65536, ram.mvMat[11]/65536, ram.mvMat[12]/65536, ram.mvMat[13]/65536, ram.mvMat[14]/65536, ram.mvMat[15]/65536
	ram.mvMat[0]		=65536*(a0  * b0  + a4  * b1  + a8  * b2  + a12 * b3)
	ram.mvMat[4]		=65536*(a0  * b4  + a4  * b5  + a8  * b6  + a12 * b7)
	ram.mvMat[8]		=65536*(a0  * b8  + a4  * b9  + a8  * b10 + a12 * b11)
	ram.mvMat[12]		=65536*(a0  * b12 + a4  * b13 + a8  * b14 + a12 * b15)
	ram.mvMat[1]		=65536*(a1  * b0  + a5  * b1  + a9  * b2  + a13 * b3)
	ram.mvMat[5]		=65536*(a1  * b4  + a5  * b5  + a9  * b6  + a13 * b7)
	ram.mvMat[9]		=65536*(a1  * b8  + a5  * b9  + a9  * b10 + a13 * b11)
	ram.mvMat[13]		=65536*(a1  * b12 + a5  * b13 + a9  * b14 + a13 * b15)
	ram.mvMat[2]		=65536*(a2  * b0  + a6  * b1  + a10 * b2  + a14 * b3)
	ram.mvMat[6]		=65536*(a2  * b4  + a6  * b5  + a10 * b6  + a14 * b7)
	ram.mvMat[10]		=65536*(a2  * b8  + a6  * b9  + a10 * b10 + a14 * b11)
	ram.mvMat[14]		=65536*(a2  * b12 + a6  * b13 + a10 * b14 + a14 * b15)
	ram.mvMat[3]		=65536*(a3  * b0  + a7  * b1  + a11 * b2  + a15 * b3)
	ram.mvMat[7]		=65536*(a3  * b4  + a7  * b5  + a11 * b6  + a15 * b7)
	ram.mvMat[11]		=65536*(a3  * b8  + a7  * b9  + a11 * b10 + a15 * b11)
	ram.mvMat[15]		=65536*(a3  * b12 + a7  * b13 + a11 * b14 + a15 * b15)
end
--]]

new=[cl,...]do
	local o=setmetatable({},cl)
	o?:init(...)
	return o
end
isa=[cl,o]o.isaSet[cl]
classmeta = {__call=new}
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

local getvalue=[x, dim]do
	if type(x)=='number' then return x end
	if type(x)=='table' then
		x=x[dim]
		if type(x)~='number' then
			error("expected a table of numbers, got a table with index "..dim.." of "..type(x))
		end
		return x
	end
	error("tried to getvalue from an unknown type "..type(x))
end
vec2=class{
	dim=2,
	init=[v,x,y]do
		if x then
			v:set(x,y)
		else
			v:set(0,0)
		end
	end,
	set=[v,x,y]do
		if type(x) == 'table' then
			v[1] = x[1]
			v[2] = x[2]
		else
			v[1] = x
			if y then
				v[2] = y
			else
				v[2] = x
			end
		end
	end,
	unpack=[v](v[1],v[2]),
	product=[v]v[1]*v[2],
	map=[v,f]do
		v[1]=f(v[1],1)
		v[2]=f(v[2],2)
		return v
	end,
	dot=[a,b]a[1]*b[1]+a[2]*b[2],
	lenSq=[v]vec2.dot(v,v),
	length=[v]math.sqrt(vec2.lenSq(v)),
	normalize=[v]v/vec2.length(v),
	__unm=[a]vec2(-a[1],-a[2]),
	__add=[a,b]vec2(getvalue(a,1)+getvalue(b,1),getvalue(a,2)+getvalue(b,2)),
	__sub=[a,b]vec2(getvalue(a,1)-getvalue(b,1),getvalue(a,2)-getvalue(b,2)),
	__mul=[a,b]vec2(getvalue(a,1)*getvalue(b,1),getvalue(a,2)*getvalue(b,2)),
	__div=[a,b]vec2(getvalue(a,1)/getvalue(b,1),getvalue(a,2)/getvalue(b,2)),
	__eq=[a,b]a[1]==b[1]and a[2]==b[2],
	__tostring=[v]table.concat(v,','),
	__concat=string.concat,
}

vec3=class{
	dim=3,
	init=[v,x,y,z]do
		if x then
			v:set(x,y,z)
		else
			v:set(0,0,0)
		end
	end,
	set=[v,x,y,z]do
		if type(x)=='table' then
			v[1]=x[1]
			v[2]=x[2]
			v[3]=x[3]
		else
			v[1]=x
			if y then
				v[2]=y
				if z then
					v[3]=z
				else
					v[3]=0
				end
			else
				v[2]=x
				v[3]=x
			end
		end
	end,
	unpack=[v](v[1],v[2],v[3]),
	product=[v]v[1]*v[2]*v[3],
	map=[v,f]do
		v[1]=f(v[1],1)
		v[2]=f(v[2],2)
		v[3]=f(v[3],3)
		return v
	end,
	dot=[a,b]a[1]*b[1]+a[2]*b[2]+a[3]*b[3],
	lenSq=[v]vec3.dot(v,v),
	length=[v]math.sqrt(vec3.lenSq(v)),
	normalize=[v]v/vec3.length(v),
	cross=[a,b]vec3(a[2]*b[3]-a[3]*b[2],a[3]*b[1]-a[1]*b[3],a[1]*b[2]-a[2]*b[1]),
	__unm=[a]vec2(-a[1],-a[2],-a[3]),
	__add=[a,b]vec3(getvalue(a,1)+getvalue(b,1),getvalue(a,2)+getvalue(b,2),getvalue(a,3)+getvalue(b,3)),
	__sub=[a,b]vec3(getvalue(a,1)-getvalue(b,1),getvalue(a,2)-getvalue(b,2),getvalue(a,3)-getvalue(b,3)),
	__mul=[a,b]vec3(getvalue(a,1)*getvalue(b,1),getvalue(a,2)*getvalue(b,2),getvalue(a,3)*getvalue(b,3)),
	__div=[a,b]vec3(getvalue(a,1)/getvalue(b,1),getvalue(a,2)/getvalue(b,2),getvalue(a,3)/getvalue(b,3)),
	__eq=[a,b]a[1]==b[1]and a[2]==b[2]and a[3]==b[3],
	__tostring=[v]table.concat(v,','),
	__concat=string.concat,
}

local function rot2d(v, costh, sinth, newv)
	if not newv then newv = vec3() end
	newv[1], newv[2], newv[3] = v[1] * costh - v[2] * sinth, v[1] * sinth + v[2] * costh, v[3]
	return newv
end

local tileIndexForName = {
	SmoothTile= 0,
	RoughTile = 1,
	SolidTile= 2,
	BoostTile = 3,
	item = 4,
	startback = 5,
	startfront = 6,
	StartingLineTile = 7,	-- visual only
}

-- lookup for class from tile index
local tileClassForIndex = {}


local game	-- TODO use pointers instead of global
local fixedDeltaTime = 1/50	-- for some reason setting this to 1/60 prevents you from starting unless you jump and turn while pushing gas ...
--local fixedDeltaTime = 1/60

local engineSound = 0	--AudioBuffer('sound/engine.wav')
local brakeSound = 0	--AudioBuffer('sound/brake.wav')
local boostSound = 0	--AudioBuffer('sound/explode.wav')
local shockSound = 0	--AudioBuffer('sound/shock.wav')
local castSpellSound = 0	--AudioBuffer('sound/castspell.wav')
local startBeep32Sound = 0	--AudioBuffer('sound/startbeep32.wav')	-- how about just a pitch change?
local startBeep1Sound = 0	--AudioBuffer('sound/startbeep1.wav')	-- how about just a pitch change?
local dizzySound = 0	--AudioBuffer('sound/dizzy.wav')
local trackAudioSource = 0	--AudioSource()

local bgMusic = 0	--AudioBuffer('sound/bgmusic.wav')
local bgAudioSource = 0	--AudioSource()
--bgAudioSource:setBuffer(bgMusic)
--bgAudioSource:setLooping(true)
--bgAudioSource:setGain(.5)
--bgAudioSource:play()

-- currently a linear ramp
local function getBlendInOut(x, h, min, max)
	if x < min then
		return 0
	elseif x < min + h then
		return (x - min) / h
	elseif x < max - h then
		return 1
	elseif x < max then
		return (max - x) / h
	end
	return 0
end

local function tileBounceVel(ix, iy, pos, vel, restitution, newvel)
	if not newvel then newvel = vec3() end
	if not restitution then restitution = .5 end
	-- and bounce ...
	local deltaX = pos[1] - (ix + .5)
	local deltaY = pos[2] - (iy + .5)
	local absDeltaX = math.abs(deltaX)
	local absDeltaY = math.abs(deltaY)
	local nx, ny, nz = 0, 0, 0
	if absDeltaX > absDeltaY then	-- E/W
		if deltaX > 0 then
			nx = 1
		else
			nx = -1
		end
	else	-- N/S
		if deltaX > 0 then
			ny = 1
		else
			ny = -1
		end
	end
	local vdotn = vel[1] * nx + vel[2] * ny + vel[3] * nz
	newvel[1] = vel[1] - nx * (1 + restitution) * vdotn
	newvel[2] = vel[2] - ny * (1 + restitution) * vdotn
	newvel[3] = vel[3] - nz * (1 + restitution) * vdotn
	return newvel
end


local Tile = class()
Tile.friction = .1
Tile.drag = 0

local SmoothTile = Tile:subclass()
tileClassForIndex[tileIndexForName.SmoothTile] = SmoothTile
tileClassForIndex[tileIndexForName.StartingLineTile] = SmoothTile

local RoughTile = Tile:subclass()
RoughTile.drag = .4
tileClassForIndex[tileIndexForName.RoughTile] = RoughTile

local SolidTile = Tile:subclass()
SolidTile.solid = true
SolidTile.friction = 0
tileClassForIndex[tileIndexForName.SolidTile] = SolidTile

local BoostTile = Tile:subclass()
BoostTile.friction = 0
BoostTile.boost = true
tileClassForIndex[tileIndexForName.BoostTile] = BoostTile


-- track collidable physical object
-- TODO put kart under this?

local Object = class()

Object.radius = .5
Object.spriteIndex = sprites.ItemBox

function Object:init(args)
	self.pos = vec3()
	if args.pos then self.pos:set(args.pos[1], args.pos[2], args.pos[3]) end
	game:addObject(self)
end

function Object:remove()
	self.removed = true
	game:removeObject(self)
end

Object.drawRadius = .5
Object.gravity = vec3(0,0,-22)		-- set to this value to 'fall' at the correct speed
Object.mass = 1

function Object:draw(viewMatrix)
	local viewFwd = viewMatrix[1]
	local viewRight = viewMatrix[2]
	local viewUp = viewMatrix[3]

	--[[
	local so = spriteSceneObj
	so.texs[1] = self.tex
	so.uniforms.viewFwd = viewFwd
	so.uniforms.viewRight = viewRight
	so.uniforms.viewUp = viewUp
	so.uniforms.pos = pos
	so.uniforms.drawRadius = drawRadius
	so.uniforms.uScaleAndBias = {1, 0}
	so.uniforms.billboardOffset = {0, 0}
	so.uniforms.mvProjMat = view.mvProjMat.ptr
	so:draw()
	--]]

	-- [[
	do
		-- TODO how to calculate this
local viewAngle = math.atan2(viewFwd[2], viewFwd[1])
		matpush()

--[=[ using world origin as view origin
		mattrans(self.pos[1], self.pos[2], self.pos[3])
--]=]
-- [=[ using 0,0,0 as view origin, and subtracting origin per-scene-object for rendering
		mattrans(self.pos[1] - currentCamPos[1], self.pos[2] - currentCamPos[2], self.pos[3] - currentCamPos[3])
--]=]
		matscale(1/16,1/16,1/16)

		-- undo camera viewAngle to make a billboard
		matrot(viewAngle + .5 * math.pi, 0, 0, 1)
		matrot(math.rad(-70), 1, 0, 0)
		local w, h = self.spriteIndex[2], self.spriteIndex[3]
		mattrans(-(w/2)*8, -(h/2)*8, 0)
--[=[ not helping
applyprojmat()
--]=]
		spr(self.spriteIndex[1], 0, 0, w, h)
		matpop()
	end
	--]]
end


local BananaObject = Object:subclass()

BananaObject.spriteIndex = sprites.banana
BananaObject.drawRadius = .3
BananaObject.radius = .3
BananaObject.spinsOutPlayerOnTouch = true
BananaObject.removesOnPlayerTouch = true

function BananaObject:init(args)
	BananaObject.super.init(self, args)
	self.vel = vec3()
	if args.throw then
		self.vel = args.vel + args.dir * 20 + vec3(0,0,7)
		self.pos = args.pos + args.dir
		self.pos[3] = self.pos[3] + 1
	else
		self.pos = args.pos - args.dir
	end
end

function BananaObject:update(dt)
	if self.vel then
		local z = 0
		if self.pos[3] < z then
			self.pos[3] = z
			self.vel = nil

			local ix, iy = math.floor(self.pos[1]), math.floor(self.pos[2])
			if ix >= 0 and iy >= 0 and ix < game.track.size[1] and iy < game.track.size[1] then
			else
				self:remove()
				return
			end
		else
			self.vel[1] = self.vel[1] + self.gravity[1] * dt
			self.vel[2] = self.vel[2] + self.gravity[2] * dt
			self.vel[3] = self.vel[3] + self.gravity[3] * dt
			self.pos[1] = self.pos[1] + self.vel[1] * dt
			self.pos[2] = self.pos[2] + self.vel[2] * dt
			self.pos[3] = self.pos[3] + self.vel[3] * dt
		end
	end
end


local GreenShellObject = Object:subclass()

GreenShellObject.spriteIndex = sprites.greenshell
GreenShellObject.initialSpeed = 20
GreenShellObject.spinsOutPlayerOnTouch = true
GreenShellObject.removesOnPlayerTouch = true

function GreenShellObject:init(args)
	GreenShellObject.super.init(self, args)
	if args.drop then
		self.pos = args.pos - args.dir
	else
		self.pos = args.pos + args.dir
		self.vel = args.vel + args.dir * self.initialSpeed
	end
	self.pos[3] = 0
end

function GreenShellObject:update(dt)
	if self.vel then
		local newposX = self.pos[1] + self.vel[1] * dt
		local newposY = self.pos[2] + self.vel[2] * dt
		local newposZ = self.pos[3] + self.vel[3] * dt

		local ix, iy = math.floor(newposX), math.floor(newposY)
		if ix >= 0 and iy >= 0 and ix < game.track.size[1] and iy < game.track.size[1] then
			local tileClass = tileClassForIndex[mget(ix,iy)]
			if tileClass.solid then
				newposX = self.pos[1]
				newposY = self.pos[2]
				newposZ = self.pos[3]
				tileBounceVel(ix, iy, self.pos, self.vel, nil, self.vel)
			end
			--newposZ = 0
		else
			self:remove()
			return
		end

		self.pos[1] = newposX
		self.pos[2] = newposY
		self.pos[3] = newposZ
	end
end


local Kart

local RedShellObject = Object:subclass()

RedShellObject.spriteIndex = sprites.redshell
RedShellObject.noSeekDuration = .5
RedShellObject.initialSpeed = 20
RedShellObject.spinsOutPlayerOnTouch = true
RedShellObject.removesOnPlayerTouch = true

function RedShellObject:init(args)
	RedShellObject.super.init(self, args)
	self.owner = args.owner
	self.vel = args.vel + args.dir * self.initialSpeed
	self.pos = args.pos + args.dir
	self.pos[3] = 0
	self.seekTime = game.time + self.noSeekDuration
end

function RedShellObject:update(dt)
	local newposX = self.pos[1] + self.vel[1] * dt
	local newposY = self.pos[2] + self.vel[2] * dt
	local newposZ = self.pos[3] + self.vel[3] * dt

	local ix, iy = math.floor(newposX), math.floor(newposY)
	if ix >= 0 and iy >= 0 and ix < game.track.size[1] and iy < game.track.size[1] then
		local tileClass = tileClassForIndex[mget(ix,iy)]
		if tileClass.solid then
			self:remove()
			return
		end
		newposZ = 0
	else
		self:remove()
		return
	end

	self.pos[1] = newposX
	self.pos[2] = newposY
	self.pos[3] = newposZ

	if self.seekTime > game.time then return end

	-- now SICK EM!

	if not self.seekObj then
		local bestPosDiff, bestDistSq, bestObj
		local karts = game.objsOfClass[Kart]
		for i=1,#karts do
			local obj = karts[i]
			if obj ~= self.owner then
				local posDiffX = obj.pos[1] - self.pos[1]
				local posDiffY = obj.pos[2] - self.pos[2]
				local posDiffZ = obj.pos[3] - self.pos[3]
				local distSq = posDiffX * posDiffX + posDiffY * posDiffY + posDiffZ * posDiffZ
				if not bestDistSq or distSq < bestDistSq then
					bestPosDiff = posDiff
					bestDistSq = distSq
					bestObj = obj
				end
			end
		end
		self.seekObj = bestObj
	end

	if self.seekObj then
		local posDiffX = self.seekObj.pos[1] - self.pos[1]
		local posDiffY = self.seekObj.pos[2] - self.pos[2]
		local posDiffZ = self.seekObj.pos[3] - self.pos[3]
		local posDiffLen = math.sqrt(posDiffX * posDiffX + posDiffY * posDiffY + posDiffZ * posDiffZ)
		local seekDirX = posDiffX / posDiffLen
		local seekDirY = posDiffY / posDiffLen
		local seekDirZ = posDiffZ / posDiffLen
		local coeff = .1
		local oldSpeed = self.vel:length()
		self.vel[1] = (self.vel[1] / oldSpeed) * (1 - coeff) + seekDirX * coeff
		self.vel[2] = (self.vel[2] / oldSpeed) * (1 - coeff) + seekDirY * coeff
		self.vel[3] = (self.vel[3] / oldSpeed) * (1 - coeff) + seekDirZ * coeff
		local newSpeed = self.vel:length()
		self.vel[1] = self.vel[1] / newSpeed * oldSpeed
		self.vel[2] = self.vel[2] / newSpeed * oldSpeed
		self.vel[3] = self.vel[3] / newSpeed * oldSpeed
	end
end


local VanDeGraaffObject = Object:subclass()

VanDeGraaffObject.duration = 1
VanDeGraaffObject.startTime = -10
VanDeGraaffObject.doneTime = -9

function VanDeGraaffObject:init(args)
	VanDeGraaffObject.super.init(self, args)

	self.startTime = game.time
	self.doneTime = self.startTime + self.duration

	local start = self.pos

	self.lineStrips = table()
	local function addLineStrip(destpos)
		local lineStrip = {}
		local numDivs = 64

		lineStrip[1] = vec3(start[1], start[2], start[3])
		lineStrip[numDivs] = vec3(destpos[1], destpos[2], destpos[3])

		local function subdiv(i1,i2)
			local imid = math.floor((i1+i2)*.5)
			if imid <= i1 or imid >= i2 then return end

			local posDiff = lineStrip[i2] - lineStrip[i1]
			local dist = posDiff:length() * .4

			lineStrip[imid] = lineStrip[i1] + posDiff * .5
				+ vec3((math.random() - .5) * dist, (math.random() - .5) * dist, (math.random() - .5) * dist)
			if lineStrip[imid][3] < start[3]+.1 then lineStrip[imid][3] = start[3]+.1 end

			subdiv(i1,imid)
			subdiv(imid,i2)
		end

		subdiv(1,numDivs)

		self.lineStrips:insert(lineStrip)
	end

	for i=1,#args.shockTargetPositions do
		local otherpos = args.shockTargetPositions[i]
		addLineStrip(otherpos)
	end
end

function VanDeGraaffObject:update(dt)
	if game.time >= self.doneTime then
		self:remove()
		return
	end
end

function VanDeGraaffObject:drawInit()
	blend(0)
end

function VanDeGraaffObject:draw()
	--local fade = (self.doneTime - game.time) / self.duration
	for _,lineStrip in ipairs(self.lineStrips) do
		for j=1,#lineStrip-1 do
			local v1 = lineStrip[j]
			local v2 = lineStrip[j+1]
			line3d(
				v1[1] - currentCamPos[1], v1[2] - currentCamPos[2], v1[3] - currentCamPos[3],
				v2[1] - currentCamPos[1], v2[2] - currentCamPos[2], v2[3] - currentCamPos[3],
				colors.white)
		end
	end
end

function VanDeGraaffObject:drawShutdown()
	blend(-1)
end


local CloudObject = Object:subclass()

CloudObject.startTime = -10
CloudObject.endTime = -9
CloudObject.duration = 60
CloudObject.radius = 1		-- .5 radius per drawn cloud, each spaced at .5 from the plop position

function CloudObject:init(args)
	CloudObject.super.init(self, args)
	self.startTime = game.time
	self.endTime = self.startTime + self.duration
	self.randomOffsets = {}
	for i=1,5 do
		local th = math.random() * math.pi * 2
		self.randomOffsets[i] = {math.cos(th) * .5, math.sin(th) * .5}
	end
end

function CloudObject:update(dt)
	if game.time > self.endTime then
		self:remove()
		return
	end
end

function CloudObject:draw(viewMatrix)
	local pushposX, pushposY, pushposZ = self.pos[1], self.pos[2], self.pos[3]
	for i=1,#self.randomOffsets do
		local offset = self.randomOffsets[i]
		self.pos[1], self.pos[2], self.pos[3] = pushposX + offset[1], pushposY + offset[2], pushposZ
		CloudObject.super.draw(self, viewMatrix)
	end
	self.pos[1], self.pos[2], self.pos[3] = pushposX, pushposY, pushposZ
end


local CloudKillObject = CloudObject:subclass()
CloudKillObject.spriteIndex = sprites.cloudkill
CloudKillObject.duration = 10
CloudKillObject.spinsOutPlayerOnTouch = true


local ColorSprayObject = CloudObject:subclass()
ColorSprayObject.spriteIndex = sprites.colorcloud


local BananaItem, GreenShellItem, RedShellItem, CloudKillItem

local Item = class()

Item.count = 1

-- returns true if we didn't use the item (returns false/nil if we did)
function Item:use(kart)
	trace'not implemented'
end

BananaItem = Item:subclass()

BananaItem.count = 10
BananaItem.spriteIndex = sprites.banana

function BananaItem:use(kart)
	BananaObject{pos = kart.pos, vel = kart.vel, dir = kart.dir, throw = kart.inputUpDown > 0}
end


GreenShellItem = Item:subclass()

GreenShellItem.count = 10
GreenShellItem.spriteIndex = sprites.greenshell

function GreenShellItem:use(kart)
	GreenShellObject{pos = kart.pos, vel = kart.vel, dir = kart.dir, drop = kart.inputUpDown < 0}
end


RedShellItem = Item:subclass()

RedShellItem.count = 5
RedShellItem.spriteIndex = sprites.redshell

function RedShellItem:use(kart)
	RedShellObject{
		pos = kart.pos,
		vel = kart.vel,
		dir = kart.dir,
		owner = kart,
	}
end


local MushroomItem = Item:subclass()

MushroomItem.count = 5
MushroomItem.spriteIndex = sprites.mushroom

function MushroomItem:use(kart)
	return not kart:boost()
end


local VanDeGraaffItem = Item:subclass()

VanDeGraaffItem.count = 6
VanDeGraaffItem.spriteIndex = sprites.vandegraaf

function VanDeGraaffItem:use(kart)
	local start = kart.pos + vec3(0,0,.5)

--[[ if it's a player ...
	kart.effectAudioSource:setBuffer(shockSound)
	kart.effectAudioSource:play()
--]]

	local shockTargetPositions = table()

	local shockLength = 20
	local shockAngleThreshold = math.cos(math.rad(60))
	local i = 1
	while i <= #game.objs do
		local obj = game.objs[i]
		local isItem = BananaObject:isa(obj) or RedShellObject:isa(obj) or GreenShellObject:isa(obj)
		if Kart:isa(obj) or isItem then
			local otherPos = obj.pos
			if not isItem then otherPos = otherPos + vec3(0,0,.5) end
			local posDiff = otherPos - start
			if vec3.dot(posDiff:normalize(), kart.dir) > shockAngleThreshold
			and posDiff:lenSq() < shockLength * shockLength
			then
				if not isItem then
					obj:spinOut()
				else
					obj:remove()	-- TODO a consistent destroy() for all shells / bananas
				end
				shockTargetPositions:insert(otherPos)
			end
		end
		i=i+1
	end
	if #shockTargetPositions == 0 then
		shockTargetPositions:insert(start + kart.dir * shockLength)
	end

	-- lightning and stun
	VanDeGraaffObject{pos=start, shockTargetPositions=shockTargetPositions}
end


local CloudItem = Item:subclass()

CloudItem.count = 10

function CloudItem:use(kart)
	local plop = kart.pos - kart.dir * 1.5
	plop[3] = plop[3] + .5
	self.objectClass{pos=plop}
end


CloudKillItem = CloudItem:subclass()

CloudKillItem.objectClass = CloudKillObject
CloudKillItem.spriteIndex = sprites.cloudkill


local ColorSprayItem = CloudItem:subclass()

ColorSprayItem.objectClass = ColorSprayObject
ColorSprayItem.spriteIndex = sprites.colorspray


local HandToFootItem = Item:subclass()
HandToFootItem.spriteIndex = sprites.handtofoot

function HandToFootItem:use(kart)
--[[
	kart.effectAudioSource:setBuffer(castSpellSound)
	kart.effectAudioSource:play()
--]]

	local karts = game.objsOfClass[Kart]
	for i=1,#karts do
		local otherKart = karts[i]
		if kart ~= otherKart then
			otherKart:handToFoot()
		end
	end
end


Item.types = {BananaItem, GreenShellItem, RedShellItem, MushroomItem, VanDeGraaffItem, CloudKillItem, ColorSprayItem, HandToFootItem}


local ItemBox = Object:subclass()

ItemBox.drawRadius = .5
ItemBox.respawnTime = -1

function ItemBox:draw(...)
	if self.respawnTime > game.time then return end
	ItemBox.super.draw(self, ...)
end


local Track = class()

function Track:init(args)
	local zScale = 16

	self.startPos = vec2(0,0)
	self.startDir = vec2(1,0)

	self.nodes = [[
220.44807852958, 94.287804405524, 8
216.93629282519, 114.20413082523, 8
213.41589576494, 134.12053951153, 7.2670865210312
210.93006098443, 154.45796508795, 5.2914202124029
208.82177524987, 174.88347776415, 3.3050844871468
207.96548201461, 195.52103218155, 1.2841994545879
202.11102234929, 213.98278481466, 3.0157830402004
182.56863730467, 215.34568226233, 6.8186881413866
162.77360189915, 211.11531089687, 6.817744472967
143.90023994383, 203.98558713314, 6.6618916519683
124.09651685871, 204.30065586571, 6.9078983247095
106.55536358719, 214.30353303744, 7.8109029815886
91.738487152681, 228.28878600405, 7.0366488232996
73.330700868491, 235.44901703016, 6.7534685129974
54.44006410883, 228.87690130692, 6.2069987997982
42.899904357547, 213.43973666432, 6.6749841181928
43.658704640989, 193.29854575112, 6.567727705925
43.363042184064, 173.09597864938, 5.9468038004676
48.311158756878, 153.24562905653, 6.4565405306112
59.091900429379, 136.05478218483, 6.837497098786
69.483914483174, 118.78783359282, 7.5168492143479
62.187881630514, 99.9733736626, 6.2398099927415
46.368385272002, 91.089785130481, 6.7225330208207
35.618797411354, 108.37907740825, 7.0094226560628
23.565556796582, 101.31716874443, 6.364506951947
21.885528892006, 81.072427680997, 6.6931267704128
21.257159078281, 60.815523136702, 6.7456880304335
21.531467904909, 40.505879202794, 6.7911697064077
29.49636185973, 22.486483181469, 7.6195745836824
49.499348729257, 21.37876193524, 7.6425676007413
68.570006128524, 27.973316991257, 6.7506877229675
87.366498256949, 36.038062616216, 6.8392157554626
105.44365886027, 44.8521303785, 6.8392157554626
121.14244516154, 58.066445621448, 6.8392157554626
134.52599050561, 73.405753688884, 6.8392157554626
153.92442864452, 77.683186163996, 6.7947819622679
168.12179224226, 63.373509208536, 7.4819504299069
176.09625737017, 44.888558945457, 8
186.02836301853, 27.218073722744, 7.2602233346505
205.1668421285, 21.800035021895, 7.605750377657
221.93167316411, 32.136298021778, 8
225.46654505101, 51.764759635523, 8
223.93364120053, 74.520196198627, 8
]]
	if self.nodes then
		self.nodes = string.split(self.nodes, '\n'):mapi([line]do
			local v = vec3(table.unpack(string.split(line,','):mapi([v]
				tonumber(string.trim(v))
			)))
			v *= .5				-- cuz they were recorded at 256x but now the track is 128x
			v[2] = 128 - v[2]	-- cuz console vflip
			return v
		end)
		for i=1,#self.nodes do
			node = self.nodes[i]
			local ii = (i % #self.nodes) + 1
			local nextNode = self.nodes[ii]
			node.vecToNext = nextNode - node
			node.distSqToNext = node.vecToNext:lenSq()
		end
	end

	-- each tile represents [i-1,1]x[j-1,j]
	self.size = vec2(128,128)
	self.itemBoxPositions = table()
	local realStartDest
	for i=0,self.size[1]-1 do
		for j=0,self.size[2]-1 do
			local tileIndex = mget(i,j)
			local startDest = self:processTrackColor(i, j, tileIndex)
			realStartDest = realStartDest or startDest
		end
	end
	if realStartDest then
		self.startDir = (realStartDest - self.startPos):normalize()
	end

	-- find the starting line
	do
		local function trace(dir)
			local v = self.startPos + self.startDir + dir
			while true do
				local newv = v + dir
				local ix, iy = math.floor(v[1]), math.floor(v[2])
				if ix < 0 or iy < 0 or ix >= self.size[1] or iy >= self.size[2] then
					break
				end
				if tileClassForIndex[mget(ix,iy)].solid then
					break
				end
				v = newv
			end
			return v
		end
		local left = vec2(-self.startDir[2], self.startDir[1])
		self.startingLineZ = 0
		self.startingLineLeftPos = trace(left)
		self.startingLineRightPos = trace(-left)
	end

	for i=1,#self.itemBoxPositions do
		local itemPos = self.itemBoxPositions[i]
		itemPos[3] = 0
	end

	local l = vec3(1,1,1):normalize()
	self.lightPos = ffi.new('float[4]', {l[1], l[2], l[3], 0})
end

function Track:processTrackColor(u,v,tileIndex)
	if tileIndex==tileIndexForName.SmoothTile then
	elseif tileIndex==tileIndexForName.RoughTile then
	elseif tileIndex==tileIndexForName.SolidTile then
	elseif tileIndex==tileIndexForName.BoostTile then
	elseif tileIndex==tileIndexForName.StartingLineTile then
	elseif tileIndex==tileIndexForName.startback then
		mset(u,v,tileIndexForName.SmoothTile)
		return vec2(u+.5,v+.5)
	elseif tileIndex==tileIndexForName.startfront then
		mset(u,v,tileIndexForName.SmoothTile)
		self.startPos = vec2(u+.5,v+.5)
	elseif tileIndex==tileIndexForName.item then
		mset(u,v,tileIndexForName.SmoothTile)
		self.itemBoxPositions:insert(vec3(u+.5, v+.5,0))
	else
		trace("unknown tile at "..u..", "..v.." has "..tileIndex)
		mset(u,v,tileIndexForName.SmoothTile)
	end
end

function Track:draw(viewMatrix, viewX, viewY, viewWidth, viewHeight)
	-- draw sky
--	gl.glDisable(gl.GL_DEPTH_TEST)
	local viewTheta = -math.atan2(viewMatrix[1][2], viewMatrix[1][1])
	local viewU = viewTheta / (2 * math.pi)
	matpush()
	matident()
	local skyScale = viewWidth / windowWidth
	local s = 2 * skyScale
	matscale(s, s)
	mattrans(viewU * 32 * 8, 0)
	spr(768, viewX / s, viewY / s, 32, 8)		-- draw sky
	spr(768, viewX / s - 32 * 8, viewY / s, 32, 8)	-- make it wrap
	matpop()

	-- [[ draw the track as tilemap
	matpush()
-- [=[ using 0,0,0 as view origin, and subtracting origin per-scene-object for rendering
	mattrans(-currentCamPos[1], -currentCamPos[2], -currentCamPos[3])
--]=]
	matscale(1/8, 1/8, 1/8)
--[=[ not helping
applyprojmat()
--]=]
	map(0, 0, track.size[1], track.size[2], 0, 0)
	matpop()
	--]]
end


local kartNames = {'mario','luigi','princess','yoshi','bowser','donkeykong','koopa','toad'}

Kart = Object:subclass()	-- previously local'd

Kart.reserveItemCount = 0

function Kart:init(args)
	Kart.super.init(self, args)

	self.kartName = kartNames[math.random(#kartNames)]
	local kartSpacing = 2
	local dx = ((args.startIndex % 2) - .5) * 2 * kartSpacing
	local dy = (args.startIndex + 1) * kartSpacing
trace('game.track.startPos', game.track.startPos)
trace('game.track.startDir', game.track.startDir)
	self.pos = vec3(
		game.track.startPos[1] - game.track.startDir[1] * dy + game.track.startDir[2] * dx,
		game.track.startPos[2] - game.track.startDir[2] * dy - game.track.startDir[1] * dx,
		0)
	self.pos[3] = 0
--DEBUG:trace('kart.pos', self.pos)
	self.dir = vec3(game.track.startDir[1], game.track.startDir[2], 0)	-- cart fwd dir
--DEBUG:trace('kart.dir', self.dir)
	self.lookDir = vec3(self.dir[1], self.dir[2], self.dir[3])	-- follow camera fwd dir
	self.vel = vec3(0,0,0)
	self.surfaceNormal = vec3(0,0,1)	--game.track:getNormal(self.pos[1], self.pos[2])
	self.onground = true

	-- stack!
	self.boosts = table()

--[[
	self.engineAudioSource = AudioSource()
	self.engineAudioSource:setBuffer(engineSound)
	self.engineAudioSource:setLooping(true)
	self.engineAudioSource:play()

	-- put these two on a cycle buffer?

	self.brakeAudioSource = AudioSource()
	self.brakeAudioSource:setBuffer(brakeSound)
	self.brakeAudioSource:setLooping(true)

	self.effectAudioSource = AudioSource()
--]]
end

-- run once per input process
function Kart:clientInputUpdate()
	local inputBrake = self.inputBrake
	if self.handToFootFlip then inputBrake = self.inputGas end
--[[
	if inputBrake or self.inputJumpDrift then
		if not self.brakeAudioSource.isPlaying then
			self.brakeAudioSource.isPlaying = true
			self.brakeAudioSource:play()
		end
	else
		if self.brakeAudioSource.isPlaying then
			self.brakeAudioSource.isPlaying = false
			self.brakeAudioSource:stop()
		end
	end
--]]
end

function Kart:setupClientView(aspectRatio, viewX, viewY, viewWidth, viewHeight)
	matident()

	--local n=.1
	local n=.1
	local f=128

-- [[ this gets resolution issues the further from the origin we are
	local viewCenterX = viewX + .5 * viewWidth
	local viewCenterY = viewY + .5 * viewHeight
	mattrans(viewCenterX - 128, viewCenterY - 128)
	matfrustum(-n,n,-n,n,n,f)
	local s = viewWidth / windowWidth
	matscale(s, s)
--[=[
trace()
trace('frustum:')
trace(('%d %d %d %d'):format(ram.mvMat[0], ram.mvMat[4], ram.mvMat[8], ram.mvMat[12]))
trace(('%d %d %d %d'):format(ram.mvMat[1], ram.mvMat[5], ram.mvMat[9], ram.mvMat[13]))
trace(('%d %d %d %d'):format(ram.mvMat[2], ram.mvMat[6], ram.mvMat[10], ram.mvMat[14]))
trace(('%d %d %d %d'):format(ram.mvMat[3], ram.mvMat[7], ram.mvMat[11], ram.mvMat[15]))
--]=]
--[=[ not helping
for i=0,15 do
	projmat[i+1] = ram.mvMat[i]
end
matident()
--]=]
--]]
--[[ ortho works fine at all positions
	matortho(-10,10,-10,10,-1000,1000)
--]]

	-- [[
	local camHDist = 2.5 local camVDist = 2.5
	local camVLookDist = 2

	local camPos = vec3(
		self.pos[1] - self.lookDir[1] * camHDist,
		self.pos[2] - self.lookDir[2] * camHDist,
		self.pos[3] + camVDist
	)
	local camPosTrackZ = 1
	camPos[3] = math.max(camPos[3], camPosTrackZ)	-- crashes when I replace it with a condition
	local camLookAt = vec3(self.pos[1], self.pos[2], camPos[3] + (camVLookDist - camVDist))

currentCamPos = camPos

--[=[ using world origin as view origin
	matlookat(
		camPos[1], camPos[2], camPos[3],
		camLookAt[1], camLookAt[2], camLookAt[3],
		0, 0, 1)
--]=]
-- [=[ using 0,0,0 as view origin, and subtracting origin per-scene-object for rendering
-- doing this fixes the translation overflow error
-- but still getting some transformation/translation accuracy issues when our coordinates get to 256 away from the origin ... hmm
	matlookat(
		0, 0, 0,
		camLookAt[1] - camPos[1], camLookAt[2] - camPos[2], camLookAt[3] - camPos[3],
		0, 0, 1)
--]=]
	--]]
	--[[ debug overhead view
	local x, y, z = self.pos[1] + self.lookDir[1] * 10, self.pos[2] + self.lookDir[2] * 10, self.pos[3] + self.lookDir[3] * 10
	--matlookat(x,y,z + 100, x,y,z, self.lookDir[1], self.lookDir[2], self.lookDir[3])
	matlookat(0,0,100, x,y,z, self.lookDir[1], self.lookDir[2], self.lookDir[3])
	--]]

--[[
local zn, zf = 1, 100
local zo = 10
local posx,posy,angle = 10,10,0
matident()
matfrustum(-zn, zn, -zn, zn, zn, zf)	-- projection
matrot(math.rad(60), 1, 0, 0)			-- view inv angle
matrot(-angle, 0, 0, 1)					-- view inv angle
mattrans(-posx,-posy,-3)				-- view inv pos
--]]

end

Kart.drawRadius = .75

function Kart:draw(viewMatrix, kartSprites)
	if self.done then return end

	local viewFwd = viewMatrix[1]
	local viewRight = viewMatrix[2]
	local viewUp = viewMatrix[3]

	local viewFwd2DLen = vec2.length(viewFwd)
	local kartDir2DLen = vec2.length(self.dir)
	local lookFwd = vec2.dot(viewFwd, self.dir)
	local combinedLen = viewFwd2DLen * kartDir2DLen
	if combinedLen > .001 then
		lookFwd = lookFwd / combinedLen
	else
		lookFwd = 1
	end
	local cosDiff = lookFwd
	if cosDiff < -1 then
		cosDiff = -1
	elseif cosDiff > 1 then
		cosDiff = 1
	end
	local angleDiff = math.acos(cosDiff)
	local angleIndex = math.floor(angleDiff / math.pi * 11.99) + 1

	-- not used for angle, so doesn't need to be normalized
	local lookLeft = -viewFwd[2] * self.dir[1] + viewFwd[1] * self.dir[2]
	local uScale = 1
	local uBias = 0
	if lookLeft < 0 then
		uScale = -1
		uBias = 1
	end

	-- [[ crappy shadow
	do
		blend(1)
		matpush()
		mattrans(self.pos[1] - currentCamPos[1], self.pos[2] - currentCamPos[2], -currentCamPos[3])
		local length = .3
		elli(-length, -length, 2 * length, 2 * length, 0)
		blend(-1)
		matpop()
	end
	--]]

	-- [[
	do
		-- TODO how to calculate this
local viewAngle = math.atan2(viewFwd[2], viewFwd[1])
local kartAngle = math.atan2(self.dir[2], self.dir[1])
		matpush()

--[=[ using world origin as view origin
		mattrans(self.pos[1], self.pos[2], self.pos[3])
--]=]
-- [=[ using 0,0,0 as view origin, and subtracting origin per-scene-object for rendering
		mattrans(self.pos[1] - currentCamPos[1], self.pos[2] - currentCamPos[2], self.pos[3] - currentCamPos[3])
--]=]

		matscale(1/32,1/32,1/32)
		-- undo camera viewAngle to make a billboard
		matrot(viewAngle + .5 * math.pi, 0, 0, 1)
		matrot(math.rad(-70), 1, 0, 0)
		local angleNorm = (-(viewAngle - kartAngle) / math.pi) % 2
		local scaleX = 1
		if angleNorm > 1 then
			angleNorm = 2 - angleNorm
			scaleX = -1
			mattrans(16, -32, 0)
		else
			mattrans(-16, -32, 0)
		end
		local spriteIndex = spriteIndexForAngle[math.floor(angleNorm * #spriteIndexForAngle) + 1]
--[=[ not helping
applyprojmat()
--]=]
		spr(spriteIndex, 0, 0, 4, 4, nil, nil, nil, nil, scaleX)
		matpop()
	end
	--]]

	--[[ debug dir pointer
	local unitVel = self.vel:normalize()
	for i,dir in ipairs{unitVel, self.dir} do
		gl.glColor3f(1,1,i-1)
		gl.glBegin(gl.GL_TRIANGLES)
		gl.glVertex3f(
			self.pos[1] + dir[1],
			self.pos[2] + dir[2],
			self.pos[3]+.01+i*.01)
		gl.glVertex3f(
			self.pos[1] - .2 * dir[2],
			self.pos[2] + .2 * dir[1],
			self.pos[3]+.01+i*.01)
		gl.glVertex3f(
			self.pos[1] + .2 * dir[2],
			self.pos[2] - .2 * dir[1],
			self.pos[3]+.01+i*.01)
		gl.glEnd()
	end
	--]]

	--[[ debug measurement grid
	do
		gl.glColor3f(0,1,0)
		gl.glPushMatrix()
		local x,y,z = math.floor(self.pos[1]), math.floor(self.pos[2]), math.floor(self.pos[3])
		gl.glTranslatef(x,y,z)
		gl.glBegin(gl.GL_LINES)
		local size = 5
		for i=-size,size do
			for j=-size,size do
				gl.glVertex3f(-size,i,j)
				gl.glVertex3f(size,i,j)
				gl.glVertex3f(i,-size,j)
				gl.glVertex3f(i,size,j)
				gl.glVertex3f(i,j,-size)
				gl.glVertex3f(i,j,size)
			end
		end
		gl.glEnd()
		gl.glPopMatrix()
	end
	--]]
end

local function placeSuffix(n)
	if n == 1 then return 'st' end
	if n == 2 then return 'nd' end
	if n == 3 then return 'rd' end
	return 'th'
end

Kart.lakituCenterX = 0
Kart.lakituCenterY = -.1

function Kart:drawHUD(aspectRatio, viewX, viewY, viewWidth, viewHeight)
	matident()
	-- inverse-transform ortho so that [0,256]^2 lines up with the view rect
	--matortho(viewX, viewX + viewWidth, viewY, viewY + viewHeight)
	mattrans(viewX, viewY)
	matscale(viewWidth/256, viewHeight/256)
	local speed = self.vel:length()

	do
		local spedoAngle = math.pi * 5 / 4 - (speed / 3) / (2 * math.pi)
		local dx = math.cos(spedoAngle)
		local dy = -math.sin(spedoAngle)
		local centerX, centerY = 31, 255-31
		local length = 26

		blend(1)
		elli(centerX - length, centerY - length, 2 * length, 2 * length, 0)

		tri(
			-- x1 y1
			centerX + length * dx,
			centerY + length * dy,
			-- x2 y2
			centerX - .2 * length * dy,
			centerY + .2 * length * dx,
			-- x3 y3
			centerX + .2 * length * dy,
			centerY - .2 * length * dx,
			-- colorIndex
			0x81
		)
		blend(-1)
	end

	do
		local centerX, centerY = 128, 18
		local length = 8

		matpush()
		mattrans(centerX, centerY)
		matscale(2, 2)

		spr(sprites.outline[1], -8, -8, sprites.outline[2], sprites.outline[3])

		if self.gettingItem then
			if self.getItemTime + self.getItemDuration > game.time then
				local itemIndex = math.random(#Item.types)
				local randomType = Item.types[itemIndex]
				if not randomType.spriteIndex then error("Item.types["..itemIndex.."] is missing its .spriteIndex") end
				spr(randomType.spriteIndex[1], -8, -8, randomType.spriteIndex[2], randomType.spriteIndex[3])
			end
		end
		if self.item then
			spr(self.item.spriteIndex[1], -8, -8, self.item.spriteIndex[2], self.item.spriteIndex[3])
		end

		if self.handToFootEndTime >= game.time then
			local frac = math.sin(10 * game.time / math.pi) * .15 + .65

			local transition = .5
			if game.time < self.handToFootStartTime + transition then
				frac = frac * (game.time - self.handToFootStartTime) / transition
			elseif game.time > self.handToFootEndTime - transition then
				local alpha = 1 - (self.handToFootEndTime - game.time) / transition
				frac = frac * (1 - alpha) + alpha
			end

			--gl.glColor4f(1,1,1,1-frac)	-- TODO fade
			spr(sprites.handtofoot[1], centerX - length, centerY - length, sprites.handtofoot[2], sprites.handtofoot[3])
		end

		matpop()
	end
--]]

	if game.time >= 0 then
		text(
			('%02d:%02d.%02d'):format(math.floor(game.time/60), math.floor(game.time)%60, math.floor(game.time*100)%100),
			1, 1,
			colors.white, -1,
			2, 2
		)
	end

	text(
		('%02.1f'):format(speed),
		4, 240,
		colors.white, -1,
		2, 2
	)

	text(
		tostring(self.place)..placeSuffix(self.place),
		220, 224,
		colors.white, -1,
		2, 2
	)

	text(
		'lap '..tostring(self.lap+1),
		200, 240,
		colors.white, -1,
		2, 2
	)

	--[[ debugging
	if game.track.nodes then
		text(
			'node '..tostring(self.nodeIndex)
				..' : '..tostring(self.nodeIndexParam)
				..' /'..#game.track.nodes,
			0, 16,
			colors.white, -1
		)
	end
	--]]

	if self.item then
		text(
			'x'..self.item.count,
			144, 2,
			colors.white, -1,
			2, 2
		)
	end

	if self.reserveItemCount > 0 then
		text(
			'R'..self.reserveItemCount,
			144, 18,
			colors.white, -1,
			2, 2
		)
	end

	-- draw lakitu if we're starting

	do
		local starting = game.time < 0
		local needsLakitu = starting or self.goingBackwards

		local alpha = .005
		if needsLakitu then
			self.lakituCenterX = self.lakituCenterX * (1 - alpha) + .5 * alpha
			self.lakituCenterY = self.lakituCenterY * (1 - alpha) + .5 * alpha
		else
			self.lakituCenterX = self.lakituCenterX * (1 - alpha) + .5 * alpha
			self.lakituCenterY = self.lakituCenterY * (1 - alpha) + -.5 * alpha
		end
		local floatRadius = .2
		local centerX = self.lakituCenterX + math.cos(game.time) * floatRadius
		local centerY = self.lakituCenterY + math.sin(game.time) * floatRadius
		local length = .3

		spr(sprites.ralph[1], 256 * (centerX + (-.5) * length), 256 * (centerY + (-.5) * length), sprites.ralph[2], sprites.ralph[3])

		if starting then
			local msg
			if game.time > -.3 then
				msg = 'GO!!!'
			elseif game.time > -1.3 then
				msg = '1'
			elseif game.time > -2.3 then
				msg = '2'
			elseif game.time > -3.3 then
				msg = '3'
			end
			if msg then
			text(msg, 256*centerX, 256*centerY, colors.white, colors.black, 2, 2)
			end
		elseif self.done then
			text(self.place.."rd Place!", 256*centerX-32, 256*centerY, colors.white, colors.black, 2, 2)
		elseif self.goingBackwards then
			text("Wrong Way", 256*centerX-32, 256*centerY, colors.white, colors.black, 2, 2)
			text("RETARD!", 256*centerX-32, 16+256*centerY, colors.white, colors.black, 2, 2)
		end
	end
end

Kart.nextBoostTime = -10

-- returns false if no boost was given, true if a boost was given
function Kart:boost()
	if self.nextBoostTime > game.time then return false end
	self.nextBoostTime = game.time + .2		-- boost delay

	self.boosts:insert{start = game,time, finish = game.time + 2}

--[[
	self.effectAudioSource:setBuffer(boostSound)
	self.effectAudioSource:play()
--]]

	return true
end

Kart.spinOutStartTime = -10
Kart.spinOutEndTime = -9

function Kart:spinOut()
	self.spinOutStartTime = game.time
	self.spinOutEndTime = self.spinOutStartTime + 1
end

Kart.handToFootStartTime = -10
Kart.handToFootEndTime = -9
Kart.handToFootNextFlipTime = -1

function Kart:handToFoot()
	if self.handToFootStartTime < game.time then
		self.handToFootStartTime = game.time
	end
	self.handToFootEndTime = game.time + 15
	self.handToFootNextFlipTime = game.time + 1
	self.handToFootFlip = true
end

Kart.colorSprayStartTime = -10
Kart.colorSprayEndTime = -9

function Kart:colorSpray()
	-- only refresh the start time if the interval has already completed
	if self.colorSprayEndTime < game.time then
--[[
		self.effectAudioSource:setBuffer(dizzySound)
		self.effectAudioSource:play()
--]]
		self.colorSprayStartTime = game.time
	end
	self.colorSprayEndTime = game.time + 30
end

Kart.inputGas = false
Kart.inputItem = false
Kart.inputBrake = false
Kart.inputJumpDrift = false
Kart.inputLeftRight = 0
Kart.inputUpDown = 0

Kart.getItemTime = -2
Kart.getItemDuration = 1

Kart.mass = 10
Kart.boostForce = 50
Kart.turnSpeed = 70
Kart.turnSharpness = 0		-- %age.  can't notice a difference
Kart.gasForce = 50
Kart.jumpForce = 2800
Kart.driftSwingForce = 100	-- left/right swing force when drifting and on ground
Kart.speed = 0

local recording = {
	distBetweenPositions = 10,
	positions = table(),
	update = function(self, kart)
		if self.done then return end
		if #self.positions == 0 or (kart.pos - self.positions[#self.positions]):length() > self.distBetweenPositions then
			self.positions:insert(vec3(kart.pos[1], kart.pos[2], kart.pos[3]))
		end
		if #self.positions > 3 and (kart.pos - self.positions[1]):length() < self.distBetweenPositions then
			trace('writing nodes')
			self.positions:insert(vec3(kart.pos[1], kart.pos[2], kart.pos[3]))
			trace(self.positions:mapi(tostring):concat('\n'))
			self.done = true
		end
	end,
}

Kart.nodeIndex = 1
Kart.nodeIndexParam = 0
Kart.place = 1
Kart.lap = 0

function Kart:update(dt)
	if self.done then return end

--	recording:update(self)	-- enable to record track nodes
--DEBUG:trace('kart.pos', self.pos)
	local track = game.track

	if track.nodes then
		if not self.nodesDistSq then self.nodesDistSq = {} end

		local bestNodeDistSq, bestNodeIndex
		for nodeIndex=1,#track.nodes do
			local node = track.nodes[nodeIndex]
			local dx = self.pos[1] - node[1]
			local dy = self.pos[2] - node[2]
			local dz = self.pos[3] - node[3]
			local distSq = math.sqrt(dx*dx + dy*dy + dz*dz)
			self.nodesDistSq[nodeIndex] = distSq
			if not bestNodeDistSq then
				bestNodeIndex = nodeIndex
				bestNodeDistSq = distSq
			else
				if distSq < bestNodeDistSq then
					bestNodeIndex = nodeIndex
					bestNodeDistSq = distSq
				end
			end
		end

		local prevOfBestIndex = ((bestNodeIndex - 2) % #track.nodes) + 1
		local nextOfBestIndex = (bestNodeIndex % #track.nodes) + 1
		local distSqToNextNode = self.nodesDistSq[prevOfBestIndex]
		local bestToPrevDistSq = track.nodes[prevOfBestIndex].distSqToNext
		local bestToNextDistSq = track.nodes[bestNodeIndex].distSqToNext

		-- self.nodeIndex is modulo #track.nodes, so it holds the current lap as well
		local currentNodeIndex = (self.nodeIndex - 1) % #track.nodes + 1
		local deltaNode = bestNodeIndex - currentNodeIndex
		if math.abs(deltaNode) > #track.nodes / 2 then
			if deltaNode > 0 then
				deltaNode = deltaNode - #track.nodes
			else
				deltaNode = deltaNode + #track.nodes
			end
		end

		self.nodeIndex = self.nodeIndex + deltaNode
		local lap = math.floor( (self.nodeIndex-1) / #track.nodes )
		if lap > self.lap then
			self.lap = lap
			-- lap # is one off so
			if self.lap >= game.maxLaps then
				-- TODO switch to AI or something
				game.finishPlayers:insert(self.playerIndex)

				if #game.finishPlayers == #clientViewObjs then
					-- game is over or something
				end

				self.done = true
				self:remove()
				return
			end
		end

		self.nodeIndexParam = (bestToNextDistSq - bestToPrevDistSq) - (self.nodesDistSq[nextOfBestIndex] - self.nodesDistSq[prevOfBestIndex])

		local vecToNext = track.nodes[currentNodeIndex].vecToNext
		local fwddotnext = vec3.dot(vecToNext, self.dir)
		self.goingBackwards = fwddotnext < -math.cos(math.rad(60))
	end


	--trace('--')
	--trace('pos before integration',self.pos)
	--trace('vel before integration',self.vel)

	-- hand to foot
	if self.handToFootEndTime >= game.time then
		if self.handToFootNextFlipTime < game.time then
			self.handToFootNextFlipTime = self.handToFootNextFlipTime + 1
			if math.random(2) == 2 then
				self.handToFootFlip = not self.handToFootFlip
			end
		end
	else
		self.handToFootFlip = false
	end

	-- spinning out
	local spinningOut = self.spinOutEndTime >= game.time
	if spinningOut then
		local turnAngle = 4 * (2 * math.pi) * fixedDeltaTime / (self.spinOutEndTime - self.spinOutStartTime)
		local costh, sinth = math.cos(turnAngle), math.sin(turnAngle)
		rot2d(self.dir, costh, sinth, self.dir)

		local invlen = 1 / self.dir:length()
--DEBUG:trace('spinning out before dir=', self.dir)
		self.dir[1] = self.dir[1] * invlen
		self.dir[2] = self.dir[2] * invlen
		self.dir[3] = self.dir[3] * invlen
--DEBUG:trace('spinning out after dir=', self.dir)
	end

	-- after dir influences, recorrect to surface normal
	if self.onground then
--DEBUG:trace('self.surfaceNormal', self.surfaceNormal)
		local dirDotNormal = vec3.dot(self.dir, self.surfaceNormal)
--DEBUG:trace('dirDotNormal', dirDotNormal)
--DEBUG:trace('ongroundA before dir=', self.dir)
		self.dir[1] = self.dir[1] - self.surfaceNormal[1] * dirDotNormal
		self.dir[2] = self.dir[2] - self.surfaceNormal[2] * dirDotNormal
		self.dir[3] = self.dir[3] - self.surfaceNormal[3] * dirDotNormal
--DEBUG:trace('ongroundA before2 dir=', self.dir)

		local invlen = 1 / self.dir:length()
		self.dir[1] = self.dir[1] * invlen
		self.dir[2] = self.dir[2] * invlen
		self.dir[3] = self.dir[3] * invlen
--DEBUG:trace('ongroundA after dir=', self.dir)
	end

	-- spinning items stopped
	if self.gettingItem and self.getItemTime + self.getItemDuration < game.time then
		local itemClass = Item.types[math.random(#Item.types)]
		self.item = itemClass()
		self.gettingItem = false
	end

	-- used items
	if self.inputItem and not self.lastInputItem and self.item then
		if not self.item:use(self) then
			self.item.count = self.item.count - 1
			if self.item.count <= 0 then
				self.item = nil

				if self.reserveItemCount > 0 then
					self.reserveItemCount = self.reserveItemCount - 1
					self.getItemTime = game.time
					self.gettingItem = true
				end

			end
		end
	end

	-- start with gravity
	local forceX = self.gravity[1] * self.mass
	local forceY = self.gravity[2] * self.mass
	local forceZ = self.gravity[3] * self.mass
	--trace('forceZ initial',forceZ)

	-- add engine accel and gravity

	-- add boosts
	for i=#self.boosts,1,-1 do
		if self.boosts[i].finish < game.time then
			self.boosts:remove(i)
		end
	end

	if #self.boosts > 0 then
		local boostForce = #self.boosts * self.boostForce * 5
		forceX = forceX + self.dir[1] * boostForce
		forceY = forceY + self.dir[2] * boostForce
		forceZ = forceZ + self.dir[3] * boostForce
--DEBUG:trace('forceZ after boost',forceZ)
	end

	if self.onground and not spinningOut then
		local inputGas = self.inputGas
		if self.handToFootFlip then inputGas = self.inputBrake end
		if inputGas then
			forceX = forceX + self.dir[1] * self.gasForce
			forceY = forceY + self.dir[2] * self.gasForce
			forceZ = forceZ + self.dir[3] * self.gasForce
--DEBUG:trace('forceZ after gas',forceZ)
		end
	end

	-- calc air drag
	if self.vel:lenSq() > .001 then
		local ix, iy = math.floor(self.pos[1]), math.floor(self.pos[2])
		local groundDragCoeff = 0
		local groundDragArea = 1
		if self.onground and #self.boosts == 0 then
			if ix >= 0 and iy >= 0 and ix < track.size[1] and iy < track.size[2] then
				groundDragCoeff = tileClassForIndex[mget(ix,iy)].drag
			end
		else
			groundDragArea = 0
		end
		local airDensity = 1.184	-- kg/m^3 at temperature 77 degrees F
		local airDragCoeff = 0		-- unitless.  .5 is for a car
		local airReferenceArea = 1	-- in m^2
--DEBUG:trace('dragForce',dragForce)
		local speed = self.vel:length()
		local dragPerSpeedMagn = .5 * airDensity * speed * (airDragCoeff * airReferenceArea + groundDragCoeff * groundDragArea)
		forceX = forceX - self.vel[1] * dragPerSpeedMagn
		forceY = forceY - self.vel[2] * dragPerSpeedMagn
		forceZ = forceZ - self.vel[3] * dragPerSpeedMagn
--DEBUG:trace('forceZ after drag',forceZ)
	end

	-- integrate force without friction
	-- but keep the force vector around for determining friction
--DEBUG:trace('total integrated force',force)
--DEBUG:trace('vel before integration before friction',self.vel)
	self.vel[1] = self.vel[1] + forceX * (dt / self.mass)
	self.vel[2] = self.vel[2] + forceY * (dt / self.mass)
	self.vel[3] = self.vel[3] + forceZ * (dt / self.mass)

--DEBUG:trace('vel after integration before friction',self.vel)

--[[ fake friction?
	if self.onground then
		local frictionAmount = dt
		if self.vel:lenSq() > frictionAmount then
			local oldspeed = vec2.length(self.vel)
			local newspeed = oldspeed - frictionAmount
			if newspeed <= 0.0001 then
				self.vel[1], self.vel[2] = 0, 0
			else
				local coeff = newspeed / oldspeed
				self.vel[1] = self.vel[1] * coeff
				self.vel[2] = self.vel[2] * coeff
			end
		end
	end
--]]
-- [[ friction
	if self.onground then
		if self.vel:lenSq() > .01 then

			local frictionCoeff = SmoothTile.friction

			-- friction decel

			-- get the kart surface friction
			if self.pos[1] >= 0 and self.pos[1] < track.size[1]
			and self.pos[2] >= 0 and self.pos[2] < track.size[2]
			then
				local ix, iy = math.floor(self.pos[1]), math.floor(self.pos[2])
				local tileClass = tileClassForIndex[mget(ix,iy)]
				if tileClass.boost then self:boost() end
				if #self.boosts == 0 then
					frictionCoeff = tileClass.friction
				else
					frictionCoeff = SmoothTile.friction
				end
			end

			if not spinningOut and #self.boosts == 0 then
				local inputBrake = self.inputBrake
				if self.handToFootFlip then inputBrake = self.inputGas end
				if inputBrake then
					frictionCoeff = frictionCoeff + 1
				end
			end

			local leftX = self.surfaceNormal[2] * self.dir[3] - self.surfaceNormal[3] * self.dir[2]
			local leftY = self.surfaceNormal[3] * self.dir[1] - self.surfaceNormal[1] * self.dir[3]
			local leftZ = self.surfaceNormal[1] * self.dir[2] - self.surfaceNormal[2] * self.dir[1]

			-- fwd = unit velocity
			-- up = self.surfaceNormal
			-- left = forward x up

			--local forceIntoNormal = -(self.surfaceNormal[1] * forceX + self.surfaceNormal[2] * forceY + self.surfaceNormal[3] * forceZ)		-- magnitude of gravity
			local forceIntoNormal = 220

			-- this shouldn't happen ... if it does, do we zero the force or do we ignore friction?
			if forceIntoNormal < 0 then forceIntoNormal = 0 end

--DEBUG:trace('forceIntoNormal',forceIntoNormal)
--DEBUG:trace('frictionCoeff',frictionCoeff)

			local speed = self.vel:length()
--DEBUG:trace('speed', speed)
			local frictionForceWithoutCoeffX = -self.vel[1] * forceIntoNormal / speed
			local frictionForceWithoutCoeffY = -self.vel[2] * forceIntoNormal / speed
			local frictionForceWithoutCoeffZ = -self.vel[3] * forceIntoNormal / speed
--DEBUG:trace('self.dir', self.dir)
			local frictionForceFwdMagn =
				  frictionForceWithoutCoeffX * self.dir[1]
				+ frictionForceWithoutCoeffY * self.dir[2]
				+ frictionForceWithoutCoeffZ * self.dir[3]
			local frictionForceLeftMagn =
				  frictionForceWithoutCoeffX * leftX
				+ frictionForceWithoutCoeffY * leftY
				+ frictionForceWithoutCoeffZ * leftZ
--DEBUG:trace('friction force (w/o coeff) forward',frictionForceFwdMagn,'left',frictionForceLeftMagn)

			local frictionImpulseFwdMagn = frictionForceFwdMagn * frictionCoeff * (dt / self.mass)
			local frictionImpulseLeftMagn = frictionForceLeftMagn * (frictionCoeff + 10) * (dt / self.mass)
--DEBUG:trace('friction impulse forward',frictionImpulseFwdMagn,'left',frictionImpulseLeftMagn)

--DEBUG:trace('surface normal',self.surfaceNormal)

			-- decompose velocity into direction basis

			local velFwdMagn = vec3.dot(self.vel, self.dir)
			local velLeftMagn = self.vel[1] * leftX + self.vel[2] * leftY + self.vel[3] * leftZ
			local velUpMagn = vec3.dot(self.vel, self.surfaceNormal)
--DEBUG:trace('vel forward', velFwdMagn, 'left', velLeftMagn,'up',velUpMagn)

			local restingVelocityThreshold = .1

			local newVelFwdMagn
			if math.abs(velFwdMagn) < restingVelocityThreshold then
--DEBUG:trace('|vel fwd| == '..velFwdMagn..' < resting threshold')
				newVelFwdMagn = 0
			elseif velFwdMagn > 0 then
				newVelFwdMagn = velFwdMagn + frictionImpulseFwdMagn
				if newVelFwdMagn < 0 then newVelFwdMagn = 0 end
			else
				newVelFwdMagn = velFwdMagn + frictionImpulseFwdMagn
				if newVelFwdMagn > 0 then newVelFwdMagn = 0 end
			end

			local newVelLeftMagn
			if math.abs(velLeftMagn) < restingVelocityThreshold then
--DEBUG:trace('|vel left| == '..velLeftMagn..' < resting threshold')
				newVelLeftMagn = 0
			elseif velLeftMagn > 0 then
				newVelLeftMagn = velLeftMagn + frictionImpulseLeftMagn
				if newVelLeftMagn < 0 then newVelLeftMagn = 0 end
			else
				newVelLeftMagn = velLeftMagn + frictionImpulseLeftMagn
				if newVelLeftMagn > 0 then newVelLeftMagn = 0 end
			end

			-- TODO this is what is pulling a resting kart uphill
			-- velocity 'up' is velocity with the surface normal.
			-- surface up / out of the surface is up in the air in the downhill direction
			-- surface down / into the surface is down in the air in the uphill direction
			-- so gravity pulling down will create a force in the uphill direction
			-- so reducing the surface plane velocity without also reducing (or zero'ing) the surface normal velocity will cause the uphill pull
			--local newVelUpMagn = velUpMagn
			local newVelUpMagn = velUpMagn
			if newVelUpMagn < 0 then newVelUpMagn = 0 end

--DEBUG:trace('new vel forward',newVelFwdMagn,'left',newVelLeftMagn,'up',newVelUpMagn)

			self.vel[1] = leftX * newVelLeftMagn + self.dir[1] * newVelFwdMagn + self.surfaceNormal[1] * newVelUpMagn
			self.vel[2] = leftY * newVelLeftMagn + self.dir[2] * newVelFwdMagn + self.surfaceNormal[2] * newVelUpMagn
			self.vel[3] = leftZ * newVelLeftMagn + self.dir[3] * newVelFwdMagn + self.surfaceNormal[3] * newVelUpMagn
--DEBUG:trace('post friction new vel',self.vel)
		else
			self.vel[1], self.vel[2], self.vel[3] = 0, 0, 0
		end
	end
--]]

--DEBUG:trace('vel after friction',self.vel)

	-- integrate position
	local newposX = self.pos[1] + self.vel[1] * dt
	local newposY = self.pos[2] + self.vel[2] * dt
	local newposZ = self.pos[3] + self.vel[3] * dt
--DEBUG:trace('dt', dt)
--DEBUG:trace('vel', self.vel)
--DEBUG:trace('newpos', newposX, newposY, newposZ)
-- [[
	-- check for collisions with world
	do
		local solid = false
		local ix, iy = math.floor(newposX), math.floor(newposY)
		if ix >= 0 and ix < track.size[1]
		and iy >= 0 and iy < track.size[2]
		then
			local tileClass = tileClassForIndex[mget(ix,iy)]
			solid = tileClass.solid
		else
			solid = true
		end

		if solid then
			newposX, newposY, newposZ = self.pos[1], self.pos[2], self.pos[3]
			tileBounceVel(ix, iy, self.pos, self.vel, nil, self.vel)
		end
	end
--]]

	-- check for ground contact
	do
		local z = 0
		self.onground = false
		-- TODO if newposZ < z then track back to collision point and try again
		if newposZ <= z+.1 then
			self.onground = true
			self.surfaceNormal[1], self.surfaceNormal[2], self.surfaceNormal[3] = 0,0,1
			--track:getNormal(newposX, newposY, self.surfaceNormal)
			newposZ = z

			-- if velocity is into the ground then remove velocity into the ground
			local velDotNormal = vec3.dot(self.vel, self.surfaceNormal)
			if velDotNormal < 0 then
				self.vel[1] = self.vel[1] - self.surfaceNormal[1] * velDotNormal
				self.vel[2] = self.vel[2] - self.surfaceNormal[2] * velDotNormal
				self.vel[3] = self.vel[3] - self.surfaceNormal[3] * velDotNormal
			end

			--trace('vel after clipping surface normal',self.vel)

			-- and if we got a new surface normal then readjust our pitch
			if self.onground then
				local dirDotNormal = vec3.dot(self.dir, self.surfaceNormal)
--DEBUG:trace('ongroundB before dir=', self.dir)
				self.dir[1] = self.dir[1] - self.surfaceNormal[1] * dirDotNormal
				self.dir[2] = self.dir[2] - self.surfaceNormal[2] * dirDotNormal
				self.dir[3] = self.dir[3] - self.surfaceNormal[3] * dirDotNormal
--DEBUG:trace('ongroundB before2 dir=', self.dir)
				local invlen = 1 / self.dir:length()
				self.dir[1] = self.dir[1] * invlen
				self.dir[2] = self.dir[2] * invlen
				self.dir[3] = self.dir[3] * invlen
--DEBUG:trace('ongroundB after dir=', self.dir)
			end
		else
--DEBUG:trace('ongroundC before dir=', self.dir)
			self.dir[3] = 0
			local invlen = 1 / vec2.length(self.dir)
			self.dir[1] = self.dir[1] * invlen
			self.dir[2] = self.dir[2] * invlen
			self.dir[3] = self.dir[3] * invlen
--DEBUG:trace('ongroundC before dir=', self.dir)
		end
	end
	self.pos[1], self.pos[2], self.pos[3] = newposX, newposY, newposZ
--DEBUG:trace('setting pos', self.pos)

	-- [[ jumping
	if self.onground and self.inputJumpDrift and not self.lastInputJumpDrift then
		self.vel[3] = self.vel[3] + self.jumpForce * (dt / self.mass)
		self.onground = false
	end
	--]]

	-- converge camera on fwd dir
	do
		local convergeCoeff = .1
		self.lookDir[1] = self.lookDir[1] * (1 - convergeCoeff) + self.dir[1] * convergeCoeff
		self.lookDir[2] = self.lookDir[2] * (1 - convergeCoeff) + self.dir[2] * convergeCoeff
		self.lookDir[3] = 0
		local invlen = 1 / vec2.length(self.lookDir)
		self.lookDir[1] = self.lookDir[1] * invlen
		self.lookDir[2] = self.lookDir[2] * invlen
	end

	-- turning
	if self.inputLeftRight ~= 0 and (not self.onground or self.vel:lenSq() > 0) then
		local turnSpeed = self.inputLeftRight * self.turnSpeed
		if self.inputJumpDrift then turnSpeed = turnSpeed * 2 end
		if self.handToFootFlip then turnSpeed = -turnSpeed end

		local theta = math.rad(turnSpeed) * dt
		local costh = math.cos(theta)
		local sinth = math.sin(theta)
		-- TODO rotate on surfaceNormal
		rot2d(self.dir, costh, sinth, self.dir)
		rot2d(self.lookDir, costh, sinth, self.lookDir)
		if self.inputJumpDrift then
			if self.onground then
				-- [[
				local leftX = self.surfaceNormal[2] * self.dir[3] - self.surfaceNormal[3] * self.dir[2]
				local leftY = self.surfaceNormal[3] * self.dir[1] - self.surfaceNormal[1] * self.dir[3]
				local leftZ = self.surfaceNormal[1] * self.dir[2] - self.surfaceNormal[2] * self.dir[1]
				local swingMagn = (-self.inputLeftRight * self.driftSwingForce * dt)
				self.vel[1] = self.vel[1] + leftX * swingMagn
				self.vel[2] = self.vel[2] + leftY * swingMagn
				self.vel[3] = self.vel[3] + leftZ * swingMagn
				--]]
				--[[
				rot2d(self.vel, costh, -sinth, self.vel)
				--]]
			end

			rot2d(self.lookDir, costh, sinth, self.lookDir)
		end

		local invlen = 1 / self.dir:length()
--DEBUG:trace('turning before dir', self.dir)
		self.dir[1] = self.dir[1] * invlen
		self.dir[2] = self.dir[2] * invlen
		self.dir[3] = self.dir[3] * invlen
--DEBUG:trace('turning after dir', self.dir)
		invlen = self.lookDir:length()
		self.lookDir[1] = self.lookDir[1] * invlen
		self.lookDir[2] = self.lookDir[2] * invlen
		self.lookDir[3] = self.lookDir[3] * invlen

-- [[ rotate velocity with steer direction?
		local newvelX, newvelY, newvelZ = self.vel[1], self.vel[2], self.vel[3]
		if self.onground and not spinningOut then	-- only rotate the velocity if we're on the ground
			--[=[
			newvelX, newvelY = newvelX * costh - newvelY * sinth, newvelX * sinth + newvelY * costh

			local coeff = self.turnSharpness
			if self.inputJumpDrift then coeff = 0 end
			if coeff < 0 then
				coeff = 0
			elseif coeff > 1 then
				coeff = 1
			end
			self.vel[1] = self.vel[1] * (1 - coeff) + newvelX * coeff
			self.vel[2] = self.vel[2] * (1 - coeff) + newvelY * coeff
			self.vel[3] = self.vel[3] * (1 - coeff) + newvelZ * coeff
			--]=]

			-- just rotate
			self.vel[1], self.vel[2] = newvelX * costh - newvelY * sinth, newvelX * sinth + newvelY * costh
		end
--]]
	end

	self.lastInputItem = self.inputItem
	self.lastInputJumpDrift = self.inputJumpDrift
end


local Player = class()



local Game = class()

local function sortKarts(ka,kb)
	if ka.nodeIndex > kb.nodeIndex then return true end
	if ka.nodeIndex < kb.nodeIndex then return false end
	return ka.nodeIndexParam > kb.nodeIndexParam
end

Game.maxLaps = 3

function Game:init()
	self.time = -6	-- TODO lakitu etc

	local trackName = 'map1'
	self.track = Track()

	self.players = {}		-- key = player # (0-63), value=Player object
	self.kartOrder = table()

	self.objs = table()
	self.objsOfClass = table()	-- classify by class, for better optimized drawing

	self.finishPlayers = table()
end

function Game:createItemBoxes()
	for i=1,#self.track.itemBoxPositions do
		local itemPos = self.track.itemBoxPositions[i]
		ItemBox{pos = itemPos}	-- for touch testing
	end
end

function Game:removeObject(obj)
	self.objs:removeObject(obj)
	local cl = getmetatable(obj)
	local objsOfClass = assert(self.objsOfClass[cl])
	objsOfClass:removeObject(obj)
	if #objsOfClass == 0 then
		self.objsOfClass[cl] = nil
	end
end

function Game:addObject(obj)
	self.objs:insertUnique(obj)

	local cl = getmetatable(obj)
assert(cl)
	local objsOfClass = self.objsOfClass[cl]
	if not objsOfClass then
		objsOfClass = table()
		self.objsOfClass[cl] = objsOfClass
	end
	objsOfClass:insert(obj)

	return obj
end

function Game:update(dt)
	-- TODO client update - do this clientside once per connection
	local lasttime = self.time - fixedDeltaTime
	if lasttime < -3.3 and self.time >= -3.3 then
		--trackAudioSource:setBuffer(startBeep32Sound)
		--trackAudioSource:play()
	elseif lasttime < -2.3 and self.time >= -2.3 then
		--trackAudioSource:setBuffer(startBeep32Sound)
		--trackAudioSource:play()
	elseif lasttime < -1.3 and self.time >= -1.3 then
		--trackAudioSource:setBuffer(startBeep32Sound)
		--trackAudioSource:play()
	elseif lasttime < -.3 and self.time >= -.3 then
		--trackAudioSource:setBuffer(startBeep1Sound)
		--trackAudioSource:play()				-- TODO only once per
	end

	if self.time >= 0 then

		do
			local i=1
			while i <= #self.objs do
				local obj = self.objs[i]
				if obj.update then
					obj:update(dt)
				end
				if not obj.removed then
					i=i+1
				end
			end
		end

		--[[
		things we check for:
		kart/kart bounces
		kart/item collisions
		moving item/moving item collisions
		moving item/resting item collisions
		... but resting item/resting item collisions ... that's a waste of a check, and is slowing us down ...
		--]]

		-- check for kart collisions
		local i = 1
		while i <= #self.objs-1 do
			local j = i+1
			while j <= #self.objs do
				local objA = self.objs[i]
				local objB = self.objs[j]
				local posDiff = objB.pos - objA.pos
				local objSizes = objA.radius + objB.radius
				if posDiff:lenSq() < objSizes * objSizes then

					-- collision!
					if Kart:isa(objA) and Kart:isa(objB) then
						local velDiff = objB.vel - objA.vel
						local distSq = posDiff:lenSq()
						local normal = vec3(0,0,1)
						if distSq > .1*.1 then
							normal = posDiff:normalize()
						else
							trace("DANGER")
						end

						local restitution = 0
						local vDotN = vec3.dot(velDiff, normal)

--DEBUG:trace'BOUNCE'
						objA.vel = objA.vel + normal * ((1 + restitution) * vDotN)
						objB.vel = objB.vel - normal * ((1 + restitution) * vDotN)
					else
						local kart, other
						if Kart:isa(objA) then
							kart = objA
							other = objB
						elseif Kart:isa(objB) then
							kart = objB
							other = objA
						end
						if kart then
							if ItemBox:isa(other) then
								if other.respawnTime <= game.time then
									other.respawnTime = game.time + 5
									if not kart.item and not kart.gettingItem then
										kart.getItemTime = game.time
										kart.gettingItem = true
									else
										kart.reserveItemCount = kart.reserveItemCount + 1
									end
								end
							elseif other.spinsOutPlayerOnTouch then
								kart:spinOut()
								if CloudKillObject:isa(other) then
									for i=1,3 do
										kart.vel[i] = kart.vel[i] + (math.random() * 2 - 1) * 10
									end
								end
								if other.removesOnPlayerTouch then
									other:remove()
									if other==objA then i=i-1 end
									if other==objB then j=j-1 end
								end
							elseif ColorSprayObject:isa(other) then
								kart:colorSpray()
							end
						else
							if (BananaObject:isa(objA)
								or GreenShellObject:isa(objA)
								or RedShellObject:isa(objA)
							)
							and (
								BananaObject:isa(objB)
								or GreenShellObject:isa(objB)
								or RedShellObject:isa(objB)
							)
							then
								objA:remove()
								objB:remove()
								i=i-1
								j=j-1
							end
						end
					end
				end
				j=j+1
			end
			i=i+1
		end
	end

	local karts = self.objsOfClass[Kart]
	if karts then
		karts:sort(sortKarts)
		for kartIndex=1,#karts do
			local kart = karts[kartIndex]
			kart.place = #self.finishPlayers + kartIndex
		end
	end

	self.time = self.time + dt
end


local ClientViewObject = class()

function ClientViewObject:init()
	self.viewMatrix = {vec3(),vec3(),vec3()}
end

function ClientViewObject:drawScene(kart, aspectRatio, kartSprites, viewX, viewY, viewWidth, viewHeight)
--[[ client update the sound
	do
		local speed = kart.vel:length()
		kart.engineAudioSource:setPitch(speed * .02 + 1)
		kart.engineAudioSource:setGain(speed * .1 + .5)
	end
--]]

	kart:setupClientView(aspectRatio, viewX, viewY, viewWidth, viewHeight)

	local viewFwd = self.viewMatrix[1]
	local viewLeft = self.viewMatrix[2]
	local viewUp = self.viewMatrix[3]
	viewFwd[1] = kart.lookDir[1]
	viewFwd[2] = kart.lookDir[2]
	viewFwd[3] = kart.lookDir[3]
	viewLeft[1] = -viewFwd[2]
	viewLeft[2] = viewFwd[1]
	viewLeft[3] = 0
	viewUp[1] = 0
	viewUp[2] = 0
	viewUp[3] = 1

	game.track:draw(self.viewMatrix, viewX, viewY, viewWidth, viewHeight)

	for class,classObjs in pairs(game.objsOfClass) do
		if class.drawInit then class:drawInit(self.viewMatrix, kartSprites) end
		for i,obj in ipairs(classObjs) do
			if obj.draw then obj:draw(self.viewMatrix, kartSprites) end
		end
		if class.drawShutdown then class:drawShutdown(self.viewMatrix, kartSprites) end
	end

--[[ debugging
	if game.track.nodes then
		local node = game.track.nodes[self.nodeIndex]
		if node then
			line3d(
				kart.pos[1] - currentCamPos[1], kart.pos[2] - currentCamPos[2], kart.pos[3] + 1 - currentCamPos[3],
				node[1] - currentCamPos[1], node[2] - currentCamPos[2], node[3] + 1 - currentCamPos[3],
				colors.white
			)
		end

		for nodeIndex,node in ipairs(game.track.nodes) do
			matpush()
			mattrans(node[1] - currentCamPos[1], node[2] - currentCamPos[2], .1 - currentCamPos[3])
			local length = .5
			elli(-length, -length, 2 * length, 2 * length,
				({
					colors.white,
					colors.black,
					0xb0,	-- red
					0x89,	-- green
					0xf6,	-- blue
				})[((nodeIndex-1)%5)+1]
			)
			matpop()
		end
	end
--]]


-- [[ debug - show projection matrix
	local r1 = ('%08x %08x %08x %08x'):format(peekl(matAddr+(0<<2)), peekl(matAddr+(4<<2)), peekl(matAddr+(8<<2)), peekl(matAddr+(12<<2)))
	local r2 = ('%08x %08x %08x %08x'):format(peekl(matAddr+(1<<2)), peekl(matAddr+(5<<2)), peekl(matAddr+(9<<2)), peekl(matAddr+(13<<2)))
	local r3 = ('%08x %08x %08x %08x'):format(peekl(matAddr+(2<<2)), peekl(matAddr+(6<<2)), peekl(matAddr+(10<<2)), peekl(matAddr+(14<<2)))
	local r4 = ('%08x %08x %08x %08x'):format(peekl(matAddr+(3<<2)), peekl(matAddr+(7<<2)), peekl(matAddr+(11<<2)), peekl(matAddr+(15<<2)))
--]]

	kart:drawHUD(aspectRatio, viewX, viewY, viewWidth, viewHeight)

-- [[ debug - show projection matrix
	text('pos:'..kart.pos, 0, 0, colors.white, -1)
	text('vel:'..kart.vel, 0, 8, colors.white, -1)
	text('dir:'..kart.dir, 0, 16, colors.white, -1)
	text(r1, 0, 32, colors.white, -1)
	text(r2, 0, 40, colors.white, -1)
	text(r3, 0, 48, colors.white, -1)
	text(r4, 0, 56, colors.white, -1)
--]]
end


local maxPlayers=4	-- TODO 64 ...TODO track conns and add/remove from the start menu accordingly?
local inMenu = true
local menuSel = 0
local playersActive=table{false}:rep(maxPlayers-1)
playersActive[0]=true
playerWins=table{0}:rep(maxPlayers):map([v,k](v,k-1))

startGame=[]do
	inMenu=false

	game = Game()
	game:createItemBoxes()
	kart = game.kart
	track = game.track

	clientViewObjs = table()	-- index is not player index
	for playerIndex=0,maxPlayers-1 do
		if playersActive[playerIndex] then
			local clientViewObj = ClientViewObject()
			clientViewObj.playerIndex = playerIndex
			clientViewObjs:insert(clientViewObj)		-- 1-based dense
			local player = Player()
			player.playerIndex = playerIndex
			game.players[playerIndex] = player
			player.clientViewObj = clientViewObj
			local kart = Kart{
				startIndex=#clientViewObjs,
				playerIndex=playerIndex,
			}
			player.kart = kart
		end
	end
end

matident()	-- hmm having trouble resetting it with 'new game'...
update=[]do
	if inMenu then
		cls(0)
		local x,y=16,96
		text('max laps: 5', 128, y-32, colors.white, -1)	-- TODO customize this
		text('>', x-8, y+16*menuSel, colors.white, colors.black)
		text('wins',x+192-16,y-12,colors.white,colors.black)
		for pid=0,maxPlayers-1 do
			spr(spriteIndexForAngle[12], x, y-4, 4, 4, nil, nil, nil, nil, .5, .5)	-- TODO palette ...
			text('player '..(pid+1)..' = '
				..tostring(playersActive[pid]),
				x+24, y, colors.white, colors.black)
			text(tostring(playerWins[pid]),x+192, y,colors.white,colors.black)
			y+=16
		end
		text('Start!', x, y, colors.white, colors.black)
		for pid=0,maxPlayers-1 do
			if btnp(0,pid) then
				menuSel-=1
				menuSel%=maxPlayers+1
			elseif btnp(1,pid) then
				menuSel+=1
				menuSel%=maxPlayers+1
			end
			if menuSel<maxPlayers then
				-- any players left/right can toggle
				if btnp(2,pid) or btnp(3,pid) then
					playersActive[menuSel] = not playersActive[menuSel]
				-- if any player presses a button then set them to human
				elseif btnp(4,pid) or btnp(5,pid) then
					playersActive[pid] = true
				elseif btnp(6,pid) or btnp(7,pid) then
					playersActive[pid] = false
				end
			else
				-- if any player pushes when we're on 'start' then go
				if btnp(4,pid) or btnp(5,pid) or btnp(6,pid) or btnp(7,pid) then
					startGame()
				end
			end
		end
		return
	end

	for playerIndex,player in pairs(game.players) do
		local kart = player.kart
		kart.inputUpDown = (btn('up',playerIndex) and 1 or 0) + (btn('down',playerIndex) and -1 or 0)
		kart.inputLeftRight = (btn('right',playerIndex) and 1 or 0) + (btn('left',playerIndex) and -1 or 0)

		kart.inputItem = btn('a',playerIndex)
		kart.inputGas = btn('b',playerIndex)
		kart.inputJumpDrift = btn('x',playerIndex)
		kart.inputBrake = btn('y',playerIndex)

if kart.inputGas then
end

		player.kart:clientInputUpdate()
	end
	game:update(fixedDeltaTime)
end

local divsForNumPlayers = {{1,1}, {1,2}, {2,2}, {2,2}}
draw=[conn, ...]do
	if not game then return end
	cls(0)
	-- TODO ... holds the player indexes for this conn
	-- we need to filter them by the players active

	--[[ draw all
	local numPlayers = select('#', ...)
	local divX, divY = table.unpack(divsForNumPlayers[numPlayers])
	for i=1,numPlayers do
		local playerIndex = select(i, ...)
	--]]
	-- [[ draw only players that the main menu flagged as active-in-this-race
	local numPlayers = 0
	for i=1,select('#', ...) do
		local playerIndex = select(i, ...)
		if playersActive[playerIndex] then
			numPlayers+=1
		end
	end
	local divForNumPlayer = divsForNumPlayers[numPlayers]
	if not divForNumPlayer then
		trace("no valid divs for "..tostring(numPlayers))
		return
	end
	local divX, divY = table.unpack(divForNumPlayer)
	for i=1,select('#', ...) do
		local playerIndex = select(i, ...)
		if playersActive[playerIndex] then
			local player = game.players[playerIndex]
			if player then	-- maybe there's one frame in there that the player hasn't yet been assigned ...
				local clientViewObj = player.clientViewObj

				local kart = player.kart

				-- TODO determine view size by the conn
				-- TODO move the rendering into draw()
				local viewX = (i - 1) % divX
				local viewY = ((i - 1) - viewX) / divX
				local viewWidth = windowWidth / divX
				local viewHeight = windowHeight / divY
				local aspectRatio = viewWidth / viewHeight
				viewX *= windowWidth / divX
				viewY *= windowHeight / divY
				clip(viewX, viewY, viewWidth - 1, viewHeight - 1)

				local useColorSpray = game.time < kart.colorSprayEndTime

				-- cycle palette
				-- TODO draw(), RAM modifications, netplay, and this...
				if useColorSpray then
					for i=0,255 do
						pokew(palAddr+(i<<1),
							(0x7fff & palPush[(i+10*time())&0xff])
							| (0x8000 & palPush[i])	-- preserve transparnecy flag
						)
					end
				end

				clientViewObj:drawScene(kart, aspectRatio, kartSprites, viewX, viewY, viewWidth, viewHeight)

				-- reset
				if useColorSpray then
					for i=0,255 do
						pokew(palAddr+(i<<1), palPush[i])
					end
				end
			end
		end
	end
end
