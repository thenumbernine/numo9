local ffi = require 'ffi'
local gl = require 'gl'
local math = require 'ext.math'
local table = require 'ext.table'
local assert = require 'ext.assert'
local vec2i = require 'vec-ffi.vec2i'
local vec2d = require 'vec-ffi.vec2d'
local clip = require 'clip'	-- clipboard support
local Image = require 'image'
local Quantize = require 'image.quantize_mediancut'

local numo9_rom = require 'numo9.rom'
local paletteSize = numo9_rom.paletteSize
local spriteSize = numo9_rom.spriteSize
local frameBufferSize = numo9_rom.frameBufferSize
local frameBufferSizeInTiles = numo9_rom.frameBufferSizeInTiles
local spriteSheetSize = numo9_rom.spriteSheetSize
local spriteSheetSizeInTiles = numo9_rom.spriteSheetSizeInTiles
local tilemapAddr = numo9_rom.tilemapAddr
local tilemapSize = numo9_rom.tilemapSize
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

	self.pickOpen = false
	self.spriteSelPos = vec2i()
	self.spriteSelSize = vec2i(1,1)
	self.horzFlip = false
	self.vertFlip = false
	self.selPalHiOffset = 0
	self.drawMode = 'draw'	--TODO ui for this
	self.gridSpacing = 1
	self.penSize = 1
	self.tilePanDownPos = vec2i()
	self.tilemapPanOffset = vec2d()
	self.tilePanPressed = false
	self.scale = 1

	-- save these in config?
	self.drawGrid = true
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
	self:guiRadio(x, y, {'draw', 'fill', 'dropper', 'pan'}, self.drawMode, function(result)
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
	x = x + 16

	self:guiSpinner(x, y, function(dx)
		self.selPalHiOffset = math.clamp(self.selPalHiOffset + dx, 0, 0xf)
	end, 'palhi='..self.selPalHiOffset)
	x = x + 24

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
		self.scale = self.scale * math.exp(-.1 * app.ram.mouseWheel.y)
		pan(-128 / self.scale, -128 / self.scale)
	else
		pan(
			bit.lshift(spriteSize.x, draw16As0or1) * app.ram.mouseWheel.x,
			-bit.lshift(spriteSize.y, draw16As0or1) * app.ram.mouseWheel.y
		)
	end

	gl.glScissor(mapX,mapY,mapWidth,mapHeight)
	
	app:matident()
	app:mattrans(mapX, mapY)
	app:matscale(self.scale, self.scale)
	app:mattrans(-self.tilemapPanOffset.x, -self.tilemapPanOffset.y)

	app:drawQuad(
		-tileSize, -tileSize,
		2*tileSize+bit.lshift(tilemapSize.x,tileBits), 2*tileSize+bit.lshift(tilemapSize.y, tileBits),
		0, 0,
		(2+mapWidth)*2, (2+mapHeight)*2,
		app.checkerTex,
		app.palMenuTex
	)

	app:drawMap(
		0,		-- upper-left index in the tile tex
		0,
		tilemapSize.x,	-- tiles wide
		tilemapSize.y,	-- tiles high
		0,		-- pixel x
		0,		-- pixel y
		0,		-- map index offset / high page
		self.draw16Sprites	-- draw 16x16 vs 8x8
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
	gl.glScissor(0,0,frameBufferSize:unpack())

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
			1,
			1,
			app.tileTex,
			app.palTex,
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
			return app:peekw(tilemapAddr + bit.lshift(texelIndex, 1))
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
			self:edit_pokew(tilemapAddr + bit.lshift(texelIndex, 1), tileSelIndex)
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
		local x = 0
		local y = 0
		--TODO cut or copy ... need to specify selection beforehand
		if app:keyp'v' then
			-- TODO how to specify where to paste? beforehand? or paste as overlay until you click outside the box?
		
			-- how about allowing over-paste?  same with over-draw., how about a flag to allow it or not?
			assert(not app.mapTex.dirtyGPU)
			local image = clip.image()
			if image then
				local pasteTargetNumColors = 1024
				local indexOffset = 0
				-- TODO right now libclip always converts to RGBA, so I'm just quantizing to convert back
				-- so it's mixing up the palette index order
				-- TODO allow 1-channel support from libclip
				if image.channels ~= 1 then
					print('quantizing image to '..tostring(pasteTargetNumColors)..' colors')
					assert(image.channels >= 3)	-- NOTICE it's only RGB right now ... not even alpha
					image = image:rgb()
					assert.eq(image.channels, 3, "image channels")

					local hist
					image, hist = Quantize.reduceColorsMedianCut{
						image = image,
						targetSize = pasteTargetNumColors,
					}
					assert.eq(image.channels, 3, "image channels")
					-- I could use image.quantize_mediancut.applyColorMap but it doesn't use palette'd image (cuz my image library didn't support it at the time)
					-- soo .. I'll implement indexed-apply here (TODO move this into image.quantize_mediancut, and TOOD change convert-to-8x84bpp to use paletted images)
					local colors = table.keys(hist):sort()
print('num colors', #colors)
assert.le(#colors, 256, "resulting number of quantized colors")
					local indexForColor = colors:mapi(function(color,i)	-- 0-based index
						return i-1, color
					end)
					-- override colors here ...
					local image1ch = Image(image.width, image.height, 1, 'unsigned char')
					local srcp = image.buffer
					local dstp = image1ch.buffer
					for i=0,image.width*image.height-1 do
						local key = string.char(unpackptr(3, srcp))
						local dstIndex = indexForColor[key]
						if not dstIndex then
print("no index for color "..Quantize.bintohex(key))
print('possible colors: '..require 'ext.tolua'(colors))
							error'here'
						end
						dstp[0] = bit.band(0xff, dstIndex + indexOffset)
						dstp = dstp + 1
						srcp = srcp + image.channels
					end
					-- TODO proper would be to set image1ch.palette here but meh I'm just copying it on the next line anyways ...
					image = image1ch
				end
				assert.eq(image.channels, 1, "image.channels")
print'pasting image'
				for j=0,image.height-1 do
					for i=0,image.width-1 do
						local destx = i + x
						local desty = j + y
						if destx >= 0 and destx < app.mapTex.width
						and desty >= 0 and desty < app.mapTex.height
						then
							local c = image.buffer[i + image.width * j]
							self:edit_pokew(tilemapAddr + bit.lshift(destx + app.mapTex.width * desty, 1), c)
						end
					end
				end
			end

		end
	end

	self:drawTooltip()
end

return EditTilemap
