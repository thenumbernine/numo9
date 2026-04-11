-- TODO better test with multiple lights or something
-- move the uber-lightmap-region allocator over to include/ and have this make use of it too

--#include ext/range.lua
--#include numo9/matstack.lua
--#include numo9/lights.lua

poke(ramaddr'HD2DFlags', 0xff & ~4)	-- lightmaps without ssao
pokef(ramaddr'ssaoSampleRadius', .1)
mode(2)	-- 256x256 rgb332
--mode(0)
--mode(255)

local poly = |t, a| do
	local s = 0
	for i=#a,1,-1 do
		s *= t
		s += a[i]
	end
	return s
end

pokef(ramaddr'lightAmbientColor', .5)	-- global ambient color
pokef(ramaddr'lightAmbientColor' + 4, .5)
pokef(ramaddr'lightAmbientColor' + 8, .5)

pokew(ramaddr'numLights', 1)			-- turn on 1 light
Lights:beginFrame()
Lights.MakeSpotLight.ambient:set(0,0,0)
Lights.MakeSpotLight.diffuse:set(1,1,1)
Lights.MakeSpotLight.specular:set(1,1,1)
Lights.MakeSpotLight.shininess = 10
Lights.MakeSpotLight.distAtten:set(1,0,0)
Lights.makeSpotLight(
	0,0,0,	-- x,y,z
	0,-90,	-- yaw, pitch
	math.pi, math.pi	-- outer angle, inner angle
)
pokew(ramaddr'lights' + 2, 0)	-- lightmap region: use the full lightmap
pokew(ramaddr'lights' + 4, 0)
pokew(ramaddr'lights' + 6, peekw(ramaddr'lightmapWidth'))
pokew(ramaddr'lights' + 8, peekw(ramaddr'lightmapHeight'))
pokef(ramaddr'lights' + 0x40, -2)	-- angle atten
pokef(ramaddr'lights' + 0x44, -1)
Lights:endFrame()

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

local lightInitialized

update = ||do
	cls()
	matident(modelMatrixIndex)
	matident(viewMatrixIndex)
	matident(projMatrixIndex)
	matfrustum(-.1, .1, -.1, .1, .1, 100)
	local t = time()
	--local cx, cy = math.cos(t), math.sin(t)
	
	-- TODO I could use the makeSpotLight info here but its using a dif Euler-angle basis
	-- which means I should change it to not evne force the makeSpotLight call to accept xyz or orientation at all...
	mattrans(0, 0, -1, viewMatrixIndex)		-- view transform
	matrot(.3 * t, 0, 1, 0, viewMatrixIndex)	-- view transform

	if not lightInitialized then

		memcpy(ramaddr'lights' + Lights.lightViewMatOffset, ramaddr'viewMat', 64)
		memcpy(ramaddr'lights' + Lights.lightProjMatOffset, ramaddr'projMat', 64)

		lightInitialized = true
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
