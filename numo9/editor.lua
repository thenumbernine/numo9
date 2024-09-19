local ffi = require 'ffi'
local math = require 'ext.math'
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

	self.thread = coroutine.create(function()
		while true do
			coroutine.yield()
			self:update()
		end
	end)
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

	local mouseX, mouseY = app.ram.mousePos:unpack()
	if mouseX >= x and mouseX < x + spriteSize.x
	and mouseY >= y and mouseY < y + spriteSize.y
	then
		if tooltip then
			self:drawTooltip(tooltip, mouseX - 12, mouseY - 12, 12, 6)
		end

		local leftButtonLastDown = bit.band(app.ram.lastMouseButtons[0], 1) == 1
		local leftButtonDown = bit.band(app.ram.mouseButtons[0], 1) == 1
		local leftButtonPress = leftButtonDown and not leftButtonLastDown
		if leftButtonPress then
			return true
		end
	end
end

function Editor:guiSpinner(x, y, cb, tooltip)
	local app = self.app

	-- TODO this in one spot, mabye with glapp.mouse ...
	local leftButtonLastDown = bit.band(app.ram.lastMouseButtons[0], 1) == 1
	local leftButtonDown = bit.band(app.ram.mouseButtons[0], 1) == 1
	local leftButtonPress = leftButtonDown and not leftButtonLastDown
	local mouseX, mouseY = app.ram.mousePos:unpack()

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
			self:drawTooltip(tooltip, mouseX - 12, mouseY - 12, 12, 6)
		end
	end
end

function Editor:drawTooltip(s, x, y, fg, bg)
	x = math.clamp(x, 8, frameBufferSize.x-8)
	y = math.clamp(y, 8, frameBufferSize.y-8)
	return self:drawText(s, x, y, fg, bg)
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

	app:clearScreen(0xf0)

	app:drawSolidRect(
		0, 0,	-- x,y,
		frameBufferSize.x, spriteSize.y,	-- w, h,
		self:color(0)
	)

	self:guiRadio(
		0,
		0,
		editModes,
		app.editMode,
		function(x)
			app.editMode = x
			app:setFocus(app[editFieldForMode[x] or ''])
		end
	)

	local titlebar = '  '..app.editMode
	self:drawText(
		titlebar,
		#editModes * spriteSize.x,
		0,
		12,
		-1
	)
end

-- put editor palette in the last entry
-- so that people dont touch it
-- but still make sure they can use it
-- cuz honestly I'm aiming to turn the editor into a ROM itself and stash it in console 'memory'
function Editor:color(i)
	if i == -1 then return -1 end	-- -1 for transparency meant don't use a valid color ...
	return bit.bor(bit.band(i,0xf),0xf0)
end

function Editor:drawText(s,x,y,fg,bg)
	return self.app:drawText(
		s,x,y,
		self:color(fg),
		self:color(bg))
end

--[[
Editing will go on in RAM, for live cpu/gpu sprite/palette update's sake
but it'll always reflect the cartridge state

When the user sets the editCode to focus,
copy from the app.cartridge.code to the editor,
so we can use Lua string functinoality.

While playing, assume .cartridge has the baseline content of the game,
and assume whatever's in .ram is dirty.

But while editing, assume .ram has the baseline content of the game,
and assume whatever's in .cartridge is stale.
--]]
function Editor:gainFocus()
	local app = self.app

	-- if an editor tab gains focus, make sure to select it
	for name,field in pairs(editFieldForMode) do
		if self == app[field] then
			app.editMode = name
		end
	end

	app.spriteTex:checkDirtyGPU()
	app.tileTex:checkDirtyGPU()
	app.mapTex:checkDirtyGPU()
	app.palTex:checkDirtyGPU()
	app.fbTex:checkDirtyGPU()
	-- copy everything from cartridge to RAM (where it'll be edited & the engine can live-update the edits)
	ffi.copy(app.ram, app.cartridge, ffi.sizeof'ROM')
	-- set all dirty flags too
	app.spriteTex.dirtyCPU = true
	app.tileTex.dirtyCPU = true
	app.mapTex.dirtyCPU = true
	app.palTex.dirtyCPU = true
	app.fbTex.dirtyCPU = true
	app.fbTex.changedSinceDraw = true

	-- copy cartridge code to editCode (where we can use Lua string functionality)
	local code = ffi.string(app.cartridge.code, app.codeSize)	-- TODO max size on this ...
	local i = code:find('\0', 1, true)
	if i then code = code:sub(1, i-1) end
	app.editCode:setText(code)
end

function Editor:loseFocus()
	local app = self.app

	-- sync with RAM as well for when we run stuff ... tho calling run() or reset() should do this copy ROM->RAM for us
	ffi.copy(app.cartridge, app.ram, ffi.sizeof'ROM')

	-- sync us back from editor to cartridge so everyone else sees the console code where it belongs
	ffi.fill(app.cartridge.code, ffi.sizeof(app.cartridge.code))
	ffi.copy(app.cartridge.code, app.editCode.text:sub(1,app.codeSize-1))
end

return Editor
