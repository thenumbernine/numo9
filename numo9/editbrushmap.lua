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
local tolua = require 'ext.tolua'
local vec2i = require 'vec-ffi.vec2i'
local vec2d = require 'vec-ffi.vec2d'

local numo9_rom = require 'numo9.rom'
local spriteSize = numo9_rom.spriteSize
local frameBufferSize = numo9_rom.frameBufferSize
local frameBufferSizeInTiles = numo9_rom.frameBufferSizeInTiles
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
	-- or TODO stampScreenX = stampTileX * tileSizeInPixels
	-- but for the select's sake, keep the two separate

	local draw16As0or1 = draw16Sprites and 1 or 0
	local tileSizeInTiles = bit.lshift(1, draw16As0or1)
	local tileBits = draw16Sprites and 4 or 3
	local tileSizeInPixels = bit.lshift(1, tileBits)
	
	for tx=0,stampTilesWide-1 do
		for ty=0,stampTilesHigh-1 do
			local screenX = stampScreenX + tx * tileSizeInPixels
			local screenY = stampScreenY + ty * tileSizeInPixels
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
				screenX + tileSizeInPixels / 2,
				screenY + tileSizeInPixels / 2
			)
			local rot = bit.rshift(orientation, 1)
			app:matrot(rot * math.pi * .5)
			if bit.band(orientation, 1) ~= 0 then
				app:matscale(-1, 1)
			end
			app:drawSprite(
				spriteIndex,
				-tileSizeInPixels / 2,
				-tileSizeInPixels / 2,
				tileSizeInTiles,
				tileSizeInTiles,
				bit.lshift(palHi, 5))
		end
	end

	ffi.copy(app.ram.mvMat, mvMatPush, ffi.sizeof(mvMatPush))
end


local EditBrushmap = require 'numo9.ui':subclass()

