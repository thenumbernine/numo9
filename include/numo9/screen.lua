getScreenSize=|| (tonumber(peekw(ramaddr'screenWidth')), tonumber(peekw(ramaddr'screenHeight')))

getAspectRatio=||do
	local w, h = getScreenSize()
	return w / h
end
