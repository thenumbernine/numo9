--[[
Here's where the stuff that handles the prompt and running commands goes
--]]
local sdl = require 'sdl'
local class = require 'ext.class'
local table = require 'ext.table'
local vec2i = require 'vec-ffi.vec2i'

local Console = class()

function Console:init(args)
	local app = assert(args.app)
	self.app = app
	self.cmdbuf = ''

	self.cmdHistory = table()
	self.cmdHistoryIndex = nil
	self.cursorPos = vec2i(0, 0)
	self.cursorPaletteIndex = 0

	-- TODO 'getFocus' or TODO always reload?
	-- clear the screen every time, or save the screen every time?
	app:clearScreen()
	self:print(app.title)
	self.prompt = '> '
	self:write(self.prompt)
end

function Console:runCmdBuf()
	local cmd = self.cmdbuf
	self.cmdHistory:insert(cmd)
	self.cmdHistoryIndex = nil
	self.cmdbuf = ''
	self:write'\n'

	local success, msg = self.app:runCmd(cmd)
	if not success then
		self:print(tostring(msg))
	end

	self:write(self.prompt)
end

-- should cursor be a 'app' property or an 'editor' property?
-- should the low-level os be 'editor' or its own thing?
function Console:offsetCursor(dx, dy)
	local app = self.app
	local fb = self.fb
	self.cursorPos.x = self.cursorPos.x + dx
	self.cursorPos.y = self.cursorPos.y + dy
	
	while self.cursorPos.x < 0 do
		self.cursorPos.x = self.cursorPos.x + app.frameBufferSize.x
		self.cursorPos.y = self.cursorPos.y - app.spriteSize.y
	end
	while self.cursorPos.x >= app.frameBufferSize.x do
		self.cursorPos.x = self.cursorPos.x - app.frameBufferSize.x
		self.cursorPos.y = self.cursorPos.y + app.spriteSize.y
	end

	while self.cursorPos.y < 0 do
		self.cursorPos.y = self.cursorPos.y + app.frameBufferSize.y
	end
	while self.cursorPos.y >= app.frameBufferSize.y do
		self.cursorPos.y = self.cursorPos.y - app.frameBufferSize.y
	end
end

function Console:drawChar(ch)
	local app = self.app
	app:drawSprite(
		self.cursorPos.x,
		self.cursorPos.y,
		ch,
		self.cursorPaletteIndex
	)
	self:offsetCursor(app.spriteSize.x, 0)
end

function Console:addCharToScreen(ch)
	local app = self.app
	if ch == 8 then
		self:drawChar((' '):byte())	-- in case the cursor is there
		self:offsetCursor(-2*app.spriteSize.x, 0)
		self:drawChar((' '):byte())	-- clear the prev char as well
		self:offsetCursor(-app.spriteSize.x, 0)
	elseif ch == 10 or ch == 13 then
		self:drawChar((' '):byte())	-- just in case the cursor is drawing white on the next char ...
		self.cursorPos.x = 0
		self.cursorPos.y = self.cursorPos.y + app.spriteSize.y
	else
		self:drawChar(ch)
	end
end

function Console:write(...)
	for j=1,select('#', ...) do
		local s = tostring(select(j, ...))
		for i=1,#s do
			self:addCharToScreen(s:byte(i,i))
		end
	end
end

function Console:print(...)
	for i=1,select('#', ...) do
		if i > 1 then self:write'\t' end
		self:write(tostring(select(i, ...)))
	end
	self:write'\n'
end

function Console:selectHistory(dx)
	local n = #self.cmdHistory
	self.cmdHistoryIndex = (((self.cmdHistoryIndex or n+1) + dx - 1) % n) + 1
	self.cmdbuf = self.cmdHistory[self.cmdHistoryIndex] or ''
	self.cursorPos.x = 0
	
	self:write(self.prompt)
	self:write(self.cmdbuf)
end

