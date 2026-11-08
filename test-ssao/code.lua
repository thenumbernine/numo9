--[[
this used to be just a copy of test-lightmaps with ssao enabled.
i think now instead I'll use it for testing multilpe hd2d flags rendered to the same frame using the flushHD2D() command ...
--]]
local matpush = require 'numo9.matstack'.push
local matpop = require 'numo9.matstack'.pop
local getScreenSize = require 'numo9.screen'.getScreenSize
local getAspectRatio = require 'numo9.screen'.getAspectRatio
local Lights = require 'numo9.lights'
local quat = require 'vec.quat'
local vec3 = require 'vec.vec3'

local modelMatrixIndex = require 'numo9.matstack'.modelMatrixIndex
local viewMatrixIndex = require 'numo9.matstack'.viewMatrixIndex
local projMatrixIndex = require 'numo9.matstack'.projMatrixIndex

local angle = quat()

-- TODO cullFace==2 affects ui

local HD2DFlags = 0
HD2DFlags |= 1	-- 1 = turn on light calcs
HD2DFlags |= 2	-- 1 = apply shadowmap (where?)
--HD2DFlags |= 4	-- 4 = ssao
HD2DFlags |= 8	-- 8 = use bump map
HD2DFlags |= 16	-- 16 = use shadow in lighting
HD2DFlags |= 32	-- 32 = use amb diff spec in light color calcs

pokef(ramaddr'ssaoSampleRadius', .1)

pokef(ramaddr'lightAmbientColor'+0, 0)
pokef(ramaddr'lightAmbientColor'+4, 0)
pokef(ramaddr'lightAmbientColor'+8, 0)

mode(0xff)	-- native res x RGB565
--mode(0)	-- 256x256xRGB565
--mode(1)	-- 256x256x8bppIndex
--mode(2)	-- 256x256 rgb332

