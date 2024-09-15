local class = require 'ext.class'

local App = require 'numo9.app'
local paletteSize = App.paletteSize
local spriteSize = App.spriteSize
local frameBufferSize = App.frameBufferSize
local frameBufferSizeInTiles = App.frameBufferSizeInTiles
local spriteSheetSize = App.spriteSheetSize
local spriteSheetSizeInTiles = App.spriteSheetSizeInTiles
local tilemapSize = App.tilemapSize
local tilemapSizeInSprites = App.tilemapSizeInSprites

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
	tilemap = 'editTilemap',
}


local Editor = class()

function Editor:init(args)
	self.app = assert(args.app)
	self.tilemapEditor = args.tilemapEditor
end

function Editor:guiButton(x, y, str, isset, tooltip)
	local app = self.app

	-- TODO it's tempting to draw the editor directly to RGB, not using the fantasy-console's rendering ...
	-- ... that means builtin font as well ...
	-- yeah it's not a console for sure.
	self:drawText(str, x, y,
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
			self:drawText(tooltip, mouseX - 12, mouseY - 12, 12, 6)
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

	self:drawText('<', x, y, 13, 0)
	if leftButtonPress
	and mouseX >= x and mouseX < x + spriteSize.x
	and mouseY >= y and mouseY < y + spriteSize.y
	then
		cb(-1)
	end

	x = x + spriteSize.x
	self:drawText('>', x, y, 13, 0)
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
			self:drawText(tooltip, mouseX - 12, mouseY - 12, 12, 6)
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
	titlebar = titlebar .. (' '):rep(frameBufferSizeInTiles.x - #titlebar)
	self:drawText(
		titlebar,
		#editModes * spriteSize.x,
		0,
		12,
		8
	)
end

-- put editor palette in the last entry
-- so that people dont touch it
-- but still make sure they can use it
-- cuz honestly I'm aiming to turn the editor into a ROM itself and stash it in console 'memory'
function Editor:color(i)
	return bit.bor(bit.band(i,0xf),0xf0)
end

function Editor:drawText(s,x,y,fg,bg)
	return self.app:drawText(
		s,x,y,
		self:color(fg),
		self:color(bg))
end

return Editor
