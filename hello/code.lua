-- title = Hello World
-- saveid = hello
-- author = Chris Moore
-- description = Hello World

--mode(0)		-- 256x256xRGB565 will work to shift palette colors of the full screen tilemap() draws, but will not shift colors of spr()'s already drawn.
mode(1)			-- 256x256x8bppIndex will shift the palette colors of the spr() draws already in the framebuffer
--mode(2)		-- 256x256xxRGB332 works like mode 0 but with dithering

local w = peekw(ramaddr'screenWidth')
local h = peekw(ramaddr'screenHeight')

print'Hello NuMo9'

local sheetMem = blobaddr'sheet'
local tilemapMem = blobaddr'tilemap'
local paletteMem = blobaddr'palette'

-- [=[ fill our tiles with a gradient
for j=0,h-1 do
	for i=0,w-1 do
		poke(sheetMem + (i|(j<<8)), (i+j)%240)
	end
end
--]=]
function update()
	local w = peekw(ramaddr'screenWidth')
	local h = peekw(ramaddr'screenHeight')

	-- [[ every three seconds shift the palette randomly
	-- this will still appear to shift everything in 565 due to tilemap() being called every frame
	if time()%4>3 then
		for i=0,255 do
		--do local i=math.random(0,239)
			pokew(paletteMem+(i<<1),
				0x8000|math.random(0,0x7fff))
		end
	end
	--]]

-- [=[ fill our map with random tiles

	--[[ all?
	for j=0,31 do
		for i=0,31 do
	--]]
	-- [[ or just one?
	local i=math.random(0,31)
	local j=math.random(0,31)

	if math.floor(time()) & 1 == 1 then
		-- just clutter the framebuffer
		spr(
			math.random(0, 0x3ff),
			math.random(0, 0xff),
			math.random(0, 0xff),
			1, 1,
			math.random(0,7),
			1, 1,
			math.random(0, 0xff)
		)
	else
		do do
		--]]
		--[[ or sequentially?
		ij = ij or 0
		ij+=1
		ij&=0x3ff
		local i,j = (ij&0x1f), ((ij>>5)&0x1f)
		do do
		--]]
				-- [[ poke tilemap
				local addr = ((j<<8)|i)<<1
				pokew(tilemapMem+addr, math.random(0,0xffff))
				--]]
				--[[ should be equiv
				mset(i,j,math.random(0,0xffff))
				--]]

				-- notice poking and redrawing the tilemap should be fine in 565 for reflecting palette changes
				-- but poking the palette can only be demonstrated if I'm not redrawing everything every frame
			end
		end
		-- redraw tilemap
		tilemap(0,0,32,32)
	end
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

	mattrans(x2,y2)
	matrot(t, 0, 0, 1)
	text(
		'HelloWorld', -- str
		0, 0,        -- x y
		13,-- fg
		0, -- bg
		1.5, 3 -- sx sy
	)

	-- reset model matrix
	matident()
end
