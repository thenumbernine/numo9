local getScreenSize=||(
	tonumber(peekw(ramaddr'screenWidth')),
	tonumber(peekw(ramaddr'screenHeight'))
)

local getAspectRatio=||do
	local w, h = getScreenSize()
	return w / h
end

return {
	getScreenSize = getScreenSize,
	getAspectRatio = getAspectRatio,
}
