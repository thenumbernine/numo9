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
	self.spriteSelSize = vec2i()
	self.lastMouseDown = vec2i()
	self.spriteBit = 0	-- which bitplane to start at: 0-7
	self.spriteBitDepth = 8	-- how many bits to edit at once: 1-8
	self.paletteSelIndex = 0	-- which color we are painting
	self.log2PalBits = 2	-- showing an 1<<3 == 8bpp image: 0-3
	self.paletteOffset = 0	-- allow selecting this in another full-palette pic?

	-- TODO still:
	self.penSize = 1 -- TODO size 1 thru 5 or so
	self.spriteEditTool = 1 -- TODO pen dropper cut copy paste pan fill circle flipHorz flipVert rotate clear
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

function Editor:update()
end

local selBorderColors = {13,12}

function Editor:drawSpinner(x, y, cb)
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
end

function Editor:draw()
	local app = self.app

	-- handle input in the draw because i'm too lazy to move all the data outside it and share it between two functions
	local leftButtonLastDown = bit.band(app.lastMouseButtons, 1) == 1
	local leftButtonDown = bit.band(app.mouseButtons, 1) == 1
	local leftButtonPress = leftButtonDown and not leftButtonLastDown
	local mouseX, mouseY = app.mousePos:unpack()
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
			local i = self.newlines[y]+1
			local j = self.newlines[y+1]
			app:drawTextFgBg(
				spriteSize.x,
				y * spriteSize.y,
				self.text:sub(i, j-1),
				12,
				-1
			)
			y = y + 1
		end

		if getTime() % 1 < .5 then
			app:drawSolidRect(
				self.cursorCol * spriteSize.x,
				self.cursorRow * spriteSize.y,
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

		app:drawTextFgBg(
			128+16+24,
			12,
			'#'..self.spriteBit,
			13,
			-1
		)

		self:drawSpinner(128+16+24, 20, function(dx)
			self.spriteBit = math.clamp(self.spriteBit + dx, 0, 7)
		end)

		app:drawTextFgBg(
			128+16+24+32,
			12,
			'#'..self.spriteBitDepth,
			13,
			-1
		)

		self:drawSpinner(128+16+24+32, 20, function(dx)
			-- should I not let this exceed 8 - spriteBit ?
			-- or should I wrap around bits and be really unnecessarily clever?
			self.spriteBitDepth = math.clamp(self.spriteBitDepth + dx, 1, 8)
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
		app:drawSprite(
			x,		-- x
			y,		-- y
			0,		-- index
			sw,		-- sw
			sh,		-- sh
			0,		-- paletteShift
			-1,		-- transparentIndex
			0,		-- spriteBit
			0xFF	-- spriteMask
		)
		if x <= mouseX and mouseX < x+w
		and y <= mouseY and mouseY <= y+h
		then
			if leftButtonPress then
				self.spriteSelPos.x = (mouseX - x) / spriteSize.x
				self.spriteSelPos.y = (mouseY - y) / spriteSize.y
				self.spriteSelSize:set(1,1)
			elseif leftButtonDown then
				self.spriteSelSize.x = math.ceil((math.abs(mouseX - self.lastMouseDown.x) + 1) / spriteSize.x)
				self.spriteSelSize.y = math.ceil((math.abs(mouseY - self.lastMouseDown.y) + 1) / spriteSize.y)
			end
		end

		-- sprite sel rect (1x1 ... 8x8)
		app:drawBorderRect(
			x + self.spriteSelPos.x * spriteSize.x,
			y + self.spriteSelPos.y * spriteSize.y,
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
		app:drawBorderRect(
			x-1,
			y-1,
			w+2,
			h+2,
			13
		)
		app:drawSprite(
			x,
			y,
			self.spriteSelPos.x + spritesPerSheet.x * self.spriteSelPos.y,
			self.spriteSelSize.x,	-- spritesWide
			self.spriteSelSize.y,	-- spritesHigh
			0,						-- paletteIndex
			-1,						-- transparentIndex
			self.spriteBit,			-- spriteBit
			bit.lshift(1, self.spriteBitDepth)-1,	-- spriteMask
			w / tonumber(self.spriteSelSize.x * spriteSize.x),	-- scaleX
			h / tonumber(self.spriteSelSize.y * spriteSize.y)	-- scaleY
		)
		if leftButtonDown
		and mouseX >= x and mouseX < x + w
		and mouseY >= y and mouseY < y + h
		then
--DEBUG:print('drawing on the picture')
			local bx = math.floor((mouseX - x) / w * tonumber(self.spriteSelSize.x * spriteSize.x))
			local by = math.floor((mouseY - y) / h * tonumber(self.spriteSelSize.y * spriteSize.y))
--DEBUG:print('drawing at local texel', bx, by)
			-- TODO HERE draw a pixel to the sprite sheet ...
			-- TODO TODO I'm gonna write to the spriteSheet.image then re-upload it
			-- I hope nobody has modified the GPU buffer and invalidated the sync between them ...
			local tx = bx + self.spriteSelPos.x * spriteSize.x
			local ty = by + self.spriteSelPos.y * spriteSize.y
--DEBUG:print('texel index', tx, ty)
			assert(0 <= tx and tx < spriteSheetSize.x)
			assert(0 <= ty and ty < spriteSheetSize.y)
			local texelIndex = tx + spriteSheetSize.x * ty
			assert(0 <= texelIndex and texelIndex < spriteSheetSize:volume())
			-- TODO since shift is shift, should I be subtracing it here?
			-- or should I just be AND'ing it?
			-- let's subtract it
			local texPtr = app.spriteTex.image.buffer + texelIndex
--DEBUG:print('color index was', texPtr[0])
--DEBUG:print('paletteSelIndex', self.paletteSelIndex)
--DEBUG:print('paletteOffset', self.paletteOffset)
--[[ just get it working
			texPtr[0] = bit.band(0xff, self.paletteSelIndex - self.paletteOffset)
--]]
-- [[ proper masking
			local mask = bit.lshift(
				bit.lshift(1, self.spriteBitDepth) - 1,
				self.spriteBit
			)
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
--]]
--DEBUG:print('color index is now', texPtr[0])
			assert(app.spriteTex.image.buffer == app.spriteTex.data)
			app.spriteTex
				:bind()
				--:subimage()
				:subimage{xoffset=tx, yoffset=ty, width=1, height=1, data=texPtr}
				--:subimage{xoffset=self.spriteSelPos.x * spriteSize.x, yoffset=self.spriteSelPos.y * spriteSize.y, width=self.spriteSelSize.x * spriteSize.x, height=self.spriteSelSize.y * spriteSize.y}
				:unbind()
		end

		-- choose spriteBit
		-- choose spriteMask

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
		self:drawSpinner(16, 200, function(dx)
			self.log2PalBits = math.clamp(self.log2PalBits + dx, 0, 3)
		end)

		-- adjust palette offset
		self:drawSpinner(16+24, 200, function(dx)
			self.paletteOffset = bit.band(0xff, self.paletteOffset + dx)
		end)

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
