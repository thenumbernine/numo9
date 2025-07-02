--[[
By the 16-bit era, some games would store their levels lz-compessed (ex: Super Metroid)
but some would store their levels in brushes (and then lz-compress the brushes) (ex: Super Mario World)

TODO store this in the 'extra' bank location of 0xf600
TODO TODO have 'extra', audio, all just blobs stored wherever there's space.

types of brushes?
1x1
3x3
4x4 or 5x5, how to handle diagonals?
custom based on brush position?

speaking of custom, I need a tile remapping for animations

so each brush is going to be:
uint16_t x, y, w, h;	<- 8 bytes
... then comes the brush info 
... do we store per-brush a {uint8_t bw, bh; uint16_t tile[bw*bh]} = 2 * 2*n bytes?
... or do we put this in another table, and just give the brush a uint8_t to lookup into that table?
... I'll do the latter for now and see how quickly it fills up.

TODO checkbox for showing entity-tables as well (objects in level)
TODO space in RAM for all of this ... it'll be a blob like audio already is ... one more step to formless banks.
TODO cart API for "brush-to-tilemap" , brush #, tilemap x y w h

--]]
local math = require 'ext.math'
local vec2i = require 'vec-ffi.vec2i'
local numo9_rom = require 'numo9.rom'
local spriteSize = numo9_rom.spriteSize
local frameBufferSize = numo9_rom.frameBufferSize
local spriteSheetSize = numo9_rom.spriteSheetSize
local spriteSheetSizeInTiles = numo9_rom.spriteSheetSizeInTiles

local EditBrushes = require 'numo9.ui':subclass()

function EditBrushes:init(args)
	EditBrushes.super.init(self, args)

	self.stampSize = vec2i(1,1)
	self.stamp = {}
	for i=1,self.stampSize.x do
		self.stamp[i] = self.stamp[i] or {}
		for j=1,self.stampSize.y do
			self.stamp[i][j] = self.stamp[i][j] or 0
		end
	end

	self.pickOpen = nil
	self.spriteSelPos = vec2i()
	self.spriteSelSize = vec2i(1,1)
	self.draw16Sprites = false
end

function EditBrushes:update()
	local app = self.app

	local draw16As0or1 = self.draw16Sprites and 1 or 0
	local thisTileSize = vec2i(
		bit.lshift(spriteSize.x, draw16As0or1),
		bit.lshift(spriteSize.y, draw16As0or1))
	local leftButtonDown = app.mouse.leftDown
	local leftButtonPress = app.mouse.leftPress
	local leftButtonRelease = app.mouse.leftRelease
	local mouseX, mouseY = app.ram.mousePos:unpack()

	local shift = app:key'lshift' or app:key'rshift'
	
	EditBrushes.super.update(self)

	-- title controls
	local x,y = 128, 0

	-- TODO this across here and the tilemap editor, and maybe from a memory address in the game...
	if self:guiButton('X', x, y, self.draw16Sprites, self.draw16Sprites and '16x16' or '8x8') then
		self.draw16Sprites = not self.draw16Sprites
	end
	
	x, y = 0, 8

	local stampSizeChanged
	if self:guiButton('<', x+5, y, nil, 'stamp width') then
		self.stampSize.x = math.clamp(self.stampSize.x - 1, 1, 255)
		stampSizeChanged = true
	end
	if self:guiButton('>', x+10, y, nil, 'stamp width') then
		self.stampSize.x = math.clamp(self.stampSize.x + 1, 1, 255)
		stampSizeChanged = true
	end
	if self:guiButton('^', x, y+8, nil, 'stamp height') then
		self.stampSize.y = math.clamp(self.stampSize.y - 1, 1, 255)
		stampSizeChanged = true
	end
	if self:guiButton('v', x, y+16, nil, 'stamp height') then
		self.stampSize.y = math.clamp(self.stampSize.y + 1, 1, 255)
		stampSizeChanged = true
	end
	if stampSizeChanged then
		local newStamp = {}
		for i=1,self.stampSize.x do
			newStamp[i] = newStamp[i] or {}
			for j=1,self.stampSize.y do
				newStamp[i][j] = (self.stamp[i] or {})[j] or 0
			end
		end
		self.stamp = newStamp
	end

	for pass=0,1 do
		for j=0,self.stampSize.y-1 do
			for i=0,self.stampSize.x-1 do
				local ux = 5 + i * thisTileSize.x
				local uy = 16 + j * thisTileSize.y
				local uw = thisTileSize.x
				local uh = thisTileSize.y
				if pass==0 then
					app:drawBorderRect(ux-1, uy-1, uw+2, uh+2, self:color(10))
					app:drawSolidRect(ux, uy, uw, uh, self:color(0))
				else
					local t = assert(self.stamp[i+1][j+1])
					local tx = bit.band(t, 0x1f) * spriteSize.x					-- ux
					local ty = bit.band(bit.rshift(t, 5), 0x1f) * spriteSize.y	-- uy 
					local tw = thisTileSize.x-1					-- uw
					local th = thisTileSize.y-1					-- uh                
					-- TODO h and v flip 
					app:drawQuad(
						ux, uy, uw, uh,		-- x, y, w, h
						tx, ty, tw, th,
						1,		-- sheetIndex
						bit.lshift(bit.band(bit.rshift(t, 10), 7), 5),		-- paletteShift
						-1,		-- transparentIndex
						0,		-- spriteBit
						0xff	-- spriteMask
					)
					if self.pickOpen == nil
					and leftButtonRelease
					and mouseX >= ux and mouseX < ux + uw
					and mouseY >= uy and mouseY < uy + uh
					then
						self.pickOpen = {i, j}	-- which tile we are replacing
						return 	-- don't handle future clicks tht would close the pick window
					end
				end
			end
		end
	end

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
				self.stamp[self.pickOpen[1]+1][self.pickOpen[2]+1] = bit.bor(
					self.spriteSelPos.x,
					bit.lshift(self.spriteSelPos.y, 5)
					-- TODO also high bits
				)
				-- TODO if there were spriteSelSize then fill in more pick neighboring tiles in the stamp
				self.pickOpen = nil
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
		-- TODO show current brushes *here*
		-- click and drag off a brush to place a new one
		-- click and drag on a brush center to move it
		-- click and drag on a brush edge to resize it
		if leftButtonPress then
		elseif leftButtonDown then
		elseif leftButtnRelease then
		end
	end
end

return EditBrushes 