update = ||do
	poke(ramaddr'HD2DFlags', HD2DFlags)
	cls(7)	-- HD2DFlags + clear() == clear lighting gbuf

	matident(0)	-- model
	matident(1)	-- view
	matident(2)	-- proj

	local ar = getAspectRatio()

	local zn, zf = 1, 100
	matfrustum(-ar * zn, ar * zn, -zn, zn, zn, zf)	-- proj transform

	local th = .05
	if btn'left' then
		--matrot(.1, 0, 1, 0)
		local x,y,z,w = quat.quat_fromAngleAxis(-th, 0, 1, 0)
		angle:set(quat.quat_mul(x,y,z,w, angle:unpack()))
	end
	if btn'right' then
		--matrot(-.1, 0, 1, 0)
		local x,y,z,w = quat.quat_fromAngleAxis(th, 0, 1, 0)
		angle:set(quat.quat_mul(x,y,z,w, angle:unpack()))
	end
	if btn'up' then
		local x,y,z,w = quat.quat_fromAngleAxis(-th, 1, 0, 0)
		angle:set(quat.quat_mul(x,y,z,w, angle:unpack()))
		--matrot(.1, 1, 0, 0)
	end
	if btn'down' then
		--matrot(-.1, 1, 0, 0)
		local x,y,z,w = quat.quat_fromAngleAxis(th, 1, 0, 0)
		angle:set(quat.quat_mul(x,y,z,w, angle:unpack()))
	end

	-- init view matrix before lights
	mattrans(0, 0, -12, viewMatrixIndex)

	local w, h = getScreenSize()
	local lightPosX = 6 * (tonumber(int16_t(peekw(ramaddr'mousePos')))/w*2-1)
	local lightPosY = -6 * (tonumber(int16_t(peekw(ramaddr'mousePos'+2)))/h*2-1)
	local lightPosZ = 6


	if true then
		Lights:beginFrame()

		-- [==[
		-- set up a torch point light at the player
		-- TODO lightmap block allocation system ...
		local lightAddr, lx, ly, lw, lh = Lights:new(1024, 1024) --2048, 2048)

		-- subimage/viewport on the lightmap
		poke(lightAddr + Lights.lightEnabledOffset, 0xff)		-- light is enabled for depth-write and for surface-calculations
		pokew(lightAddr + Lights.lightRegionOffset, lx)
		pokew(lightAddr + Lights.lightRegionOffset+2, ly)
		pokew(lightAddr + Lights.lightRegionOffset+4, lw)
		pokew(lightAddr + Lights.lightRegionOffset+6, lh)
		pokef(lightAddr + Lights.lightAmbientColorOffset, .1)
		pokef(lightAddr + Lights.lightAmbientColorOffset+4, .1)
		pokef(lightAddr + Lights.lightAmbientColorOffset+8, .1)
		pokef(lightAddr + Lights.lightDiffuseColorOffset, .6)
		pokef(lightAddr + Lights.lightDiffuseColorOffset+4, .5)
		pokef(lightAddr + Lights.lightDiffuseColorOffset+8, .4)
		pokef(lightAddr + Lights.lightSpecularColorOffset, 1)
		pokef(lightAddr + Lights.lightSpecularColorOffset+4, 1)
		pokef(lightAddr + Lights.lightSpecularColorOffset+8, 1)
		pokef(lightAddr + Lights.lightSpecularColorOffset+12, 40)
		pokef(lightAddr + Lights.lightDistAttenOffset, 1)
		pokef(lightAddr + Lights.lightDistAttenOffset+4, 0)
		pokef(lightAddr + Lights.lightDistAttenOffset+8, 0)

		local spotOuterAngle = 45
		local spotInnerAngle = 0
		local tanHalfFOV = math.tan(math.rad(spotOuterAngle))
		local znear, zfar = .1, 20	-- light znear/zfar

		pokef(lightAddr + Lights.lightCosAngleRangeOffset, math.cos(math.rad(spotOuterAngle)))
		pokef(lightAddr + Lights.lightCosAngleRangeOffset+4, math.cos(math.rad(spotInnerAngle)))

		-- TODO using mat for our light math causes tri buf flushes and mat dirty bit flags ... meh?
		matpush(projMatrixIndex)
		matpush(viewMatrixIndex)	-- push the view mat

		matident(projMatrixIndex)

		matfrustum(
			-tanHalfFOV * znear,
			tanHalfFOV * znear,
			-tanHalfFOV * znear,
			tanHalfFOV * znear,
			znear, zfar)	-- projMatrixIndex by default

		matident(viewMatrixIndex)

		mattrans(-lightPosX, -lightPosY, -lightPosZ, viewMatrixIndex)

		memcpy(lightAddr + Lights.lightViewMatOffset, ramaddr'viewMat', 64)	-- matrix #1
		memcpy(lightAddr + Lights.lightProjMatOffset, ramaddr'projMat', 64)	-- matrix #2

		matpop(viewMatrixIndex)
		matpop(projMatrixIndex)
		--]==]
		--[==[
		Lights.makePointLight(lightPosX, lightPosY, lightPosZ)
		--]==]
	end

	matpush(modelMatrixIndex)

	local x,y,z,th = quat.quat_toAngleAxis(angle:unpack())
	matrot(th,x,y,z)

	for _,cube in ipairs{
		-- center
		{pos=vec3(0,0,0), scale=vec3(5,5,5)},
		-- walls
		--{pos=vec3(8,0,0), scale=vec3(.5,16,16)},
		{pos=vec3(-8,0,0), scale=vec3(.5,16,16)},
		{pos=vec3(0,8,0), scale=vec3(16,.5,16)},
		{pos=vec3(0,-8,0), scale=vec3(16,.5,16)},
		--{pos=vec3(0,0,8), scale=vec3(16,16,.5)},
		{pos=vec3(0,0,-8), scale=vec3(16,16,.5)},
	} do
		matpush(modelMatrixIndex)
		mattrans(cube.pos:unpack())
		matscale(cube.scale:unpack())

		--poke(ramaddr'cullFace', 2)	-- why is this messing up the ui even if i reset cullFace?
		--mesh(1, 16, 0)	-- cube without z+
		matscale(1/32768, 1/32768, 1/32768)
		mesh(0, 16, 0)		-- cube
		--poke(ramaddr'cullFace', 1)
		matpop(modelMatrixIndex)
	end

	matpop(modelMatrixIndex)

	-- draw a box at the light too
	matpush(modelMatrixIndex)
	mattrans(lightPosX, lightPosY, lightPosZ)
	matscale(1/32768, 1/32768, 1/32768)
	mesh(0, 16, 0)		-- cube
	matpop(modelMatrixIndex)

	if true then
		Lights:endFrame()
	end

	--[[ flush will write back to framebuffer ...
	flushHD2D()

	poke(ramaddr'HD2DFlags', 0)	-- 0 flags = no lighting application at end-of-frame
	--]]
	--poke(ramaddr'HD2DFlags', HD2DFlags)
	--poke(ramaddr'HD2DFlags', 0xff)
	--poke(ramaddr'HD2DFlags', 0)
	--cls(nil, true)	-- HD2DFlags + clear() == clear lighting gbuf
end
