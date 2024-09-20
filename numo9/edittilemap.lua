local math = require 'ext.math'
local vec2i = require 'vec-ffi.vec2i'

local App = require 'numo9.app'
local paletteSize = App.paletteSize
local spriteSize = App.spriteSize
local frameBufferSize = App.frameBufferSize
local frameBufferSizeInTiles = App.frameBufferSizeInTiles
local spriteSheetSize = App.spriteSheetSize
local spriteSheetSizeInTiles = App.spriteSheetSizeInTiles
local tilemapSize = App.tilemapSize
local tilemapSizeInSprites = App.tilemapSizeInSprites

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

	if self:guiButton(x, y, 'G', self.drawGrid, 'grid') then
		self.drawGrid = not self.drawGrid
	end
	x = x + 8
	if self:guiButton(x, y, 'T', self.pickOpen, 'tile') then
		self.pickOpen = not self.pickOpen
	end
	x = x + 8
	if self:guiButton(x, y, 'X', self.draw16Sprites, self.draw16Sprites and '16x16' or '8x8') then
		self.draw16Sprites = not self.draw16Sprites
	end

	-- sprite edit method
	x = x + 16
	self:guiRadio(x, y, {'draw', 'dropper', 'pan'}, self.drawMode, function(result)
		self.drawMode = result
	end)


	local mapTex = app.mapTex

	-- draw map
	local mapX = 0
	local mapY = spriteSize.y
	local mapWidthInTiles = tilemapSizeInSprites.x
	local mapHeightInTiles = tilemapSizeInSprites.y-2
	local mapWidth = bit.lshift(mapWidthInTiles, self.draw16Sprites and 4 or 3)
	local mapHeight = bit.lshift(mapWidthInTiles, self.draw16Sprites and 4 or 3)
--print('map', require 'ext.string'.hexdump(require 'ffi'.string(mapTex.data, 16)))

	app:drawMap(
		self.tilemapPanOffset.x,	-- upper-left index in the tile tex
		self.tilemapPanOffset.y,
		tilemapSizeInSprites.x,	-- tiles wide
		tilemapSizeInSprites.y,	-- tiles high
		mapX,		-- pixel x
		mapY,		-- pixel y
		0,			-- map index offset / high page
		self.draw16Sprites	-- draw 16x16 vs 8x8
	)
	if self.drawGrid then
		local step = bit.lshift(self.gridSpacing, self.draw16Sprites and 4 or 3)
		for i=0,frameBufferSize.x-1,step do
			app:drawSolidLine(i, spriteSize.y, i, frameBufferSize.y-spriteSize.y, self:color(1))
		end
		for j=spriteSize.y,frameBufferSize.y-spriteSize.y-1,step do
			app:drawSolidLine(0, j, frameBufferSize.x, j, self:color(1))
		end
	end

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
				local ptr = mapTex.image.buffer + texelIndex
				local tileSelIndex = ptr[0]
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
				assert(mapTex.image.buffer == mapTex.data)
				mapTex:bind()
				for dy=0,self.spriteSelSize.y-1 do -- self.penSize-1 do
					local ty = ty0 + dy
					for dx=0,self.spriteSelSize.x-1 do -- self.penSize-1 do
						local tx = tx0 + dx
						if 0 <= tx and tx < tilemapSize.x
						and 0 <= ty and ty < tilemapSize.y
						then
							local texelIndex = tx + tilemapSize.x * ty
							assert(0 <= texelIndex and texelIndex < tilemapSize:volume())
							local ptr = mapTex.image.buffer + texelIndex
							local tileSelIndex = self.spriteSelPos.x + dx
								+ spriteSheetSizeInTiles.x * (self.spriteSelPos.y + dy)
							ptr[0] = tileSelIndex
							app.mapTex.dirtyCPU = true
						end
					end
				end
				mapTex:unbind()
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
end

return EditTilemap
