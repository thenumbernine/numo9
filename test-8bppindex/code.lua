local m = 1
mode(m)
for i=0,0xff do
	for j=0,0x1ff do	-- cover the whole framebuffer region in case the user switches to mode 0 later
		poke(i | (j << 8), i)
	end
end

local paletteMem = blobaddr'palette'

local x,y = 128,128
update = ||do
	pokew(paletteMem+(math.random(0, 0xff)<<1),
		0x8000|math.random(0,0x7fff))

	spr(0,x,y,2,2)
	local s = 3
	if btn'up' then y -= s end
	if btn'down' then y += s end
	if btn'left' then x -= s end
	if btn'right' then x += s end
	if btnp'a' then
		m += 1
		trace('mode', m, mode(m))
	end
	if btnp'b' then
		m -= 1
		trace('mode', m, mode(m))
	end
end
