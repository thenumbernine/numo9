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

local App = require 'numo9.app'
local paletteSize = App.paletteSize
local frameBufferSize = App.frameBufferSize
local spriteSheetSize = App.spriteSheetSize
local spriteSize = App.spriteSize
local spriteSheetSizeInTiles = App.spriteSheetSizeInTiles
local frameBufferSizeInTiles = App.frameBufferSizeInTiles


local Console = class()

function Console:init(args)
	self.app = assert(args.app)

	self:reset()
end

function Console:reset()
	local app = self.app
	self.cmdbuf = ''

	self.cmdHistory = table()
	self.cmdHistoryIndex = nil
	self.cursorPos = vec2i(0, 0)

	-- right now fgColor just adds
	-- meanwhile the font texture is indexed 0's and 15's
	-- so whatever you set fgColor to, that value is background and that value plus 15 is foreground
	self.fgColor = 13
	self.bgColor = 0

	-- TODO 'getFocus' or TODO always reload?
	-- clear the screen every time, or save the screen every time?
	app:clearScreen()
	self:print(app.title)

	for i=0,15 do
		self.fgColor = i	-- bg = i, fg = i + 15 at the moemnt thanks to the font.png storage ...
		self.bgColor = i+1
		self:print'hello world'
	end
	--self.fgColor = 14			-- 14 = bg, 15 = fg
	self.fgColor = 11			-- 11 = bg, 12 = fg
	self.bgColor = 0

	self.prompt = '> '
	self:write(app.fs.cwd:path()..self.prompt)
end

function Console:runCmdBuf()
	local app = self.app
	local cmd = self.cmdbuf
	self.cmdHistory:insert(cmd)
	self.cmdHistoryIndex = nil
	self.cmdbuf = ''
	self:write'\n'

	-- TODO ... runCmd return nil vs error ...
	cmd = cmd:gsub('^=', 'return ')

	local success, msg = pcall(function() return app:runCmd(cmd) end)
--[[ seems nice but has no direction 
--DEBUG:print('runCmdBuf', cmd, 'got', success, msg)	
	-- if fails try wrapping arg2..N with quotes ...
	-- TODO this or 'return ' first?
	-- this one si good for console ...
	if not success then
		local parts = string.split(cmd, '%s+')
		cmd = table{
			parts[1],
		}:append(
			parts:sub(2):mapi(function(s) return (tolua(s)) end)
		):concat' '
		success, msg = pcall(function() return app:runCmd(cmd) end)
--DEBUG:print('runCmdBuf', cmd, 'got', success, msg)	
	end
	-- if fail then try appending a '()'
	-- do this before prepending 'return ' so we don't return a function before we call it
	local cmdBeforePar = cmd
	if not success then
		cmd = cmd .. '()'
		success, msg = pcall(function() return app:runCmd(cmd) end)
--DEBUG:print('runCmdBuf', cmd, 'got', success, msg)
	end
	-- if fail then try prepending a 'return' ...
	if not success then
		cmd = 'return '..cmdBeforePar
		success, msg = pcall(function() return app:runCmd(cmd) end)
--DEBUG:print('runCmdBuf', cmd, 'got', success, msg)
	end
--]]
	if not success then
--DEBUG:print('runCmdBuf', cmd, 'got', success, msg)	
		self:print(tostring(msg))
	end
	self:write(app.fs.cwd:path()..self.prompt)
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
	self:offsetCursor(spriteSize.x, 0)
end

function Console:addCharToScreen(ch)
	local app = self.app
	if ch == 8 then
		self:addChar((' '):byte())	-- in case the cursor is there
		self:offsetCursor(-2*spriteSize.x, 0)
		self:addChar((' '):byte())	-- clear the prev char as well
		self:offsetCursor(-spriteSize.x, 0)
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

	self:write(self.app.fs.cwd:path()..self.prompt)
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
function Console:update()
	local app = self.app

	-- TODO start to bypass the internal console prompt

	--[[ TODO draw
	self.cursorPos:set(0,0)
	app:write'CSMAB code editor'
	--]]

	if getTime() % 1 < .5 then
		app:drawSolidRect(self.cursorPos.x, self.cursorPos.y, spriteSize.x, spriteSize.y, 15)
	else
		-- else TODO draw the character in the buffer at this location
		app:drawSolidRect(self.cursorPos.x, self.cursorPos.y, spriteSize.x, spriteSize.y, 0)
	end

	local shift = app:key'lshift' or app:key'rshift'
	for keycode=0,#keyCodeNames-1 do
		if app:keyp(keycode) then
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

return Console
