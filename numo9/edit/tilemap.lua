local ffi = require 'ffi'
local math = require 'ext.math'
local table = require 'ext.table'
local assert = require 'ext.assert'
local vec2i = require 'vec-ffi.vec2i'
local vec2d = require 'vec-ffi.vec2d'
require 'ffi.req' 'c.string'	-- memcmp
local Image = require 'image'

local clip = require 'numo9.clipboard'
local Undo = require 'numo9.ui.undo'
local TileSelect = require 'numo9.ui.tilesel'

local numo9_rom = require 'numo9.rom'
local spriteSize = numo9_rom.spriteSize
local frameBufferSize = numo9_rom.frameBufferSize
local frameBufferSizeInTiles = numo9_rom.frameBufferSizeInTiles
local spriteSheetSizeInTiles = numo9_rom.spriteSheetSizeInTiles
local tilemapSize = numo9_rom.tilemapSize
local clipMax = numo9_rom.clipMax


local uint8_t = ffi.typeof'uint8_t'


-- used by fill
local dirs = {
	{0,-1},
	{0,1},
	{-1,0},
	{1,0},
}

local EditTilemap = require 'numo9.ui':subclass()

function EditTilemap:init(args)
	EditTilemap.super.init(self, args)

	self.undo = Undo{
		get = function()
			-- for now I'll just have one undo buffer for the current sheet
			-- TODO palette too
			local app = self.app
			local tilemapRAM = app.blobs.tilemap[self.tilemapBlobIndex+1].ramgpu
			return {
				tilemap = tilemapRAM.image:clone(),
			}
		end,
		changed = function(entry)
			local app = self.app
			local tilemapRAM = app.blobs.tilemap[self.tilemapBlobIndex+1].ramgpu
			return 0 ~= ffi.C.memcmp(entry.tilemap.buffer, tilemapRAM.image.buffer, tilemapRAM.image:getBufferSize())
		end,
	}

	self:onCartLoad()
end

function EditTilemap:onCartLoad()
	self.sheetBlobIndex = 0
	self.tilemapBlobIndex = 0
	self.paletteBlobIndex = 0	-- TODO :drawTileMap() allow specifying palette #

	self.tileSel = TileSelect{edit=self}
	self.autotileOpen = false
	self.autotilePreviewBorder = 1

	self.tileOrAutotile = 'tile'	-- 'tile' or 'autotile' depending on which you're painting with
	self.autotileSel = nil			-- index into `numo9_autotile` array

	-- and this is for copy paste in the tilemap
	self.tileSelDown = vec2i()
	self.tileSelUp = vec2i()
	self.selPalHiOffset = 0
	self.orientation = 0	-- 2D orientation: bit 0 = hflip bits 12 = rotation
	self.drawMode = 'draw'
	self.gridSpacing = 1
	self.penSize = 1
	self.tilePanDownPos = vec2i()
	self.tilemapPanOffset = vec2d()
	self.tilePanPressed = false
	self.scale = 1

	self.drawGrid = false
	self.draw16Sprites = false

	self.undo:clear()
end

