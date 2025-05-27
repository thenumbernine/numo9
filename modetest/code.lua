--mode(0)
--mode(1)
--mode(2)
--mode(36)
-- TODO bug in ellipse drawing x's

-- i could store resolution in the RAM, but nah, just rtfm
local resolutions = {
	[0] = {256, 256},
	{272, 217},
	{288, 216},
	{304, 202},
	{320, 200},
	{320, 192},
	{336, 189},
	{336, 177},
	{352, 176},
	{384, 164},
}

update=||do
	cls()
	t=time()

	local m = tonumber((t % (3 * (#resolutions+1))) // 1)
	mode(m)
	local w, h = table.unpack(resolutions[tonumber(m // 3)])

	local x1, y1 = 
		w * (math.cos(t * .4) * .5 + .5),
		h * (math.sin(t * .5) * .5 + .5)
	local x2, y2 = 
		w * (math.cos(t * .6) * .5 + .5),
		h * (math.sin(t * .7) * .5 + .5)
	local xmin = math.min(x1, x2)
    local ymin = math.min(y1, y2)
	--ellib(	TODO bugs in ellipse border when not a circle
	elli(
		xmin,
		ymin,
		math.max(x1, x2) - xmin,
		math.max(y1, y2) - ymin,
		t * 3)

	local xmid = .5 * (x1 + x2)
	local ymid = .5 * (y1 + y2)
	
	local w, h = text('mode '..m, -999, -999)
	mattrans(xmid, ymid)
	matrot(t)
	mattrans(- .5 * w, - 4)
	text('mode '..m)
	matident()
end
