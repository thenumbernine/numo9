assert.eq(ramsize'mvMat', 16*4, "expected mvmat to be 32bit")	-- need to assert this for my peek/poke push/pop. need to peek/poke vs writing to app.ram directly so it is net-reflected.
local matAddr = ramaddr'mvMat'
local matstack=table()
local matpush=[]do
	local t={}
	for i=0,15 do
		t[i+1] = peekl(matAddr + (i<<2))
	end
	matstack:insert(t)
end
local matpop=[]do
	local t = matstack:remove(1)
	if not t then return end
	for i=0,15 do
		pokel(matAddr + (i<<2), t[i+1])
	end
end
