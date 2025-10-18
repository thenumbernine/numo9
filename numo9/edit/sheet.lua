--[[
This will be the code editor
--]]
local ffi = require 'ffi'
local gl = require 'gl'
local assert = require 'ext.assert'
local math = require 'ext.math'
local table = require 'ext.table'
local string = require 'ext.string'
local vec2i = require 'vec-ffi.vec2i'
require 'ffi.req' 'c.string'	-- memcmp
local Image = require 'image'
local Quantize = require 'image.quantize_mediancut'

local clip = require 'numo9.clipboard'
local Undo = require 'numo9.ui.undo'

local numo9_video = require 'numo9.video'
local rgba8888_4ch_to_5551 = numo9_video.rgba8888_4ch_to_5551	-- TODO move this
local rgba5551_to_rgba8888_4ch = numo9_video.rgba5551_to_rgba8888_4ch

local numo9_rom = require 'numo9.rom'
local spriteSheetSize = numo9_rom.spriteSheetSize
local spriteSize = numo9_rom.spriteSize
local spriteSheetSizeInTiles = numo9_rom.spriteSheetSizeInTiles
local clipMax = numo9_rom.clipMax
local unpackptr = numo9_rom.unpackptr
local palettePtrType = numo9_rom.palettePtrType


local uint8_t = ffi.typeof'uint8_t'

-- used by fill
local dirs = {
	{1,0},
	{0,1},
	{-1,0},
	{0,-1},
}

local EditSheet = require 'numo9.ui':subclass()

function EditSheet:init(args)
	EditSheet.super.init(self, args)

	self.undo = Undo{
		get = function()
			-- for now I'll just have one undo buffer for the current sheet
			-- TODO palette too
			local app = self.app
			local sheetRAM = app.blobs.sheet[self.sheetBlobIndex+1].ramgpu
			local paletteRAM = app.blobs.palette[self.paletteBlobIndex+1].ramgpu
			return {
				sheet = sheetRAM.image:clone(),
				palette = paletteRAM.image:clone(),
			}
		end,
		changed = function(entry)
			local app = self.app
			local sheetRAM = app.blobs.sheet[self.sheetBlobIndex+1].ramgpu
			local paletteRAM = app.blobs.palette[self.paletteBlobIndex+1].ramgpu
			return 0 ~= ffi.C.memcmp(entry.sheet.buffer, sheetRAM.image.buffer, sheetRAM.image:getBufferSize())
			or 0 ~= ffi.C.memcmp(entry.palette.buffer, paletteRAM.image.buffer, paletteRAM.image:getBufferSize())
		end,
	}

	self:onCartLoad()
end

function EditSheet:onCartLoad()
	self.sheetBlobIndex = 0

	self.paletteBlobIndex = 0

--[[ nah metainfo isnt defined, and this doesnt remember palettes per sheet, so nah not right now
	local app = self.app
	local paletteForSheet = app.metainfo['archive.paletteForSheet']
	if paletteForSheet then
		-- TODO hmm, way to do this for each sheet?
		-- I could save the paletteForSheet in this editor ... so when you change sheets it remembers the palette ...
		-- maybe
		self.paletteBlobIndex = paletteForSheet[1+self.sheetBlobIndex] or 0
	end
--]]

	-- sprite edit mode
	self.spriteSelPos = vec2i()	-- TODO make this texel based, not sprite based (x8 less resolution)
	self.spriteSelSize = vec2i(1,1)
	self.spritesheetPanOffset = vec2i()
	self.spritesheetPanDownPos = vec2i()
	self.spritesheetPanPressed = false

	self.spritePanOffset = vec2i()	-- holds the panning offset from the sprite location
	self.spritePanDownPos = vec2i()	-- where the mouse was when you pressed down to pan
	self.spritePanPressed = false

	self.spriteBit = 0	-- which bitplane to start at: 0-7
	self.spriteBitDepth = 8	-- how many bits to edit at once: 1-8
	self.spritesheetEditMode = 'select'

	self.spriteDrawMode = 'draw'
	self.paletteSelIndex = 0	-- which color we are painting
	self.log2PalBits = 3	-- showing an 1<<3 == 8bpp image: 0-3
	self.paletteOffset = 0	-- allow selecting this in another full-palette pic?

	self.pasteKeepsPalette = true
	self.pasteTargetNumColors = 256
	self.penSize = 1 		-- size 1 thru 5 or so
	-- TODO pen dropper cut copy paste pan fill circle flipHorz flipVert rotate clear

	self.pasteTransparent = false

	self.undo:clear()
end

local selBorderColors = {0xfd,0xfc}

