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
local vec2d = require 'vec-ffi.vec2d'

local numo9_rom = require 'numo9.rom'
local spriteSize = numo9_rom.spriteSize
local frameBufferSize = numo9_rom.frameBufferSize
local frameBufferSizeInTiles = numo9_rom.frameBufferSizeInTiles

-- returns highest-to-lowest indexes of the selected keys found in stamps
local function getSelIndexes(selected, stamps)
	return table.map(selected, function(_,sel,t)
		return assert(table.find(stamps, sel)), #t+1
	end):sort(function(a,b)
		return a > b
	end)
end


local EditBrushmap = require 'numo9.ui':subclass()

function EditBrushmap:init(args)
	EditBrushmap.super.init(self, args)

	self:onCartLoad()
end

function EditBrushmap:onCartLoad()
	self.brushmapBlobIndex = 0
	self.tilemapBlobIndex = 0
	self.sheetBlobIndex = 0
	self.paletteBlobIndex = 0

	-- in case there's one there
	self:readSelBrushmapBlob()
end

function EditBrushmap:update()
	local app = self.app

	EditBrushmap.super.update(self)

	local gameEnv = app.gameEnv
	if not gameEnv then
		app:drawMenuText("plz run your game once to reload the code env", 4, 128)
		return
	end
	local brushes = gameEnv.numo9_brushes
	if not brushes then
		app:drawMenuText("define 'numo9_brushes' in your code to use brushes", 4, 128)
		return
	end

	local brushesKeys = table.keys(brushes):sort()
	local leftButtonDown = app:key'mouse_left'
	local leftButtonPress = app:keyp'mouse_left'
	local leftButtonRelease = app:keyr'mouse_left'
	local mouseX, mouseY = app.ram.mousePos:unpack()

	local draw16As0or1 = self.draw16Sprites and 1 or 0
	local tileBits = self.draw16Sprites and 4 or 3
	local tileSizeInTiles = bit.lshift(1, draw16As0or1)
	local tileSizeInPixels = bit.lshift(1, tileBits)

	app:matident()

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

			app:drawBrush(
				brushIndex,
				stampScreenX, stampScreenY,
				self.brushPreviewSize, self.brushPreviewSize,
				0,
				self.draw16Sprites,
				self.sheetBlobIndex)

			local stampWidthInPixels = self.brushPreviewSize * tileSizeInPixels
			local stampHeightInPixels = self.brushPreviewSize * tileSizeInPixels
			if brushIndex == self.selBrushIndex then
				app:drawBorderRect(
					stampScreenX,
					stampScreenY,
					stampWidthInPixels,
					stampHeightInPixels,
					27,
					ni,
					app.paletteMenuTex
				)
			end

			-- TODO left down + drag to scroll
			if leftButtonPress
			and mouseX >= stampScreenX
			and mouseY >= stampScreenY
			and mouseX < stampScreenX + stampWidthInPixels
			and mouseY < stampScreenY + stampHeightInPixels
			then
				self.selBrushIndex = brushIndex
			end

			stampScreenX = stampScreenX + tileSizeInPixels * self.brushPreviewSize
			if stampScreenX > pickW then
				stampScreenX = 0
				stampScreenY = stampScreenY + tileSizeInPixels * self.brushPreviewSize
			end
		end
	end

	local brushmapBlob = app.blobs.brushmap[self.brushmapBlobIndex+1]
	if not brushmapBlob then
		app:drawMenuText("push + on the brushmap blob select to continue", 4, 128)
	else
		x, y = 0, 8

		if not self.pickOpen then

			local mapX = 0
			local mapY = spriteSize.y	-- fontSize.y
			-- size of the map on the screen, in tiles
			local mapSizeInTiles = vec2i(frameBufferSizeInTiles:unpack())
			-- size of the map on the screen, in pixels
			local mapSizeInPixels = vec2i(
				bit.lshift(mapSizeInTiles.x, tileBits),
				bit.lshift(mapSizeInTiles.y, tileBits))


			app:matident()
			app:mattrans(mapX, mapY)
			app:matscale(self.scale, self.scale)
			app:mattrans(-self.tilemapPanOffset.x, -self.tilemapPanOffset.y)

			for _,stamp in ipairs(self.stamps) do
				app:drawBrush(
					tonumber(stamp.brush),	-- might be nil
					stamp.x * tileSizeInPixels,
					stamp.y * tileSizeInPixels,
					stamp.w,
					stamp.h,
					stamp.orientation,
					self.draw16Sprites,
					self.sheetBlobIndex)
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


			-- only do interaction if we're not on the top UI bar ...
			if mouseY > mapY then

				local function fbToTileCoord(cx, cy)
					return
						((cx - mapX) / self.scale + self.tilemapPanOffset.x) / tileSizeInPixels,
						((cy - mapY) / self.scale + self.tilemapPanOffset.y) / tileSizeInPixels
				end
				local ftx, fty = fbToTileCoord(mouseX, mouseY)
				local tx = math.floor(ftx)
				local ty = math.floor(fty)

				local tilemapPanHandled
				local function tilemapPan(press)
					tilemapPanHandled = true
					if press then
						if mouseX >= mapX and mouseX < mapX + mapSizeInPixels.x
						and mouseY >= mapY and mouseY < mapY + mapSizeInPixels.y
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
						if stamp.x <= ftx and ftx < stamp.x + stamp.w
						and stamp.y <= fty and fty < stamp.y + stamp.h
						then
							selUnder:insert(stamp)
						end
					end
