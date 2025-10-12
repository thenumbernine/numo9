-- hmm only mode 0 is working for this .... why?
mode(0)
--mode(1)
--mode(2)
--mode(3)

local w = peekw(ramaddr'screenWidth')
local h = peekw(ramaddr'screenHeight')
trace('w, h', w, h)
-- [[
matident()
matident(1)
matident(2)
matortho(0, w, h, 0)
--]]

print'Hello NuMo9'

local spriteMem = blobaddr'sheet'
local tileMem = blobaddr('sheet', 1)
local mapMem = blobaddr'tilemap'
local palMem = blobaddr'palette'

-- [=[ fill our tiles with a gradient
for j=0,h-1 do
	for i=0,w-1 do
		poke(tileMem + (i|(j<<8)), (i+j)%240)
	end
end
--]=]
function update()
	local w = peekw(ramaddr'screenWidth')
	local h = peekw(ramaddr'screenHeight')

	-- every three seconds ...
	if time()%4>3 then
		-- shift the palette randomly
		for i=0,255 do
		--do local i=math.random(0,239)
			pokew(palMem+(i<<1),
				0x8000|math.random(0,0x7fff))
		end
	end

-- [=[ fill our map with random tiles

-- [[
	matident()
	matident(1)
	matident(2)
	matortho(0, w, h, 0)
--]]

	--[[ all?
	for j=0,31 do
		for i=0,31 do
	--]]
	-- [[ or just one?
	local i=math.random(0,31)
	local j=math.random(0,31)
	do do
	--]]
	--[[ or sequentially?
	ij = ij or 0
	ij+=1
	ij&=0x3ff
	local i,j = (ij&0x1f), ((ij>>5)&0x1f)
	do do
	--]]
			-- [[
			local addr = ((j<<8)|i)<<1
			pokew(mapMem+addr, math.random(0,0xffff))
			--]]
			--[[ should be equiv
			mset(i,j,math.random(0,0xffff))
			--]]
		end
	end
	map(0,0,32,32,0,0)
--]=]


	local x = 128
	local y = 128
	local t = time()
	local cx = math.cos(t)
	local cy = math.sin(t)
	local r = 50*math.cos(t/3)
	local x1=x-r*cx
	local x2=x+r*cx
	local y1=y-r*cy
	local y2=y+r*cy

	local f = ({
		elli, ellib, rect, rectb
	})[math.floor(time()%4)+1]
	f(x1,y1,x2-x1+1,y2-y1+1,
		math.floor(50 * t)
	)

-- [[
	matident()
	matident(1)
	matident(2)
	matortho(0, w, h, 0)

	mattrans(x2,y2)
	matrot(t, 0, 0, 1)
--]]	
	text(
		'HelloWorld', -- str
		0, 0,        -- x y
		13,-- fg
		0, -- bg
		1.5, 3 -- sx sy
	)
end

do return 42 end
