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
local mvMatType = numo9_rom.mvMatType


local mvMatPush = ffi.new(mvMatType..'[16]')
-- this is a sprite-based preview of tilemap rendering
-- it's made to simulate blitting the brush onto the tilemap (without me writing the tiles to a GPU texture and using the shader pathway)
local function drawStamp(
	app,
	brush,
	stampScreenX, stampScreenY,
	stampTilesWide, stampTilesHigh,
	draw16Sprites
)
	local stampTileX, stampTileY = 0, 0	-- TODO how to show select brushes? as alays in UL, or as their location in the pick screen? meh?
	-- or TODO stampScreenX = stampTileX * tileSizeInTexels.x
	-- but for the select's sake, keep the two separate

	local draw16As0or1 = draw16Sprites and 1 or 0
	local tileSizeInTiles = vec2i(
		bit.lshift(1, draw16As0or1),
		bit.lshift(1, draw16As0or1))
	local tileSizeInTexels = vec2i(		-- size in pixels
		bit.lshift(spriteSize.x, draw16As0or1),
		bit.lshift(spriteSize.y, draw16As0or1))
	for tx=0,stampTilesWide-1 do
		for ty=0,stampTilesHigh-1 do
			local screenX = stampScreenX + tx * tileSizeInTexels.x
			local screenY = stampScreenY + ty * tileSizeInTexels.y
			-- TODO what if 'brush' is not there, i.e. a bad brushIndex in a stamp?
			local tileIndex = brush
				and brush(tx, ty, stampTilesWide, stampTilesHigh, stampTileX, stampTileY)
				or 0
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

	ffi.copy(app.ram.mvMat, mvMatPush, ffi.sizeof(mvMatPush))
end


local EditBrushmap = require 'numo9.ui':subclass()

function EditBrushmap:init(args)
	EditBrushmap.super.init(self, args)

	self.draw16Sprites = false
	self.brushPreviewSize = 3

	-- stamps: index, x, y, width, height
	self.stamps = table()
	self.selected = table()

	self.selBrushIndex = 1	-- 0-based? 1-based? this indexes into the Lua table in code so 1-based for now

	self.brushmapBlobIndex = 0
	self.tilemapBlobIndex = 0
	self.sheetBlobIndex = 1
	self.paletteBlobIndex = 0
end