--DEBUG:print('#selUnder', #selUnder)
					self.lastMoveDown:set(mouseX, mouseY)
					local mx = math.floor(mouseX / tileSizeInPixels)
					local my = math.floor(mouseY / tileSizeInPixels)
--DEBUG:print('ftx', ftx, 'fty', fty)
					if #selUnder > 0 then
						-- check corner vs center for dragging or resizing
						self.resizing = false

						for _,stamp in ipairs(selUnder) do
--DEBUG:print('checking', require 'ext.tolua'(stamp))
							if ftx >= stamp.x and ftx < stamp.x + stamp.w
							and fty >= stamp.y and fty < stamp.y + stamp.h
							then
								local nearL = math.abs(stamp.x - ftx) <= .5
								local nearU = math.abs(stamp.y - fty) <= .5
								local nearR = math.abs(stamp.x + stamp.w - ftx) <= .5
								local nearD = math.abs(stamp.y + stamp.h - fty) <= .5
								if nearL or nearR or nearU or nearD then
--DEBUG:print('edge', nearL, nearU, nearR, nearD)
									if nearL or nearR then
										self:setTooltip('-', mouseX, mouseY, 0xc)
									elseif nearU or nearD then
										self:setTooltip('|', mouseX, mouseY, 0xc)
									end
									-- TODO what if it's a stamp smaller than 3x3?
									-- then we'll click a border no matter what ...
									self.resizing = {
										ulx = nearL,
										uly = nearU,
									}
									break
								else
--DEBUG:print'move'
									-- center-click on something
									self.resizing = false
									break
								end
							end
						end
--DEBUG:print('resizing', require 'ext.tolua'(self.resizing))
					else
						-- pressed down but not on a selected ...
						-- did we press down on an unselected?
						self.selected = {}
						for _,stamp in ipairs(self.stamps) do
							if mx >= stamp.x and mx < stamp.x + stamp.w
							and my >= stamp.y and my < stamp.y + stamp.h
							then
								self.orientation = stamp.orientation
								self.selected[stamp] = true
							end
						end
						if not next(self.selected) then
							-- we pushed down on nothing ...
							-- create, pan, or select-box?

							-- create
							local stamp = ffi.new('Stamp', {
								brush = self.selBrushIndex,
								x = tx,
								y = ty,
								w = 1,	-- default size?
								h = 1,
							})
							self.stamps:insert(stamp)
							self:writeSelBrushmapBlob()
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
--DEBUG:print('resizing', require 'ext.tolua'(self.resizing))
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
							self:writeSelBrushmapBlob()
						else
							for stamp in pairs(self.selected) do
								stamp.x = stamp.x + dx
								stamp.y = stamp.y + dy
							end
							self:writeSelBrushmapBlob()
						end
						self.lastMoveDown:set(mouseX, mouseY)
					end
				elseif leftButtonRelease then
					-- if any are selected then move them to the front
					local sel = table()
					for _,i in ipairs(getSelIndexes(self.selected, self.stamps)) do
						sel:insert(self.stamps:remove(i))
					end
					self.stamps:append(sel)
					self:writeSelBrushmapBlob()	-- order changed
				end

				if not tilemapPanHandled then
					self.tilePanPressed = false
				end

				if not self.tooltip then
					self:setTooltip(tx..','..ty, mouseX-8, mouseY-8, 0xc, 0)
				end
			end
		end

		if app:keyp'delete' or app:keyp'backspace' then
			for _,i in ipairs(getSelIndexes(self.selected, self.stamps)) do
				self.stamps:remove(i)
			end
			self:writeSelBrushmapBlob()
			self.selected = {}
		end
	end

	app:matident()

	local x, y = 50, 0
	self:guiBlobSelect(x, y, 'brushmap', self, 'brushmapBlobIndex', function()
		-- assume we already wrote it as soon as a changed happened
		self:readSelBrushmapBlob()
	end)
	x = x + 12
	self:guiBlobSelect(x, y, 'tilemap', self, 'tilemapBlobIndex')
	x = x + 12
	self:guiBlobSelect(x, y, 'sheet', self, 'sheetBlobIndex')
	x = x + 12
	self:guiBlobSelect(x, y, 'palette', self, 'paletteBlobIndex')
	x = x + 12

	do--if brushmapBlob then
		-- title controls
		x = x + 2

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
		x = x + 8

		self:guiSpinner(x, y, function(dx)
			self.orientation = bit.band(7, self.orientation + dx)
			for stamp in pairs(self.selected) do
				stamp.orientation = self.orientation
			end
		end, 'orient='..tostring(self.orientation))
		if next(self.selected) then
			self:writeSelBrushmapBlob()
		end
		x = x + 16
	end

	self:drawTooltip()
end

function EditBrushmap:readSelBrushmapBlob()
	local app = self.app

	-- table-of-Stamp cdata , each allocated individually so that vector-resizes dont mess up pointers into this table (like the selected[] table uses)
	self.stamps = table()

	local brushmapBlob = app.blobs.brushmap[self.brushmapBlobIndex+1]
	if brushmapBlob then
		for _,stamp in ipairs(brushmapBlob.vec) do
			self.stamps:insert(ffi.new('Stamp', stamp))	-- allocate a new Stamp so that its not pointing to memory in the blob, so if the blob vec resizes we don't lose our pointer
		end
	end

	-- reset UI state variables while we're here

	self.brushPreviewSize = 3

	self.lastMoveDown = vec2i()

	self.selected = {}

	self.selBrushIndex = 1	-- 0-based? 1-based? this indexes into the Lua table in code so 1-based for now

	self.tilePanDownPos = vec2i()
	self.tilemapPanOffset = vec2d()
	self.tilePanPressed = false
	self.scale = 1
	self.drawGrid = false
	self.draw16Sprites = false
	self.orientation = 0	-- 2D orientation: bit 0 = hflip bits 12 = rotation


end

function EditBrushmap:writeSelBrushmapBlob()
	local app = self.app
	local brushmapBlob = app.blobs.brushmap[self.brushmapBlobIndex+1]
	if not brushmapBlob then
		error("WARNING trying to save brushmap when there's no brushmap blob selected")
		return
	end
	brushmapBlob.vec:clear()
	for _,stamp in ipairs(self.stamps) do
		brushmapBlob.vec:emplace_back()[0] = stamp
	end
	-- TODO ... regen the ROM or something? idk?
	-- ... yeah that's what typically happens in the editor
	-- but doing so means invalidating all our ram ptrs ...
	-- so for now brushmaps can't be edited live
end

return EditBrushmap