function EditSheet:update()
	local app = self.app

	local leftButtonDown = app:key'mouse_left'
	local leftButtonPress = app:keyp'mouse_left'
	local leftButtonRelease = app:keyr'mouse_left'
	local mouseX, mouseY = app:invTransform(app.ram.mousePos:unpack())
	local lastMousePressX, lastMousePressY = app:invTransform(app.ram.lastMousePressPos:unpack())

	local shift = app:key'lshift' or app:key'rshift'

	EditSheet.super.update(self)

	local sheetBlob = app.blobs.sheet[self.sheetBlobIndex+1]
	local sheetRAM = sheetBlob.ramgpu
	-- use the ramgpu's addr which can be relocated?  or use the blob's addr?
	-- I'm using the blob addr at the moment, since it is related to the permanent state of the cart/blob.
	local currentSheetAddr = sheetBlob.addr
	--local currentSheetAddr = sheetRAM.addr	-- use this to see whatever the "fantasy hardware" is seeing at present

	local paletteBlob = app.blobs.palette[self.paletteBlobIndex+1]
	local paletteRAM = paletteBlob.ramgpu

	-- choose spriteBit
	app:drawMenuText(
		'#',
		128+16+24,
		12,
		13,
		-1
	)
	self:guiTextField(
		128+16+24+5,
		12,
		10,
		self, 'spriteBit',
		function(result)
			self.spriteBit = math.clamp(tonumber(result) or self.spriteBit, 0, 7)
		end
	)
	self:guiSpinner(128+16+24, 20, function(dx)
		self.spriteBit = math.clamp(self.spriteBit + dx, 0, 7)
	end, 'bit='..self.spriteBit)

	-- choose spriteMask
	app:drawMenuText(
		'#',
		128+16+24+32,
		12,
		13,
		-1
	)
	self:guiTextField(
		128+16+24+32+5,
		12,
		10,
		self, 'spriteBitDepth',
		function(result)
			self.spriteBitDepth = tonumber(result) or self.spriteBitDepth
		end
	)

	self:guiSpinner(128+16+24+32, 20, function(dx)
		-- should I not let this exceed 8 - spriteBit ?
		-- or should I wrap around bits and be really unnecessarily clever?
		self.spriteBitDepth = math.clamp(self.spriteBitDepth + dx, 1, 8)
	end, 'bpp='..self.spriteBitDepth)

	-- spritesheet pan vs select
	self:guiRadio(224, 12, {'select', 'pan'}, self.spritesheetEditMode,
		function(result)
			self.spritesheetEditMode = result
		end)

	local x = 126
	local y = 32
	local sw = spriteSheetSizeInTiles.x / 2	-- only draw a quarter worth since it's the same size as the screen
	local sh = spriteSheetSizeInTiles.y / 2
	local w = sw * spriteSize.x
	local h = sh * spriteSize.y

	local function spritesheetCoordToFb(ssX, ssY)
		return
			ssX * spriteSize.x - self.spritesheetPanOffset.x + x,
			ssY * spriteSize.y - self.spritesheetPanOffset.y + y
	end
	-- draw some pattern under the spritesheet so you can tell what's transparent
	self:guiSetClipRect(x, y, w-1, h-1)
	do
		-- this is the framebuffer coord bounds of the spritesheet.
		local x1, y1 = spritesheetCoordToFb(0, 0)
		local x2, y2 = spritesheetCoordToFb(spriteSheetSizeInTiles:unpack())
		app:drawQuadTex(
			app.paletteMenuTex,
			app.checkerTex,
			x1, y1, x2-x1, y2-y1,	-- x y w h
			0, 0, w/2, h/2)			-- tx ty tw th
	end
	local pushPalBlobIndex = app.ram.paletteBlobIndex
	app.ram.paletteBlobIndex = self.paletteBlobIndex
	app:drawQuad(
		x,		-- x
		y,		-- y
		w,		-- w
		h,		-- h
		self.spritesheetPanOffset.x,-- tx
		self.spritesheetPanOffset.y,-- ty
		w-1,						-- tw
		h-1,						-- th
		0,		--- orientation2D
		self.sheetBlobIndex,
		0,		-- paletteShift
		-1,		-- transparentIndex
		0,		-- spriteBit
		0xFF	-- spriteMask
	)
	app.ram.paletteBlobIndex = pushPalBlobIndex

	-- since when is clipMax having problems?
	--self:guiSetClipRect(0, 0, clipMax, clipMax)
	self:guiSetClipRect(0, 0, 256, 256)

	app:drawBorderRect(x-1, y-1, w+2, h+2, 0xd, nil, app.paletteMenuTex)
	local function fbToSpritesheetCoord(fbX, fbY)
		return
			(fbX - x + self.spritesheetPanOffset.x) / spriteSize.x,
			(fbY - y + self.spritesheetPanOffset.y) / spriteSize.y
	end

	local spritesheetPanHandled
	local function spritesheetPan(press)
		spritesheetPanHandled = true
		if press then
			if mouseX >= x and mouseX < x + w
			and mouseY >= y and mouseY < y + h
			then
				self.spritesheetPanDownPos:set(mouseX, mouseY)
				self.spritesheetPanPressed = true
			end
		else
			if self.spritesheetPanPressed then
				local tx = math.round(mouseX - self.spritesheetPanDownPos.x)
				local ty = math.round(mouseY - self.spritesheetPanDownPos.y)
				if tx ~= 0 or ty ~= 0 then
					self.spritesheetPanOffset.x = self.spritesheetPanOffset.x - tx
					self.spritesheetPanOffset.y = self.spritesheetPanOffset.y - ty
					self.spritesheetPanDownPos:set(mouseX, mouseY)
				end
			end
		end
	end

	if x <= mouseX and mouseX < x+w
	and y <= mouseY and mouseY <= y+h
	then
		if app:key'space' then
			spritesheetPan(app:keyp'space')
		end
		if self.spritesheetEditMode == 'select' then
			if leftButtonPress then
				self.spriteSelPos:set(fbToSpritesheetCoord(mouseX, mouseY))
				self.spriteSelPos.x = math.clamp(self.spriteSelPos.x, 0, spriteSheetSizeInTiles.x-1)
				self.spriteSelPos.y = math.clamp(self.spriteSelPos.y, 0, spriteSheetSizeInTiles.x-1)
				self.spriteSelSize:set(1,1)
				self.spritePanOffset:set(0,0)
			elseif leftButtonDown then
				self.spriteSelSize.x = math.ceil((math.abs(mouseX - lastMousePressX) + 1) / spriteSize.x)
				self.spriteSelSize.y = math.ceil((math.abs(mouseY - lastMousePressY) + 1) / spriteSize.y)
			end
		elseif self.spritesheetEditMode == 'pan'  then
			if leftButtonDown then
				spritesheetPan(leftButtonPress)
			end
		end
	end

	if not spritesheetPanHandled then
		self.spritesheetPanPressed = false
	end

	self:guiSetClipRect(x, y, w-1, h-1)
	-- sprite sel rect (1x1 ... 8x8)
	-- ... also show the offset ... is that a good idea?
	app:drawBorderRect(
		x + self.spriteSelPos.x * spriteSize.x + self.spritePanOffset.x - self.spritesheetPanOffset.x,
		y + self.spriteSelPos.y * spriteSize.y + self.spritePanOffset.y - self.spritesheetPanOffset.y,
		spriteSize.x * self.spriteSelSize.x,
		spriteSize.y * self.spriteSelSize.y,
		0xd,
		nil,
		app.paletteMenuTex
	)

	-- since when is clipMax having problems?
	--self:guiSetClipRect(0, 0, clipMax, clipMax)
	self:guiSetClipRect(0, 0, 256, 256)

	-- sprite edit area
	local x = 2
	local y = 12
	app:drawMenuText(
		'#',
		x + 32,
		y,
		0xfd,
		-1
	)
	self:guiTextField(
		x + 32 + 5,
		y,
		20,
		self.spriteSelPos.x + spriteSheetSizeInTiles.x * self.spriteSelPos.y, nil,
		function(result)
			local index = tonumber(result)
			if index then
				self.spriteSelPos.x = index % spriteSheetSizeInTiles.x
				self.spriteSelPos.y = (index - self.spriteSelPos.x) / spriteSheetSizeInTiles.x
			end
		end
	)

	local y = 24
	local w = 64
	local h = 64
	-- draw some pattern under the sprite so you can tell what's transparent
	self:guiSetClipRect(x, y, w-1, h-1)
	local function spriteCoordToFb(sX, sY)
		return
			(sX - self.spriteSelPos.x * spriteSize.x - self.spritePanOffset.x) / tonumber(self.spriteSelSize.x * spriteSize.x) * w + x,
			(sY - self.spriteSelPos.y * spriteSize.y - self.spritePanOffset.y) / tonumber(self.spriteSelSize.y * spriteSize.y) * h + y
	end
	do
		local x1, y1 = spriteCoordToFb(0, 0)
		local x2, y2 = spriteCoordToFb(spriteSheetSize:unpack())
		app:drawQuadTex(
			app.paletteMenuTex,
			app.checkerTex,
			x1, y1, x2-x1, y2-y1,	-- x y w h
			0, 0, w*8, h*8)			-- tx ty tw th
	end
	local pushPalBlobIndex = app.ram.paletteBlobIndex
	app.ram.paletteBlobIndex = self.paletteBlobIndex
	app:drawQuad(
		x, y, w, h,
		self.spriteSelPos.x * spriteSize.x + self.spritePanOffset.x,
		self.spriteSelPos.y * spriteSize.y + self.spritePanOffset.y,
		self.spriteSelSize.x * spriteSize.x,
		self.spriteSelSize.y * spriteSize.y,
		0,		-- orientation2D
		self.sheetBlobIndex,
		0,										-- paletteIndex
		-1,										-- transparentIndex
		self.spriteBit,							-- spriteBit
		bit.lshift(1, self.spriteBitDepth)-1	-- spriteMask
	)
	app.ram.paletteBlobIndex = pushPalBlobIndex

	-- since when is clipMax having problems?
	--self:guiSetClipRect(0, 0, clipMax, clipMax)
	self:guiSetClipRect(0, 0, 256, 256)

	app:drawBorderRect(x-1, y-1, w+2, h+2, 0xd, nil, app.paletteMenuTex)

	-- convert x y in framebuffer space to x y in sprite window space
	local function fbToSpriteCoord(fbX, fbY)
		return
			(fbX - x) / w * tonumber(self.spriteSelSize.x * spriteSize.x) + self.spriteSelPos.x * spriteSize.x + self.spritePanOffset.x,
			(fbY - y) / h * tonumber(self.spriteSelSize.y * spriteSize.y) + self.spriteSelPos.y * spriteSize.y + self.spritePanOffset.y
	end

	local spritePanHandled
	local function spritePan(press)
		spritePanHandled = true
		if press then
			if mouseX >= x and mouseX < x + w
			and mouseY >= y and mouseY < y + h
			then
				self.spritePanDownPos:set(mouseX, mouseY)
				self.spritePanPressed = true
			end
		else
			if self.spritePanPressed then
				local tx1, ty1 = fbToSpriteCoord(mouseX, mouseY)
				local tx0, ty0 = fbToSpriteCoord(self.spritePanDownPos:unpack())
				-- convert mouse framebuffer pixel movement to sprite texel movement
				local tx = math.round(tx1 - tx0)
				local ty = math.round(ty1 - ty0)
				if tx ~= 0 or ty ~= 0 then
					self.spritePanOffset.x = self.spritePanOffset.x - tx
					self.spritePanOffset.y = self.spritePanOffset.y - ty
					self.spritePanDownPos:set(mouseX, mouseY)
				end
			end
		end
	end

	if self.spriteDrawMode == 'draw'
	or self.spriteDrawMode == 'dropper'
	or self.spriteDrawMode == 'fill'
	then
		if leftButtonDown
		and mouseX >= x and mouseX < x + w
		and mouseY >= y and mouseY < y + h
		then
			local tx, ty = fbToSpriteCoord(mouseX, mouseY)
			tx = math.floor(tx)
			ty = math.floor(ty)
			-- TODO HERE draw a pixel to the sprite sheet ...
			-- TODO TODO I'm gonna write to the spriteSheet.image then re-upload it
			-- I hope nobody has modified the GPU buffer and invalidated the sync between them ...
			local mask = bit.lshift(
				bit.lshift(1, self.spriteBitDepth) - 1,
				self.spriteBit
			)

			local function getpixel(tx, ty)
				if not (0 <= tx and tx < spriteSheetSize.x
				and 0 <= ty and ty < spriteSheetSize.y)
				then return end

				-- TODO since shift is shift, should I be subtracing it here?
				-- or should I just be AND'ing it?
				-- let's subtract it
				local texelIndex = tx + spriteSheetSize.x * ty
				assert(0 <= texelIndex and texelIndex < spriteSheetSize:volume())
				local addr = currentSheetAddr + texelIndex
				return bit.band(
					0xff,
					self.paletteOffset
					+ bit.rshift(
						bit.band(mask, app:peek(addr)),
						self.spriteBit
					)
				)
			end
			local function putpixel(tx,ty)
				if not (0 <= tx and tx < spriteSheetSize.x
				and 0 <= ty and ty < spriteSheetSize.y)
				then return end

				local texelIndex = tx + spriteSheetSize.x * ty
				assert(0 <= texelIndex and texelIndex < spriteSheetSize:volume())
				local addr = currentSheetAddr + texelIndex
				local value = bit.bor(
					bit.band(
						bit.bnot(mask),
						app:peek(addr)
					),
					bit.band(
						mask,
						bit.lshift(
							self.paletteSelIndex - self.paletteOffset,
							self.spriteBit
						)
					)
				)
				self:edit_poke(addr, value)
				self.hist = nil	-- invalidate histogram

				-- TODO wait does edit_poke write to the blob?
				-- it has to right?
				-- if not then pushing the undo content wont matter
				self.undo:pushContinuous()
			end

			if self.spriteDrawMode == 'dropper'
			or (self.spriteDrawMode == 'draw' and shift)
			or (self.spriteDrawMode == 'fill' and shift)
			then
				local c = getpixel(tx, ty)
				if c then
					self.paletteSelIndex = bit.band(0xff, c + self.paletteOffset)
				end
			elseif self.spriteDrawMode == 'draw' then
				local tx0 = tx - math.floor(self.penSize / 2)
				local ty0 = ty - math.floor(self.penSize / 2)
				assert.eq(sheetRAM.image.buffer, sheetRAM.tex.data)
				sheetRAM.tex:bind()
				for dy=0,self.penSize-1 do
					for dx=0,self.penSize-1 do
						local tx = tx0 + dx
						local ty = ty0 + dy
						--[[ constrain to entire sheet (TODO flag for this option)
						if tx >= 0 and tx < spriteSheetSize.x
						and ty >= 0 and ty < spriteSheetSize.y
						--]]
						-- [[ constrain to current selection
						if  tx >= self.spriteSelPos.x * spriteSize.x
						and ty >= self.spriteSelPos.y * spriteSize.y
						and tx < (self.spriteSelPos.x + self.spriteSelSize.x) * spriteSize.x
						and ty < (self.spriteSelPos.y + self.spriteSelSize.y) * spriteSize.y
						--]]
						then
							putpixel(tx,ty)
						end
					end
				end
				sheetRAM.tex:unbind()
			elseif self.spriteDrawMode == 'fill' then
				local srcColor = getpixel(tx, ty)
				if srcColor ~= self.paletteSelIndex then
					local fillstack = table()
					putpixel(tx, ty)
					fillstack:insert{tx, ty}
					while #fillstack > 0 do
						local tx0, ty0 = table.unpack(fillstack:remove())
						for _,dir in ipairs(dirs) do
							local tx1, ty1 = tx0 + dir[1], ty0 + dir[2]
							--[[ constrain to entire sheet (TODO flag for this option)
							if tx1 >= 0 and tx1 < spriteSheetSize.x
							and ty1 >= 0 and ty1 < spriteSheetSize.y
							--]]
							-- [[ constrain to current selection
							if  tx1 >= self.spriteSelPos.x * spriteSize.x
							and ty1 >= self.spriteSelPos.y * spriteSize.y
							and tx1 < (self.spriteSelPos.x + self.spriteSelSize.x) * spriteSize.x
							and ty1 < (self.spriteSelPos.y + self.spriteSelSize.y) * spriteSize.y
							--]]
							and getpixel(tx1, ty1) == srcColor
							then
								putpixel(tx1, ty1)
								fillstack:insert{tx1, ty1}
							end
						end
					end
				end
			end
		end
	end

	if mouseX >= x and mouseX < x + w
	and mouseY >= y and mouseY < y + h
	then
		if app:key'space' then
			spritePan(app:keyp'space')
		end
		if self.spriteDrawMode == 'pan' then
			if leftButtonDown then
				spritePan(leftButtonPress)
			end
		end
	end

	if not spritePanHandled then
		self.spritePanPressed = false
	end

	-- sprite edit method
	local x = 32
	local y = 96
	self:guiRadio(x, y, {'draw', 'dropper', 'fill', 'pan'}, self.spriteDrawMode, function(result)
		self.spriteDrawMode = result
	end)

	-- select palette color to draw
	app:drawMenuText(
		'#',
		16,
		112,
		13,
		-1
	)
	self:guiTextField(
		16+5,
		112,
		15,
		self, 'paletteSelIndex',
		function(result)
			self.paletteSelIndex = tonumber(result) or self.paletteSelIndex
		end
	)

	-- TODO how to draw all colors
	-- or how many to draw ...
	local y = 128
	app:drawBorderRect(
		x-1,
		y-1,
		w+2,
		h+2,
		0xd,
		nil,
		app.paletteMenuTex
	)

	-- log2PalBits == 3 <=> palBits == 8 <=> showing 1<<8 = 256 colors <=> showing 16 x 16 colors
	-- log2PalBits == 2 <=> palBits == 4 <=> showing 1<<4 = 16 colors <=> showing 4 x 4 colors
	-- log2PalBits == 1 <=> palBits == 2 <=> showing 1<<2 = 4 colors <=> showing 2 x 2 colors
	-- log2PalBits == 0 <=> palBits == 1 <=> showing 1<<1 = 2 colors <=> showing 2 x 1 colors
	-- means showing 1 << 8 = 256 palettes, means showing 1 << 4 = 16 per width and height
	local palCount = bit.lshift(1, bit.lshift(1, self.log2PalBits))
	local palBlockWidth = math.sqrt(palCount)
	local palBlockHeight = math.ceil(palCount / palBlockWidth)
	local bw = w / palBlockWidth
	local bh = h / palBlockHeight
	for j=0,palBlockHeight-1 do
		for i=0,palBlockWidth-1 do
			local paletteIndex = bit.band(0xff, self.paletteOffset + i + palBlockWidth * j)
			local rx = x + bw * i
			local ry = y + bh * j

			app:drawSolidRect(
				rx,
				ry,
				bw,
				bh,
				paletteIndex,
				nil,			-- borderOnly
				nil,			-- round
				paletteRAM.tex	-- paletteTex
			)

			if mouseX >= rx and mouseX < rx + bw
			and mouseY >= ry and mouseY < ry + bh
			then
				if leftButtonPress then
					if self.isPaletteSwapping then
						self.undo:pushContinuous()
						-- TODO button for only swap in this screen
						app:colorSwap(
							self.paletteSelIndex, 	-- from
							paletteIndex, 			-- to
							0, 0, 					-- x, y
							spriteSheetSize.x,		-- w
							spriteSheetSize.y-8,	-- h ... cheap trick to avoid the font row
							self.paletteBlobIndex
						)
						self.isPaletteSwapping = false
					end
					self.paletteSelIndex = paletteIndex
					self.paletteSelDown = paletteIndex
				elseif leftButtonDown then
					local move = paletteIndex - self.paletteSelDown
					self.paletteOffset = bit.band(0xff, self.paletteOffset - move)
					self.paletteSelDown = bit.band(0xff, paletteIndex - move)
				else
					-- histogram info ... TODO when to recalculate it ...
					if not self.hist then
						self.hist = Quantize.buildHistogram(sheetRAM.image)
					end
					self:setTooltip(
						tostring(self.hist[string.char(paletteIndex)] or 0),
						mouseX - 12,
						mouseY - 12,
						12,
						6
					)
				end
			end
		end
	end
	for j=0,palBlockHeight-1 do
		for i=0,palBlockWidth-1 do
			local paletteIndex = bit.band(0xff, self.paletteOffset + i + palBlockWidth * j)
			local rx = x + bw * i
			local ry = y + bh * j
			if self.paletteSelIndex == paletteIndex then
				for k,selBorderColor in ipairs(selBorderColors) do
					app:drawBorderRect(
						rx-k,
						ry-k,
						bw+2*k,
						bh+2*k,
						selBorderColor,
						nil,
						app.paletteMenuTex
					)
				end
			end
		end
	end

	if self:guiButton('X', 16, 128, self.isPaletteSwapping, 'pal swap') then
		self.isPaletteSwapping = not self.isPaletteSwapping
	end

	-- adjust palette size
	self:guiSpinner(16, 200, function(dx)
		self.log2PalBits = math.clamp(self.log2PalBits + dx, 0, 3)
	end, 'pal bpp='..bit.lshift(1,self.log2PalBits))

	-- adjust palette offset
	self:guiSpinner(16+24, 200, function(dx)
		self.paletteOffset = bit.band(0xff, self.paletteOffset + dx)
	end, 'pal ofs='..self.paletteOffset)

	-- adjust pen size
	self:guiSpinner(16+48, 200, function(dx)
		self.penSize = math.clamp(self.penSize + dx, 1, 5)
	end, 'pen size='..self.penSize)

	-- edit palette entries
	local selPaletteAddr = paletteRAM.addr + bit.lshift(self.paletteSelIndex, 1)
	local selColorValue = app:peekw(selPaletteAddr)
	app:drawMenuText('C=', 16, 216, 13, -1)
	self:guiTextField(
		16+10, 216, 20,
		('%04X'):format(selColorValue), nil,
		function(result)
			result = tonumber(result, 16)
			if result then
				self.undo:pushContinuous()
				self:edit_pokew(selPaletteAddr, result)
				selColorValue = result
			end
		end
	)

	app:drawMenuText('R=', 16, 224, 13, -1)
	self:guiTextField(
		16+10, 224, 20,
		('%02X'):format(bit.band(selColorValue,0x1f)), nil,
		function(result)
			result = tonumber(result, 16)
			if result then
				self.undo:pushContinuous()
				selColorValue = bit.bor(
					bit.band(app:peekw(selPaletteAddr), bit.bnot(0x1f)),
					result
				)
				self:edit_pokew(selPaletteAddr, selColorValue)
			end
		end
	)
	self:guiSpinner(16+32, 224, function(dx)
		selColorValue = bit.bor(bit.band(selColorValue+dx,0x1f), bit.band(selColorValue,bit.bnot(0x1f)))
		self:edit_pokew(selPaletteAddr, selColorValue)
	end)

	app:drawMenuText('G=', 16, 224+8, 13, -1)
	self:guiTextField(
		16+10, 224+8, 20,
		('%02X'):format(bit.band(bit.rshift(selColorValue,5),0x1f)), nil,
		function(result)
			result = tonumber(result, 16)
			if result then
				self.undo:pushContinuous()
				selColorValue = bit.bor(
					bit.band(app:peekw(selPaletteAddr), bit.bnot(0x3e0)),
					bit.lshift(result, 5)
				)
				self:edit_pokew(selPaletteAddr, selColorValue)
			end
		end
	)
	self:guiSpinner(16+32, 224+8, function(dx)
		self.undo:pushContinuous()
		selColorValue = bit.bor(bit.band((selColorValue+bit.lshift(dx,5)),0x3e0),bit.band(selColorValue,bit.bnot(0x3e0)))
		self:edit_pokew(selPaletteAddr, selColorValue)
	end)

	app:drawMenuText('B=', 16, 224+16, 13, -1)
	self:guiTextField(
		16+10, 224+16, 20,
		('%02X'):format(bit.band(bit.rshift(selColorValue,10),0x1f)), nil,
		function(result)
			result = tonumber(result, 16)
			if result then
				self.undo:pushContinuous()
				selColorValue = bit.bor(
					bit.band(app:peekw(selPaletteAddr), bit.bnot(0x7c00)),
					bit.lshift(result, 10)
				)
				self:edit_pokew(selPaletteAddr, selColorValue)
			end
		end
	)
	self:guiSpinner(16+32, 224+16, function(dx)
		self.undo:pushContinuous()
		selColorValue = bit.bor(bit.band((selColorValue+bit.lshift(dx,10)),0x7c00),bit.band(selColorValue,bit.bnot(0x7c00)))
		self:edit_pokew(selPaletteAddr, selColorValue)
	end)

	local alpha = bit.band(selColorValue,0x8000)~=0
	if self:guiButton('A', 16, 224+24, alpha) then
		self.undo:pushContinuous()
		if alpha then	-- if it was set then clear it
			selColorValue = bit.band(selColorValue, 0x7fff)
			self:edit_pokew(selPaletteAddr, selColorValue)
		else	-- otherwise set it
			selColorValue = bit.bor(selColorValue, 0x8000)
			self:edit_pokew(selPaletteAddr, selColorValue)
		end
	end
	app:drawMenuText(alpha and 'opaque' or 'clear', 16+16,224+24, 13, -1)

	if self:guiButton('P', 112, 32, self.pasteKeepsPalette, 'Paste Keeps Pal='..tostring(self.pasteKeepsPalette)) then
		self.pasteKeepsPalette = not self.pasteKeepsPalette
	end
	if self:guiButton('A', 112, 42, self.pasteTransparent, 'Paste Transparent='..tostring(self.pasteTransparent)) then
		self.pasteTransparent = not self.pasteTransparent
	end

	--[[
	self:guiSpinner(96, 52, function(dx)
		self.pasteTargetNumColors = bit.band(self.pasteTargetNumColors + dx)
	end, 'paste target # colors='..tostring(self.pasteTargetNumColors))
	--]]
	-- [[
	self:guiTextField(
		80, 32, 4*8,
		self, 'pasteTargetNumColors',
		function(result)
			self.pasteTargetNumColors = tonumber(result) or 0
		end,
		'paste target # colors='..self.pasteTargetNumColors
	)
	--]]

	-- TODO button for cut copy and paste as well

	-- flags ... ???

	-- handle input

	local uikey
	if ffi.os == 'OSX' then
		uikey = app:key'lgui' or app:key'rgui'
	else
		uikey = app:key'lctrl' or app:key'rctrl'
	end
	if uikey then
		local x = self.spriteSelPos.x * spriteSize.x
		local y = self.spriteSelPos.y * spriteSize.y
		local width = spriteSize.x * self.spriteSelSize.x
		local height = spriteSize.y * self.spriteSelSize.y
		if app:keyp'x' or app:keyp'c' then
			-- copy the selected region in the sprite/tile sheet
			-- TODO copy the current-edit region? wait it's the same region ...
			-- TODO if there is such a spriteSheetRAM.dirtyGPU then flush GPU changes here ... but there's not cuz I never write to it with the GPU ...
			assert(not sheetRAM.dirtyGPU)
			assert(x >= 0 and y >= 0 and x + width <= sheetRAM.image.width and y + height <= sheetRAM.image.height)
			local image = sheetRAM.image:copy{x=x, y=y, width=width, height=height}
			if image.channels == 1 then