function EditBrushmap:init(args)
	EditBrushmap.super.init(self, args)

	self.brushPreviewSize = 3

	self.lastMoveDown = vec2i()

	-- stamps: index, x, y, width, height
	self.stamps = table()
	self.selected = {}

	self.selBrushIndex = 1	-- 0-based? 1-based? this indexes into the Lua table in code so 1-based for now


	self.tilePanDownPos = vec2i()
	self.tilemapPanOffset = vec2d()
	self.tilePanPressed = false
	self.scale = 1
	self.drawGrid = false
	self.draw16Sprites = false

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

		local leftButtonDown = app:key'mouse_left'
		local leftButtonPress = app:keyp'mouse_left'
		local leftButtonRelease = app:keyr'mouse_left'
		local mouseX, mouseY = app.ram.mousePos:unpack()

		local draw16As0or1 = draw16Sprites and 1 or 0
		local tileSizeInTiles = bit.lshift(1, draw16As0or1)
		local tileBits = self.draw16Sprites and 4 or 3
		local tileSizeInPixels = bit.lshift(1, tileBits)

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
				stamp.x * tileSizeInPixels,
				stamp.y * tileSizeInPixels,
				stamp.w,
				stamp.h,
				self.draw16Sprites
			)
			if self.selected[stamp] then
				app:drawBorderRect(
					stamp.x * tileSizeInPixels,
					stamp.y * tileSizeInPixels,
					stamp.w * tileSizeInPixels,
					stamp.h * tileSizeInPixels,
					27,
					ni,
					app.paletteMenuTex
				)		
			end
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
						self.brushPreviewSize * tileSizeInPixels,
						self.brushPreviewSize * tileSizeInPixels,
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

				stampScreenX = stampScreenX + tileSizeInPixels * self.brushPreviewSize
				if stampScreenX > pickW then
					stampScreenX = 0
					stampScreenY = stampScreenY + tileSizeInPixels * self.brushPreviewSize
				end
			end
		
		else
			local mapX = 0
			local mapY = spriteSize.y	-- fontSize.y
			-- size of the map on the screen, in tiles
			local mapSizeInTiles = vec2i(frameBufferSizeInTiles:unpack())
			-- size of the map on the screen, in pixels
			local mapSizeInPixels = vec2i(
				bit.lshift(mapSizeInTiles.x, tileBits),
				bit.lshift(mapSizeInTiles.y, tileBits))

			-- only do interaction if we're not on the top UI bar ...
			if mouseY > mapY then

				local function fbToTileCoord(cx, cy)
					return
						(cx - mapX) / (bit.lshift(spriteSize.x, draw16As0or1) * self.scale) + self.tilemapPanOffset.x / bit.lshift(spriteSize.x, draw16As0or1),
						(cy - mapY) / (bit.lshift(spriteSize.y, draw16As0or1) * self.scale) + self.tilemapPanOffset.y / bit.lshift(spriteSize.y, draw16As0or1)
				end
				local tx, ty = fbToTileCoord(mouseX, mouseY)
				tx = math.floor(tx)
				ty = math.floor(ty)

				local tilemapPanHandled
				local function tilemapPan(press)
					tilemapPanHandled = true
					if press then
						if mouseX >= mapX and mouseX < mapX + mapWidthInPixels
						and mouseY >= mapY and mouseY < mapY + mapHeightInPixels
						then
							self.tilePanDownPos:set(mouseX, mouseY)
							self.tilePanPressed = true
						end
					else
						if self.tilePanPressed then
							local tx1, ty1 = fbToTileCoord(mouseX, mouseY)
							local tx0, ty0 = fbToTileCoord(self.tilePanDownPos:unpack())
							-- convert mouse framebuffer pixel movement to sprite texel movement
							local tx = tx1 - tx0
							local ty = ty1 - ty0
							if tx ~= 0 or ty ~= 0 then
								self.tilemapPanOffset.x = self.tilemapPanOffset.x - tx * bit.lshift(spriteSize.x, draw16As0or1)
								self.tilemapPanOffset.y = self.tilemapPanOffset.y - ty * bit.lshift(spriteSize.y, draw16As0or1)
								self.tilePanDownPos:set(mouseX, mouseY)
							end
						end
					end
				end


				if app:key'space' then
					tilemapPan(app:keyp'space')
				end


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
					for stamp in pairs(self.selected) do
						if stamp.x * tileSizeInPixels < mouseX
						and mouseX < (stamp.x + stamp.w) * tileSizeInPixels 
						and stamp.y * tileSizeInPixels < mouseY
						and mouseY < (stamp.y + stamp.h) * tileSizeInPixels 
						then
							selUnder:insert(stamp)
						end
					end
	print('#selUnder', #selUnder)
					self.lastMoveDown:set(mouseX, mouseY)
					local mx = math.floor(mouseX / tileSizeInPixels) 
					local my = math.floor(mouseY / tileSizeInPixels) 
					if #selUnder > 0 then
						-- check corner vs center for dragging or resizing
						self.resizing = false
					
						for _,stamp in ipairs(selUnder) do
							if mx >= stamp.x and mx <= stamp.x + stamp.w - 1
							and my >= stamp.y and my <= stamp.y + stamp.h - 1
							then
print('mx', mx, 'my', my, 'stamp', tolua(stamp))								
								if mx == stamp.x or mx == stamp.x + stamp.w - 1
								or my == stamp.y or my == stamp.y + stamp.h - 1
								then
									-- TODO what if it's a stamp smaller than 3x3?  
									-- then we'll click a border no matter what ...
									self.resizing = {
										ulx = mx == stamp.x,
										uly = my == stamp.y,
									}
									break
								else
									-- center-click on something
									self.resizing = false
									break
								end
							end
						end
print('resizing', tolua(self.resizing))
					else
						-- pressed down but not on a selected ...
						-- did we press down on an unselected?
						self.selected = {}
						for _,stamp in ipairs(self.stamps) do
							if mx >= stamp.x and mx < stamp.x + stamp.w
							and my >= stamp.y and my < stamp.y + stamp.h
							then
								self.selected[stamp] = true
							end
						end
						if not next(self.selected) then
							-- we pushed down on nothing ...
							-- create, pan, or select-box?

							-- create
							local stamp = {
								brush = self.selBrushIndex,
								x = math.round(mouseX / tileSizeInPixels),
								y = math.round(mouseY / tileSizeInPixels),
								w = 1,	-- default size?
								h = 1,
							}
							self.stamps:insert(stamp)
							self:refreshStampBlob()
							self.selected = {}
							self.selected[stamp] = true
							self.resizing = {}
						end
					end
				elseif leftButtonDown then
					local dx = math.trunc((mouseX - self.lastMoveDown.x) / tileSizeInPixels)
					local dy = math.trunc((mouseY - self.lastMoveDown.y) / tileSizeInPixels)
					if dx ~= 0 or dy ~= 0 then
						if self.resizing then
print('resizing', tolua(self.resizing))						
							for stamp in pairs(self.selected) do
								if self.resizing.ulx then
									stamp.x = stamp.x + dx
									stamp.w = math.max(1, stamp.w - dx)
								else
									stamp.w = math.max(1, stamp.w + dx)
								end
								if self.resizing.uly then
									stamp.y = stamp.y + dy
									stamp.h = math.max(1, stamp.h - dy)
								else
									stamp.h = math.max(1, stamp.h + dy)
								end
							end
							self:refreshStampBlob()
						else
							for stamp in pairs(self.selected) do
								stamp.x = stamp.x + dx
								stamp.y = stamp.y + dy
							end
							self:refreshStampBlob()
						end
						self.lastMoveDown:set(mouseX, mouseY)
					end
				elseif leftButtnRelease then
				end

				if not tilemapPanHandled then
					self.tilePanPressed = false
				end

				if not self.tooltip then
					self:setTooltip(tx..','..ty, mouseX-8, mouseY-8, 0xfc, 0)
				end
			end
		end

		if app:keyp'delete' or app:keyp'backspace' then
			for _,i in ipairs(table.map(self.selected, function(_,sel,t)
				return assert(table.find(self.stamps, sel)), #t+1
			end):sort(function(a,b) 
				return a > b
			end)) do
				self.stamps:remove(i)
			end
			self:refreshStampBlob()
			self.selected = {}
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

function EditBrushmap:refreshStampBlob()
	local app = self.app
	local brushmapBlob = app.blobs.brushmap[self.brushmapBlobIndex+1]
	if not brushmapBlob then
		error("WARNING trying to save brushmap when there's no brushmap blob selected")	
		return
	end
	brushmapBlob.data = tolua(self.stamps)
	-- TODO ... regen the ROM or something? idk?
end

return EditBrushmap
