--[[
Here's where the stuff that handles the prompt and running commands goes
--]]
local class = require 'ext.class'
local table = require 'ext.table'
local string = require 'ext.string'
local tolua = require 'ext.tolua'
local getTime = require 'ext.timer'.getTime
local vec2i = require 'vec-ffi.vec2i'
local sdl = require 'sdl'

local numo9_keys = require 'numo9.keys'
local keyCodeNames = numo9_keys.keyCodeNames
local keyCodeForName = numo9_keys.keyCodeForName
local sdlSymToKeyCode = numo9_keys.sdlSymToKeyCode
local getAsciiForKeyCode = numo9_keys.getAsciiForKeyCode

local numo9_rom = require 'numo9.rom'
local spriteSize = numo9_rom.spriteSize
local menuFontWidth = numo9_rom.menuFontWidth


local Console = class()

function Console:init(args)
	self.app = assert(args.app)

	-- defaults, but stretch the width to match the aspect ratio
	-- and maybe a console font zoom size, or a menu font zoom size, idk
	self.width = 256
	self.height = 256

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

	self:resetThread()
end

-- reset console state ...
function Console:reset()

	self.cursorLoc = 0	-- where to draw the cursor
	self.fgColor = 0xfd
	self.bgColor = 0x10

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
	if cmd ~= '' then
		-- how about if the cmd is a previous cmd? also don't insert?
		--  or insert and remove all other instances so it is on top of the history?
		self.cmdHistory:insert(cmd)
	end
	self.cmdHistoryIndex = nil
	self.cmdbuf = ''
	self.cursorLoc = 0

	local cmdBufWithPrompt = app.fs.cwd:path()..self.prompt..cmd
	local maxcol = math.floor(self.width / menuFontWidth)
	local numCmdBufWithPromptRows = math.ceil(#cmdBufWithPrompt/maxcol)
	for row=1,numCmdBufWithPromptRows do
		local lineStr = cmdBufWithPrompt:sub(1+(row-1)*maxcol, row*maxcol)
		self:print(lineStr)
	end

	self.needsPrompt = true
	app:runCmd(cmd)
end

function Console:print(...)
print(...)
	local s = ''
	for i=1,select('#', ...) do
		if i > 1 then s=s..'\t' end
		s=s..tostring(select(i, ...))
	end
	-- chop up newlines
	for _,l in ipairs(string.split(s, '[\r\n]')) do
		-- TODO do we still want colored console text?
		-- I could save it per-line or per-letter
		-- or meh just not ...
		-- [[ add line without truncating
		self.lines:insert(1, l)
		--]]
		--[[ chop lines up
		local maxcol = math.floor(self.width / menuFontWidth)
		while #l > maxcol do
			self.lines:insert(1, l:sub(1,maxcol))
			l = l:sub(maxcol+1)
		end
		if #l > 0 then
			self.lines:insert(1, l)
		end
		--]]
	end
end

function Console:selectHistory(dx)
	local n = #self.cmdHistory
	self.cmdHistoryIndex = (((self.cmdHistoryIndex or n+1) + dx - 1) % n) + 1
	self.cmdbuf = self.cmdHistory[self.cmdHistoryIndex] or ''
	self.cursorLoc = #self.cmdbuf
end

function Console:addCharToCmd(ch)
	if ch == 8 then
		if self.cursorLoc > 0
		and #self.cmdbuf > 0
		then
			self.cursorLoc = self.cursorLoc - 1
			self.cmdbuf = self.cmdbuf:sub(1,self.cursorLoc)..self.cmdbuf:sub(self.cursorLoc+2)
		end
	else
		self.cmdbuf = self.cmdbuf:sub(1,self.cursorLoc) .. string.char(ch) .. self.cmdbuf:sub(self.cursorLoc+1)
		self.cursorLoc = self.cursorLoc + 1
	end
end

-- TODO just use the same functionality as the code editor ...
function Console:update()
	local app = self.app


	local ar = tonumber(app.ram.screenWidth) / tonumber(app.ram.screenHeight)
	self.height = 256
	self.width = self.height * ar


	-- [[ same as matMenuReset but without the translate
	-- aligns things to the left
	-- also in numo9/edit/code.lua's :update
	local app = self.app
	local ar = app.ram.screenWidth / app.ram.screenHeight
	app:matident(0)
	app:matident(1)
	app:matident(2)
	app:matortho(
		0, app.ram.screenWidth,
		app.ram.screenHeight, 0)
	app:matscale(app.width / app.menuSizeInSprites.x, app.height / app.menuSizeInSprites.y)
	--]]


	-- if a game is running, overlay the console on the top
	-- otherwise give it full screen
	--local maxLines = app.runFocus and 10 or 30
	-- or just always show it over everything?
	-- ... or just don't at all any of this and do like old apple 2's?
	local maxLines = 30

	local pathAndPrompt = app.fs.cwd:path()..self.prompt
	local cmdBufWithPrompt = pathAndPrompt..self.cmdbuf
	local maxcol = math.floor(self.width / menuFontWidth)
	local numCmdBufWithPromptRows = math.ceil(#cmdBufWithPrompt/maxcol)

	local shownLines = math.min(#self.lines, maxLines - (numCmdBufWithPromptRows-1))
	app:setBlendMode(3)
	app:drawSolidRect(0, 0, self.width, (shownLines + 1) * spriteSize.y, 0xf0)
	app:setBlendMode(0xff)

	local cursorPosX = 0
	local cursorPosY = 0
	for i=shownLines,1,-1 do
		local l = self.lines[i]
		--[[ hmm TODO split up lines in display, or split them up when adding them?
		while #l > maxcol do
			app:drawMenuText(l:sub(1,maxcol), 0, cursorPosY, self.fgColor, self.bgColor)
			l = l:sub(maxcol+1)
			cursorPosY = cursorPosY + 8
		end
		--]]
		local w = app:drawMenuText(l, 0, cursorPosY, self.fgColor, self.bgColor)
		app:drawSolidRect(w, cursorPosY, app.ram.screenWidth, 8, 0x10)	-- which black is solid?
		cursorPosY = cursorPosY + 8
	end
	local promptStartY = cursorPosY
	for row=1,numCmdBufWithPromptRows do
		local lineStr = cmdBufWithPrompt:sub(1+(row-1)*maxcol, row*maxcol)
		app:drawMenuText(lineStr, 0, cursorPosY, self.fgColor, self.bgColor)
		cursorPosY = cursorPosY + 8
	end

	local cursorDrawLoc = self.cursorLoc + #pathAndPrompt
	if getTime() % 1 < .5 then
		app:drawSolidRect(
			(cursorDrawLoc % maxcol) * menuFontWidth,
			promptStartY + math.floor(cursorDrawLoc / maxcol) * 8,
			8, 8, 0xc
		)
	end
	--cursorPosX = #cmdBufWithPrompt * menuFontWidth

	app:matMenuReset()
end

function Console:event(e)
	local app = self.app
	-- hmm no key repeat this way ...
	if e[0].type == sdl.SDL_EVENT_KEY_DOWN then
		local keycode = sdlSymToKeyCode[e[0].key.key]
		if keycode then
			local shift = app:key'lshift' or app:key'rshift'
			local ch = getAsciiForKeyCode(keycode, shift)

			if ch == 10 or ch == 13 then
				-- now that this is outside :update, it needs to be xpcall'd
				local s
				xpcall(function()
					self:runCmdBuf()
				end, function(err)
					s = err..'\n'..debug.traceback()
					--print(s)	-- don't print here if you're going to print in self:print as well (which is only for debugging.  so is this so meh.)
				end)
				if s then
					self:print(s)
				end
			elseif ch then
				self:addCharToCmd(ch)
			elseif keycode == keyCodeForName.up then
				self:selectHistory(-1)
			elseif keycode == keyCodeForName.down then
				self:selectHistory(1)
			-- TODO left right to move the cursor
			elseif keycode == keyCodeForName.left then
				self.cursorLoc = math.max(self.cursorLoc - 1, 0)
			elseif keycode == keyCodeForName.right then
				self.cursorLoc = math.min(self.cursorLoc + 1, #self.cmdbuf)
			end
		end
	end
end

return Console
