--[[
Here's where the stuff that handles the prompt and running commands goes
--]]
local sdl = require 'sdl'
local class = require 'ext.class'
local table = require 'ext.table'
local string = require 'ext.string'
local tolua = require 'ext.tolua'
local getTime = require 'ext.timer'.getTime
local vec2i = require 'vec-ffi.vec2i'

local keyCodeNames = require 'numo9.keys'.keyCodeNames
local keyCodeForName = require 'numo9.keys'.keyCodeForName
local getAsciiForKeyCode = require 'numo9.keys'.getAsciiForKeyCode

local paletteSize = require 'numo9.rom'.paletteSize
local frameBufferSize = require 'numo9.rom'.frameBufferSize
local spriteSheetSize = require 'numo9.rom'.spriteSheetSize
local spriteSize = require 'numo9.rom'.spriteSize
local spriteSheetSizeInTiles = require 'numo9.rom'.spriteSheetSizeInTiles
local frameBufferSizeInTiles = require 'numo9.rom'.frameBufferSizeInTiles
local fontWidth = require 'numo9.rom'.fontWidth


local Console = class()

function Console:init(args)
	self.app = assert(args.app)

	self:reset()
	
	local app = self.app
	self.cmdbuf = ''
	self.prompt = '> '

	self.cmdHistory = table()
	self.cmdHistoryIndex = nil

	-- TODO 'getFocus' or TODO always reload?
	-- clear the screen every time, or save the screen every time?
	app:clearScreen(0xf0)

	self:coolPrint'NuMo-9 ver. 0.1-alpha'
	self:coolPrint'https://github.com/thenumbernine/numo9 (c) 2024'
	self:coolPrint'...OpenResty LuaJIT'
	self:coolPrint('...'..frameBufferSize.x..'x'..frameBufferSize.y..'x8bpp framebuffer')
	--self:print"type help() for help" -- not really

	-- flag 'needsPrompt' then write the prompt in update if it's needed

	self:resetThread()
end

-- reset console state ...
function Console:reset()
	
	-- TODO move these to RAM
	self.cursorPos = vec2i(0, 0)
	self.fgColor = 0xfd
	self.bgColor = 0xf0

	self.needsPrompt = true
end

function Console:resetThread()
	self.thread = coroutine.create(function()
		while true do
			coroutine.yield()
			self:update()
		end
	end)
end

function Console:runCmdBuf()
	local app = self.app
	local cmd = self.cmdbuf
	self.cmdHistory:insert(cmd)
	self.cmdHistoryIndex = nil
	self.cmdbuf = ''
	self:write'\n'
	self.needsPrompt = true

	-- TODO merge this with App:runCmd?
	cmd = cmd:gsub('^=', 'return ')
	app:runCmd(cmd)
end

-- should cursor be a 'app' property or an 'editor' property?
-- should the low-level os be 'editor' or its own thing?
function Console:offsetCursor(dx, dy)
	local app = self.app
	local fb = self.fb
	self.cursorPos.x = self.cursorPos.x + dx
	self.cursorPos.y = self.cursorPos.y + dy

	while self.cursorPos.x < 0 do
		self.cursorPos.x = self.cursorPos.x + frameBufferSize.x
		self.cursorPos.y = self.cursorPos.y - spriteSize.y
	end
	while self.cursorPos.x >= frameBufferSize.x do
		self.cursorPos.x = self.cursorPos.x - frameBufferSize.x
		self.cursorPos.y = self.cursorPos.y + spriteSize.y
	end

	while self.cursorPos.y < 0 do
		self.cursorPos.y = self.cursorPos.y + frameBufferSize.y
	end
	while self.cursorPos.y >= frameBufferSize.y do
		self.cursorPos.y = self.cursorPos.y - frameBufferSize.y
	end
end

function Console:addChar(ch)
	local app = self.app
	app:drawText(
		string.char(ch),
		self.cursorPos.x,
		self.cursorPos.y,
		self.fgColor,
		self.bgColor
	)
	self:offsetCursor(fontWidth, 0)