function EditTilemap:update()
	local app = self.app

	local draw16As0or1 = self.draw16Sprites and 1 or 0

	local leftButtonDown = app:key'mouse_left'
	local leftButtonRelease = app:keyr'mouse_left'
	local leftButtonPress = app:keyp'mouse_left'
	local mouseX, mouseY = app:invTransform(app.ram.mousePos:unpack())

	-- hmm without this the panning starts to drift
	-- TODO fix all this coordinate conversion stuff someday
	mouseX = math.floor(mouseX)
	mouseY = math.floor(mouseY)


	local shift = app:key'lshift' or app:key'rshift'

	EditTilemap.super.update(self)

	-- title controls
	local x = 90
	local y = 0


	self.tileSel:button(x,y)
	x = x + 6

	-- here, autotile-select
	local gameEnv = app.gameEnv
	local canAutoTile = gameEnv and gameEnv.numo9_autotile
	if self:guiButton('A', x, y, self.tileOrAutotile == 'autotile',
		canAutoTile and 'autotile'
		or "define 'numo9_autotile' for autotiling"
	) then
		if canAutoTile then
			self.autotileOpen = not self.autotileOpen
		else
			self.autotileOpen = false
		end
	end
	x = x + 6

	self:guiSpinner(x, y, function(dx)
		self.penSize = math.max(1, self.penSize + dx)
	end, 'penSize='..tostring(self.penSize))
	x = x + 12

	self:guiSpinner(x, y, function(dx)
		self.autotilePreviewBorder = math.max(1, self.autotilePreviewBorder + dx)
	end, 'autotilePreviewBorder='..tostring(self.autotilePreviewBorder))
	x = x + 12

	if self:guiButton('X', x, y, self.draw16Sprites, self.draw16Sprites and '16x16' or '8x8') then
		self.draw16Sprites = not self.draw16Sprites
	end
	x = x + 6

	-- sprite edit method
	self:guiRadio(x, y, {'draw', 'fill', 'dropper', 'pan', 'select'}, self.drawMode, function(result)
		self.drawMode = result
	end)
	x = x + 6 * 6

	self:guiSpinner(x, y, function(dx)
		self.orientation = bit.band(7, self.orientation + dx)
	end, 'orient='..tostring(self.orientation))
	x = x + 16

	self:guiSpinner(x, y, function(dx)
		self.selPalHiOffset = bit.band(7, self.selPalHiOffset + dx)
	end, 'palhi='..self.selPalHiOffset)
	x = x + 16

	self:guiSpinner(x, y, function(dx)
		self.gridSpacing = math.clamp(self.gridSpacing + dx, 1, 256)
	end, 'grid='..self.gridSpacing)
	x = x + 16

	if self:guiButton('G', x, y, self.drawGrid, 'grid') then
		self.drawGrid = not self.drawGrid
	end

	local tilemapRAM = app.blobs.tilemap[self.tilemapBlobIndex+1].ramgpu

	local tileBits = self.draw16Sprites and 4 or 3
	local tileSize = bit.lshift(1, tileBits)

	-- draw map
	local mapX = 0
	local mapY = spriteSize.y
	-- size of the map on the screen, in tiles
	local mapSizeInTiles = vec2i(frameBufferSizeInTiles:unpack())
	-- size of the map on the screen, in pixels
	local mapSizeInPixels = vec2i(
		bit.lshift(mapSizeInTiles.x, tileBits),
		bit.lshift(mapSizeInTiles.y, tileBits))

	local function pan(dx,dy)	-- dx, dy in screen coords right?
		self.tilemapPanOffset.x = self.tilemapPanOffset.x + dx
		self.tilemapPanOffset.y = self.tilemapPanOffset.y + dy
	end
	if shift then
		pan(128 / self.scale, 128 / self.scale)
		self.scale = self.scale * math.exp(.1 * app.ram.mouseWheel.y)
		pan(-128 / self.scale, -128 / self.scale)
	else
		pan(
			-bit.lshift(spriteSize.x, draw16As0or1) * app.ram.mouseWheel.x,
			-bit.lshift(spriteSize.y, draw16As0or1) * app.ram.mouseWheel.y
		)
	end


	local tileSelIndex = bit.bor(
		self.tileSel.pos.x
		+ spriteSheetSizeInTiles.x * self.tileSel.pos.y,
		bit.lshift(bit.band(7, self.selPalHiOffset), 10),
		bit.lshift(bit.band(7, self.orientation), 13)
	)
	self:guiTextField(
		202, 0, 20,
		('%04X'):format(tileSelIndex), nil,
		function(result)
			result = tonumber(result, 16)
			if result then
				self.tileSel.pos.x = result % spriteSheetSizeInTiles.x
				self.tileSel.pos.y = (result - self.tileSel.pos.x) / spriteSheetSizeInTiles.x
				self.selPalHiOffset = bit.band(7, bit.rshift(result, 10))
				self.orientation = bit.band(7, bit.rshift(result, 13))
			end
		end
	)

	--self:guiSetClipRect(mapX, mapY, mapSizeInPixels.x-1, mapSizeInPixels.y-1)
	self:guiSetClipRect(-1000, mapY, 3000, mapSizeInPixels.y-1)

	app:matMenuReset()
	app:mattrans(mapX, mapY)
	app:matscale(self.scale, self.scale)
	app:mattrans(-self.tilemapPanOffset.x, -self.tilemapPanOffset.y)

	app:drawQuadTex(
		app.paletteMenuTex,
		app.checkerTex,
		-1, -1,									-- x y
		2+bit.lshift(tilemapSize.x, tileBits),	-- w
		2+bit.lshift(tilemapSize.y, tileBits),	-- h
		0, 0,									-- tx ty tw th
		1, 1 --2+mapSizeInPixels.x*2, 2+mapSizeInPixels.y*2
	)

	-- set the current selected palette via RAM registry to self.paletteBlobIndex
	local pushPalBlobIndex = app.ram.paletteBlobIndex
	app.ram.paletteBlobIndex = self.paletteBlobIndex
	app:drawTileMap(
		0,		-- upper-left index in the tile tex
		0,
		tilemapSize.x,	-- tiles wide
		tilemapSize.y,	-- tiles high
		0,		-- pixel x
		0,		-- pixel y
		0,		-- map index offset / high page
		self.draw16Sprites,	-- draw 16x16 vs 8x8
		self.sheetBlobIndex	-- sprite vs tile sheet
	)
	app.ram.paletteBlobIndex = pushPalBlobIndex

