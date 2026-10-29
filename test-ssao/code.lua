--[[
this used to be just a copy of test-lightmaps with ssao enabled.
i think now instead I'll use it for testing multilpe hd2d flags rendered to the same frame using the flushHD2D() command ...
--]]
local range = require 'ext.range'
local matpush = require 'numo9.matstack'.push
local matpop = require 'numo9.matstack'.pop

poke(ramaddr'HD2DFlags', 1|4)	-- 1 = turn on light calcs, 4 = ssao calcs
pokef(ramaddr'ssaoSampleRadius', .1)
mode(-1)	-- native res x RGB565 works
--mode(0)	-- 256x256xRGB565 works
--mode(1)	-- 256x256x8bppIndex works
--mode(2)	-- 256x256 rgb332 works

update = ||do
	cls()
	matident(0)
	matident(1)
	matident(2)
	matfrustum(-.1, .1, -.1, .1, .1, 100)
	local t = time()
	--local cx, cy = math.cos(t), math.sin(t)
	mattrans(0, 0, -1, 1)		-- view transform
	matrot(.3 * 2/3, 0, 1, 0, 1)	-- view transform

	matpush()
	mattrans(-.5, -.5, 0)
	rect(0, 0, 1, 1, 12)	-- first render of the frame will capture the draw view matrix for lighting
	matpop()
end
