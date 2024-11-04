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

local range=[a,b,c]do
	local t = table()
	if c then
		for x=a,b,c do t:insert(x) end
	elseif b then
		for x=a,b do t:insert(x) end
	else
		for x=1,a do t:insert(x) end
	end
	return t
end


-- divided into 180'.  flip the sprite to get the other 180'
local spriteIndexForAngle = {
	0, 4, 8, 12,
	128+0, 128+4, 128+8, 128+12,
	256+0, 256+4, 256+8, 256+12,
}

local karts = table()
for i=1,10 do
	karts:insert{
		x = math.random()*20,
		y = math.random()*20,
		angle = math.random()*math.pi*2,
	}
end
local player = karts[1]
player.x = 0
player.y = 0
player.angle = 0
viewAngle=0

-- true = y+ goes on the left, and the tilemap looks like it does in the editor
-- false = y+ goes on the right, and the tilemap looks flipped
spaceRHS=true

update=[]do
	cls()
	local zn, zf = 1, 100
	local zo = 10
	local viewDist = 2
	local viewAlt = 2

	local viewAngle = player.angle
	local fwdx = math.cos(viewAngle)
	local fwdy = math.sin(viewAngle)
	local viewX = player.x - viewDist * fwdx
	local viewY = player.y - viewDist * fwdy
	local viewZ = viewAlt

	matident()
	--[[ ortho
	matortho(-zo,zo,-zo,zo)
	--]]
	-- [==[ frustum
	--projection
	matfrustum(-zn, zn, -zn, zn, zn, zf)
	-- go from lhs to rhs coord system (??) since usu x+ is right and y+ is *DOWN* ... maybe I should be putting this in matfrustum?
	-- this is to match opengl convention, but I don't think I'll move it into the numo9 API since I want frustum to match the numo9 y+ down 90s-console convention
	if spaceRHS then
		matscale(-1, 1, 1)
	end

--[[
8388608, 0, 0, 8388608
0, 8388608, 0, 8388608
0, 0, -66859, -132395
0, 0, -65536, 0
--]]

	local tiltUpAngle = 70
	--[=[ using explicit inverse rotate/translate
	-- inverse-rotate
		-- rot on x axis so now x+ is right and y+ is forward
		-- by default the view is looking along the z axis , and I'm using XY as my drawing coordinates (cuz that's what the map() and spr() use), so Z is up/down by the renderer.
		-- so I have to tilt up to look along the Y+ plane
	matrot(math.rad(tiltUpAngle), 1, 0, 0)
		-- inv-rot by our viewAngle around
		-- add an extra rot of 90' on z axis to put x+ forward.  now we can use exp(i*viewAngle) for our forward vector.
	matrot(-(viewAngle + .5*math.pi), 0, 0, 1)
	-- inverse-translate
	mattrans(-viewX, -viewY, -viewZ)
--[[
tilUpAngle = 70:
0, -8388608, 0, 8388608
-2869073, 0, -7882713, 18415888
62826, 0, -22867, 38991
61583, 0, -22414, 167994

tiltUpAngle = 90:
0, -8388608, 0, 8388608
0, 0, -8388608, 25165824
66859, 0, 0, 1323
65536, 0, 0, 131072
--]]
	--]=]
	-- [=[ using matlookat
	matlookat(
		viewX, viewY, viewZ,
		viewX + fwdx * math.sin(math.rad(tiltUpAngle)),
			viewY + fwdy * math.sin(math.rad(tiltUpAngle)),
			viewZ - math.cos(math.rad(tiltUpAngle)),	-- TODO pick a 60' slope to match above
		0, 0, 1
	)
--[[[
tiltUpAngle = 70:
0, -8388608, 0, 8388608
-2869073, 0, -7882713, 18415888
62826, 0, -22867, 38993
61583, 0, -22414, 167996

tiltUpAngle = 90:
0, -8388608, 0, 8388608
0, 0, -8388608, 25165824
66859, 0, 0, 1323
65536, 0, 0, 131072
--]]

	--]=]
	-- then per-model:
	-- modelspace translate
	-- modelspace rotate
	--]==]

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
	local depths = karts:mapi([kart]((kart.x - viewX) * fwdx + (kart.y - viewY) * fwdy))
	local order = range(#karts):sort([a,b] depths[a] > depths[b])
	for _,i in ipairs(order) do
		local kart = karts[i]
		matpush()
		mattrans(kart.x,kart.y, 0)
		matscale(1/32,1/32,1/32)

		-- undo camera viewAngle to make a billboard
		matrot(viewAngle + .5 * math.pi, 0, 0, 1)
		matrot(math.rad(-60), 1, 0, 0)
		-- recenter

		local angleNorm = (-(viewAngle - kart.angle) / math.pi) % 2
		local scaleX = 1
		if angleNorm > 1 then
			angleNorm = 2 - angleNorm
			scaleX = -1
			mattrans(16, -32, 0)
		else
			mattrans(-16, -32, 0)
		end
		local spriteIndex = spriteIndexForAngle[math.floor(angleNorm * #spriteIndexForAngle) + 1]
		spr(spriteIndex, 0, 0, 4, 4, nil, nil, nil, nil, scaleX)
		matpop()
	end
	--]]

	local spd = .2
	local rot = spaceRHS and .03 or -.03
	if btn(0) then
		player.x += spd * fwdx
		player.y += spd * fwdy
	end
	if btn(1) then
		player.x -= spd * fwdx
		player.y -= spd * fwdy
	end
	if btn(2) then
		player.angle+=rot
	end
	if btn(3) then
		player.angle-=rot
	end
end