--self:setTooltip(self.tilemapPanOffset..' x'..self.scale, mouseX-8, mouseY-8, 0xfc, 0)
	if self.drawGrid then
		local step = bit.lshift(self.gridSpacing, tileBits)
		local gx = math.floor(self.tilemapPanOffset.x / step) * step
		local gy = math.floor(self.tilemapPanOffset.y / step) * step
		local xmin = math.max(0, gx-step)
		local xmax = math.min(gx+3*step+frameBufferSize.x/self.scale, bit.lshift(tilemapSize.x, tileBits))
		local ymin = math.max(0, gy-step)
		local ymax = math.min(gy+3*step+frameBufferSize.y/self.scale, bit.lshift(tilemapSize.y, tileBits))
		for i=xmin,xmax,step do
			app:drawSolidLine(i, ymin, i, ymax, 1)
		end
		for j=ymin,ymax,step do
			app:drawSolidLine(xmin, j, xmax, j, 1)
		end
	end

	if self.drawMode == 'select' then
		local selx = math.min(self.tileSelDown.x, self.tileSelUp.x)
		local sely = math.min(self.tileSelDown.y, self.tileSelUp.y)
		local selw = math.max(self.tileSelDown.x, self.tileSelUp.x) - selx + 1
		local selh = math.max(self.tileSelDown.y, self.tileSelUp.y) - sely + 1
		app:drawBorderRect(
			tileSize * selx,
			tileSize * sely,
			tileSize * selw,
			tileSize * selh,
			0xd,
			nil,
			app.paletteMenuTex
		)
	end


	local function fbToTileCoord(cx, cy)
		return
			(cx - mapX) / (bit.lshift(spriteSize.x, draw16As0or1) * self.scale) + self.tilemapPanOffset.x / bit.lshift(spriteSize.x, draw16As0or1),
			(cy - mapY) / (bit.lshift(spriteSize.y, draw16As0or1) * self.scale) + self.tilemapPanOffset.y / bit.lshift(spriteSize.y, draw16As0or1)
	end
	local tx, ty = fbToTileCoord(mouseX, mouseY)
	tx = math.floor(tx)
	ty = math.floor(ty)

	-- while we're here, draw over the selected tile
	if tx >= 0 and tx < tilemapSize.x
	and ty >= 0 and ty < tilemapSize.y
	then
		app:drawBorderRect(tx * tileSize, ty * tileSize, tileSize, tileSize, 0x1b, nil, app.paletteMenuTex)
	end


	-- since when is clipMax having problems?
	-- TODO FIXME since guiSeetClipRect uses the matrix state ...
	app:matMenuReset()
	--self:guiSetClipRect(0, 0, clipMax, clipMax)
	self:guiSetClipRect(0, 0, 256, 256)

	if self.autotileOpen then
		-- autotile box
		local winX = 2 * spriteSize.x
		local winY = 2 * spriteSize.y
		local winW = 256 - 2 * winX
		local winH = 256 - 2 * winY
		app:drawBorderRect(
			winX-1,
			winY-1,
			winW+2,
			winH+2,
			10,
			nil,
			app.paletteMenuTex
		)
		app:drawSolidRect(
			winX,
			winY,
			winW,
			winH,
			1,
			nil,
			nil,
			app.paletteMenuTex
		)

		if gameEnv.numo9_autotile then
			local selx, sely = self.tileSelDown:unpack()
			for autotileIndex,autotile in ipairs(gameEnv.numo9_autotile) do
				local pw, ph = 32, 32
				local px = winX + pw * ((autotileIndex - 1) % 4)
				local py = winY + ph * math.floor((autotileIndex - 1) / 4)

				if self.tileOrAutotile == 'autotile'
				and self.autotileSel == autotileIndex
				then
					app:drawBorderRect(px, py, pw, ph, 0xd, nil, app.paletteMenuTex)
				end

				local pushPalBlobIndex = app.ram.paletteBlobIndex
				app.ram.paletteBlobIndex = self.paletteBlobIndex

				-- show a rect around what the current selected tile would be like if it was painted with this autotile brush
				local r = self.penSize - 1 + 2 * self.autotilePreviewBorder
				app:drawTileMap(
					selx - self.autotilePreviewBorder,		-- upper-left index in the tile tex
					sely - self.autotilePreviewBorder,
					r,		-- tiles wide
					r,		-- tiles high
					px,		-- pixel x
					py,		-- pixel y
					0,		-- map index offset / high page
					self.draw16Sprites,	-- draw 16x16 vs 8x8
					self.sheetBlobIndex	-- sprite vs tile sheet
				)
				--[[ hmm how to use bigger previews ...
				for dx=-self.autotilePreviewBorder,self.autotilePreviewBorder + self.penSize do
					for dy=-self.autotilePreviewBorder,self.autotilePreviewBorder + self.penSize do
				--]]
				-- [[ for now the autotile functions should only accept -1,1 for dx
				-- but TODO soon, dont use dx at all
				for dx=-1,1 do
					for dy=-1,1 do
				--]]
						-- then draw
						-- TODO at the moment autotile writes in place
						-- so preview is tough to consider
						-- but if we had it return written content
						-- then I'd need it to return a region of tile values equal to the pen radius ...
						-- and the autotiles themselves operate on mget/mset/peek/poke so ...
						-- how to preview at all ...
						-- how to do this ...
						local tile = autotile(selx, sely, dx, dy, self.tilemapBlobIndex)
						if tile then
							app:drawSprite(
								bit.band(tile, 0x3ff),
								px + (dx + self.autotilePreviewBorder) * tileSize,
								py + (dy + self.autotilePreviewBorder) * tileSize,
								1,
								1,
								bit.band(7, bit.rshift(tile, 13)),
								1,
								1,
								bit.lshift(bit.band(7, bit.rshift(tile, 10)), 5),	-- palette offset
								nil,
								nil,
								nil
							)
						end
					end
				end

				app.ram.paletteBlobIndex = pushPalBlobIndex

				if leftButtonRelease
				and mouseX >= px and mouseX < px + pw
				and mouseY >= py and mouseY < py + ph
				then
					self.tileOrAutotile = 'autotile'
					self.autotileSel = autotileIndex
					self.autotileOpen = false
				end
			end
		end

	elseif self.tileSel:doPopup() then
		self.tileOrAutotile = 'tile'
	else
		-- TODO allow drawing while picking window is open, like tic80 does?
		-- maybe ... then i should disable the auto-close-on-select ...
		-- and I should also resize the pick tile area

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

		local function gettile(tx, ty)
			return app:mget(tx, ty, self.tilemapBlobIndex)
		end

		-- TODO move the dx,dy out of this function ... and fix it.
		local function puttile(tx, ty, dx, dy)
			local tileSelIndex = bit.bor(
				self.tileSel.pos.x + (dx % self.tileSel.size.x)
				+ spriteSheetSizeInTiles.x * (self.tileSel.pos.y + (dy % self.tileSel.size.y)),
				bit.lshift(bit.band(7, self.selPalHiOffset), 10),
				bit.lshift(bit.band(7, self.orientation), 13)
			)

			self.undo:pushContinuous()
			self:edit_mset(tx, ty, tileSelIndex, self.tilemapBlobIndex)
		end

		-- TODO pen size here
		if self.drawMode == 'dropper'
		or (self.drawMode == 'draw' and shift)
		or (self.drawMode == 'fill' and shift)
		then
			if leftButtonPress
			and mouseX >= mapX and mouseX < mapX + mapSizeInPixels.x
			and mouseY >= mapY and mouseY < mapY + mapSizeInPixels.y
			then
				local tileSelIndex = gettile(tx, ty)
				if tileSelIndex then
					self.tileSel.pos.x = tileSelIndex % spriteSheetSizeInTiles.x
					self.tileSel.pos.y = ((tileSelIndex - self.tileSel.pos.x) / spriteSheetSizeInTiles.x) % spriteSheetSizeInTiles.y
					self.selPalHiOffset = bit.band(7, bit.rshift(tileSelIndex, 10))
					self.orientation = bit.band(7, bit.rshift(tileSelIndex, 13))
					self.tileOrAutotile = 'tile'
				end
			end
		elseif self.drawMode == 'draw' then
			if leftButtonDown
			and mouseX >= mapX and mouseX < mapX + mapSizeInPixels.x
			and mouseY >= mapY and mouseY < mapY + mapSizeInPixels.y
			and 0 <= tx and tx < tilemapSize.x
			and 0 <= ty and ty < tilemapSize.y
			then
				if self.tileOrAutotile == 'tile' then
					local tx0 = tx -- - math.floor(self.penSize / 2)
					local ty0 = ty -- - math.floor(self.penSize / 2)
					local r = self.penSize
					local l = math.floor((r-1)/2)
					-- hmm right now penSize is the border in tiles around the stamp
					-- should instead penSize be the number of stamps to plot in a grid?
					for dy=-l,-l + r-1 + math.ceil(self.tileSel.size.y / bit.lshift(1,draw16As0or1))-1 do
						-- hmm how should stamps and pensizes work together?
						local ty = ty0 + dy
						for dx=-l,-l + r-1 + math.ceil(self.tileSel.size.x / bit.lshift(1,draw16As0or1))-1 do
							local tx = tx0 + dx
							puttile(tx,ty, bit.lshift(dx, draw16As0or1), bit.lshift(dy, draw16As0or1))
						end
					end
				elseif self.tileOrAutotile == 'autotile' then
					local r = self.penSize
					local l = math.floor((r-1)/2)
					local f = gameEnv and gameEnv.numo9_autotile[self.autotileSel]
					if f then
						self.undo:pushContinuous()
						--[[
						for dy=-l,-l+r-1 do
							for dx=-l,-l+r-1 do
								f(tx, ty, dx, dy, self.tilemapBlobIndex)
							end
						end
						--]]
						-- [[
						for dy=-1,1 do
							for dx=-1,1 do
								local tile = f(tx, ty, dx, dy, self.tilemapBlobIndex)
								if tile then
									self:edit_mset(tx + dx, ty + dy, tile, self.tilemapBlobIndex)
								end
							end
						end
						--]]
					end
				end
			end
		elseif self.drawMode == 'fill' then
			if leftButtonDown
			and mouseX >= mapX and mouseX < mapX + mapSizeInPixels.x
			and mouseY >= mapY and mouseY < mapY + mapSizeInPixels.y
			then
				local srcTile = gettile(tx, ty)

				local tileSelIndex = bit.bor(
					self.tileSel.pos.x
					+ spriteSheetSizeInTiles.x * self.tileSel.pos.y,
					bit.lshift(bit.band(7, self.selPalHiOffset), 10),
					bit.lshift(bit.band(7, self.orientation), 13)
				)

				if srcTile ~= tileSelIndex then
					local fillstack = table()
					puttile(tx, ty, 0, 0)
					fillstack:insert{tx, ty}
					while #fillstack > 0 do
						local tx0, ty0 = table.unpack(fillstack:remove())
						for _,dir in ipairs(dirs) do
							local tx1, ty1 = tx0 + dir[1], ty0 + dir[2]
							-- [[ constrain to entire sheet (TODO flag for this option)
							if tx1 >= 0 and tx1 < tilemapSize.x
							and ty1 >= 0 and ty1 < tilemapSize.y
							--]]
							--[[ constrain to current selection
							if  tx1 >= self.tileSel.pos.x * spriteSize.x
							and ty1 >= self.tileSel.pos.y * spriteSize.y
							and tx1 < (self.tileSel.pos.x + self.tileSel.size.x) * spriteSize.x
							and ty1 < (self.tileSel.pos.y + self.tileSel.size.y) * spriteSize.y
							--]]
							and gettile(tx1, ty1) == srcTile
							then
								puttile(tx1, ty1, 0, 0)
								fillstack:insert{tx1, ty1}
							end
						end
					end
				end
			end
		elseif self.drawMode == 'select' then
			if leftButtonPress then
				self.tileSelDown:set(tx, ty)
				self.tileSelDown.x = math.clamp(self.tileSelDown.x, 0, tilemapSize.x-1)
				self.tileSelDown.y = math.clamp(self.tileSelDown.y, 0, tilemapSize.x-1)
				self.tileSelUp:set(self.tileSelDown:unpack())
			elseif leftButtonDown then
				self.tileSelUp:set(tx, ty)
			end
		elseif self.drawMode == 'pan' then
			if leftButtonDown then
				tilemapPan(leftButtonPress)
			end
		end

		if not tilemapPanHandled then
			self.tilePanPressed = false
		end

		if not self.tooltip then
			self:setTooltip(tx..','..ty, mouseX-8, mouseY-8, 0xfc, 0)
		end
	end

	app:matMenuReset()

	local uikey
	if ffi.os == 'OSX' then
		uikey = app:key'lgui' or app:key'rgui'
	else
		uikey = app:key'lctrl' or app:key'rctrl'
	end
	if uikey then
		local selx = math.min(self.tileSelDown.x, self.tileSelUp.x)
		local sely = math.min(self.tileSelDown.y, self.tileSelUp.y)
		local selw = math.max(self.tileSelDown.x, self.tileSelUp.x) - selx + 1
		local selh = math.max(self.tileSelDown.y, self.tileSelUp.y) - sely + 1
		if app:keyp'x' or app:keyp'c' then
			assert(not tilemapRAM.dirtyGPU)
			local image = tilemapRAM.image:copy{x=selx, y=sely, width=selw, height=selh}
			-- 1-channel uint16_t image
			local channels = 4
			local imageRGBA = Image(image.width, image.height, channels, uint8_t)
			for i=0,image.width*image.height-1 do
				imageRGBA.buffer[0 + channels * i] = bit.band(0xff, image.buffer[i])
				imageRGBA.buffer[1 + channels * i] = bit.band(0xff, bit.rshift(image.buffer[i], 8))
				imageRGBA.buffer[2 + channels * i] = 0
				imageRGBA.buffer[3 + channels * i] = 0xff
			end
			clip.image(imageRGBA)
			if app:keyp'x' then
				self.undo:push()
				tilemapRAM.dirtyCPU = true
				assert.eq(tilemapRAM.image.channels, 1)
				for j=sely,sely+selh-1 do
					for i=selx,selx+selw-1 do
						self:edit_mset(i, j, 0, self.tilemapBlobIndex)
					end
				end
			end
		elseif app:keyp'v' then
			-- TODO how to specify where to paste? beforehand?
			-- or paste as overlay until you click outside the box?
			-- or use the select rect to specify ... then only paste in select mode?
			-- how about allowing over-paste?  same with over-draw., how about a flag to allow it or not?
			assert(not tilemapRAM.dirtyGPU)
			local image = clip.image()
			if image then
				self.undo:push()
				-- 4-channel uint8_t image
				for j=0,image.height-1 do
					for i=0,image.width-1 do
						local destx = i + selx
						local desty = j + sely
						if destx >= 0 and destx < tilemapRAM.image.width
						and desty >= 0 and desty < tilemapRAM.image.height
						then
							local c = 0
							local readChannels = math.min(image.channels, 2)	-- don't include alpha channel... heck only need R and G ...
							for ch=readChannels-1,0,-1 do
								c = bit.lshift(c, 8)
								c = bit.bor(c, image.buffer[ch + image.channels * (i + image.width * j)])
							end
							self:edit_mset(destx, desty, c, self.tilemapBlobIndex)
						end
					end
				end
			end
		elseif app:keyp'z' then
			self:popUndo(shift)
		end
	end

	local x, y = 50, 0

	-- draw ui menubar last so it draws over the rest of the page
	-- TODO put this first for blocking subsequent click fallthroughs
	--		or put it last for drawing over the display
	-- 		or put it first + use depth buffer for both ...
	self:guiBlobSelect(x, y, 'tilemap', self, 'tilemapBlobIndex', function()
		-- for now only one undo per tilemap at a time
		self.undo:clear()
	end)

	x = x + 12
	-- the current sheetmap is purely cosmetic, so if it changes no need to push undo
	self:guiBlobSelect(x, y, 'sheet', self, 'sheetBlobIndex')
	x = x + 12
	self:guiBlobSelect(x, y, 'palette', self, 'paletteBlobIndex')
	-- TODO palette spinner, and use selected palette for tilemap render
	-- and TODO add paletteIndex to map() function

	self:drawTooltip()
end

function EditTilemap:popUndo(redo)
	local app = self.app
	local undoEntry = self.undo:pop(redo)
	if undoEntry then
		local tilemapRAM = app.blobs.tilemap[self.tilemapBlobIndex+1].ramgpu
		ffi.C.memcpy(tilemapRAM.image.buffer, undoEntry.tilemap.buffer, tilemapRAM.image:getBufferSize())
		tilemapRAM.dirtyCPU = true
	end
end


return EditTilemap
