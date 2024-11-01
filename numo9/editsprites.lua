--[[
This will be the code editor
--]]
local ffi = require 'ffi'
local gl = require 'gl'
local assert = require 'ext.assert'
local math = require 'ext.math'
local table = require 'ext.table'
local vec2i = require 'vec-ffi.vec2i'
local clip = require 'clip'	-- clipboard support
local Image = require 'image'
local Quantize = require 'image.quantize_mediancut'

local rgba8888_4ch_to_5551 = require 'numo9.video'.rgba8888_4ch_to_5551	-- TODO move this
local rgba5551_to_rgba8888_4ch = require 'numo9.video'.rgba5551_to_rgba8888_4ch

local paletteSize = require 'numo9.rom'.paletteSize
local paletteAddr = require 'numo9.rom'.paletteAddr
local frameBufferSize = require 'numo9.rom'.frameBufferSize
local spriteSheetSize = require 'numo9.rom'.spriteSheetSize
local spriteSize = require 'numo9.rom'.spriteSize
local spriteSheetSizeInTiles = require 'numo9.rom'.spriteSheetSizeInTiles
local frameBufferSizeInTiles = require 'numo9.rom'.frameBufferSizeInTiles
local tilemapSize = require 'numo9.rom'.tilemapSize
local tilemapSizeInSprites = require 'numo9.rom'.tilemapSizeInSprites
local unpackptr = require 'numo9.rom'.unpackptr

local dirs = {
	{-1,0},
	{1,0},
	{0,-1},
	{0,1},
}

local EditSprites = require 'numo9.ui':subclass()

function EditSprites:init(args)
	EditSprites.super.init(self, args)

	-- sprite edit mode
	self.spriteSelPos = vec2i()	-- TODO make this texel based, not sprite based (x8 less resolution)
	self.spriteSelSize = vec2i(1,1)
	self.spritesheetPanOffset = vec2i()
	self.spritesheetPanDownPos = vec2i()
	self.spritesheetPanPressed = false

	self.texField = 'spriteTex'
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

	self.pastePreservePalette = true
	self.pasteTargetNumColors = 256
	self.penSize = 1 		-- size 1 thru 5 or so
	-- TODO pen dropper cut copy paste pan fill circle flipHorz flipVert rotate clear

	self.pasteTransparent = false
end

local selBorderColors = {0xfd,0xfc}