print'BAKING PALETTE'
				-- TODO move palette functionality inot Image
				-- TODO offset palette by current bits / shift?
				local rgba = Image(image.width, image.height, 4, uint8_t)
				local srcp = image.buffer
				local dstp = rgba.buffer
				for i=0,image.width*image.height-1 do
					dstp[0],dstp[1],dstp[2],dstp[3] = rgba5551_to_rgba8888_4ch(
						ffi.cast(palettePtrType, paletteBlob.ramptr)[srcp[0]]
					)
--DEBUG:print(i, dstp[0],dstp[1],dstp[2],dstp[3])
					dstp = dstp + 4
					srcp = srcp + 1
				end
				image = rgba	-- current clipboard restrictions ... only 32bpp
			end
			clip.image(image)
			if app:keyp'x' then
				self.undo:push()
				-- image-cut ... how about setting the region to the current-palette-offset (whatever appears as zero) ?
				sheetRAM.dirtyCPU = true
				assert.eq(sheetRAM.image.channels, 1)
				for j=y,y+height-1 do
					for i=x,x+width-1 do
						self:edit_poke(currentSheetAddr + i + sheetRAM.image.width * j, self.paletteOffset)
					end
				end
				self.hist = nil	-- invalidate histogram
			end
		elseif app:keyp'v' then
			-- how about allowing over-paste?  same with over-draw., how about a flag to allow it or not?
			assert(not sheetRAM.dirtyGPU)
			local image = clip.image()
			if image then
				self.undo:push()
				--[[
				image paste options:
				- constrain to selection vs spill over (same with drawing pen)
				- blit to selection vs keeping 1:1 with original
				- quantize palette ...
					- use current palette
						- option to preserve pasted image original indexes vs remap them
					- or create new palette from pasted image
						- option to preserve spritesheet original indexes vs remap them
					- or create new palette from current and pasted image
					- target bitness?  just use spriteFlags?
					- target palette offset?  just use paletteOffset?
				- quantize tiles? only relevant for whatever the tilemap is pointing into ...
					- use 'convert-to-8x8x4pp's trick there ...
				--]]
				if image.channels ~= 1 then
					print('quantizing image to '..tostring(self.pasteTargetNumColors)..' colors')
					assert(image.channels >= 3)	-- NOTICE it's only RGB right now ... not even alpha
					image = image:rgb()
					assert.eq(image.channels, 3, "image channels")

					if self.pasteKeepsPalette then
						local image1ch = Image(image.width, image.height, 1, uint8_t)
						local srcp = image.buffer
						local dstp = image1ch.buffer
						for i=0,image.width*image.height-1 do
							-- slow way - just test every color against every color
							-- TODO build a mapping and then use 'applyColorMap' to go quicker
							--local r,g,b,a = srcp[0], srcp[1], srcp[2], srcp[3]
							local r,g,b = srcp[0], srcp[1], srcp[2]
							local bestIndex = bit.band(0xff, self.paletteOffset)
							local palR, palG, palB, palA = rgba5551_to_rgba8888_4ch(ffi.cast(palettePtrType, paletteBlob.ramptr)[bestIndex])
							local bestDistSq = (palR-r)^2 + (palG-g)^2 + (palB-b)^2	-- + (palA-a)^2
							for j=1,self.pasteTargetNumColors-1 do
								local colorIndex = bit.band(0xff, j + self.paletteOffset)
								local palR, palG, palB, palA = rgba5551_to_rgba8888_4ch(ffi.cast(palettePtrType, paletteBlob.ramptr)[colorIndex])
								local distSq = (palR-r)^2 + (palG-g)^2 + (palB-b)^2	-- + (palA-a)^2
								if distSq < bestDistSq then
									bestDistSq = distSq
									bestIndex = colorIndex
								end
							end
							dstp[0] = bestIndex
							dstp = dstp + 1
							srcp = srcp + image.channels
						end
						image = image1ch
					else
						image1ch = image:toIndexed()

						for i,color in ipairs(image.palette) do
							self:edit_pokew(
								paletteRAM.addr + bit.lshift(bit.band(0xff, i-1 + self.paletteOffset), 1),
								rgba8888_4ch_to_5551(
									color[1],
									color[2],
									color[3],
									0xff	-- ?
								)
							)
						end
					end
				end
				assert.eq(image.channels, 1, "image.channels")
