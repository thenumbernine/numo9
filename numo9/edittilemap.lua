local ffi = require 'ffi'
local gl = require 'gl'
local math = require 'ext.math'
local vec2i = require 'vec-ffi.vec2i'

local numo9_rom = require 'numo9.rom'
local paletteSize = numo9_rom.paletteSize
local spriteSize = numo9_rom.spriteSize
local frameBufferSize = numo9_rom.frameBufferSize
local frameBufferSizeInTiles = numo9_rom.frameBufferSizeInTiles
local spriteSheetSize = numo9_rom.spriteSheetSize
local spriteSheetSizeInTiles = numo9_rom.spriteSheetSizeInTiles
local tilemapAddr = numo9_rom.tilemapAddr
local tilemapSize = numo9_rom.tilemapSize
local tilemapSizeInSprites = numo9_rom.tilemapSizeInSprites

local EditTilemap = require 'numo9.editor':subclass()

function EditTilemap:init(args)
	EditTilemap.super.init(self, args)

	self.drawGrid = true
	self.pickOpen = false
	self.spriteSelPos = vec2i()
	self.spriteSelSize = vec2i(1,1)
	self.draw16Sprites = false
	self.drawMode = 'draw'	--TODO ui for this
	self.gridSpacing = 1
	self.penSize = 1
	self.tilePanDownPos = vec2i()
	self.tilemapPanOffset = vec2i()
	self.tilePanPressed = false
end

