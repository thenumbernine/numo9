--[[
By the 16-bit era, some games would store their levels lz-compessed (ex: Super Metroid)
but some would store their levels in brushes (and then lz-compress the brushes) (ex: Super Mario World)

for now I'll store it in a global. "numo9_brushes={[brushIndex] = func}"

Brush functions will be defined as:
`tileIndex = brush(relx, rely, stampw, stamph, stampx, stampy)`
... where tileIndex is treated like tilemaps contents.
So if you want global coords, just add relxy to stampxy.

Each stamp in the brushmap is going to be:
uint16_t brushIndex, x, y, w, h;	<- 10 bytes each

Brushes will just be text / Lua script defined functions if I ever make them distinct of the rest of the code.
--]]
local ffi = require 'ffi'
local table = require 'ext.table'
local math = require 'ext.math'
local vec2i = require 'vec-ffi.vec2i'

local numo9_rom = require 'numo9.rom'
local spriteSize = numo9_rom.spriteSize
local frameBufferSize = numo9_rom.frameBufferSize
local spriteSheetSize = numo9_rom.spriteSheetSize
local spriteSheetSizeInTiles = numo9_rom.spriteSheetSizeInTiles
local mvMatType = numo9_rom.mvMatType

local EditBrushmap = require 'numo9.ui':subclass()

function EditBrushmap:init(args)
	EditBrushmap.super.init(self, args)

	self.draw16Sprites = false
	self.brushPreviewSize = 3

	-- stamps: index, x, y, width, height
	self.stamps = table()

	self.sheetBlobIndex = 1
	self.tilemapBlobIndex = 0
	self.paletteBlobIndex = 0
end

local mvMatPush = ffi.new(mvMatType..'[16]')
function EditBrushmap:update()
	local app = self.app

	local draw16As0or1 = self.draw16Sprites and 1 or 0
	local tileSizeInTexels = vec2i(						-- size in pixels
		bit.lshift(spriteSize.x, draw16As0or1),
		bit.lshift(spriteSize.y, draw16As0or1))
	local tileSizeInTiles = vec2i(
		bit.lshift(1, draw16As0or1),
		bit.lshift(1, draw16As0or1))

	local leftButtonDown = app:key'mouse_left'
	local leftButtonPress = app:keyp'mouse_left'
	local leftButtonRelease = app:keyr'mouse_left'
	local mouseX, mouseY = app.ram.mousePos:unpack()

	local shift = app:key'lshift' or app:key'rshift'

	EditBrushmap.super.update(self)


	local gameEnv = app.gameEnv
	local brushes = gameEnv and gameEnv.numo9_brushes
	local brushesKeys = brushes and table.keys(brushes):sort()

	-- title controls
	local x, y = 64, 0

	self:guiButton('#'..(brushes and #brushesKeys or 0), x, y, nil, 'numo9_brushes[]')
	x = x + 24

	self:guiSpinner(x, y, function(dx)
		self.brushPreviewSize = math.max(1, self.brushPreviewSize + dx)
	end, 'previewSize='..tostring(self.brushPreviewSize))
	x = x + 16

	if self:guiButton('T', x, y, self.pickOpen, 'tile') then
		self.pickOpen = not self.pickOpen
	end
	x = x + 8

	-- TODO this across here and the tilemap editor, and maybe from a memory address in the game...
	if self:guiButton('X', x, y, self.draw16Sprites, self.draw16Sprites and '16x16' or '8x8') then
		self.draw16Sprites = not self.draw16Sprites
	end
	x = x + 8

	if self:guiButton('G', x, y, self.drawGrid, 'grid') then
		self.drawGrid = not self.drawGrid
	end


	for _,stamp in ipairs(self.stamps) do

	end

	x, y = 0, 8



	if self.pickOpen then
		app:matident()
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

		if brushes then
			ffi.copy(mvMatPush, app.ram.mvMat, ffi.sizeof(mvMatPush))

			local brushScreenX, brushScreenY = pickX, pickY
			local brushTileX, brushTileY = 0, 0	-- TODO how to show select brushes? as alays in UL, or as their location in the pick screen? meh?
			local brushTilesWide = self.brushPreviewSize
			local brushTilesHigh = self.brushPreviewSize
			for _,i in ipairs(brushesKeys) do
				local brush = brushes[i]
				for tx=0,brushTilesWide-1 do
					for ty=0,brushTilesHigh-1 do
						local screenX = brushScreenX + tx * tileSizeInTexels.x
						local screenY = brushScreenY + ty * tileSizeInTexels.y
						-- TODO orientation(rotation) both here *AND* in tilemaps (get rid of palhigh?)
						local tileIndex = brush(tx, ty, brushTilesWide, brushTilesHigh, brushTileX, brushTileY) or 0
						local palHi = bit.band(7, bit.rshift(tileIndex, 10))
						local orientation = bit.band(7, bit.rshift(tileIndex, 13))
						spriteIndex = bit.band(0x3FF, tileIndex)	-- 10 bits

						-- TODO build rotations into the sprite pathway?
						-- it's in the tilemap pathway already ...
						-- either way, this is just a preview for the tilemap pathway
						-- since brushes don't render themselves, but just blit to the tilemap
						ffi.copy(app.ram.mvMat, mvMatPush, ffi.sizeof(mvMatPush))
						app:mattrans(
							screenX + tileSizeInTexels.x / 2,
							screenY + tileSizeInTexels.y / 2
						)
						local rot = bit.rshift(orientation, 1)
						app:matrot(rot * math.pi * .5)
						if bit.band(orientation, 1) ~= 0 then
							app:matscale(-1, 1)
						end
						app:drawSprite(
							spriteIndex,
							-tileSizeInTexels.x / 2,
							-tileSizeInTexels.y / 2,
							tileSizeInTiles.x,
							tileSizeInTiles.y,
							bit.lshift(palHi, 5))
					end
				end
				brushScreenX = brushScreenX + tileSizeInTexels.x * self.brushPreviewSize
			end

			ffi.copy(app.ram.mvMat, mvMatPush, ffi.sizeof(mvMatPush))
		end
	else
		-- TODO show current stamps *here*
		-- click and drag off a brush to place a new one
		-- click and drag on a brush center to move it
		-- click and drag on a brush edge to resize it
		if leftButtonPress then
		elseif leftButtonDown then
		elseif leftButtnRelease then
		end
	end

	local x, y = 40, 0
	self:guiBlobSelect(x, y, 'tilemap', self, 'tilemapBlobIndex')
	x = x + 12
	self:guiBlobSelect(x, y, 'sheet', self, 'sheetBlobIndex')
	x = x + 12
	self:guiBlobSelect(x, y, 'palette', self, 'paletteBlobIndex')

	self:drawTooltip()
end

return EditBrushmap
