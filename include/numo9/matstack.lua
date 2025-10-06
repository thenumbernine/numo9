--[[
There's only one stack, you can push/pop mv and proj onto it willy nilly
--]]
assert.eq(ramsize'modelMat', 16*4, "expected modelMat to be 32bit")	-- need to assert this for my peek/poke push/pop. need to peek/poke vs writing to app.ram directly so it is net-reflected.
assert.eq(ramsize'viewMat', 16*4, "expected viewMat to be 32bit")
assert.eq(ramsize'projMat', 16*4, "expected projMat to be 32bit")
local modelMatAddr = ramaddr'modelMat'
local viewMatAddr = ramaddr'viewMat'
local projMatAddr = ramaddr'projMat'
assert.eq(modelMatAddr + ramsize'modelMat', viewMatAddr)
assert.eq(viewMatAddr + ramsize'viewMat', projMatAddr)
local matstack=table()
local matpush=|matrixIndex|do
	matrixIndex = matrixIndex or 0
	local t={}
	for i=0,15 do
		t[i+1] = peekf(modelMatAddr + (i << 2 | matrixIndex << 6))
	end
	matstack:insert(t)
end
local matpop=|matrixIndex|do
	matrixIndex = matrixIndex or 0
	local t = matstack:remove()
	if not t then return end
	for i=0,15 do
		pokef(modelMatAddr + (i << 2 | matrixIndex << 6), t[i+1])
	end
end
