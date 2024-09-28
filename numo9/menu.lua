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

	local ystep = 9
	local ysepstep = 7
	local x = 60
	local y = 24

	local function section(str)
		y = y + ysepstep
		app:drawText(str, x+16, y, 0xf7, 0xf0)
		y = y + ystep
	end

	section'NuMo9'

	section'game'

	if self:guiButton('resume', x, y) then
		self.isOpen = false
		app.isPaused = false
		return
	end
	y = y + ystep

	if self:guiButton('new game', x, y) then
		self.isOpen = false
		app:runROM()
		return
	end
	y = y + ystep

	-- multiplayer

	section'multiplayer'

	if self:guiButton('connect', x, y) then
	end
	y = y + ystep

	if self:guiButton('listen', x, y) then
	end
	y = y + ystep
	-- you can redirect connected players to game players ...
	-- then have buttons for auto-assign-first-players or not

	-- configure
	section'sound'

	if self:guiButton('sfx volume', x, y) then
	end
	y = y + ystep

	if self:guiButton('music volume', x, y) then
	end
	y = y + ystep

	section'input'

	if self:guiButton('input configu', x, y) then
	end
	y = y + ystep

	if self:guiButton('player names', x, y) then
	end
	y = y + ystep

	section'system'

	if self:guiButton('to console', x, y) then
		self.isOpen = false
		app.con.isOpen = true
		return
	end
	y = y + ystep

	if self:guiButton('to editor', x, y) then
		self.isOpen = false
		app.con.isOpen = false
		app.con.isOpen = false
		if app.currentEditor and app.currentEditor.loseFocus then
			app.currentEditor:loseFocus()
		end
		app.currentEditor = app.server and app.editNet or app.editCode
		if app.currentEditor.gainFocus then
			app.currentEditor:gainFocus()
		end
		return
	end
	y = y + ystep


	if self:guiButton('quit', x, y) then
		app:requestExit()
		return
	end
	y = y + ystep
end

return Menu
