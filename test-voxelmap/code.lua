--#include vec/vec3.lua
--#include numo9/matstack.lua	-- matpush, matpop
--#include numo9/screen.lua		-- getAspectRatio

local coins = 0

local voxelTypeEmpty = 0xffffffff
local voxelTypeBricks = 0x42
local voxelTypeQuestionHit= 0x48
local voxelTypeQuestionCoin = 0x44
local voxelTypeQuestionMushroom = 0x84
local voxelTypeQuestionVine = 0xc4

local voxelInfos = {
	[voxelTypeBricks] = {
		hitUnder = |:, x,y,z|do
			-- TODO particles
			vset(0, x, y, z, voxelTypeEmpty)
		end,
	},
	[voxelTypeQuestionCoin] = {
		hitUnder = |:, x,y,z|do
			vset(0, x, y, z, voxelTypeQuestionHit)
			coins += 1
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
}

--mode(0xff)	-- NativexRGB565
mode(43)	-- 480x270xRGB332
--mode(18)	-- 336x189xRGB565
local HD2DFlags = 0xff  & ~4	-- turn off SSAO. meh.
pokef(ramaddr'ssaoSampleRadius', .5)
pokew(ramaddr'numLights', 1)			-- turn on 1 light
poke(ramaddr'lights', 0xff)				-- enable light #0

-- 0 degrees = y+ is forward, x+ is right
local viewDestYaw = 90
local viewYaw = 90
local viewTiltUpAngle = -20
local viewFollowDist = 7

local dt = 1/60
local epsilon = 1e-7
local pos = vec3(2.5, 2.5, 1)
local size = vec3(1, 1, 1)
local vel = vec3()
local jumpTime = -1
local onground = true
update=||do
	poke(ramaddr'HD2DFlags', HD2DFlags)
	cls(10)

	-- setup proj matrix
	matident(2)
	local width, height = getScreenSize()
	local ar = width / height
	local zn, zf = .01, 100
	matfrustum(-zn * ar, zn * ar, -zn, zn, zn, zf)	-- projection

	-- setup view matrix
	matident(1)
	local deltaAngle = viewDestYaw - viewYaw
	if math.abs(deltaAngle) > 1 then
		viewYaw += .1 * deltaAngle
	else
		viewDestYaw %= 360
		viewYaw = viewDestYaw
	end

	local viewPitchRad = math.rad(90 + viewTiltUpAngle)	-- 90 = up to horizon
	local cosPitch = math.cos(viewPitchRad)
	local sinPitch = math.sin(viewPitchRad)
	matrotcs(cosPitch, sinPitch, -1, 0, 0, 1)	-- view pitch = inverse-rotate x-axis
	local viewYawRad = math.rad(viewYaw - 90)
	local cosYaw = math.cos(viewYawRad)
	local sinYaw = math.sin(viewYawRad)
	matrotcs(cosYaw, sinYaw, 0, 0, -1, 1)	-- view yaw = inverse-rotate negative-z-axis
	local viewX = pos.x - viewFollowDist * sinPitch * -sinYaw
	local viewY = pos.y - viewFollowDist * sinPitch * cosYaw
	local viewZ = pos.z + viewFollowDist * cosPitch
	mattrans(-viewX, -viewY, -viewZ, 1)	-- view = inverse-translate

	matident()
	voxelmap()

	matpush()
	mattrans(pos.x, pos.y, pos.z)
	matrotcs(cosYaw, sinYaw, 0, 0, 1)
	matrotcs(0, 1, 1, 0, 0)
	matscale(1/16, -1/16, 1/16)
	spr(2, -8, -16, 2, 2)
	matpop()

	local walking
	local walkSpeed = 7 * dt
	local newX, newY, newZ = pos:unpack()
	-- hold y + dir to rotate camera
	if btn'y' then
		if btnp'left' then
			viewDestYaw += 90
		elseif btnp'right' then
			viewDestYaw -= 90
		end
	else
		if btn'up' then
			newX += -sinYaw * walkSpeed
			newY += cosYaw * walkSpeed
			walking = true
		end
		if btn'down' then
			newX -= -sinYaw * walkSpeed
			newY -= cosYaw * walkSpeed
			walking = true
		end
		if btn'left' then
			newX -= cosYaw * walkSpeed
			newY -= sinYaw * walkSpeed
			walking = true
		end
		if btn'right' then
			newX += cosYaw * walkSpeed
			newY += sinYaw * walkSpeed
			walking = true
		end
	end
	-- test jump here before walking because walking clears onground flag for the sake of testing falling off ledges
	if onground and btnp'b' then
		jumpTime = time()
	end
	if walking then
		local stepHeight = .25 + epsilon
		local hitXY, hitZ
		local inewZ = math.floor(newZ)
		for testZ=inewZ-1,inewZ+1 do
			if vget(0, newX, newY, testZ) ~= 0xffffffff then
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
			pos:set(newX, newY, newZ)
		else
			pos:set(newX, newY, newZ)
		end
		onground = false
	end
	if jumpTime then
		local jumpDuration = .1
		local jumpAccel = 6.5 * dt
		if time() < jumpTime + jumpDuration and btn'b' then
			onground = false
			vel.z += jumpAccel
		else
			jumpTime = nil
		end
	end

	if not onground then
		local grav = -2 * dt
		vel.z += grav
		pos.z += vel.z
		if pos.z < 0 then
			pos.z = 0
			vel.z = 0
			onground = true
		else
			local inewZ = math.floor(pos.z)
			for testZ = inewZ-1, inewZ+1 do
				local voxelType = vget(0,pos.x,pos.y,testZ)
				if voxelType ~= voxelTypeEmpty then
					if testZ > pos.z and vel.z > 0 then	-- test bottom of blocks for hitting underneath
						local z = testZ - epsilon
						if pos.z + size.z > z then
							pos.z = z - size.z
							vel.z = 0
							-- hit block
							local voxelInfo = voxelInfos[voxelType]
							if voxelInfo then
								voxelInfo:hitUnder(pos.x, pos.y, testZ)
							end
						end
					else	-- test top of blocks for falling on
						local z = testZ + 1 + epsilon
						if pos.z < z then
							pos.z = z
							vel.z = 0
							onground = true
						end
					end
				end
			end
		end
	end

	-- end-of-frame, after view has been captured, do ortho and draw text
	-- but disable light flags before clearing depth or else it'll clear the light depth too
	poke(ramaddr'HD2DFlags', 0)
	cls(nil, true)
	-- [[
	matident(0)
	matident(1)
	matident(2)
	local textwidth = 32 * 8
	matortho(0, textwidth, textwidth * height / width, 0)
	text(tostring('coins x '..coins), 0, 0, 12)
	--]]
end
