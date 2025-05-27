cls()
print'fps test'
local lastTime=0
local frames=0
local tileIndex=0
update=||do
	frames += 1
	local t = time()
	local ti = math.floor(t)
	if ti > lastTime then
		trace('fps '..frames)
		text('fps '..frames, 0, 0, 0xfc)
		--_G.print('fps '..frames)
		frames = 0
		lastTime = ti
	end
end
