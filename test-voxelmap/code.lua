--#include vec/vec3.lua
--#include numo9/matstack.lua	-- matpush, matpop
--#include numo9/screen.lua		-- getAspectRatio

-- TODO FIXME in mode-255 with lighting, you must reset the mode every frame or a resize will break shadowmaps.
-- once you fix that you can move the lighting pokes here into global scope init
mode(0xff)
poke(ramaddr'HD2DFlags', 0xff & ~4)
pokef(ramaddr'ssaoSampleRadius', .5)
pokew(ramaddr'numLights', 1)			-- turn on 1 light
poke(ramaddr'lights', 0xff)				-- enable light #0

-- 0 degrees = y+ is forward, x+ is right
local viewDestYaw = 90
local viewYaw = 90
local viewTiltUpAngle = -20
local dt = 1/60
local epsilon = 1e-7
local pos = vec3(2.5,2.5,1)
local vel = vec3()
local jumpTime = -1 
local onground = true
update=||do
	cls(10)
-- [[
	matident()
	matident(1)
	matident(2)
	local ar = getAspectRatio()
	local zn, zf = .01, 100
	matfrustum(-zn * ar, zn * ar, -zn, zn, zn, zf)	-- projection

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
	local viewX = pos.x - 5 * sinPitch * -sinYaw
	local viewY = pos.y - 5 * sinPitch * cosYaw
	local viewZ = pos.z + 5 * cosPitch
	mattrans(-viewX, -viewY, -viewZ, 1)	-- view = inverse-translate
--]]

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
		local stepHeight = .5 + epsilon
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
		local jumpDuration = .0334
		local jumpAccel = 10 * dt
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
				if vget(0,pos.x,pos.y,testZ) ~= 0xffffffff then
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