function EditTilemap:update()
	local app = self.app

	local leftButtonDown = app:key'mouse_left'
	local leftButtonPress = app:keyp'mouse_left'
	local leftButtonRelease = app:keyr'mouse_left'
	local mouseX, mouseY = app.ram.mousePos:unpack()

	local shift = app:key'lshift' or app:key'rshift'

	EditTilemap.super.update(self)

	-- title controls
	local x = 104
	local y = 0

	self:guiSpinner(x, y, function(dx)
		self.gridSpacing = math.clamp(self.gridSpacing + dx, 1, 256)
	end, 'grid='..self.gridSpacing)
	x = x + 24

	if self:guiButton('G', x, y, self.drawGrid, 'grid') then
		self.drawGrid = not self.drawGrid
	end
	x = x + 8
	if self:guiButton('T', x, y, self.pickOpen, 'tile') then
		self.pickOpen = not self.pickOpen
	end
	x = x + 8
	if self:guiButton('X', x, y, self.draw16Sprites, self.draw16Sprites and '16x16' or '8x8') then
		self.draw16Sprites = not self.draw16Sprites
	end

	-- sprite edit method
	x = x + 16
	self:guiRadio(x, y, {'draw', 'dropper', 'pan'}, self.drawMode, function(result)
		self.drawMode = result
	end)


	local tileBits = self.draw16Sprites and 4 or 3

	-- draw map
	local mapX = 0
	local mapY = spriteSize.y
	local mapWidthInTiles = frameBufferSizeInTiles.x
	local mapHeightInTiles = frameBufferSizeInTiles.y-2
	local mapWidth = bit.lshift(mapWidthInTiles, tileBits)
	local mapHeight = bit.lshift(mapWidthInTiles, tileBits)

	gl.glScissor(mapX,mapY,mapWidth,mapHeight)
	app:drawQuad(
		mapX,mapY,mapWidth,mapHeight,0,0,mapWidth/2,mapHeight/2,app.checkerTex,0,-1,0xFF
	)
	do
		local tx = self.tilemapPanOffset.x
		local ty = self.tilemapPanOffset.y
		local x = mapX
		local y = mapY
		if tx < 0 then
			x = x + bit.lshift(-tx, tileBits)
			tx = 0
		end
		if ty < 0 then
			y = y + bit.lshift(-ty, tileBits)
			ty = 0
		end
		local tw = math.max(mapWidthInTiles, tilemapSize.x - tx)
		local th = math.max(mapHeightInTiles, tilemapSize.y - ty)
		if tw > 0 and th > 0 then
			app:drawMap(
				tx,		-- upper-left index in the tile tex
				ty,
				tw,		-- tiles wide
				th,		-- tiles high
				x,		-- pixel x
				y,		-- pixel y
				0,		-- map index offset / high page
				self.draw16Sprites	-- draw 16x16 vs 8x8
			)
		end
	end
	if self.drawGrid then
		local step = bit.lshift(self.gridSpacing, tileBits)
		local gx = bit.lshift(-self.tilemapPanOffset.x % self.gridSpacing, tileBits)
		local gy = bit.lshift(-self.tilemapPanOffset.y % self.gridSpacing, tileBits)
		for i=-step,frameBufferSize.x-1,step do
			app:drawSolidLine(
				gx + i,
				spriteSize.y,
				gx + i,
				frameBufferSize.y-spriteSize.y,
				self:color(1)
			)
		end
		for j=spriteSize.y-step,frameBufferSize.y-spriteSize.y-1,step do
			app:drawSolidLine(
				0,
				gy + j,
				frameBufferSize.x,
				gy + j,
				self:color(1)
			)
		end
	end
	gl.glScissor(0,0,frameBufferSize:unpack())

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
			self:color(10))
		app:drawSolidRect(
			pickX,
			pickY,
			pickW,
			pickH,
			self:color(0)
		)
		app:drawQuad(
			pickX,
			pickY,
			pickW,
			pickH,
			-- TODO scrollable pick area ... hmm ...
			-- or TODO use the same scrollable pick area for the sprite editor and the tile editor
			0,
			0,
			1,
			1,
			app.tileTex,
			0,
			-1,
			0,
			0xff
		)
		local spriteX = math.floor((mouseX - pickX) / pickW * spriteSheetSizeInTiles.x)
		local spriteY = math.floor((mouseY - pickY) / pickH * spriteSheetSizeInTiles.y)
		if spriteX >= 0 and spriteX < spriteSheetSizeInTiles.x
		and spriteY >= 0 and spriteY < spriteSheetSizeInTiles.y
		then
			if leftButtonPress then
				-- TODO rect select
				self.spriteSelPos:set(spriteX, spriteY)
				self.spriteSelSize:set(1, 1)
			elseif leftButtonDown then
				self.spriteSelSize.x = math.ceil((math.abs(mouseX - app.ram.lastMousePressPos.x) + 1) / spriteSize.x)
				self.spriteSelSize.y = math.ceil((math.abs(mouseY - app.ram.lastMousePressPos.y) + 1) / spriteSize.y)
			elseif leftButtonRelease then
				self.pickOpen = false
			end
		end

		app:drawBorderRect(
			pickX + self.spriteSelPos.x * spriteSize.x * pickW / spriteSheetSize.x,
			pickX + self.spriteSelPos.y * spriteSize.y * pickH / spriteSheetSize.y,
			spriteSize.x * self.spriteSelSize.x * pickW / spriteSheetSize.x,
			spriteSize.y * self.spriteSelSize.y * pickH / spriteSheetSize.y,
			self:color(13)
		)
	else
		-- TODO allow drawing while picking window is open, like tic80 does?
		-- maybe ... then i should disable the auto-close-on-select ...
		-- and I should also resize the pick tile area

		local draw16As0or1 = self.draw16Sprites and 1 or 0

		local function fbToTileCoord(cx, cy)
			return
				math.floor((cx - mapX) / bit.lshift(spriteSize.x, draw16As0or1)) + self.tilemapPanOffset.x,
				math.floor((cy - mapY) / bit.lshift(spriteSize.y, draw16As0or1)) + self.tilemapPanOffset.y
		end
		local tx, ty = fbToTileCoord(mouseX, mouseY)

		local tilemapPanHandled
		local function tilemapPan(press)
			tilemapPanHandled = true
			if press then
				if mouseX >= mapX and mouseX < mapX + mapWidth
				and mouseY >= mapY and mouseY < mapY + mapHeight
				then
					self.tilePanDownPos:set(mouseX, mouseY)
					self.tilePanPressed = true
				end
			else
				if self.tilePanPressed then
					local tx1, ty1 = fbToTileCoord(mouseX, mouseY)
					local tx0, ty0 = fbToTileCoord(self.tilePanDownPos:unpack())
					-- convert mouse framebuffer pixel movement to sprite texel movement
					local tx = math.round(tx1 - tx0)
					local ty = math.round(ty1 - ty0)
					if tx ~= 0 or ty ~= 0 then
						self.tilemapPanOffset.x = self.tilemapPanOffset.x - tx
						self.tilemapPanOffset.y = self.tilemapPanOffset.y - ty
						self.tilePanDownPos:set(mouseX, mouseY)
					end
				end
			end
		end

		if app:key'space' then
			tilemapPan(app:keyp'space')
		end

		-- TODO pen size here
		if self.drawMode == 'dropper'
		or (self.drawMode == 'draw' and shift)
		then
			if leftButtonPress
			and mouseX >= mapX and mouseX < mapX + mapWidth
			and mouseY >= mapY and mouseY < mapY + mapHeight
			and 0 <= tx and tx < tilemapSize.x
			and 0 <= ty and ty < tilemapSize.y
			then
				local texelIndex = tx + tilemapSize.x * ty
				assert(0 <= texelIndex and texelIndex < tilemapSize:volume())
				local tileSelIndex = app:peekw(tilemapAddr + bit.lshift(texelIndex, 1))
				self.spriteSelPos.x = tileSelIndex % spriteSheetSizeInTiles.x
				self.spriteSelPos.y = (tileSelIndex - self.spriteSelPos.x) / spriteSheetSizeInTiles.x
			end
		elseif self.drawMode == 'draw' then
			if leftButtonDown
			and mouseX >= mapX and mouseX < mapX + mapWidth
			and mouseY >= mapY and mouseY < mapY + mapHeight
			and 0 <= tx and tx < tilemapSize.x
			and 0 <= ty and ty < tilemapSize.y
			then
				local tx0 = tx -- - math.floor(self.penSize / 2)
				local ty0 = ty -- - math.floor(self.penSize / 2)
				for dy=0,self.spriteSelSize.y-1 do -- self.penSize-1 do
					local ty = ty0 + dy
					for dx=0,self.spriteSelSize.x-1 do -- self.penSize-1 do
						local tx = tx0 + dx
						if 0 <= tx and tx < tilemapSize.x
						and 0 <= ty and ty < tilemapSize.y
						then
							local tileSelIndex = self.spriteSelPos.x + dx
								+ spriteSheetSizeInTiles.x * (self.spriteSelPos.y + dy)
							local texelIndex = tx + tilemapSize.x * ty
							assert(0 <= texelIndex and texelIndex < tilemapSize:volume())
							self:edit_pokew(tilemapAddr + bit.lshift(texelIndex, 1), tileSelIndex)
						end
					end
				end
			end
		elseif self.drawMode == 'pan' then
			if leftButtonDown then
				tilemapPan(leftButtonPress)
			end
		end

		if not tilemapPanHandled then
			self.tilePanPressed = false
		end
	end

	self:drawTooltip()
end

return EditTilemap
