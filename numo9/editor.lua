local class = require 'ext.class'

local App = require 'numo9.app'
local paletteSize = App.paletteSize
local frameBufferSize = App.frameBufferSize
local spriteSheetSize = App.spriteSheetSize
local spriteSize = App.spriteSize
local spritesPerSheet = App.spritesPerSheet
local spritesPerFrameBuffer = App.spritesPerFrameBuffer

-- TODO make the editor a rom itself
-- TODO make roms that hold all the necessary stuff

local editModes = {
	'code',
	'sprites',
	'tilemap',
	'fx',
	'music',
}
local editFieldForMode = {
	code = 'editCode',
	sprites = 'editSprites',
}


local Editor = class()

function Editor:init(args)
	self.app = assert(args.app)
end

function Editor:guiButton(x, y, str, isset, tooltip)
	local app = self.app
	app:drawTextFgBg(x, y, str,
		isset and 13 or 10,
		isset and 4 or 2
		--isset and 15 or 4,
		--isset and 7 or 8
	)

	local mouseX, mouseY = app.mousePos:unpack()
	if mouseX >= x and mouseX < x + spriteSize.x
	and mouseY >= y and mouseY < y + spriteSize.y
	then
		if tooltip then
			app:drawTextFgBg(mouseX - 12, mouseY - 12, tooltip, 12, 6)
		end

		local leftButtonLastDown = bit.band(app.lastMouseButtons, 1) == 1
		local leftButtonDown = bit.band(app.mouseButtons, 1) == 1
		local leftButtonPress = leftButtonDown and not leftButtonLastDown
		if leftButtonPress then
			return true
		end
	end
end

function Editor:guiSpinner(x, y, cb, tooltip)
	local app = self.app

	-- TODO this in one spot, mabye with glapp.mouse ...
	local leftButtonLastDown = bit.band(app.lastMouseButtons, 1) == 1
	local leftButtonDown = bit.band(app.mouseButtons, 1) == 1
	local leftButtonPress = leftButtonDown and not leftButtonLastDown
	local mouseX, mouseY = app.mousePos:unpack()

	app:drawTextFgBg(x, y, '<', 13, 0)
	if leftButtonPress
	and mouseX >= x and mouseX < x + spriteSize.x
	and mouseY >= y and mouseY < y + spriteSize.y
	then
		cb(-1)
	end

	x = x + spriteSize.x
	app:drawTextFgBg(x, y, '>', 13, 0)
	if leftButtonPress
	and mouseX >= x and mouseX < x + spriteSize.x
	and mouseY >= y and mouseY < y + spriteSize.y
	then
		cb(1)
	end

	if mouseX >= x - spriteSize.x and mouseX < x + spriteSize.x
	and mouseY >= y and mouseY < y + spriteSize.y
	then
		if tooltip then
			app:drawTextFgBg(mouseX - 12, mouseY - 12, tooltip, 12, 6)
		end
	end
end

function Editor:guiRadio(x, y, options, selected, cb)
	for _,name in ipairs(options) do
		if self:guiButton(
			x,
			y,
			name:sub(1,1):upper(),
			selected == name,
			name
		) then
			cb(name)
		end
		x = x + 8
	end
end

function Editor:update()
	local app = self.app

	app:clearScreen()
	
	self:guiRadio(
		0,
		0,
		editModes,
		app.editMode,
		function(x)
			app.editMode = x
			app.runFocus = app[editFieldForMode[x] or '']
		end
	)

	local titlebar = '  '..app.editMode
	titlebar = titlebar .. (' '):rep(spritesPerFrameBuffer.x - #titlebar)
	app:drawTextFgBg(
		#editModes * spriteSize.x,
		0,
		titlebar,
		12,
		8
	)
end

return Editor