print'pasting image'
print('currentSheetAddr', ('$%x'):format(currentSheetAddr))
				for j=0,image.height-1 do
					for i=0,image.width-1 do
						local destx = i + x
						local desty = j + y
						if destx >= 0 and destx < sheetRAM.image.width
						and desty >= 0 and desty < sheetRAM.image.height
						then
							local c = image.buffer[i + image.width * j]
							local r,g,b,a = rgba5551_to_rgba8888_4ch(ffi.cast(palettePtrType, paletteBlob.ramptr)[c])
							if not self.pasteTransparent or a > 0 then
								self:edit_poke(currentSheetAddr + destx + sheetRAM.image.width * desty, c)
							end
						end
					end
				end
				self.hist = nil
			end
		elseif app:keyp'z' then
			self:popUndo(shift)
		end
	end

	-- draw ui menubar last so it draws over the rest of the page
	self:guiBlobSelect(80, 0, 'sheet', self, 'sheetBlobIndex', function()
		-- for now only one undo per sheet/palette at a time
		self.undo:clear()
	end)
	self:guiBlobSelect(96, 0, 'palette', self, 'paletteBlobIndex', function()
		-- for now only one undo per sheet/palette at a time
		self.undo:clear()
	end)

	self:drawTooltip()
end

function EditSheet:popUndo(redo)
	local app = self.app
	local undoEntry = self.undo:pop(redo)
	if undoEntry then
		local sheetRAM = app.blobs.sheet[self.sheetBlobIndex+1].ramgpu
		local paletteRAM = app.blobs.palette[self.paletteBlobIndex+1].ramgpu
		ffi.C.memcpy(sheetRAM.image.buffer, undoEntry.sheet.buffer, sheetRAM.image:getBufferSize())
		ffi.C.memcpy(paletteRAM.image.buffer, undoEntry.palette.buffer, paletteRAM.image:getBufferSize())
		sheetRAM.dirtyCPU = true
		paletteRAM.dirtyCPU = true
	end
end

return EditSheet
