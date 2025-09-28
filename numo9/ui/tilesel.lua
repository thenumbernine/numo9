--[[
I think I'll put the tile-selection widget here,
and use it in mesh3d and voxelmap for tile preview/selection.
--]]
local assert = require 'ext.assert'
local class = require 'ext.class'
local vec2i = require 'vec-ffi.vec2i'

local numo9_rom = require 'numo9.rom'
local spriteSize = numo9_rom.spriteSize
local spriteSheetSize = numo9_rom.spriteSheetSize
local frameBufferSize = numo9_rom.frameBufferSize
local spriteSheetSizeInTiles = numo9_rom.spriteSheetSizeInTiles

local TileSelect = class()

--[[
args:
	edit = points to the editor panel using this ui
		used for:
		- edit.app to point back to the app
		- edit.paletteBlobIndex if present for determining what palette to use ...
		- edit.sheetBlobIndex if present for which sheet to use
	onSetTile (optional)
		set this for a callback when .pos changes.

TODO 'allowRect' since tilemap select allows a rectangle-box-select for stamping multiple tiles,
 meanwhile mesh3d and voxelmap just need a coordinate for offsetting mesh texture coordiantes.
--]]
function TileSelect:init(args)
	self.edit = assert.index(args, 'edit')
	self.onSetTile = args.onSetTile

	self.pickOpen = false			-- if this is open or not
	self.pos = vec2i()
	self.size = vec2i(1,1)
end

function TileSelect:button(x, y)
	local edit = self.edit
	if edit:guiButton('T', x, y, self.pickOpen, 'tile') then
		self.pickOpen = not self.pickOpen
	end
end

-- returns true if handled ui, false if otherwise
function TileSelect:doPopup()
	local edit = self.edit
	local app = edit.app

	if not self.pickOpen then return false end

	-- TODO should this go here or in the caller:
	app:matident()

	local leftButtonDown = app:key'mouse_left'
	local leftButtonPress = app:keyp'mouse_left'
	local leftButtonRelease = app:keyr'mouse_left'
	local mouseX, mouseY = app.ram.mousePos:unpack()

	local pickX = 2 * spriteSize.x
	local pickY = 2 * spriteSize.y
	local pickW = frameBufferSize.x - 2 * pickX
	local pickH = frameBufferSize.y - 2 * pickY

	app:drawBorderRect(
		pickX-1,
		pickY-1,
		pickW+2,
		pickH+2,
		10,
		nil,
		app.paletteMenuTex
	)
	app:drawSolidRect(
		pickX,
		pickY,
		pickW,
		pickH,
		1,
		nil,
		nil,
		app.paletteMenuTex
	)

	-- set the current selected palette via RAM registry to self.paletteBlobIndex
	local pushPalBlobIndex = app.ram.paletteBlobIndex
	app.ram.paletteBlobIndex = edit.paletteBlobIndex or 0
	app:drawQuad(
		pickX,
		pickY,
		pickW,
		pickH,
		-- TODO scrollable pick area ... hmm ...
		-- or TODO use the same scrollable pick area for the sprite editor and the tile editor
		0,
		0,
		255,
		255,
		edit.sheetBlobIndex,
		0,
		-1,
		0,
		0xff
	)
	app.ram.paletteBlobIndex = pushPalBlobIndex

	local spriteX = math.floor((mouseX - pickX) / pickW * spriteSheetSizeInTiles.x)
	local spriteY = math.floor((mouseY - pickY) / pickH * spriteSheetSizeInTiles.y)
	if spriteX >= 0 and spriteX < spriteSheetSizeInTiles.x
	and spriteY >= 0 and spriteY < spriteSheetSizeInTiles.y
	then
		if leftButtonPress then
			-- TODO rect select
			self.pos:set(spriteX, spriteY)
			self.size:set(1, 1)
			if self.onSetTile then
				self:onSetTile()
			end
		elseif leftButtonDown then
			self.size.x = math.ceil((math.abs(mouseX - app.ram.lastMousePressPos.x) + 1) / spriteSize.x)
			self.size.y = math.ceil((math.abs(mouseY - app.ram.lastMousePressPos.y) + 1) / spriteSize.y)
		elseif leftButtonRelease then
			self.pickOpen = false
		end
	end

	app:drawBorderRect(
		pickX + self.pos.x * spriteSize.x * pickW / spriteSheetSize.x,
		pickY + self.pos.y * spriteSize.y * pickH / spriteSheetSize.y,
		spriteSize.x * self.size.x * pickW / spriteSheetSize.x,
		spriteSize.y * self.size.y * pickH / spriteSheetSize.y,
		13,
		nil,
		app.paletteMenuTex
	)

	return true
end

return TileSelect
