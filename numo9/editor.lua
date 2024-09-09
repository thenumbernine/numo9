--[[
This will be the code editor
--]]
local sdl = require 'sdl'
local table = require 'ext.table'
local range = require 'ext.range'
local math = require 'ext.math'
local class = require 'ext.class'
local getTime = require 'ext.timer'.getTime
local vec2i = require 'vec-ffi.vec2i'

local App = require 'numo9.app'
local paletteSize = App.paletteSize
local frameBufferSize = App.frameBufferSize
local spriteSheetSize = App.spriteSheetSize
local spriteSize = App.spriteSize
local spritesPerSheet = App.spritesPerSheet
local spritesPerFrameBuffer = App.spritesPerFrameBuffer

-- TODO make the editor a rom itself
-- TODO make roms that hold all the necessary stuff

local editModes = {
	'code',
	'sprites',
	'tilemap',
	'fx',
	'music',
}

local Editor = class()

function Editor:init(args)
	self.app = assert(args.app)

	self.editMode = 1

	-- text cursor loc
	self.cursorLoc = 1
	self.editLineOffset = 0
	self:setText[[
print'Hello NuMo9'

function draw()
	local x = 128
	local y = 128
	local t = time()
	local cx = cos(t)
	local cy = sin(t)
	local r = 50
	rect(
		x - r * cx,
		y - r * cy,
		x + r * cx,
		y + r * cy,
		math.floor(5 * time())
	)
end

do return 42 end
]]

	-- sprite edit mode
	self.spriteSelPos = vec2i()	-- TODO make this texel based, not sprite based (x8 less resolution)
	self.spriteSelSize = vec2i(1,1)
	self.spritesheetPanOffset = vec2i()
	self.spritesheetPanDownPos = vec2i()
	self.spritesheetPanPressed = false
	self.spritePanOffset = vec2i()	-- holds the panning offset from the sprite location
	self.spritePanDownPos = vec2i()	-- where the mouse was when you pressed down to pan
	self.spritePanPressed = false

	-- TODO this in app and let it be queried?
	self.lastMouseDown = vec2i()

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

