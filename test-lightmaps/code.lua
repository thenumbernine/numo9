-- TODO better test with multiple lights or something
-- move the uber-lightmap-region allocator over to include/ and have this make use of it too

--#include ext/range.lua
--#include numo9/matstack.lua

poke(ramaddr'useHardwareLighting', 0xff & ~4)	-- lightmaps without ssao
pokef(ramaddr'ssaoSampleRadius', .1)
mode(2)	-- 256x256 rgb332

local poly = |t, a| do
	local s = 0
	for i=#a,1,-1 do
		s *= t
		s += a[i]
	end
	return s
end

pokew(ramaddr'numLights', 1)			-- turn on 1 light
-- [[
pokef(ramaddr'lightAmbientColor', .5)	-- global ambient color
pokef(ramaddr'lightAmbientColor' + 4, .5)
pokef(ramaddr'lightAmbientColor' + 8, .5)
poke(ramaddr'lights', 0xff)	-- enable light #0
pokew(ramaddr'lights' + 2, 0)	-- lightmap region
pokew(ramaddr'lights' + 4, 0)
pokew(ramaddr'lights' + 6, peekw(ramaddr'lightmapWidth'))
pokew(ramaddr'lights' + 8, peekw(ramaddr'lightmapHeight'))
pokef(ramaddr'lights' + 0xc, 0)		-- ambient color
pokef(ramaddr'lights' + 0x10, 0)
pokef(ramaddr'lights' + 0x14, 0)
pokef(ramaddr'lights' + 0x18, 1)	-- diffuse color
pokef(ramaddr'lights' + 0x1c, 1)
pokef(ramaddr'lights' + 0x20, 1)
pokef(ramaddr'lights' + 0x24, 1)	-- specular color
pokef(ramaddr'lights' + 0x28, 1)
pokef(ramaddr'lights' + 0x2c, 1)
pokef(ramaddr'lights' + 0x30, 10)	-- specular highlight
pokef(ramaddr'lights' + 0x34, 1)	-- dist atten
pokef(ramaddr'lights' + 0x38, 0)
pokef(ramaddr'lights' + 0x3c, 0)
pokef(ramaddr'lights' + 0x40, -2)	-- angle atten
pokef(ramaddr'lights' + 0x44, -1)
--]]
local lightViewMatOffset = 0x48
local lightProjMatOffset = 0x88
local copied

local rects = range(100):mapi(|i| {
	rcoeff = range(3):mapi(|| math.random() + .1),
	thetacoeff = range(3):mapi(|| .1 * math.random() + .1),
	omegacoeff = range(3):mapi(|| .1 * math.random() + .1),
	color = math.random(0,255),
	update = |:, t|do
		local r = poly(math.cos(t), self.rcoeff)
		local theta = poly(math.sin(t), self.thetacoeff)
		local omega = poly(math.sin(t), self.omegacoeff)
		self.x = r * math.cos(t * omega) * math.sin(t * theta)
		self.y = r * math.sin(t * omega) * math.sin(t * theta)
		self.z = r * math.cos(t * theta)
		self.w = .1
		self.h = .1
	end,
})

update = ||do
	cls()
	matident(0)
	matident(1)
	matident(2)
	matfrustum(-.1, .1, -.1, .1, .1, 100)
	local t = time()
	--local cx, cy = math.cos(t), math.sin(t)
	mattrans(0, 0, -1, 1)		-- view transform
	matrot(.3 * t, 0, 1, 0, 1)	-- view transform

	if not copied then
		memcpy(ramaddr'lights' + lightViewMatOffset, ramaddr'viewMat', 64)
		memcpy(ramaddr'lights' + lightProjMatOffset, ramaddr'projMat', 64)
		copied = true
	end

	matpush()
	mattrans(-.5, -.5, 0)
	rect(0, 0, 1, 1, 12)	-- first render of the frame will capture the draw view matrix for lighting
	matpop()
	for _,r in ipairs(rects) do
		matpush()
		mattrans(r.x, r.y, r.z)
		r:update(t)
		rect(-.5*r.w, -.5*r.h, r.w, r.h, r.color)
		matpop()
	end
end

