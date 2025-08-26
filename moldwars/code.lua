local fbAddr = ramaddr'framebuffer'

--[[ indexed?
w,h = 256,256	mode(1)	--8bpp indexed
local palAddr=blobaddr'palette'
for i=0,511 do
	poke(i, math.random(0,255))
end
for i=0,w*h-1 do
	poke(i, math.random(0,255))
end

update=||do
	for y=0,h-1 do
		for x=0,w-1 do
			local di = math.random(0,3)
			if di == 0 then
				di = 1
			elseif di == 1 then
				di = -1
			elseif di == 2 then
				di = 256
			elseif di == 3 then
				di = -256
			end
			local i = x|(y<<8)
			poke(i, peek((i + di) & 0xFFFF))
		end
	end
end--]]
-- [[ 16bpp?
--w,h = 256,256		mode(0)		-- RGB565 1:1
w,h = 336,189   	mode(18)	-- RGB565 16:9
for i=0,w*h-1 do
	pokew(i<<1, math.random(0,0xffff))
end

update=||do
	for y=0,h-1 do
		for x=0,w-1 do
			local di = math.random(0,3)
			if di == 0 then
				di = 1
			elseif di == 1 then
				di = -1
			elseif di == 2 then
				di = w
			elseif di == 3 then
				di = -w
			end
			local i = x + y * w
			local src = peekw(((i + di) % (w * h)) << 1)
			local r = ((src & 0x1f) + math.random(0,2)-1) & 0x1f
			local g = (((src >> 6) & 0x1f) + math.random(0,2)-1) & 0x1f
			local b = ((src >> 11) + math.random(0,2)-1) & 0x1f
			pokew(i<<1, r | (g << 6) | ((g << 1) & 0x20) | (b << 11))
		end
	end
end
--]]
