mode(2)
local paladdr=ramaddr'bank'+romaddr'palette'
for i=0,255 do
	pokew(paladdr+(i<<1),i|0x8000)
end
update=||do
	mode(2)
	cls(0)
	for i=0,31 do
		rect(i<<2,0,4,128,i)
	end
end
