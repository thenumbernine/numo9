--#include ext/class.lua
--#include vec/vec3.lua
--#include numo9/matstack.lua	-- matpush, matpop
--#include numo9/screen.lua		-- getAspectRatio

mode(0xff)	-- NativexRGB565
--mode(43)	-- 480x270xRGB332
--mode(18)	-- 336x189xRGB565
local HD2DFlags = 0xff  & ~4	-- turn off SSAO. meh.
pokef(ramaddr'ssaoSampleRadius', .5)
pokew(ramaddr'numLights', 1)			-- turn on 1 light
poke(ramaddr'lights', 0xff)				-- enable light #0


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
	local viewX = player.pos.x - self.followDist * sinPitch * -self.sinYaw
	local viewY = player.pos.y - self.followDist * sinPitch * self.cosYaw
	local viewZ = player.pos.z + self.followDist * cosPitch
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
end

local Beetle = Object:subclass()
Beetle.draw = |:, ...| do
	if not self.leaveShellTime then
		self.voxelCode = voxelTypeBeetle + ((math.floor(time() * 5) & 1) << 1)
	end
	Beetle.super.draw(self, ...)
end
Beetle.update = |:| do
	if self.leaveShellTime then
		if time() > self.leaveShellTime then
			self.leaveShellTime = nil
		end
		return
	end
	if player then
		self.vel = (player.pos - self.pos):normalize()
	end
end
Beetle.jumpedOn = |:,other| do
	if not Player:isa(other) then return end
	self.voxelCode = voxelTypeBeetle + 4
	self.leaveShellTime = time() + 5
	other.jumpTime = time()
	other.vel.z = bounceZVel
end

local Goomba = Object:subclass()
Goomba.draw = |:, ...| do
	if not self.squashedTime then
		self.voxelCode = voxelTypeGoomba + ((math.floor(time() * 5) & 1) << 1)
	end
	Goomba.super.draw(self, ...)
end
Goomba.update = |:| do
	if self.squashedTime then
		if time() > self.squashedTime then
			self.remove = true
		end
		return
	end
	if player then
		self.vel = (player.pos - self.pos):normalize()
	end
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
Player.update = |:|do

	self.vel.x = 0
	self.vel.y = 0
	-- hold y + dir to rotate camera
	if btn'y' then
		if btnp'left' then
			view.destYaw += 90
		elseif btnp'right' then
			view.destYaw -= 90
		end
	else
		if btn'up' then
			self.vel.x += -view.sinYaw * self.walkSpeed
			self.vel.y += view.cosYaw * self.walkSpeed
			self.angle = view.yaw + 90
			self.angle %= 360
		end
		if btn'down' then
			self.vel.x -= -view.sinYaw * self.walkSpeed
			self.vel.y -= view.cosYaw * self.walkSpeed
			self.angle = view.yaw - 90
			self.angle %= 360
		end
		if btn'left' then
			self.vel.x -= view.cosYaw * self.walkSpeed
			self.vel.y -= view.sinYaw * self.walkSpeed
			self.angle = view.yaw + 180
			self.angle %= 360
		end
		if btn'right' then
			self.vel.x += view.cosYaw * self.walkSpeed
			self.vel.y += view.sinYaw * self.walkSpeed
			self.angle = view.yaw
		end
	end

	-- test jump here before walking because walking clears onground flag for the sake of testing falling off ledges
	if self.onground and btnp'b' then
		self.jumpTime = time()
	end
	
	local newX = self.pos.x + self.vel.x * dt
	local newY = self.pos.y + self.vel.y * dt
	local newZ = self.pos.z	-- don't test jumping/falling yet...

	-- TODO what about falling vs walking?
	self.walking = self.vel.x ~= 0 or self.vel.y ~= 0

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
						if self.pos.z + self.size.z > z then
							self.pos.z = z - self.size.z
							self.vel.z = 0
							-- hit block
							local voxelInfo = voxelInfos[voxelType]
							if voxelInfo then
								voxelInfo:hitUnder(self.pos.x, self.pos.y, testZ)
							end
						end
					else	-- test top of blocks for falling on
						local z = testZ + 1 + epsilon
						if self.pos.z < z then
							self.pos.z = z
							self.vel.z = 0
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

local player = Player{
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


update=||do
	poke(ramaddr'HD2DFlags', HD2DFlags)
	cls(10)

	local width, height = getScreenSize()
	view:update(width, height, player)

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
	-- [[
	--poke(ramaddr'HD2DFlags', 2)	-- if you want the gui text to cast a shadow...
	matident(0)
	matident(1)
	matident(2)
	local textwidth = 32 * 8
	matortho(0, textwidth, textwidth * height / width, 0)
	text(tostring('coins x '..playerCoins), 0, 0, 12)
	--]]
end