function EditBrushmap:update()
	local app = self.app

	EditBrushmap.super.update(self)

	local gameEnv = app.gameEnv
	if not gameEnv then
		app:drawMenuText("plz run your game once to reload the code env", 16, 128)
		return
	end
	local brushes = gameEnv.numo9_brushes
	if not brushes then
		app:drawMenuText("define 'numo9_brushes' in your code to use brushes", 16, 128)
		return
	end

	local brushmapBlob = app.blobs.brushmap[self.brushmapBlobIndex+1]
	if not brushmapBlob then
		app:drawMenuText("push + on the brushmap blob select to continue", 16, 128)
	else
		app:matident()
		ffi.copy(mvMatPush, app.ram.mvMat, ffi.sizeof(mvMatPush))

		local draw16As0or1 = self.draw16Sprites and 1 or 0
		local tileSizeInTexels = vec2i(						-- size in pixels
			bit.lshift(spriteSize.x, draw16As0or1),
			bit.lshift(spriteSize.y, draw16As0or1))

		local leftButtonDown = app:key'mouse_left'
		local leftButtonPress = app:keyp'mouse_left'
		local leftButtonRelease = app:keyr'mouse_left'
		local mouseX, mouseY = app.ram.mousePos:unpack()

		local shift = app:key'lshift' or app:key'rshift'

		local brushesKeys = table.keys(brushes):sort()

		-- title controls
		local x, y = 64, 0

		self:guiButton('#'..#brushesKeys, x, y, nil, 'numo9_brushes[]')
		x = x + 24

		self:guiSpinner(x, y, function(dx)
			self.brushPreviewSize = math.max(1, self.brushPreviewSize + dx)
		end, 'previewSize='..tostring(self.brushPreviewSize))
		x = x + 16

		self:guiSpinner(x, y, function(dx)
			self.selBrushIndex = math.clamp(self.selBrushIndex + dx, 1, #brushes)
		end, 'brush='..self.selBrushIndex)
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
			drawStamp(
				app,
				brushes[stamp.brush],	-- might be nil
				stamp.x * tileSizeInTexels.x,
				stamp.y * tileSizeInTexels.y,
				stamp.w,
				stamp.h,
				self.draw16Sprites
			)
		end

		x, y = 0, 8


		if self.pickOpen then
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

			local stampScreenX, stampScreenY = pickX, pickY
			for _,brushIndex in ipairs(brushesKeys) do
				local brush = brushes[brushIndex]

				drawStamp(
					app,
					brush,
					stampScreenX, stampScreenY,
					self.brushPreviewSize, self.brushPreviewSize,
					self.draw16Sprites)

				if brushIndex == self.selBrushIndex then
					app:drawBorderRect(
						stampScreenX,
						stampScreenY,
						self.brushPreviewSize * tileSizeInTexels.x,
						self.brushPreviewSize * tileSizeInTexels.y,
						27,
						ni,
						app.paletteMenuTex
					)
				end

				-- TODO left down + drag to scroll
				if leftButtonPress then
					self.selBrushIndex = brushIndex
					--self.pickOpen = false	-- TODO delay past click-to-open time
				end

				stampScreenX = stampScreenX + tileSizeInTexels.x * self.brushPreviewSize
				if stampScreenX > pickW then
					stampScreenX = 0
					stampScreenY = stampScreenY + tileSizeInTexels.y * self.brushPreviewSize
				end
			end
		else
			--[[
			tools ...
			- move ... left down on center of selected + move to move multiple
			- resize ... left down on border of selected to resize
			- click and drag outside a brush to select multiple?
			- click on a brush to select a single brush?
			- add ... click outside any brushes to add
			- remove ... select+delete?
			--]]

			if leftButtonDown then
				if mouseX ~= app.ram.lastMousePressPos.x
				or mouseY ~= app.ram.lastMousePressPos.y
				then
					self.mouseDragged = true
				end
			else
				self.mouseDragged = false
			end


			if leftButtonPress then
				local selUnder = table()
				for _,stamp in ipairs(self.selected) do
					if stamp.x * tileSizeInTexels.x < mouseX
					and stamp.y * tileSizeInTexels.y < mouseY
					and (stamp.x + stamp.w) * tileSizeInTexels.x > mouseX
					and (stamp.y + stamp.h) * tileSizeInTexels.y > mouseY
					then
						selUnder:insert(stamp)
					end
				end
				if #selUnder > 0 then
					-- check corner vs center for dragging or resizing
					self.resizing = false
				else
					-- pressed down on nothing ...
					-- create, pan, or select-box?

					-- create
					local stamp = {
						brush = self.selBrushIndex,
						x = math.floor(mouseX / tileSizeInTexels.x),
						y = math.floor(mouseY / tileSizeInTexels.y),
						w = 1,	-- default size?
						h = 1,
					}
					self.stamps:insert(stamp)
					self.selected = table{stamp}
					self.resizing = true
				end
			elseif leftButtonDown then
				if self.resizing then
					for _,stamp in ipairs(self.selected) do
						stamp.w = math.ceil((math.abs(mouseX - app.ram.lastMousePressPos.x) + 1) / tileSizeInTexels.x)
						stamp.h = math.ceil((math.abs(mouseY - app.ram.lastMousePressPos.y) + 1) / tileSizeInTexels.y)
					end
				else
					for _,stamp in ipairs(self.selected) do
						stamp.x = stamp.x + math.ceil((math.abs(mouseX - app.ram.lastMousePressPos.x) + 1) / tileSizeInTexels.x)
						stamp.y = stamp.y + math.ceil((math.abs(mouseY - app.ram.lastMousePressPos.y) + 1) / tileSizeInTexels.y)
					end
				end
			elseif leftButtnRelease then
			end
		end
	end

	local x, y = 40, 0
	self:guiBlobSelect(x, y, 'brushmap', self, 'brushmapBlobIndex')
	x = x + 12
	self:guiBlobSelect(x, y, 'tilemap', self, 'tilemapBlobIndex')
	x = x + 12
	self:guiBlobSelect(x, y, 'sheet', self, 'sheetBlobIndex')
	x = x + 12
	self:guiBlobSelect(x, y, 'palette', self, 'paletteBlobIndex')

	self:drawTooltip()
end

return EditBrushmap
