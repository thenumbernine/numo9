local ffi = require 'ffi'
local gl = require 'gl'
local math = require 'ext.math'
local table = require 'ext.table'
local assert = require 'ext.assert'
local vec2i = require 'vec-ffi.vec2i'
local vec2d = require 'vec-ffi.vec2d'
local clip = require 'numo9.clipboard'
local Image = require 'image'
local Quantize = require 'image.quantize_mediancut'

local numo9_rom = require 'numo9.rom'
local spriteSize = numo9_rom.spriteSize
local frameBufferSize = numo9_rom.frameBufferSize
local frameBufferSizeInTiles = numo9_rom.frameBufferSizeInTiles
local spriteSheetSize = numo9_rom.spriteSheetSize
local spriteSheetSizeInTiles = numo9_rom.spriteSheetSizeInTiles
local tilemapSize = numo9_rom.tilemapSize
local clipMax = numo9_rom.clipMax
local unpackptr = require 'numo9.rom'.unpackptr

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

	self.sheetBlobIndex = 1
	self.tilemapBlobIndex = 0
	self.paletteBlobIndex = 0	-- TODO :drawMap() allow specifying palette #

	self.pickOpen = false
	-- these are within the popup select tile window right?
	self.spriteSelPos = vec2i()
	self.spriteSelSize = vec2i(1,1)
	-- and this is for copy paste in the tilemap
	self.tileSelPos = vec2i()
	self.tileSelSize = vec2i()
	self.horzFlip = false
	self.vertFlip = false
	self.selPalHiOffset = 0
	self.drawMode = 'draw'
	self.gridSpacing = 1
	self.penSize = 1
	self.tilePanDownPos = vec2i()
	self.tilemapPanOffset = vec2d()
	self.tilePanPressed = false
	self.scale = 1

	-- save these in config?
	self.drawGrid = false
	self.draw16Sprites = false
end