function Editor:setText(text)
	self.text = text
		:gsub('\t', ' ')	--TODO add tab support
	self.cursorLoc = math.clamp(self.cursorLoc, 1, #self.text+1)
	self:refreshNewlines()
	self:refreshCursorColRowForLoc()
end

local slashRByte = ('\r'):byte()
local newlineByte = ('\n'):byte()
function Editor:refreshNewlines()
--print(require 'ext.string'.hexdump(self.text))
	-- refresh newlines
	self.newlines = table()
	self.newlines:insert(0)
	for i=1,#self.text do
		if self.text:byte(i) == newlineByte then
			self.newlines:insert(i)
		end
	end
	self.newlines:insert(#self.text+1)
--[[
print('newlines', require 'ext.tolua'(self.newlines))
print('lines by newlines')
for i=1,#self.newlines-1 do
	local start = self.newlines[i]+1
	local finish = self.newlines[i+1]
	print(start, finish, self.text:sub(start, finish-1))
end
--]]
end

function Editor:refreshCursorColRowForLoc()
	self.cursorRow = nil
	for i=1,#self.newlines-1 do
		local start = self.newlines[i]+1
		local finish = self.newlines[i+1]
		if start <= self.cursorLoc and self.cursorLoc <= finish then
			self.cursorRow = i
			break
		end
	end
	assert(self.cursorRow)
	self.cursorCol = self.cursorLoc - self.newlines[self.cursorRow]
end

local selBorderColors = {13,12}

function Editor:guiButton(x, y, str, isset, cb, tooltip)
	local app = self.app
	app:drawTextFgBg(x, y, str,
		isset and 13 or 10,
		isset and 4 or 2
	)

	local mouseX, mouseY = app.mousePos:unpack()
	if mouseX >= x and mouseX < x + spriteSize.x
	and mouseY >= y and mouseY < y + spriteSize.y
	then
		if tooltip then
			app:drawTextFgBg(mouseX - 12, mouseY - 12, tooltip, 12, 6)
		end

		local leftButtonLastDown = bit.band(app.lastMouseButtons, 1) == 1
		local leftButtonDown = bit.band(app.mouseButtons, 1) == 1
		local leftButtonPress = leftButtonDown and not leftButtonLastDown
		if leftButtonPress then
			return true
		end
	end
end

function Editor:guiSpinner(x, y, cb, tooltip)
	local app = self.app

	-- TODO this in one spot, mabye with glapp.mouse ...
	local leftButtonLastDown = bit.band(app.lastMouseButtons, 1) == 1
	local leftButtonDown = bit.band(app.mouseButtons, 1) == 1
	local leftButtonPress = leftButtonDown and not leftButtonLastDown
	local mouseX, mouseY = app.mousePos:unpack()

	app:drawTextFgBg(x, y, '<', 13, 0)
	if leftButtonPress
	and mouseX >= x and mouseX < x + spriteSize.x
	and mouseY >= y and mouseY < y + spriteSize.y
	then
		cb(-1)
	end

	x = x + spriteSize.x
	app:drawTextFgBg(x, y, '>', 13, 0)
	if leftButtonPress
	and mouseX >= x and mouseX < x + spriteSize.x
	and mouseY >= y and mouseY < y + spriteSize.y
	then
		cb(1)
	end

	if mouseX >= x - spriteSize.x and mouseX < x + spriteSize.x
	and mouseY >= y and mouseY < y + spriteSize.y
	then
		if tooltip then
			app:drawTextFgBg(mouseX - 12, mouseY - 12, tooltip, 12, 6)
		end
	end
end

function Editor:guiRadio(x, y, options, selected, cb)
	for _,name in ipairs(options) do
		if self:guiButton(
			x,
			y,
			name:sub(1,1):upper(),
			selected == name,
			name
		) then
			cb(name)
		end
		x = x + 8
	end
end

function Editor:update()
	local app = self.app

	-- handle input in the draw because i'm too lazy to move all the data outside it and share it between two functions
	local leftButtonLastDown = bit.band(app.lastMouseButtons, 1) == 1
	local leftButtonDown = bit.band(app.mouseButtons, 1) == 1
	local leftButtonPress = leftButtonDown and not leftButtonLastDown
	local mouseX, mouseY = app.mousePos:unpack()
	local mouseLastX, mouseLastY = app.lastMousePos:unpack()
	if leftButtonPress then
		self.lastMouseDown:set(mouseX, mouseY)
		local bx = math.floor(mouseX / spriteSize.x) + 1
		local by = math.floor(mouseY / spriteSize.y)
		if by == 0
		and bx >= 1
		and bx <= #editModes
		then
			self.editMode = bx
		end
	end


	app:clearScreen()

	for i,editMode in ipairs(editModes) do
		app:drawTextFgBg(
			(i-1) * spriteSize.x,
			0,
			editMode:sub(1,1):upper(),
			i == editMode and 15 or 4,
			i == self.editMode and 7 or 8
		)
	end

	local titlebar = '  '..editModes[self.editMode]
	titlebar = titlebar .. (' '):rep(spritesPerFrameBuffer.x - #titlebar)
	app:drawTextFgBg(
		#editModes*spriteSize.x,
		0,
		titlebar,
		12,
		8
	)

	if editModes[self.editMode] == 'code' then

		app:drawSolidRect(
			spriteSize.x,
			spriteSize.y,
			frameBufferSize.x - spriteSize.x,
			frameBufferSize.y - 2 * spriteSize.y,
			8
		)

		for y=1,spritesPerFrameBuffer.y-2 do
			if y >= #self.newlines then break end
			local i = self.newlines[y + self.editLineOffset] + 1
			local j = self.newlines[y + self.editLineOffset + 1]
			app:drawTextFgBg(
				spriteSize.x,
				y * spriteSize.y,
				self.text:sub(i, j-1),
				12,
				-1
			)
		end

		if self.cursorRow < self.editLineOffset+1 then
			self.editLineOffset = math.max(0, self.cursorRow-1)
		elseif self.cursorRow - (spritesPerFrameBuffer.y-2) > self.editLineOffset then
			self.editLineOffset = math.max(0, self.cursorRow - (spritesPerFrameBuffer.y-2))
		end

		if getTime() % 1 < .5 then
			app:drawSolidRect(
				self.cursorCol * spriteSize.x,
				(self.cursorRow - self.editLineOffset) * spriteSize.y,
				spriteSize.x,
				spriteSize.y,
				12)
		end

		local footer = 'line '..self.cursorRow..'/'..(#self.newlines-2)..' col '..self.cursorCol
		footer = footer .. (' '):rep(spritesPerFrameBuffer.x - #footer)
		app:drawTextFgBg(
			0,
			frameBufferSize.y - spriteSize.y,
			footer,
			12,
			1
		)
	elseif editModes[self.editMode] == 'sprites' then

		-- choose spriteBit
		app:drawTextFgBg(
			128+16+24,
			12,
			'#'..self.spriteBit,
			13,
			-1
		)
		self:guiSpinner(128+16+24, 20, function(dx)
			self.spriteBit = math.clamp(self.spriteBit + dx, 0, 7)
		end, 'bit='..self.spriteBit)

		-- choose spriteMask
		app:drawTextFgBg(
			128+16+24+32,
			12,
			'#'..self.spriteBitDepth,
			13,
			-1
		)
		self:guiSpinner(128+16+24+32, 20, function(dx)
			-- should I not let this exceed 8 - spriteBit ?
			-- or should I wrap around bits and be really unnecessarily clever?
			self.spriteBitDepth = math.clamp(self.spriteBitDepth + dx, 1, 8)
		end, 'bpp='..self.spriteBitDepth)

		-- spritesheet pan vs select
		self:guiRadio(224, 12, {'select', 'pan'}, self.spritesheetEditMode, function(result)
			self.spritesheetEditMode = result
		end)

		local x = 126
		local y = 32
		local sw = spritesPerSheet.x / 2	-- only draw a quarter worth since it's the same size as the screen
		local sh = spritesPerSheet.y / 2
		local w = sw * spriteSize.x
        local h = sh * spriteSize.y
		app:drawBorderRect(
			x-1,
			y-1,
			w + 2,
			h + 2,
			13
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
					self.spriteSelSize.x = math.ceil((math.abs(mouseX - self.lastMouseDown.x) + 1) / spriteSize.x)
					self.spriteSelSize.y = math.ceil((math.abs(mouseY - self.lastMouseDown.y) + 1) / spriteSize.y)
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
			13
		)

		-- sprite edit area
		local x = 2
		local y = 12
		app:drawTextFgBg(
			x + 32,
			y,
			'#'..(self.spriteSelPos.x + spritesPerSheet.x * self.spriteSelPos.y),
			13,
			-1
		)

		local y = 24
		local w = 64
		local h = 64
		app:drawBorderRect(x-1, y-1, w+2, h+2, 13)
		app:drawSolidRect(x, y, w, h, 5)
		app:drawQuad(
			x,
			y,
			w,
			h,
			tonumber(self.spriteSelPos.x * spriteSize.x + self.spritePanOffset.x) / tonumber(spriteSheetSize.x),
			tonumber(self.spriteSelPos.y * spriteSize.y + self.spritePanOffset.y) / tonumber(spriteSheetSize.y),
			tonumber(self.spriteSelSize.x * spriteSize.x) / tonumber(spriteSheetSize.x),
			tonumber(self.spriteSelSize.y * spriteSize.y) / tonumber(spriteSheetSize.y),
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
--DEBUG:print('drawing on the picture')
				local tx, ty = fbToSpriteCoord(mouseX, mouseY)
				tx = math.floor(tx)
				ty = math.floor(ty)
--DEBUG:print('texel index', tx, ty)
				-- TODO HERE draw a pixel to the sprite sheet ...
				-- TODO TODO I'm gonna write to the spriteSheet.image then re-upload it
				-- I hope nobody has modified the GPU buffer and invalidated the sync between them ...
--DEBUG:print('color index was', texPtr[0])
--DEBUG:print('paletteSelIndex', self.paletteSelIndex)
--DEBUG:print('paletteOffset', self.paletteOffset)
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
						local texPtr = app.spriteTex.image.buffer + texelIndex
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
--DEBUG:print('drawing at')
					local tx0 = tx - math.floor(self.penSize / 2)
					local ty0 = ty - math.floor(self.penSize / 2)
					assert(app.spriteTex.image.buffer == app.spriteTex.data)
					local spriteTex = app.spriteTex
					spriteTex:bind()
					for dy=0,self.penSize-1 do
						local ty = ty0 + dy
						for dx=0,self.penSize-1 do
							local tx = tx0 + dx
							if 0 <= tx and tx < spriteSheetSize.x
							and 0 <= ty and ty < spriteSheetSize.y
							then
--DEBUG:print('really drawing at', tx, ty)
								local texelIndex = tx + spriteSheetSize.x * ty
								assert(0 <= texelIndex and texelIndex < spriteSheetSize:volume())
								local texPtr = app.spriteTex.image.buffer + texelIndex
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
								spriteTex:subimage{
									xoffset = tx,
									yoffset = ty,
									width = 1,
									height = 1,
									data = texPtr,
								}
							end
						end
					end
--DEBUG:print('color index is now', texPtr[0])
					spriteTex:unbind()
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
		app:drawTextFgBg(
			16,
			112,
			'#'..self.paletteSelIndex,
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
			13
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
print('penSize', self.penSize)
		end, 'pen size='..self.penSize)

		-- edit palette entries

		-- flags ... ???
	end
end

function Editor:addCharToText(ch)
	if ch == slashRByte then ch = newlineByte end	-- store \n's instead of \r's
	if ch == 8 then
		self.text = self.text:sub(1, self.cursorLoc - 2) .. self.text:sub(self.cursorLoc)
		self.cursorLoc = math.max(1, self.cursorLoc - 1)
	else
		self.text = self.text:sub(1, self.cursorLoc-1) .. string.char(ch) .. self.text:sub(self.cursorLoc)
		self.cursorLoc = math.min(#self.text+1, self.cursorLoc + 1)
	end
	self:refreshNewlines()
	self:refreshCursorColRowForLoc()
end

local function prevNewline(s, i)
	while i >= 0 do
		i = i - 1
		if s:sub(i,i) == '\n' then return i end
	end
	return 1
end

function Editor:countRowCols(row)
	--return self.newlines[row+1] - self.newlines[row] + 1
	local linetext = self.text:sub(self.newlines[row], self.newlines[row+1])
	-- TODO enumerate chars, upon tab round up to tab indent
	--linetext = linetext:gsub('\t', (' '):rep(indentSize))
	return #linetext
end

function Editor:event(e)
	local app = self.app
	if editModes[self.editMode] == 'code' then
		if e[0].type == sdl.SDL_KEYDOWN
		or e[0].type == sdl.SDL_KEYUP
		then
			-- TODO store the press state of all as bitflags in 'ram' somewhere
			-- and let the 'cartridge' read/write it?
			-- and move this code into the 'console' 'cartridge' do the following?

			local press = e[0].type == sdl.SDL_KEYDOWN
			local keysym = e[0].key.keysym
			local sym = keysym.sym
			local mod = keysym.mod
			if press then
				local shift = bit.band(mod, sdl.SDLK_LSHIFT) ~= 0
				local charsym = app:getKeySymForShift(sym, shift)
				if charsym then
					self:addCharToText(charsym)
				elseif sym == sdl.SDLK_RETURN then
					self:addCharToText(sym)
				elseif sym == sdl.SDLK_TAB then
					-- TODO add tab and do indent up there,
					-- until then ...
					self:addCharToText(32)
				elseif sym == sdl.SDLK_UP
				or sym == sdl.SDLK_DOWN
				then
					local dy = sym == sdl.SDLK_UP and -1 or 1
					self.cursorRow = math.clamp(self.cursorRow + dy, 1, #self.newlines-2)

					local currentLineCols = self:countRowCols(self.cursorRow)
					self.cursorCol = math.clamp(self.cursorCol, 1, currentLineCols)

					self.cursorLoc = self.newlines[self.cursorRow] + self.cursorCol

					self:refreshCursorColRowForLoc()	-- just in case?
				elseif sym == sdl.SDLK_LEFT
				or sym == sdl.SDLK_RIGHT
				then
					local dx = sym == sdl.SDLK_LEFT and -1 or 1
					self.cursorLoc = math.clamp(self.cursorLoc + dx, 1, #self.text+1)
					self:refreshCursorColRowForLoc()
				end
			end
		end
	end
end

return Editor
