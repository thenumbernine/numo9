--[[
This will be the code editor
--]]
local sdl = require 'sdl'
local table = require 'ext.table'
local string = require 'ext.string'
local range = require 'ext.range'
local math = require 'ext.math'
local class = require 'ext.class'

-- TODO make the editor a rom itself
-- TODO make roms that hold all the necessary stuff

local EditCode = class()

function EditCode:init(args)
	self.app = assert(args.app)
	self.text = [[
print'hi'
do return end
]]
	self:refreshNewlines()

	-- starting point of where to render text, preferrably at a newline or beginning
	self.start = 1
	self.cursorLoc = 1	-- TODO cursor xy? or just index offset?
	self.cursorCol = 1
	self.cursorRow = 1
end

local slashRByte = ('\r'):byte()
local newlineByte = ('\n'):byte()
function EditCode:refreshNewlines()
print(string.hexdump(self.text))	
	-- refresh newlines
	self.newlines = table()
	self.newlines:insert(0)
	for i=1,#self.text do
		if self.text:byte(i) == newlineByte then
			self.newlines:insert(i)
		end
	end
	self.newlines:insert(#self.text+1)
print('newlines', require 'ext.tolua'(self.newlines))
print('lines by newlines')
for i=1,#self.newlines-1 do
	local start = self.newlines[i]+1
	local finish = self.newlines[i+1]
	print(start, finish, self.text:sub(start, finish-1))
end
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

function EditCode:update(t)
	local app = self.app
	app:clearScreen()
	app:drawText(0,0,'CESM code editor', 1)

	for y=1,app.spritesPerFrameBuffer.y-2 do
		if y >= #self.newlines then break end
		local i = self.newlines[y]+1
		local j = self.newlines[y+1]
		app:drawText(
			app.spriteSize.x,
			y * app.spriteSize.y,
			self.text:sub(i, j-1),
			0
		)
		y = y + 1
	end
	
	if t % 1 < .5 then
		app:drawSolidRect(
			self.cursorCol * app.spriteSize.x,
			self.cursorRow * app.spriteSize.y,
			app.spriteSize.x,
			app.spriteSize.y,
			15)
	end

	app:drawText(
		0,
		app.frameBufferSize.y - app.spriteSize.y,
		'line '..self.cursorRow..'/'..(#self.newlines-2)..' col '..self.cursorCol,
		1
	)
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

function EditCode:event(e)
	local app = self.app
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
			elseif sym == sdl.SDLK_RETURN 
			or sym == sdl.SDLK_TAB
			then
				self:addCharToText(sym)	
			elseif sym == sdl.SDLK_UP 
			or sym == sdl.SDLK_DOWN
			then
				local dy = sym == sdl.SDLK_UP and -1 or 1
				self.cursorRow = math.clamp(self.cursorRow + dy, 1, #self.newlines-2)
				local currentLineLen = self.newlines[self.cursorRow+1] - self.newlines[self.cursorRow] + 1
				self.cursorCol = math.clamp(self.cursorCol, 1, currentLineLen)
				self.cursorLoc = self.newlines[self.cursorRow] + self.cursorCol
				self:refreshCursorColRowForLoc()	-- just in case?
			elseif sym == sdl.SDLK_LEFT 
			or sym == sdl.SDLK_RIGHT
			then
				local dx = sym == sdl.SDLK_LEFT and -1 or 1
				self.cursorLoc = math.clamp(self.cursorLoc + dx, 1, #self.text+1)
				self:refreshCursorColRowForLoc()
			elseif sym == sdl.SDLK_ESCAPE then
				app.runFocus = app.con
				app.con:reset()	-- or save the screen
			end
		end
	end
end

return EditCode
