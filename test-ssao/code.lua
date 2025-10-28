--#include ext/range.lua
--#include numo9/matstack.lua

poke(ramaddr'useHardwareLighting', 1|4)	-- 1 = turn on light calcs, 4 = ssao calcs
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