function Console:addCharToCmd(ch)
	if ch == 8 then
		if #self.cmdbuf > 0 then
			self.cmdbuf = self.cmdbuf:sub(1,-2)
			self:addCharToScreen(ch)
		end
	else
		self.cmdbuf = self.cmdbuf .. string.char(ch)
		self:addCharToScreen(ch)
	end
end

-- TODO run at 60hz
function Console:update(t)
	local app = self.app

	-- TODO start to bypass the internal console prompt
	
	--[[ TODO draw 
	self.cursorPos:set(0,0)
	app:write'CSMAB code editor'
	--]]

	if t % 1 < .5 then
		app:drawSolidRect(self.cursorPos.x, self.cursorPos.y, app.spriteSize.x, app.spriteSize.y, 15)
	else
		-- else TODO draw the character in the buffer at this location
		app:drawSolidRect(self.cursorPos.x, self.cursorPos.y, app.spriteSize.x, app.spriteSize.y, 0)
	end
end

local shiftFor = {
	-- letters handled separate
	[('`'):byte()] = ('~'):byte(),
	[('1'):byte()] = ('!'):byte(),
	[('2'):byte()] = ('@'):byte(),
	[('3'):byte()] = ('#'):byte(),
	[('4'):byte()] = ('$'):byte(),
	[('5'):byte()] = ('%'):byte(),
	[('6'):byte()] = ('^'):byte(),
	[('7'):byte()] = ('&'):byte(),
	[('8'):byte()] = ('*'):byte(),
	[('9'):byte()] = ('('):byte(),
	[('0'):byte()] = (')'):byte(),
	[('-'):byte()] = ('_'):byte(),
	[('='):byte()] = ('+'):byte(),
	[('['):byte()] = ('{'):byte(),
	[(']'):byte()] = ('}'):byte(),
	[('\\'):byte()] = ('|'):byte(),
	[(';'):byte()] = (':'):byte(),
	[("'"):byte()] = ('"'):byte(),
	[(','):byte()] = (','):byte(),
	[('<'):byte()] = ('>'):byte(),
	[('/'):byte()] = ('?'):byte(),
}

-- TODO shift behavior should go somewhere that both editor and console can get to it
-- TODO if 'editor' is a console then how to handle events in limited memory ...
-- keydown = xor test of key bits ... if i'm using a bitvector for the keyboard state ...
-- this all involves *another* set of key remappings which seems tedious ...
function Console:event(e)
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
			if sym >= sdl.SDLK_a and sym <= sdl.SDLK_z then
				if shift then
					sym = sym - 32
				end
				self:addCharToCmd(sym)
			-- add with non-standard shift capitalizing
			elseif sym >= sdl.SDLK_0 and sym <= sdl.SDLK_9
			or sym == sdl.SDLK_BACKQUOTE
			or sym == sdl.SDLK_MINUS
			or sym == sdl.SDLK_EQUALS
			or sym == sdl.SDLK_LEFTBRACKET
			or sym == sdl.SDLK_RIGHTBRACKET
			or sym == sdl.SDLK_BACKSLASH
			or sym == sdl.SDLK_QUOTE
			or sym == sdl.SDLK_SEMICOLON
			or sym == sdl.SDLK_COMMA
			or sym == sdl.SDLK_PERIOD
			or sym == sdl.SDLK_SLASH
			then
				if shift then 
					sym = assert(shiftFor[sym])
				end
				self:addCharToCmd(sym)
			elseif sym == sdl.SDLK_SPACE
			or sym == sdl.SDLK_BACKSPACE 
			then
				self:addCharToCmd(sym)
			elseif sym == sdl.SDLK_RETURN then
				self:runCmdBuf()
			elseif sym == sdl.SDLK_UP then
				self:selectHistory(-1)
			elseif sym == sdl.SDLK_DOWN then 
				self:selectHistory(1)
			-- TODO left right to move the cursor
			end
		end
	end
end

return Console
