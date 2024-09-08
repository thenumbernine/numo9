--[[
This will be the code editor
--]]
local sdl = require 'sdl'
local table = require 'ext.table'
local range = require 'ext.range'
local math = require 'ext.math'
local class = require 'ext.class'
local getTime = require 'ext.timer'.getTime

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

local EditCode = class()

function EditCode:init(args)
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
end

function EditCode:setText(text)
	self.text = text
		:gsub('\t', ' ')	--TODO add tab support
	self.cursorLoc = math.clamp(self.cursorLoc, 1, #self.text+1)
	self:refreshNewlines()
	self:refreshCursorColRowForLoc()
end

local slashRByte = ('\r'):byte()
local newlineByte = ('\n'):byte()
function EditCode:refreshNewlines()
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

function EditCode:refreshCursorColRowForLoc()
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

function EditCode:update()
	local app = self.app
	if bit.band(app.mouseButtons, 1) == 1
	and bit.band(app.lastMouseButtons, 1) == 0
	then
		local x, y = app.mousePos:unpack()
		local bx = math.floor(x / spriteSize.x) + 1
		local by = math.floor(y / spriteSize.y)
		if by == 0
		and bx >= 1
		and bx <= #editModes
		then
			self.editMode = bx
		end
	end
end

function EditCode:draw()
	local app = self.app
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
		app:drawSprite(
			130,	-- x
			32,		-- y
			0,		-- index
			spritesPerSheet.x,	-- sw
			spritesPerSheet.y,	-- sh
			0,					-- paletteShift
			-1,					-- transparentIndex
			0,					-- spriteBit
			0xFF				-- spriteMask
		)
	end
end

function EditCode:addCharToText(ch)
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

function EditCode:countRowCols(row)
	--return self.newlines[row+1] - self.newlines[row] + 1
	local linetext = self.text:sub(self.newlines[row], self.newlines[row+1])
	-- TODO enumerate chars, upon tab round up to tab indent
	--linetext = linetext:gsub('\t', (' '):rep(indentSize))
	return #linetext
end

function EditCode:event(e)
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

return EditCode