function EditSprites:update()
	local app = self.app

	local leftButtonDown = app:key'mouse_left'
	local leftButtonPress = app:keyp'mouse_left'
	local leftButtonRelease = app:keyr'mouse_left'
	local mouseX, mouseY = app.ram.mousePos:unpack()

	local shift = app:key'lshift' or app:key'rshift'

	EditSprites.super.update(self)

	-- choose spriteBit
	self:drawText(
		'#'..self.spriteBit,
		128+16+24,
		12,
		13,
		-1
	)
	self:guiSpinner(128+16+24, 20, function(dx)
		self.spriteBit = math.clamp(self.spriteBit + dx, 0, 7)
	end, 'bit='..self.spriteBit)

	-- choose spriteMask
	self:drawText(
		'#'..self.spriteBitDepth,
		128+16+24+32,
		12,
		13,
		-1
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

	self:guiRadio(128, 12, {'spriteTex', 'tileTex'}, self.texField,
		function(result)
			self.texField = result
		end)
	local currentTex = app[self.texField]
	local currentTexAddr = ffi.cast('char*', currentTex.image.buffer) - app.ram.v

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
	gl.glScissor(x,y,w,h)
	do
		-- this is the framebuffer coord bounds of the spritesheet.
		local x1, y1 = spritesheetCoordToFb(0, 0)
		local x2, y2 = spritesheetCoordToFb(spriteSheetSizeInTiles:unpack())
		app:drawQuad(x1, y1, x2-x1, y2-y1, 0, 0, w/2, h/2, app.checkerTex, app.palMenuTex, 0, -1, 0, 0xFF)
		-- clamp it to the viewport of the spritesheet to get the rendered region
		-- then you can scissor-test this to get rid of the horrible texture stretching at borders from clamp_to_edge ...
		gl.glScissor(x1, y1, x2-x1, y2-y1)
	end
	app:drawQuad(
		x,		-- x
		y,		-- y
		w,		-- w
		h,		-- h
		tonumber(self.spritesheetPanOffset.x) / tonumber(spriteSheetSize.x),		-- tx
		tonumber(self.spritesheetPanOffset.y) / tonumber(spriteSheetSize.y),		-- ty
		tonumber(w) / tonumber(spriteSheetSize.x),							-- tw
		tonumber(h) / tonumber(spriteSheetSize.y),							-- th
		currentTex,
		app.palTex,
		0,		-- paletteShift
		-1,		-- transparentIndex
		0,		-- spriteBit
		0xFF	-- spriteMask
	)
	gl.glScissor(0,0,frameBufferSize:unpack())
	app:drawBorderRect(x-1, y-1, w+2, h+2, 0xfd)
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
				self.spriteSelSize:set(1,1)
				self.spritePanOffset:set(0,0)
			elseif leftButtonDown then
				self.spriteSelSize.x = math.ceil((math.abs(mouseX - app.ram.lastMousePressPos.x) + 1) / spriteSize.x)
				self.spriteSelSize.y = math.ceil((math.abs(mouseY - app.ram.lastMousePressPos.y) + 1) / spriteSize.y)
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


	gl.glScissor(x, y, w, h)
	-- sprite sel rect (1x1 ... 8x8)
	-- ... also show the offset ... is that a good idea?
	app:drawBorderRect(
		x + self.spriteSelPos.x * spriteSize.x + self.spritePanOffset.x - self.spritesheetPanOffset.x,
		y + self.spriteSelPos.y * spriteSize.y + self.spritePanOffset.y - self.spritesheetPanOffset.y,
		spriteSize.x * self.spriteSelSize.x,
		spriteSize.y * self.spriteSelSize.y,
		0xfd
	)
	gl.glScissor(0, 0, frameBufferSize:unpack())

	-- sprite edit area
	local x = 2
	local y = 12
	self:drawText(
		'#'..(self.spriteSelPos.x + spriteSheetSizeInTiles.x * self.spriteSelPos.y),
		x + 32,
		y,
		0xfd,
		-1
	)

	local y = 24
	local w = 64
	local h = 64
	-- draw some pattern under the sprite so you can tell what's transparent
	gl.glScissor(x,y,w,h)
	local function spriteCoordToFb(sX, sY)
		return
			(sX - self.spriteSelPos.x * spriteSize.x - self.spritePanOffset.x) / tonumber(self.spriteSelSize.x * spriteSize.x) * w + x,
			(sY - self.spriteSelPos.y * spriteSize.y - self.spritePanOffset.y) / tonumber(self.spriteSelSize.y * spriteSize.y) * h + y
	end
	do
		local x1, y1 = spriteCoordToFb(0, 0)
		local x2, y2 = spriteCoordToFb(spriteSheetSize:unpack())
		app:drawQuad(x1, y1, x2-x1, y2-y1, 0, 0, w*8, h*8, app.checkerTex, app.palMenuTex, 0, -1, 0, 0xFF)
		gl.glScissor(x1, y1, x2-x1, y2-y1)
	end
	app:drawQuad(
		x,
		y,
		w,
		h,
		tonumber(self.spriteSelPos.x * spriteSize.x + self.spritePanOffset.x) / tonumber(spriteSheetSize.x),
		tonumber(self.spriteSelPos.y * spriteSize.y + self.spritePanOffset.y) / tonumber(spriteSheetSize.y),
		tonumber(self.spriteSelSize.x * spriteSize.x) / tonumber(spriteSheetSize.x),
		tonumber(self.spriteSelSize.y * spriteSize.y) / tonumber(spriteSheetSize.y),
		currentTex,
		app.palTex,
		0,										-- paletteIndex
		-1,										-- transparentIndex
		self.spriteBit,							-- spriteBit
		bit.lshift(1, self.spriteBitDepth)-1	-- spriteMask
	)
	gl.glScissor(0, 0, frameBufferSize:unpack())
	app:drawBorderRect(x-1, y-1, w+2, h+2, 0xfd)

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
				local addr = currentTexAddr + texelIndex
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
				local addr = currentTexAddr + texelIndex
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
			end

			if self.spriteDrawMode == 'dropper'
			or (self.spriteDrawMode == 'draw' and shift)
			then
				local c = getpixel(tx, ty)
				if c then
					self.paletteSelIndex = bit.band(0xff, c + self.paletteOffset)
				end
			elseif self.spriteDrawMode == 'draw' then
				local tx0 = tx - math.floor(self.penSize / 2)
				local ty0 = ty - math.floor(self.penSize / 2)
				assert(currentTex.image.buffer == currentTex.data)
				currentTex:bind()
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
				currentTex:unbind()
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
	self:drawText(
		'#'..self.paletteSelIndex,
		16,
		112,
		13,
		-1
	)

	-- TODO how to draw all colors
	-- or how many to draw ...
	local y = 128
	app:drawBorderRect(
		x-1,
		y-1,
		w+2,
		h+2,
		0xfd
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
			
			-- cheap hack to use game palette here instead of menu palette ...
			-- TODO just make it an arg like drawQuad
			app.videoModeInfo[0].quadSolidObj.texs[1] = app.palTex
			app:drawSolidRect(
				rx,
				ry,
				bw,
				bh,
				paletteIndex
			)
			app.videoModeInfo[0].quadSolidObj.texs[1] = app.palMenuTex
			-- end cheap hack
			
			if mouseX >= rx and mouseX < rx + bw
			and mouseY >= ry and mouseY < ry + bh
			then
				if leftButtonPress then
					if self.isPaletteSwapping then
						-- TODO button for only swap in this screen
						app:colorSwap(self.paletteSelIndex, paletteIndex, 0, 0, spriteSheetSize.x, 
							spriteSheetSize.y-8	-- cheap trick to avoid the font row
						)
						self.isPaletteSwapping = false
					end
					self.paletteSelIndex = paletteIndex
					self.paletteSelDown = paletteIndex
				elseif leftButtonDown then
					local move = paletteIndex - self.paletteSelDown
					self.paletteOffset = bit.band(0xff, self.paletteOffset - move)
					self.paletteSelDown = bit.band(0xff, paletteIndex - move)
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
						selBorderColor
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
	local selPaletteAddr = paletteAddr + bit.lshift(self.paletteSelIndex, 1)
	local selColorValue = app:peekw(selPaletteAddr)
	self:drawText(('C=%04X'):format(selColorValue), 16, 216, 13, -1)
	self:drawText(('R=%02X'):format(bit.band(selColorValue,0x1f)), 16, 224, 13, -1)
	self:guiSpinner(16+32, 224, function(dx)
		self:edit_pokew(selPaletteAddr,
			bit.bor(bit.band(selColorValue+dx,0x1f),bit.band(selColorValue,bit.bnot(0x1f)))
		)
	end)
	self:drawText(('G=%02X'):format(bit.band(bit.rshift(selColorValue,5),0x1f)), 16, 224+8, 13, -1)
	self:guiSpinner(16+32, 224+8, function(dx)
		self:edit_pokew(selPaletteAddr,
			bit.bor(bit.band((selColorValue+bit.lshift(dx,5)),0x3e0),bit.band(selColorValue,bit.bnot(0x3e0)))
		)
	end)
	self:drawText(('B=%02X'):format(bit.band(bit.rshift(selColorValue,10),0x1f)), 16, 224+16, 13, -1)
	self:guiSpinner(16+32, 224+16, function(dx)
		self:edit_pokew(selPaletteAddr,
			bit.bor(bit.band((selColorValue+bit.lshift(dx,10)),0x7c00),bit.band(selColorValue,bit.bnot(0x7c00)))
		)
	end)
	local alpha = bit.band(selColorValue,0x8000)~=0
	if self:guiButton('A', 16, 224+24, alpha) then
		if alpha then	-- if it was set then clear it
			self:edit_pokew(selPaletteAddr,
				bit.band(selColorValue, 0x7fff)
			)
		else	-- otherwise set it
			self:edit_pokew(selPaletteAddr,
				bit.bor(selColorValue, 0x8000)
			)
		end
	end
	self:drawText(alpha and 'opaque' or 'clear', 16+16,224+24, 13, -1)

	if self:guiButton('P', 112, 32, self.pastePreservePalette, 'Paste Keeps Pal='..tostring(self.pastePreservePalette)) then
		self.pastePreservePalette = not self.pastePreservePalette
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
	local tmp = {}
	tmp[1] = tostring(self.pasteTargetNumColors)
	if self:guiTextField(80, 32, 4*8, tmp, 1, 'paste target # colors='..tmp[1]) then
		self.pasteTargetNumColors = tonumber(tmp[1]) or 0 --self.pasteTargetNumColors
	end
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
			-- TODO if there is such a spriteTex.dirtyGPU then flush GPU changes here ... but there's not cuz I never write to it with the GPU ...
			assert(not currentTex.dirtyGPU)
			assert(x >= 0 and y >= 0 and x + width <= currentTex.image.width and y + height <= currentTex.image.height)
			local image = currentTex.image:copy{x=x, y=y, width=width, height=height}
			if image.channels == 1 then
print'BAKING PALETTE'
				-- TODO move palette functionality inot Image
				-- TODO offset palette by current bits / shift?
				local rgba = Image(image.width, image.height, 4, 'unsigned char')
				local srcp = image.buffer
				local dstp = rgba.buffer
				for i=0,image.width*image.height-1 do
					dstp[0],dstp[1],dstp[2],dstp[3] = rgba5551_to_rgba8888_4ch(app.ram.palette[srcp[0]])
					dstp = dstp + 4
					srcp = srcp + 1
				end
				image = rgba	-- current clipboard restrictions ... only 32bpp
			end
			clip.image(image)
			if app:keyp'x' then
				-- image-cut ... how about setting the region to the current-palette-offset (whatever appears as zero) ?
				currentTex.dirtyCPU = true
				assert.eq(currentTex.image.channels, 1)
				for j=y,y+height-1 do
					for i=x,x+width-1 do
						self:edit_poke(currentTexAddr + i + currentTex.width * j, self.paletteOffset)
					end
				end
			end
		elseif app:keyp'v' then
			-- how about allowing over-paste?  same with over-draw., how about a flag to allow it or not?
			assert(not currentTex.dirtyGPU)
			local image = clip.image()
			if image then
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

					if self.pastePreservePalette then
						local image1ch = Image(image.width, image.height, 1, 'unsigned char')
						local srcp = image.buffer
						local dstp = image1ch.buffer
						for i=0,image.width*image.height-1 do
							-- slow way - just test every color against every color
							-- TODO build a mapping and then use 'applyColorMap' to go quicker
							local r,g,b,a = srcp[0], srcp[1], srcp[2], srcp[3]
							local bestIndex = bit.band(0xff, self.paletteOffset)
							local palR, palG, palB, palA = rgba5551_to_rgba8888_4ch(app.ram.palette[bestIndex])
							local bestDistSq = (palR-r)^2 + (palG-g)^2 + (palB-b)^2	-- + (palA-a)^2
							for j=1,self.pasteTargetNumColors-1 do
								local colorIndex = bit.band(0xff, j + self.paletteOffset)
								local palR, palG, palB, palA = rgba5551_to_rgba8888_4ch(app.ram.palette[colorIndex])
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
						local hist
						image, hist = Quantize.reduceColorsMedianCut{
							image = image,
							targetSize = self.pasteTargetNumColors,
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
							dstp[0] = bit.band(0xff, dstIndex + self.paletteOffset)
							dstp = dstp + 1
							srcp = srcp + image.channels
						end
						-- TODO proper would be to set image1ch.palette here but meh I'm just copying it on the next line anyways ...
						image = image1ch
						assert.eq(image.channels, 1, "image.channels")
						for i,color in ipairs(colors) do
							self:edit_pokew(
								paletteAddr + bit.lshift(bit.band(0xff, i-1 + self.paletteOffset), 1),
								rgba8888_4ch_to_5551(
									color:byte(1),
									color:byte(2),
									color:byte(3),
									0xff
								)
							)
						end
					end
				end
				assert.eq(image.channels, 1, "image.channels")
print'pasting image'
				for j=0,image.height-1 do
					for i=0,image.width-1 do
						local destx = i + x
						local desty = j + y
						if destx >= 0 and destx < currentTex.width
						and desty >= 0 and desty < currentTex.height
						then
							local c = image.buffer[i + image.width * j]
							local r,g,b,a = rgba5551_to_rgba8888_4ch(app.ram.palette[c])
							if not self.pasteTransparent or a > 0 then
								self:edit_poke(currentTexAddr + destx + currentTex.width * desty, c)
							end
						end
					end
				end
			end
		end
	end

	self:drawTooltip()
end

return EditSprites
