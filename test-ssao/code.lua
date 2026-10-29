--[[
this used to be just a copy of test-lightmaps with ssao enabled.
i think now instead I'll use it for testing multilpe hd2d flags rendered to the same frame using the flushHD2D() command ...
--]]
local matpush = require 'numo9.matstack'.push
local matpop = require 'numo9.matstack'.pop
local getAspectRatio = require 'numo9.screen'.getAspectRatio
local Lights = require 'numo9.lights'
local quat = require 'vec.quat'
local vec3 = require 'vec.vec3'

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

--mode(-1)	-- native res x RGB565
mode(0)	-- 256x256xRGB565
--mode(1)	-- 256x256x8bppIndex
--mode(2)	-- 256x256 rgb332

update = ||do
	poke(ramaddr'HD2DFlags', 0)
	cls(7)

	poke(ramaddr'HD2DFlags', HD2DFlags)
	cls(nil, true)	-- HD2DFlags + clear() == clear lighting gbuf

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

	Lights.MakeLight.znear = 1
	Lights.MakeLight.zfar = 100
	Lights.MakeLight.ambient:set(1,1,1)
	Lights.MakeLight.diffuse:set(1,1,1)
	Lights.MakeLight.specular:set(1,1,1)
	Lights.MakeLight.shininess = 10
	Lights.MakeLight.distAtten:set(1,0,0)
	Lights:beginFrame()
	--Lights:makeSunLight(10, vec3(0,0,0))
	Lights.makeSpotLight(0, 0, 5, 0, -90, 90, 0)

	mattrans(0, 0, -8, 1)			-- view transform
	do
		local x,y,z,th = quat.quat_toAngleAxis(angle:unpack())
		matrot(th,x,y,z, 1)	-- view transform
	end

	matscale(5, 5, 5)
	matpush()
	matscale(1/32768, 1/32768, 1/32768)

	--poke(ramaddr'cullFace', 2)	-- why is this messing up the ui even if i reset cullFace?
	mesh(1, 32, 0)	-- cube without z+
	--poke(ramaddr'cullFace', 1)
	matpop()

	Lights:endFrame()

	-- [[ flush will write back to framebuffer ...
	flushHD2D()

	poke(ramaddr'HD2DFlags', 0)	-- 0 flags = no lighting application at end-of-frame
	--]]
end
