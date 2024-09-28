local assertindex = require 'ext.assert'.index
-- it's not an editor, but I put the gui functions in numo9.editor, so ...
-- strraigthen this out, either rename numo9.editor to numo9.gui, or use the gui project, or put the functions somewhere else like app or video, idk...
local Editor = require 'numo9.editor'

local Menu = Editor:subclass()

function Menu:init(args)
	self.app = assertindex(args, 'app')
	self.thread = coroutine.create(function()
		while true do
			coroutine.yield()
			self:update()
		end
	end)
end

function Menu:update()
	if not self.isOpen then return end
	local app = self.app

	local x = 128
	local y = 24
	app:drawText('NuMo9', x, y)
	y = y + 12

	if self:guiButton('resume', x, y) then
		self.isOpen = false
		app.isPaused = false
		return
	end
	y = y + 12

	if self:guiButton('new game', x, y) then
		self.isOpen = false
		app:resetROM()
		return
	end
	y = y + 12

	-- multiplayer
	
	if self:guiButton('connect', x, y) then
	end
	y = y + 12

	if self:guiButton('listen', x, y) then
	end
	y = y + 12
	-- you can redirect connected players to game players ...
	-- then have buttons for auto-assign-first-players or not
	
	-- configure

	if self:guiButton('sfx volume', x, y) then
	end
	y = y + 12

	if self:guiButton('music volume', x, y) then
	end
	y = y + 12
	
	if self:guiButton('input configu', x, y) then
	end
	y = y + 12
	
	if self:guiButton('player names', x, y) then
	end
	y = y + 12
	
	if self:guiButton('to console', x, y) then
		self.isOpen = false
		app.con.isOpen = true
		return
	end
	y = y + 12

	if self:guiButton('quit', x, y) then
		app:requestExit()
		return
	end
	y = y + 12
end

return Menu
