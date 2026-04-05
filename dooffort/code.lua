-- title = Doof Fort
-- saveid = dooffort
-- author = Chris Moore

--[[
how well can numo9 handle a voxelmap based digging strategy sims game...
--]]

--#include ext/class.lua
--#include vec/vec2.lua
--#include vec/vec3.lua
--#include numo9/matstack.lua
--#include numo9/screen.lua

mode(0xff)	-- NativexRGB565
--mode(0)		-- 256x256xRGB565
--mode(43)	-- 480x270xRGB332
--mode(18)	-- 336x189xRGB565
local HD2DFlags = 0xff & ~4	-- turn off SSAO. meh.
--[[
pokef(ramaddr'ssaoSampleRadius', .5)
pokew(ramaddr'numLights', 1)			-- turn on 1 light
poke(ramaddr'lights', 0xff)				-- enable light #0
--]]


local player

local voxelTypeEmpty = 0xffffffff
local voxelTypeBricks = 0x42
local voxelTypeQuestionHit= 0x48
local voxelTypeQuestionCoin = 0x44
local voxelTypeQuestionMushroom = 0x84
local voxelTypeQuestionVine = 0xc4
local voxelTypeGoomba = 0x50000940
local voxelTypeBeetle = 0x50000980


-- init stage:
local voxelBlob = 0
local voxelmapAddr = blobaddr('voxelmap', voxelBlob)
local voxelmapSizeX = peekl(voxelmapAddr)
local voxelmapSizeY = peekl(voxelmapAddr + 4)
local voxelmapSizeZ = peekl(voxelmapAddr + 8)
--[[
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
--]]



local dt = 1/60
local epsilon = 1e-7
local grav = -dt
local maxFallVel = -.8


local fallToFloor=|x,y,z|do
	x = math.floor(tonumber(x))
	y = math.floor(tonumber(y))
	local startZ = math.floor(tonumber(z))
	startZ = math.min(startZ, voxelmapSizeZ-1)
	-- TODO if we start in a solid block then move up just once, or a fraction, or slowly or something idk
	for z=startZ,0,-1 do
		if peekl(voxelmapAddr + 12 + 4 * (x + voxelmapSizeX * (y + voxelmapSizeY * z))) ~= 0xffffffff then
			return x, y, z+1
		end
	end
	return x, y, 0
end

local view = {
	-- 0 degrees = y+ is forward, x+ is right
	yaw = 90,
	destYaw = 90,
	tiltUpAngle = -20,
	followDist = 7,
	followPos = vec3(),
	moveSpeed = 10,
}
view.update = |:, width, height|do
	

	-- view update:
	-- hold y + dir to rotate camera
	local vx = 0
	local vy = 0
	if btn'x' then
		if btnp'left' then
			self.destYaw += 90
		elseif btnp'right' then
			self.destYaw -= 90
		end
	else
		local speed = btn'y' and self.moveSpeed * 1.5 or self.moveSpeed
		if btn'up' then
			vx += -self.sinYaw * speed
			vy += self.cosYaw * speed
		end
		if btn'down' then
			vx -= -self.sinYaw * speed
			vy -= self.cosYaw * speed
		end
		if btn'left' then
			vx -= self.cosYaw * speed
			vy -= self.sinYaw * speed
		end
		if btn'right' then
			vx += self.cosYaw * speed
			vy += self.sinYaw * speed
		end
	end
	
	self.followPos.x += vx * dt
	self.followPos.y += vy * dt

	self.followPos.z = select(3, fallToFloor(self.followPos:unpack()))

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
	local viewX = self.followPos.x - self.followDist * sinPitch * -self.sinYaw
	local viewY = self.followPos.y - self.followDist * sinPitch * self.cosYaw
	local viewZ = self.followPos.z + self.followDist * cosPitch
	mattrans(-viewX, -viewY, -viewZ, 1)	-- view = inverse-translate

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
		if time() < self.jumpTime + jumpDuration and self.requestJump then
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
	if not Doof:isa(other) then return end
	
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
	if not Doof:isa(other) then return end
	self.voxelCode = voxelTypeGoomba + 4
	self.squashedTime = time() + 1
	self.voxelCode = voxelTypeGoomba + 4
	other.jumpTime = time()
	other.vel.z = bounceZVel
end

Doof = Object:subclass()
Doof.draw = |:|do
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



voxelInfos = {
	[voxelTypeBricks] = {
		hitUnder = |:, x,y,z|do
			-- TODO particles
			vset(0, x, y, z, voxelTypeEmpty)
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

local doofs = table()
do
	view.followPos:set(
		(voxelmapSizeX>>1) + .5,
		(voxelmapSizeY>>1) + .5,
		voxelmapSizeZ
	)
	for i=1,7 do
		doofs:insert(Doof{
			pos = vec3(fallToFloor(
				(voxelmapSizeX>>1) + math.random(5)-2 + .5,
				(voxelmapSizeY>>1) + math.random(5)-2 + .5,
				voxelmapSizeZ-1
			)),
		})
	end
end


-- sizes of our UI overlay wrt text
local textwidth = 32 * 8
local textheight = textwidth

update=||do
	poke(ramaddr'HD2DFlags', HD2DFlags)
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
	cls(nil, true)	-- clear depth

	view:update(width, height)

	voxelmap()

	for _,obj in ipairs(objs) do
		obj:update()
		obj:draw()
	end
	for i=#objs,1,-1 do
		if objs[i].remove then objs:remove(i) end
	end

	-- end-of-frame, after view has been captured, do ortho and draw text
	-- but disable light flags before clearing depth or else it'll clear the light depth too
	poke(ramaddr'HD2DFlags', 0)
	cls(nil, true)
	--poke(ramaddr'HD2DFlags', 2)	-- if you want the gui text to cast a shadow...
	matident(0)
	matident(1)
	matident(2)
	textheight = textwidth * height / width
	matortho(0, textwidth, textheight, 0)

	--[[ TODO HD2D effects
	-- this is post-projection transform so good luck with that
	pokef(ramaddr'dofFocalDist', 8)
	pokef(ramaddr'dofAperature', .2)

	poke(ramaddr'HD2DFlags', 0)			-- set neither
	--poke(ramaddr'HD2DFlags', 0x80)	-- set DoF
	--poke(ramaddr'HD2DFlags', 0x40)	-- set HDR ... TODO it's showing all black hmm ...
	--poke(ramaddr'HD2DFlags', 0xC0)	-- set HDR and DoF
	--]]
end
