mode(2)
local paladdr=ramaddr'bank'+romaddr'palette'
for i=0,255 do
	pokew(paladdr+(i<<1),i|0x8000)
end
update=||do
	mode(2)
	cls(0)
	local freq = 15
	fillp( (2 << ((time() * freq) & 0xf)) - 1 )
	for i=0,31 do
		rect(i<<3,0,8,256,i)
	end
	fillp(0)
end
