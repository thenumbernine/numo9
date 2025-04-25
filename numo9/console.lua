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

local numo9_keys = require 'numo9.keys'
local keyCodeNames = numo9_keys.keyCodeNames
local keyCodeForName = numo9_keys.keyCodeForName
local getAsciiForKeyCode = numo9_keys.getAsciiForKeyCode

local numo9_rom = require 'numo9.rom'
local frameBufferSize = numo9_rom.frameBufferSize
local spriteSize = numo9_rom.spriteSize
local menuFontWidth = numo9_rom.menuFontWidth


local Console = class()

function Console:init(args)
	self.app = assert(args.app)

	self:reset()

	local app = self.app
	self.cmdbuf = ''
	self.prompt = '> '

	self.lines = table()

	self.cmdHistory = table()
	self.cmdHistoryIndex = nil

	-- TODO 'getFocus' or TODO always reload?
	-- clear the screen every time, or save the screen every time?
	app:clearScreen(0xf0)

	self:coolPrint('NuMo-9 ver. '..self.app.version)
	self:coolPrint'https://github.com/thenumbernine/numo9 (c) 2025'
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

-- TODO maybe, merge this with App:runCmd?
function Console:runCmdBuf()
	local app = self.app
	local cmd = self.cmdbuf
	self.cmdHistory:insert(cmd)
	self.cmdHistoryIndex = nil
	self.cmdbuf = ''
	self:print(app.fs.cwd:path()..self.prompt..cmd)
	self.needsPrompt = true
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
	app:drawMenuText(
		string.char(ch),
		self.cursorPos.x,
		self.cursorPos.y,
		self.fgColor,
		self.bgColor
	)
	self:offsetCursor(menuFontWidth, 0)
end

function Console:addCharToScreen(ch)
	local app = self.app
	if ch == 8 then
		self:addChar((' '):byte())	-- in case the cursor is there
		self:offsetCursor(-2*menuFontWidth, 0)
		self:addChar((' '):byte())	-- clear the prev char as well
		self:offsetCursor(-menuFontWidth, 0)
	elseif ch == 10 or ch == 13 then
		self:addChar((' '):byte())	-- just in case the cursor is drawing white on the next char ...
		self.cursorPos.x = 0
		self.cursorPos.y = self.cursorPos.y + spriteSize.y
	else
		self:addChar(ch)
	end
end

function Console:print(...)
print(...)
	local s = ''
	for i=1,select('#', ...) do
		if i > 1 then s=s..'\t' end
		s=s..tostring(select(i, ...))
	end
	-- TODO do we still want colored console text?
	-- I could save it per-line or per-letter
	-- or meh just not ...
	--[[ add line without truncating
	self.lines:insert(1, s)
	--]]
	-- [[ chop lines up
	local maxcol = math.floor(tonumber(frameBufferSize.x) / menuFontWidth)
	while #s > maxcol do
		self.lines:insert(1, s:sub(1,maxcol))
		s = s:sub(maxcol+1)
	end
	if #s > 0 then
		self.lines:insert(1, s)
	end
	--]]
end

-- because everyone else is doing it
-- TODO color in console is disabled.  either add it to the buffer and use this, or just get rid of this function.
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
	local n = #self.cmdHistory
	self.cmdHistoryIndex = (((self.cmdHistoryIndex or n+1) + dx - 1) % n) + 1
	self.cmdbuf = self.cmdHistory[self.cmdHistoryIndex] or ''
	self.cursorPos.x = 0
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

-- TODO just use the same functionality as the code editor ...
function Console:update()
	local app = self.app

	-- if a game is running, overlay the console on the top
	-- otherwise give it full screen
	local maxLines = app.runFocus and 5 or 30

	local shownLines = math.min(#self.lines, maxLines)
	app:setBlendMode(3)
	app:drawSolidRect(0, 0, frameBufferSize.x, shownLines * spriteSize.y, 0xf0)
	app:setBlendMode(0xff)

	self.cursorPos.x = 0
	self.cursorPos.y = 0
	local maxcol = math.floor(tonumber(frameBufferSize.x) / menuFontWidth)
	for i=shownLines,1,-1 do
		local l = self.lines[i]
		--[[ hmm TODO split up lines in display, or split them up when adding them?
		while #l > maxcol do
			app:drawMenuText(l:sub(1,maxcol), 0, self.cursorPos.y, self.fgColor, self.bgColor)
			l = l:sub(maxcol+1)
			self.cursorPos.y = self.cursorPos.y + 8
		end
		--]]
		app:drawMenuText(l, 0, self.cursorPos.y, self.fgColor, self.bgColor)
		self.cursorPos.y = self.cursorPos.y + 8
	end
	local s = app.fs.cwd:path()..self.prompt..self.cmdbuf
	app:drawMenuText(s, 0, self.cursorPos.y, self.fgColor, self.bgColor)
	self.cursorPos.x = #s * menuFontWidth

	if getTime() % 1 < .5 then
		app:drawSolidRect(self.cursorPos.x, self.cursorPos.y, menuFontWidth, spriteSize.y, self.fgColor)
	end

	local shift = app:key'lshift' or app:key'rshift'
	for keycode=0,#keyCodeNames-1 do
		if app:keyp(keycode,30,5) then
			local ch = getAsciiForKeyCode(keycode, shift)
			if ch == 10 or ch == 13 then
				self:runCmdBuf()
			elseif ch then
				self:addCharToCmd(ch)
			elseif keycode == keyCodeForName.up then
				self:selectHistory(-1)
			elseif keycode == keyCodeForName.down then
				self:selectHistory(1)
			-- TODO left right to move the cursor
			end
		end
	end
end

return Console
