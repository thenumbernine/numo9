--#include ext/range.lua
elli(0,0,256,256,12)
for y=0,255 do
	trace(
		range(0,255):mapi(|x| (('%04x'):format(peekw((x | y << 8) << 1)))):concat()
	)
end
update=||do
	elli(0,0,256,256,12)
end