function EditTilemap:update()
	local app = self.app

	local draw16As0or1 = self.draw16Sprites and 1 or 0

	local leftButtonDown = app:key'mouse_left'
	local leftButtonPress = app:keyp'mouse_left'
	local leftButtonRelease = app:keyr'mouse_left'
	local mouseX, mouseY = app.ram.mousePos:unpack()

	local shift = app:key'lshift' or app:key'rshift'

	EditTilemap.super.update(self)

	-- title controls
	local x = 80
	local y = 0

	self:guiSpinner(x, y, function(dx)
		self.tilemapBlobIndex = math.clamp(self.tilemapBlobIndex + dx, 0, #app.blobs.tilemap-1)
	end, 'tilemap #'..self.tilemapBlobIndex)
	x = x + 16
	-- TODO grow/shrink
	-- TODO selector for palette #
	-- TODO selector for sheet #

	if self:guiButton('T', x, y, self.pickOpen, 'tile') then
		self.pickOpen = not self.pickOpen
	end
	x = x + 8
	if self:guiButton('X', x, y, self.draw16Sprites, self.draw16Sprites and '16x16' or '8x8') then
		self.draw16Sprites = not self.draw16Sprites
	end

	-- sprite edit method
	x = x + 10
	self:guiRadio(x, y, {'draw', 'fill', 'dropper', 'pan', 'select'}, self.drawMode, function(result)
		self.drawMode = result
	end)

	x = x + 32
	if self:guiButton('H', x, y, self.horzFlip, 'hflip='..tostring(self.horzFlip)) then
		self.horzFlip = not self.horzFlip
	end
	x = x + 8

	if self:guiButton('V', x, y, self.vertFlip, 'vflip='..tostring(self.vertFlip)) then
		self.vertFlip = not self.vertFlip
	end
	x = x + 12

	self:guiSpinner(x, y, function(dx)
		self.selPalHiOffset = math.clamp(self.selPalHiOffset + dx, 0, 0xf)
	end, 'palhi='..self.selPalHiOffset)
	x = x + 16

	self:guiSpinner(x, y, function(dx)
		self.gridSpacing = math.clamp(self.gridSpacing + dx, 1, 256)
	end, 'grid='..self.gridSpacing)
	x = x + 16

	if self:guiButton('G', x, y, self.drawGrid, 'grid') then
		self.drawGrid = not self.drawGrid
	end

	local tilemapRAM = app.tilemapRAMs[self.tilemapBlobIndex+1]

	local tileBits = self.draw16Sprites and 4 or 3
	local tileSize = bit.lshift(1, tileBits)

	-- draw map
	local mapX = 0
	local mapY = spriteSize.y
	local mapWidthInTiles = frameBufferSizeInTiles.x
	local mapHeightInTiles = frameBufferSizeInTiles.y
	local mapWidth = bit.lshift(mapWidthInTiles, tileBits)
	local mapHeight = bit.lshift(mapWidthInTiles, tileBits)

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
		self.spriteSelPos.x
		+ spriteSheetSizeInTiles.x * self.spriteSelPos.y,
		bit.lshift(bit.band(0xf, self.selPalHiOffset), 10),
		self.horzFlip and 0x4000 or 0,
		self.vertFlip and 0x8000 or 0)
	self:guiTextField(
		210, 0, 20,
		('%04X'):format(tileSelIndex), nil,
		function(result)
			result = tonumber(result, 16)
			if result then
				self.spriteSelPos.x = result % spriteSheetSizeInTiles.x
				self.spriteSelPos.y = (result - self.spriteSelPos.x) / spriteSheetSizeInTiles.x
				self.selPalHiOffset = bit.band(bit.rshift(result, 10), 0xf)
				self.horzFlip = bit.band(result, 0x4000) ~= 0
				self.vertFlip = bit.band(result, 0x8000) ~= 0
			end
		end
	)


	app:setClipRect(mapX, mapY, mapWidth-1, mapHeight-1)

	app:matident()
	app:mattrans(mapX, mapY)
	app:matscale(self.scale, self.scale)
	app:mattrans(-self.tilemapPanOffset.x, -self.tilemapPanOffset.y)

	app:drawQuadTex(
		app.paletteMenuTex,
		app.checkerTex,
		-1, -1,
		2+bit.lshift(tilemapSize.x,tileBits), 2+bit.lshift(tilemapSize.y, tileBits),
		0, 0,
		2+mapWidth*2, 2+mapHeight*2
	)

	-- TODO allow specifying palette #
	app:drawMap(
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
			app:drawSolidLine(i, ymin, i, ymax, self:color(1))
		end
		for j=ymin,ymax,step do
			app:drawSolidLine(xmin, j, xmax, j, self:color(1))
		end
	end
	
	if self.drawMode == 'select' then
		app:drawBorderRect(
			self.tileSelPos.x * tileSize,
			self.tileSelPos.y * tileSize,
			tileSize * self.tileSelSize.x,
			tileSize * self.tileSelSize.y,
			0xfd
		)
	end



	app:setClipRect(0, 0, clipMax, clipMax)

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
			255,
			255,
			1,	-- sheetIndex
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
			pickY + self.spriteSelPos.y * spriteSize.y * pickH / spriteSheetSize.y,
			spriteSize.x * self.spriteSelSize.x * pickW / spriteSheetSize.x,
			spriteSize.y * self.spriteSelSize.y * pickH / spriteSheetSize.y,
			self:color(13)
		)
	else
		-- TODO allow drawing while picking window is open, like tic80 does?
		-- maybe ... then i should disable the auto-close-on-select ...
		-- and I should also resize the pick tile area

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
			if tx < 0 or tx >= tilemapSize.x
			or ty < 0 or ty >= tilemapSize.y
			then return end

			local texelIndex = tx + tilemapSize.x * ty
			assert(0 <= texelIndex and texelIndex < tilemapSize:volume())
			return app:peekw(tilemapRAM.addr + bit.lshift(texelIndex, 1))
		end

		local function puttile(tx, ty, dx, dy)
			if tx < 0 or tx >= tilemapSize.x
			or ty < 0 or ty >= tilemapSize.y
			then return end

			local tileSelIndex = bit.bor(
				self.spriteSelPos.x + dx
				+ spriteSheetSizeInTiles.x * (self.spriteSelPos.y + dy),
				bit.lshift(bit.band(0xf, self.selPalHiOffset), 10),
				self.horzFlip and 0x4000 or 0,
				self.vertFlip and 0x8000 or 0)
			local texelIndex = tx + tilemapSize.x * ty
			assert(0 <= texelIndex and texelIndex < tilemapSize:volume())
			self:edit_pokew(tilemapRAM.addr + bit.lshift(texelIndex, 1), tileSelIndex)
		end

		-- TODO pen size here
		if self.drawMode == 'dropper'
		or (self.drawMode == 'draw' and shift)
		or (self.drawMode == 'fill' and shift)
		then
			if leftButtonPress
			and mouseX >= mapX and mouseX < mapX + mapWidth
			and mouseY >= mapY and mouseY < mapY + mapHeight
			then
				local tileSelIndex = gettile(tx, ty)
				if tileSelIndex then
					self.spriteSelPos.x = tileSelIndex % spriteSheetSizeInTiles.x
					self.spriteSelPos.y = ((tileSelIndex - self.spriteSelPos.x) / spriteSheetSizeInTiles.x) % spriteSheetSizeInTiles.y
					self.selPalHiOffset = bit.band(bit.lshift(tileSelIndex, 10), 0xf)
					self.horzFlip = bit.band(tileSelIndex, 0x4000) ~= 0
					self.vertFlip = bit.band(tileSelIndex, 0x8000) ~= 0
				end
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
				local step = 1 + draw16As0or1
				for dy=0,self.spriteSelSize.y-1,step do -- self.penSize-1 do
					local ty = ty0 + bit.rshift(dy, draw16As0or1)
					for dx=0,self.spriteSelSize.x-1,step do -- self.penSize-1 do
						local tx = tx0 + bit.rshift(dx, draw16As0or1)
						puttile(tx,ty, dx,dy)
					end
				end
			end
		elseif self.drawMode == 'fill' then
			if leftButtonDown
			and mouseX >= mapX and mouseX < mapX + mapWidth
			and mouseY >= mapY and mouseY < mapY + mapHeight
			then
				local srcTile = gettile(tx, ty)

				local tileSelIndex = bit.bor(
					self.spriteSelPos.x
					+ spriteSheetSizeInTiles.x * self.spriteSelPos.y,
					bit.lshift(bit.band(0xf, self.selPalHiOffset), 10),
					self.horzFlip and 0x4000 or 0,
					self.vertFlip and 0x8000 or 0)

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
							if  tx1 >= self.spriteSelPos.x * spriteSize.x
							and ty1 >= self.spriteSelPos.y * spriteSize.y
							and tx1 < (self.spriteSelPos.x + self.spriteSelSize.x) * spriteSize.x
							and ty1 < (self.spriteSelPos.y + self.spriteSelSize.y) * spriteSize.y
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
				self.tileSelPos:set(tx, ty)
				self.tileSelPos.x = math.clamp(self.tileSelPos.x, 0, tilemapSize.x-1)
				self.tileSelPos.y = math.clamp(self.tileSelPos.y, 0, tilemapSize.x-1)
				self.tileSelSize:set(1,1)
			elseif leftButtonDown then
				self.tileSelSize.x = math.ceil((math.abs(tx - self.tileSelPos.x) + 1))
				self.tileSelSize.y = math.ceil((math.abs(ty - self.tileSelPos.y) + 1))
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

	app:matident()

	local uikey
	if ffi.os == 'OSX' then
		uikey = app:key'lgui' or app:key'rgui'
	else
		uikey = app:key'lctrl' or app:key'rctrl'
	end
	if uikey then
		local x = self.tileSelPos.x
		local y = self.tileSelPos.y
		local width = self.tileSelSize.x
		local height = self.tileSelSize.y
		if app:keyp'x' or app:keyp'c' then
			assert(not tilemapRAM.dirtyGPU)
			local image = tilemapRAM.image:copy{x=x, y=y, width=width, height=height}
			-- 1-channel uint16_t image
			local channels = 4
			local imageRGBA = Image(image.width, image.height, channels, 'uint8_t')
			for i=0,image.width*image.height-1 do
				imageRGBA.buffer[0 + channels * i] = bit.band(0xff, image.buffer[i])
				imageRGBA.buffer[1 + channels * i] = bit.band(0xff, bit.rshift(image.buffer[i], 8))
				imageRGBA.buffer[2 + channels * i] = 0
				imageRGBA.buffer[3 + channels * i] = 0xff
			end
			clip.image(imageRGBA)
			if app:keyp'x' then
				tilemapRAM.dirtyCPU = true
				assert.eq(tilemapRAM.image.channels, 1)
				for j=y,y+height-1 do
					for i=x,x+width-1 do
						self:edit_pokew(tilemapRAM.addr + bit.lshift(i + tilemapRAM.image.width * j, 1), 0)
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
				-- 4-channel uint8_t image
				for j=0,image.height-1 do
					for i=0,image.width-1 do
						local destx = i + x
						local desty = j + y
						if destx >= 0 and destx < tilemapRAM.image.width
						and desty >= 0 and desty < tilemapRAM.image.height
						then
							local c = 0
							local readChannels = math.min(image.channels, 2)	-- don't include alpha channel... heck only need R and G ...
							for ch=readChannels-1,0,-1 do
								c = bit.lshift(c, 8)
								c = bit.bor(c, image.buffer[ch + image.channels * (i + image.width * j)])
							end
							self:edit_pokew(tilemapRAM.addr + bit.lshift(destx + tilemapRAM.image.width * desty, 1), c)
						end
					end
				end
			end
		end
	end

	self:drawTooltip()
end

return EditTilemap