end

function Console:addCharToScreen(ch)
	local app = self.app
	if ch == 8 then
		self:addChar((' '):byte())	-- in case the cursor is there
		self:offsetCursor(-2*fontWidth, 0)
		self:addChar((' '):byte())	-- clear the prev char as well
		self:offsetCursor(-fontWidth, 0)
	elseif ch == 10 or ch == 13 then
		self:addChar((' '):byte())	-- just in case the cursor is drawing white on the next char ...
		self.cursorPos.x = 0
		self.cursorPos.y = self.cursorPos.y + spriteSize.y
	else
		self:addChar(ch)
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
	-- double it to the app terminal
	print(...)

	for i=1,select('#', ...) do
		if i > 1 then self:write'\t' end
		self:write(tostring(select(i, ...)))
	end
	self:write'\n'
end

-- because everyone else is doing it
function Console:coolPrint(...)
	self.fgColor = 0xf9
	--self.bgColor = 0xf1
	local ofs = 9
	local function inc(d)
		self.fgColor = bit.bor((self.fgColor-ofs+d)%4+ofs,0xf0)
		--self.bgColor = bit.bor((self.bgColor-ofs+d)%3+ofs,0xf0)
	end
	inc(bit.rshift(self.cursorPos.x,3)+bit.rshift(self.cursorPos.y,3))
	local function addChar(ch)
		self:addCharToScreen(ch)
		inc(1)
	end
	for i=1,select('#', ...) do
		if i > 1 then
			addChar(('\t'):byte())
		end
		local s = tostring(select(i, ...))
		for j=1,#s do
			addChar(s:byte(j,j))
		end
	end
	addChar(('\n'):byte())
	self.fgColor = 0xfc
	self.bgColor = 0xf0
end

function Console:selectHistory(dx)
--[[ history buf works fine except that the conosle is recreated every time esc is pushed ...
print('selecting history', self.cmdHistoryIndex)
print'history buf:'
print(require 'ext.tolua'(self.cmdHistory))
--]]	
	local n = #self.cmdHistory
	self.cmdHistoryIndex = (((self.cmdHistoryIndex or n+1) + dx - 1) % n) + 1
	self.cmdbuf = self.cmdHistory[self.cmdHistoryIndex] or ''
	self.cursorPos.x = 0

	self:writePrompt()
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

function Console:update()
	local app = self.app

	-- TODO start to bypass the internal console prompt

	if self.needsPrompt then
		self:writePrompt()
		self.needsPrompt = false
	end

	--[[ TODO draw
	self.cursorPos:set(0,0)
	app:write'CSMAB code editor'
	--]]

	if getTime() % 1 < .5 then
		app:drawSolidRect(self.cursorPos.x, self.cursorPos.y, fontWidth, spriteSize.y, 0xff)
	else
		-- else TODO draw the character in the buffer at this location
		app:drawSolidRect(self.cursorPos.x, self.cursorPos.y, fontWidth, spriteSize.y, 0xf0)
	end

	local shift = app:key'lshift' or app:key'rshift'
	for keycode=0,#keyCodeNames-1 do
		if app:keyp(keycode,30,5) then
			local ch = getAsciiForKeyCode(keycode, shift)
			if ch then
				self:addCharToCmd(ch)
			elseif keycode == keyCodeForName['return'] then
				self:runCmdBuf()
			elseif keycode == keyCodeForName.up then
				self:selectHistory(-1)
			elseif keycode == keyCodeForName.down then
				self:selectHistory(1)
			-- TODO left right to move the cursor
			end
		end
	end
end

function Console:writePrompt()
	--self:resetThread() -- nope
	self:write(self.app.fs.cwd:path()..self.prompt)
end

function Console:gainFocus()
	-- print the prompt
	self.needsPrompt = true
end

return Console
