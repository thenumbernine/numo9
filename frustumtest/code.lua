-- custom megaman mario kart sprite from : https://www.spriters-resource.com/fullview/23197/

local ram=app.ram
local matstack=table()
local matpush=[]do
	local t={}
	for i=0,15 do
		t[i+1] = ram.mvMat[i]
	end
	matstack:insert(t)
end
local matpop=[]do
	local t = matstack:remove(1)
	if not t then return end
	for i=0,15 do
		ram.mvMat[i]=t[i+1]
	end
end

-- divided into 180'.  flip the sprite to get the other 180'
local angleForIndex = {
	0, 4, 8, 12,
	128+0, 128+4, 128+8, 128+12,
	256+0, 256+4, 256+8, 256+12,
}

posx=10
posy=10
angle=0
update=[]do
	cls()
	local zn, zf = 1, 100
	local zo = 10
	local fwdx = math.cos(angle)
	local fwdy = math.sin(angle)
	matident()
	
	--[[ ortho
	matortho(-zo,zo,-zo,zo)
	--]]
	-- [[ frustum
	--projection
	matfrustum(-zn, zn, -zn, zn, zn, zf)
	
	-- [=[ using explicit inverse rotate/translate
	-- inverse-rotate
		-- rot on x axis so now x+ is right and y+ is forward
	matrot(math.rad(60), 1, 0, 0)	
		-- inv-rot by our angle around
		-- add an extra rot of 90' on z axis to put x+ forward.  now we can use exp(i*angle) for our forward vector.
	matrot(-(angle + .5*math.pi), 0, 0, 1)
	-- inverse-translate
	mattrans(-posx,-posy,-3)
	--]=]
	--[=[ using matlookat
	matlookat(
		posx, posy, 3,
		posx + fwdx, posy + fwdy, 0,	-- TODO pick a 60' slope to match above
		0, 0, 1
	)
	--]=]
	-- modelspace translate
	-- modelspace rotate
	--]]
	
	--[[ should be centered in [-10,10]^2 ortho or in FOV=45' at z=10 frustum
	ellib(-5,-5,10,10,0xfc)
	rectb(-5,-5,10,10,0xfc)
	--]]
	--[[ equivalent using matrix transforms (i.e. how to use map() with matrix transforms)
	-- mind you this is just 10 "pixels", while map() is gonna draw 8*size or 16*size "pixels"
	mattrans(-40,-40)
	rectb(0,0,80,80,0xfc)
	--[[
	local x = math.cos(time()) * 10
	local y = math.sin(time()) * 10
	rectb(x-.5,y-.5,1,1,0xfc)
	--]]
	-- [[ map
	local mapsize=21
	matpush()
	matscale(1/16,1/16,1/16)
	map(0,0,mapsize,mapsize,0,0,nil,true)
	matpop()
	--]]
	--[[
	-- scale-up to equate with map() or spr() calls
	local s=10
	mattrans(-s*16,-s*16,0)
	for j=0,2*s+1 do
		for i=0,2*s+1 do
			ellib(i*16, j*16, 16, 16, 0xfc)
		end
	end
	--]]

	-- [[ draw bilboard sprite
	matpush()
	mattrans(13,10,0)
	matscale(1/32,1/32,1/32)

	-- undo camera angle to make a billboard
	matrot(angle + .5 * math.pi, 0, 0, 1)
	matrot(math.rad(-60), 1, 0, 0)
	-- recenter

	local angleNorm = (-angle / math.pi) % 2
	local scaleX = 1
	if angleNorm > 1 then
		angleNorm = 2 - angleNorm
		scaleX = -1
		mattrans(16, -32, 0)
	else
		mattrans(-16, -32, 0)
	end
	local spriteIndex = angleForIndex[math.floor(angleNorm * #angleForIndex) + 1]
	spr(spriteIndex, 0, 0, 4, 4, nil, nil, nil, nil, scaleX)
	matpop()
	--]]

	local spd = .2
	local rot = .03
	if btn(0) then
		posx += spd * fwdx
		posy += spd * fwdy
	end
	if btn(1) then
		posx -= spd * fwdx
		posy -= spd * fwdy
	end
	if btn(2) then
		angle-=rot
	end
	if btn(3) then
		angle+=rot
	end
end
