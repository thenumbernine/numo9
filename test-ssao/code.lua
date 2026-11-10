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

local viewAngle = quat()
local lightOrbit = vec3(7, 0, 0)

-- TODO cullFace==2 affects ui

local HD2DFlags = 0
HD2DFlags |= 1	-- 1 = turn on light calcs
HD2DFlags |= 2	-- 1 = apply shadowmap (where?)
HD2DFlags |= 4	-- 4 = ssao
HD2DFlags |= 8	-- 8 = use bump map
HD2DFlags |= 16	-- 16 = use shadow in lighting
HD2DFlags |= 32	-- 32 = use amb diff spec in light color calcs
--HD2DFlags = 0xff				-- everything

pokef(ramaddr'ssaoSampleRadius', .1)

pokef(ramaddr'lightAmbientColor'+0, 0)
pokef(ramaddr'lightAmbientColor'+4, 0)
pokef(ramaddr'lightAmbientColor'+8, 0)

mode(0xff)	-- native res x RGB565
--mode(0)	-- 256x256xRGB565
--mode(1)	-- 256x256x8bppIndex
--mode(2)	-- 256x256 rgb332

update = ||do
	poke(ramaddr'HD2DFlags', 0)
	cls(7)
	poke(ramaddr'HD2DFlags', HD2DFlags)
	cls(nil, true)

	-- setup projection matrix

	local w, h = getScreenSize()
	local ar = w / h
	local zn, zf = 1, 100
	matident(projMatrixIndex)
	matfrustum(-ar * zn, ar * zn, -zn, zn, zn, zf)

	-- setup view matrix

	matident(viewMatrixIndex)

	local th = .05
	if btn'left' then
		--matrot(.1, 0, 1, 0)
		local x,y,z,w = quat.quat_fromAngleAxisUnit(-th, 0, 1, 0)
		viewAngle:set(quat.quat_mul(x,y,z,w, viewAngle:unpack()))
	end
	if btn'right' then
		--matrot(-.1, 0, 1, 0)
		local x,y,z,w = quat.quat_fromAngleAxisUnit(th, 0, 1, 0)
		viewAngle:set(quat.quat_mul(x,y,z,w, viewAngle:unpack()))
	end
	if btn'up' then
		local x,y,z,w = quat.quat_fromAngleAxisUnit(-th, 1, 0, 0)
		viewAngle:set(quat.quat_mul(x,y,z,w, viewAngle:unpack()))
		--matrot(.1, 1, 0, 0)
	end
	if btn'down' then
		--matrot(-.1, 1, 0, 0)
		local x,y,z,w = quat.quat_fromAngleAxisUnit(th, 1, 0, 0)
		viewAngle:set(quat.quat_mul(x,y,z,w, viewAngle:unpack()))
	end

	mattrans(0, 0, -12, viewMatrixIndex)

	do
		local lx = tonumber(int16_t(peekw(ramaddr'lastMousePos')))
		local ly = tonumber(int16_t(peekw(ramaddr'lastMousePos'+2)))
		local x = tonumber(int16_t(peekw(ramaddr'mousePos')))
		local y = tonumber(int16_t(peekw(ramaddr'mousePos'+2)))
		local dx = x - lx
		local dy = y - ly
		local d = math.sqrt(dx^2 + dy^2)
		if d > 0 then
			local q = quat(dy, dx, 0, math.rad(d)):fromAngleAxis()
			q = viewAngle:conj() * q * viewAngle
			q:rotate(lightOrbit, lightOrbit)
		end
	end

	local x,y,z,th = quat.quat_toAngleAxis(viewAngle:unpack())
	matrot(th,x,y,z, viewMatrixIndex)

	matident(modelMatrixIndex)	-- model

	Lights.MakePointCubeLight.lightCalcSides = 1	-- front only
	Lights.MakePointCubeLight.znear = .1
	Lights.MakePointCubeLight.zfar = 100
	Lights:beginFrame()

	Lights.makePointLight(lightOrbit:unpack())
	--Lights.makeSpotLight(lightOrbit.x, lightOrbit.y, lightOrbit.z, 0, 0, math.pi*.25, 0)

	for _,cube in ipairs{
		-- center
		--{pos=vec3(0,0,0), scale=vec3(5,5,5)},
		{pos=vec3(3,0,0), scale=vec3(1,1,1)},
		{pos=vec3(0,3,0), scale=vec3(1,1,1)},
		{pos=vec3(0,0,3), scale=vec3(1,1,1)},
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

	-- draw a box at the light too
	-- but disable casting-shadows
	poke(ramaddr'HD2DFlags', 0)
	matpush(modelMatrixIndex)
	mattrans(lightOrbit:unpack())
	matscale(1/32768, 1/32768, 1/32768)
	mesh(0, 16, 0)		-- cube
	matpop(modelMatrixIndex)
	poke(ramaddr'HD2DFlags', HD2DFlags)

	Lights:endFrame()
--pokew(ramaddr'numLights', 1)

	--[[ flush will write back to framebuffer ...
	flushHD2D()

	poke(ramaddr'HD2DFlags', 0)	-- 0 flags = no lighting application at end-of-frame
	--]]
	--poke(ramaddr'HD2DFlags', HD2DFlags)
	--poke(ramaddr'HD2DFlags', 0xff)
	--poke(ramaddr'HD2DFlags', 0)
	--cls(nil, true)	-- HD2DFlags + clear() == clear lighting gbuf


--	flushHD2D()
--	poke(ramaddr'HD2DFlags', 0)
--	cls(nil, true)
end
