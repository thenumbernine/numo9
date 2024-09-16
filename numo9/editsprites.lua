--[[
This will be the code editor
--]]
local math = require 'ext.math'
local vec2i = require 'vec-ffi.vec2i'

local App = require 'numo9.app'
local paletteSize = App.paletteSize
local frameBufferSize = App.frameBufferSize
local spriteSheetSize = App.spriteSheetSize
local spriteSize = App.spriteSize
local spriteSheetSizeInTiles = App.spriteSheetSizeInTiles
local frameBufferSizeInTiles = App.frameBufferSizeInTiles
local tilemapSize = App.tilemapSize
local tilemapSizeInSprites = App.tilemapSizeInSprites


local EditSprites = require 'numo9.editor':subclass()

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
	self.log2PalBits = 2	-- showing an 1<<3 == 8bpp image: 0-3
	self.paletteOffset = 0	-- allow selecting this in another full-palette pic?

	self.penSize = 1 		-- size 1 thru 5 or so
	-- TODO pen dropper cut copy paste pan fill circle flipHorz flipVert rotate clear
end

local selBorderColors = {0xfd,0xfc}

function EditSprites:update()
	local app = self.app

	-- handle input in the draw because i'm too lazy to move all the data outside it and share it between two functions
	local leftButtonLastDown = bit.band(app.lastMouseButtons, 1) == 1
	local leftButtonDown = bit.band(app.mouseButtons, 1) == 1
	local leftButtonPress = leftButtonDown and not leftButtonLastDown
	local mouseX, mouseY = app.mousePos:unpack()

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

	local x = 126
	local y = 32
	local sw = spriteSheetSizeInTiles.x / 2	-- only draw a quarter worth since it's the same size as the screen
	local sh = spriteSheetSizeInTiles.y / 2
	local w = sw * spriteSize.x
	local h = sh * spriteSize.y
	app:drawBorderRect(
		x-1,
		y-1,
		w + 2,
		h + 2,
		self:color(13)
	)
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
		0,		-- paletteShift
		-1,		-- transparentIndex
		0,		-- spriteBit
		0xFF	-- spriteMask
	)
	local function fbToSpritesheetCoord(cx, cy)
		return
			(cx - x + self.spritesheetPanOffset.x) / spriteSize.x,
			(cy - y + self.spritesheetPanOffset.y) / spriteSize.y
	end
	if x <= mouseX and mouseX < x+w
	and y <= mouseY and mouseY <= y+h
	then
		if self.spritesheetEditMode == 'select' then
			if leftButtonPress then
				self.spriteSelPos:set(fbToSpritesheetCoord(mouseX, mouseY))
				self.spriteSelSize:set(1,1)
				self.spritePanOffset:set(0,0)
			elseif leftButtonDown then
				self.spriteSelSize.x = math.ceil((math.abs(mouseX - app.lastMousePressPos.x) + 1) / spriteSize.x)
				self.spriteSelSize.y = math.ceil((math.abs(mouseY - app.lastMousePressPos.y) + 1) / spriteSize.y)
			end
		elseif self.spritesheetEditMode == 'pan' then
			if leftButtonPress then
				if mouseX >= x and mouseX < x + w
				and mouseY >= y and mouseY < y + h
				then
					self.spritesheetPanDownPos:set(mouseX, mouseY)
					self.spritesheetPanPressed = true
				end
			elseif leftButtonDown then
				if self.spritesheetPanPressed then
					local tx = math.round(mouseX - self.spritesheetPanDownPos.x)
					local ty = math.round(mouseY - self.spritesheetPanDownPos.y)
					if tx ~= 0 or ty ~= 0 then
						self.spritesheetPanOffset.x = self.spritesheetPanOffset.x - tx
						self.spritesheetPanOffset.y = self.spritesheetPanOffset.y - ty
						self.spritesheetPanDownPos:set(mouseX, mouseY)
					end
				end
			else
				self.spritesheetPanPressed = false
			end
		end
	end

	-- sprite sel rect (1x1 ... 8x8)
	-- ... also show the offset ... is that a good idea?
	app:drawBorderRect(
		x + self.spriteSelPos.x * spriteSize.x + self.spritePanOffset.x - self.spritesheetPanOffset.x,
		y + self.spriteSelPos.y * spriteSize.y + self.spritePanOffset.y - self.spritesheetPanOffset.y,
		spriteSize.x * self.spriteSelSize.x,
		spriteSize.y * self.spriteSelSize.y,
		self:color(13)
	)

	-- sprite edit area
	local x = 2
	local y = 12
	self:drawText(
		'#'..(self.spriteSelPos.x + spriteSheetSizeInTiles.x * self.spriteSelPos.y),
		x + 32,
		y,
		self:color(13),
		-1
	)

	local y = 24
	local w = 64
	local h = 64
	app:drawBorderRect(x-1, y-1, w+2, h+2, self:color(13))
	app:drawSolidRect(x, y, w, h, self:color(5))
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
		0,										-- paletteIndex
		-1,										-- transparentIndex
		self.spriteBit,							-- spriteBit
		bit.lshift(1, self.spriteBitDepth)-1	-- spriteMask
	)

	-- convert x y in framebuffer space to x y in sprite window space
	local function fbToSpriteCoord(cx, cy)
		return
			(cx - x) / w * tonumber(self.spriteSelSize.x * spriteSize.x) + self.spriteSelPos.x * spriteSize.x + self.spritePanOffset.x,
			(cy - y) / h * tonumber(self.spriteSelSize.y * spriteSize.y) + self.spriteSelPos.y * spriteSize.y + self.spritePanOffset.y
	end
	if self.spriteDrawMode == 'draw'
	or self.spriteDrawMode == 'dropper'
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
			if self.spriteDrawMode == 'dropper' then
				if 0 <= tx and tx < spriteSheetSize.x
				and 0 <= ty and ty < spriteSheetSize.y
				then
					-- TODO since shift is shift, should I be subtracing it here?
					-- or should I just be AND'ing it?
					-- let's subtract it
					local texelIndex = tx + spriteSheetSize.x * ty
					assert(0 <= texelIndex and texelIndex < spriteSheetSize:volume())
					local texPtr = currentTex.image.buffer + texelIndex
					self.paletteSelIndex = bit.band(
						0xff,
						self.paletteOffset
						+ bit.rshift(
							bit.band(mask, texPtr[0]),
							self.spriteBit
						)
					)
				end
			elseif self.spriteDrawMode == 'draw' then
				local tx0 = tx - math.floor(self.penSize / 2)
				local ty0 = ty - math.floor(self.penSize / 2)
				assert(currentTex.image.buffer == currentTex.data)
				currentTex:bind()
				for dy=0,self.penSize-1 do
					local ty = ty0 + dy
					for dx=0,self.penSize-1 do
						local tx = tx0 + dx
						if 0 <= tx and tx < spriteSheetSize.x
						and 0 <= ty and ty < spriteSheetSize.y
						then
							local texelIndex = tx + spriteSheetSize.x * ty
							assert(0 <= texelIndex and texelIndex < spriteSheetSize:volume())
							local texPtr = currentTex.image.buffer + texelIndex
							texPtr[0] = bit.bor(
								bit.band(
									bit.bnot(mask),
									texPtr[0]
								),
								bit.band(
									mask,
									bit.lshift(
										self.paletteSelIndex - self.paletteOffset,
										self.spriteBit
									)
								)
							)
							currentTex:subimage{
								xoffset = tx,
								yoffset = ty,
								width = 1,
								height = 1,
								data = texPtr,
							}
						end
					end
				end
				currentTex:unbind()
			end
		end
	elseif self.spriteDrawMode == 'pan' then
		if leftButtonPress then
			if mouseX >= x and mouseX < x + w
			and mouseY >= y and mouseY < y + h
			then
				self.spritePanDownPos:set(mouseX, mouseY)
				self.spritePanPressed = true
			end
		elseif leftButtonDown then
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
		else
			self.spritePanPressed = false
		end
	end

	-- sprite edit method
	local x = 32
	local y = 96
	self:guiRadio(x, y, {'draw', 'dropper', 'pan'}, self.spriteDrawMode, function(result)
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
		self:color(13)
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
				paletteIndex
			)
			if leftButtonPress
			and mouseX >= rx and mouseX < rx + bw
			and mouseY >= ry and mouseY < ry + bh
			then
				self.paletteSelIndex = paletteIndex
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
	local colorptr = app.ram.palette + self.paletteSelIndex
	self:drawText(('C=%04X'):format(colorptr[0]), 16, 216, 13, -1)
	self:drawText(('R=%02X'):format(bit.band(colorptr[0],0x1f)), 16, 224, 13, -1)
	self:guiSpinner(16+32, 224, function(dx)
		colorptr[0] = bit.bor(bit.band(colorptr[0]+dx,0x1f),bit.band(colorptr[0],bit.bnot(0x1f)))
		app.palTex.dirtyCPU = true
	end)
	self:drawText(('G=%02X'):format(bit.band(bit.rshift(colorptr[0],5),0x1f)), 16, 224+8, 13, -1)
	self:guiSpinner(16+32, 224+8, function(dx)
		colorptr[0] = bit.bor(bit.band((colorptr[0]+bit.lshift(dx,5)),0x3e0),bit.band(colorptr[0],bit.bnot(0x3e0)))
		app.palTex.dirtyCPU = true
	end)
	self:drawText(('B=%02X'):format(bit.band(bit.rshift(colorptr[0],10),0x1f)), 16, 224+16, 13, -1)
	self:guiSpinner(16+32, 224+16, function(dx)
		colorptr[0] = bit.bor(bit.band((colorptr[0]+bit.lshift(dx,10)),0x7c00),bit.band(colorptr[0],bit.bnot(0x7c00)))
		app.palTex.dirtyCPU = true
	end)
	local alpha = bit.band(colorptr[0],0x8000)~=0
	if self:guiButton(16,224+24,'A', alpha) then
		if alpha then	-- if it was set then clear it
			colorptr[0] = bit.band(colorptr[0], 0x7fff)
		else	-- otherwise set it
			colorptr[0] = bit.bor(colorptr[0], 0x8000)
		end
		app.palTex.dirtyCPU = true
	end
	self:drawText(alpha and 'opaque' or 'clear', 16+16,224+24, 13, -1)

	-- flags ... ???


end

return EditSprites
