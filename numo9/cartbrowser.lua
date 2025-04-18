local table = require 'ext.table'

local CartBrowser = require 'numo9.ui':subclass()

CartBrowser.selectedIndex = 0
function CartBrowser:update()
--	CartBrowser.super.update(self)	-- clears screen, shows the current-editor tab etc
	local app = self.app
	app:clearScreen(0xf0)

	local fs = app.fs
	local mouseX, mouseY = app.ram.mousePos:unpack()
	local lastMouseX, lastMouseY = app.ram.lastMousePos:unpack()
	local mouseMoved = mouseX ~= lastMouseX or mouseY ~= lastMouseY
	-- cycle through vfs and find .n9 carts in this dir and ...
	-- ... make textures for their icons ...
	-- ... and then have buttons on :update()
	local x = 0
	local y = 0
	local fgColor = 13
	local defaultBgColor = 8
	local selBgColor = 4

	local fileNames = table.keys(fs.cwd.chs):sort()
	if app:keyp('up', 30, 5) then
		self.selectedIndex = self.selectedIndex - 1
	elseif app:keyp('down', 30, 5) then
		self.selectedIndex = self.selectedIndex + 1
	end
	self.selectedIndex = ((self.selectedIndex - 1) % #fileNames) + 1

	-- TODO use self:guiTextField here
	app:drawMenuText(fs.cwd:path(), x, y, fgColor, defaultBgColor)

	y = y + 8
	x = x + 8
	local w = 128	-- how wide .. text length? or fixed button length?
	local h = 8
	local mouseOverSel
	for i,name in ipairs(fileNames) do
		local f = fs.cwd.chs[name]
		-- only upon mouse-move, so keyboard can move even if the mouse is hovering over a button
		local mouseOver = mouseX >= x and mouseX < x+w and mouseY >= y and mouseY < y+h
		if mouseMoved and mouseOver then
			self.selectedIndex = i
		end
		local sel = self.selectedIndex == i
		if sel then mouseOverSel = mouseOver end
		local bgColor = sel and selBgColor or defaultBgColor
		if f.isdir then 				-- dir
			app:drawMenuText('['..name..']', x, y, fgColor, bgColor)
		elseif name:match'%.n9$' then	-- cart file
			app:drawMenuText('*'..name, x, y, fgColor, bgColor)
		else							-- non-cart file
			app:drawMenuText(' '..name, x, y, fgColor, bgColor)
		end
		y = y + 8
	end

	-- TODO needs scrolling for when there's more files than screen rows
	-- TODO thumbnail preview would be nice too

	if app:keyp'return'
	or (app:keyp'mouse_left' and mouseOverSel)
	then
		-- then run the cart ... is it a cart?
		local selname = fileNames[self.selectedIndex]
		if selname:match'%.n9$' then
			--app:setMenu(nil)
			-- numo9/ui's "load" says "do this from runFocus thread, not UI thread"
			-- but if I do that here then it seems to stall after the 2nd or 3rd time until i open and close the console again ...
			--app:setFocus{
			--	thread = coroutine.create(function()
					-- name, or path / name ?  if path is cwd then we're fine right?
					-- TODO what if we're a server?  then we should do what's in numo9/app.lua's open() function, send RAM snapshot to all clients.
					app:net_openROM(selname)
					app:runROM()
			--	end),
			--}
		end
	end
end

return CartBrowser
