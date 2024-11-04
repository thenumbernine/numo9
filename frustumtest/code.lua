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

posx=10
posy=10
angle=0
update=[]do
	cls()
	local zn, zf = 1, 100
	local zo = 10
	matident()
	
	--[[ ortho
	matortho(-zo,zo,-zo,zo)
	--]]
	-- [[ frustum
	--projection
	matfrustum(-zn, zn, -zn, zn, zn, zf)
	-- inverse-rotate
	matrot(math.rad(60), 1, 0, 0)
	matrot(-angle, 0, 0, 1)
	-- inverse-translate
	mattrans(-posx,-posy,-3)
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
	mattrans(10,5,0)
	matscale(1/16,1/16,1/16)
	
	-- undo camera angle to make a billboard
	matrot(angle, 0, 0, 1)
	matrot(math.rad(-60), 1, 0, 0)
	-- recenter
	mattrans(-12, -24, 0)

	spr(0,0,0,3,3,nil,nil,nil,nil,nil,nil)
	matpop()
	--]]

	local spd = .2
	local rot = .03
	if btn(0) then
		posy -= spd * math.cos(angle)
		posx -= spd * -math.sin(angle)
	end
	if btn(1) then
		posy += spd * math.cos(angle)
		posx += spd * -math.sin(angle)
	end
	if btn(2) then
		angle-=rot
	end
	if btn(3) then
		angle+=rot
	end
end
