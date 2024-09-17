--[[
This will be the code editor
--]]
local ffi = require 'ffi'
local sdl = require 'sdl'
local table = require 'ext.table'
local math = require 'ext.math'
local getTime = require 'ext.timer'.getTime
local clip = require 'clip'	-- clipboard support

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
local fontWidth = App.fontWidth

local EditCode = require 'numo9.editor':subclass()

function EditCode:init(args)
	EditCode.super.init(self, args)

	-- text cursor loc
	self.cursorLoc = 1
	--self.selectDownLoc = 0
	--self.selectCurLoc = 0
	self.editLineOffset = 0
	self:setText''
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
	-- refresh newlines
	self.newlines = table()
	self.newlines:insert(0)
	for i=1,#self.text do
		if self.text:byte(i) == newlineByte then
			self.newlines:insert(i)
		end
	end
	self.newlines:insert(#self.text+1)
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

	-- TODO really merge mouse and virtual-joystick with the keyboard and key/p/r api
	local leftButtonLastDown = bit.band(app.lastMouseButtons, 1) == 1
	local leftButtonDown = bit.band(app.mouseButtons, 1) == 1
	local leftButtonPress = leftButtonDown and not leftButtonLastDown
	local leftButtonRelease = not leftButtonDown and leftButtonLastDown
	local mouseX, mouseY = app.mousePos:unpack()

	EditCode.super.update(self)

	-- ui controls

	if self:guiButton(120, 0, 'N', self.useLineNumbers) then
		self.useLineNumbers = not self.useLineNumbers
	end

	-- draw text
	local textareaX = 0	-- offset into textarea where we start drawing text

	local textareaY = spriteSize.y

	if self.useLineNumbers then
		-- clear the background incl line numbers
		app:drawSolidRect(
			0,
			textareaY,
			frameBufferSize.x,
			frameBufferSize.y - 2 * spriteSize.y,
			0xf9
		)
	
		-- determine line number width while we draw line numbers
		for y=1,frameBufferSizeInTiles.y-2 do
			if y + self.editLineOffset < 1
			or y + self.editLineOffset >= #self.newlines-1
			then break end

			local i = self.newlines[y + self.editLineOffset] + 1
			local j = self.newlines[y + self.editLineOffset + 1]
			textareaX = math.max(textareaX, app:drawText(
				tostring(y + self.editLineOffset),
				0,
				y * spriteSize.y,
				0xfc,
				-1
			))
		end
		textareaX = textareaX + 2
	end

	-- 2nd text background apart from the line numbers
	app:drawSolidRect(
		textareaX,
		textareaY,
		frameBufferSize.x,
		frameBufferSize.y - 2 * spriteSize.y,
		0xf8
	)
	
	for y=1,frameBufferSizeInTiles.y-2 do
		if y + self.editLineOffset < 1
		or y + self.editLineOffset >= #self.newlines-1
		then break end

		local i = self.newlines[y + self.editLineOffset] + 1
		local j = self.newlines[y + self.editLineOffset + 1]

		local lineX = textareaX
		local lineY = y * spriteSize.y
		local selLineStart = math.clamp(self.selectStart and self.selectStart or (#self.text+1), i, j)
		local selLineEnd = math.clamp(self.selectEnd and self.selectEnd or (#self.text+1), i, j)

		if selLineStart-1 >= i then
			lineX = lineX + app:drawText(
				self.text:sub(i, selLineStart-1),
				lineX,
				lineY,
				0xfc,
				-1
			)
		end
		if selLineEnd-1 >= selLineStart then
			lineX = lineX + app:drawText(
				self.text:sub(selLineStart,selLineEnd-1),
				lineX,
				lineY,
				0,
				0xfc
			)
		end
		if j-1 >= selLineEnd then
			lineX = lineX + app:drawText(
				self.text:sub(selLineEnd, j-1),
				lineX,
				lineY,
				0xfc,
				-1
			)
		end
	end

	if self.cursorRow < self.editLineOffset+1 then
		self.editLineOffset = math.max(0, self.cursorRow-1)
	elseif self.cursorRow - (frameBufferSizeInTiles.y-2) > self.editLineOffset then
		self.editLineOffset = math.max(0, self.cursorRow - (frameBufferSizeInTiles.y-2))
	end

	-- cursor

	if getTime() % 1 < .5 then
		app:drawSolidRect(
			textareaX + (self.cursorCol-1) * fontWidth,
			(self.cursorRow - self.editLineOffset) * spriteSize.y,
			fontWidth,
			spriteSize.y,
			self:color(12))
	end

	-- footer

	local footer = 'line '..self.cursorRow..'/'..(#self.newlines-2)..' col '..self.cursorCol
	footer = footer .. (' '):rep(frameBufferSizeInTiles.x - #footer)
	app:drawText(
		footer,
		0,
		frameBufferSize.y - spriteSize.y,
		0xfc,
		0xf1
	)

	-- handle mouse

	-- find cursor - do this before we start selection
	if leftButtonDown
	then
		local y = math.floor((mouseY-textareaY)/spriteSize.y)+1
		if y + self.editLineOffset >= 1
		and y + self.editLineOffset < #self.newlines-1
		then
			local i = self.newlines[y + self.editLineOffset] + 1
			local j = self.newlines[y + self.editLineOffset + 1]
			local x = math.floor((mouseX-textareaX)/fontWidth) + i
			x = math.clamp(x, i,j)	-- TODO add scrolling left/right, and consider the offset here
			self.cursorLoc = x
			self:refreshCursorColRowForLoc()	-- just in case?
		end
	end

	if leftButtonPress then
		self.selctDownLoc = nil
		self.selectCurLoc = nil
		self.selectStart = nil
		self.selectEnd = nil

		self.selectDownLoc = self.cursorLoc
	end
	if leftButtonDown then
		if self.selectDownLoc then
			self.selectCurLoc = self.cursorLoc
			self.selectStart = math.min(self.selectDownLoc, self.selectCurLoc)
			self.selectEnd = math.max(self.selectDownLoc, self.selectCurLoc)
		end
	end

	-- handle keyboard

	local shift = app:key'lshift' or app:key'rshift'
	local uikey
	if ffi.os == 'OSX' then
		uikey = app:key'lgui' or app:key'rgui'
	else
		uikey = app:key'lctrl' or app:key'rctrl'
	end
	for keycode=0,#keyCodeNames-1 do
		if app:keyp(keycode,30,5) then
			local ch = getAsciiForKeyCode(keycode, shift)

			if uikey and keycode == keyCodeForName.x then	-- cut
				if self.selectStart then
					local sel = self.text:sub(self.selectStart, self.selectEnd-1)
					clip.text(sel)
					self:deleteSelection()
					self:refreshNewlines()
					self:refreshCursorColRowForLoc()
				end
			elseif uikey and keycode == keyCodeForName.c then -- copy
				if self.selectStart then
					local sel = self.text:sub(self.selectStart, self.selectEnd-1)
					clip.text(sel)
				end
			elseif uikey and keycode == keyCodeForName.v then -- paste
				self:deleteSelection()
				local paste = clip.text()
				if paste then
					self.text = self.text:sub(1, self.cursorLoc-1)..paste..self.text:sub(self.cursorLoc)
				end
				self:refreshNewlines()
				self:refreshCursorColRowForLoc()
			elseif ch then
				self:addCharToText(ch)
			elseif keycode == keyCodeForName['return'] then
				self:addCharToText(('\n'):byte())
			elseif keycode == keyCodeForName.tab then
				-- TODO add tab and do indent up there,
				-- until then ...
				self:addCharToText((' '):byte())
			elseif keycode == keyCodeForName.up
			or keycode == keyCodeForName.down
			then
				local dy = keycode == keyCodeForName.up and -1 or 1
				self.cursorRow = math.clamp(self.cursorRow + dy, 1, #self.newlines-2)

				local currentLineCols = self:countRowCols(self.cursorRow)
				self.cursorCol = math.clamp(self.cursorCol, 1, currentLineCols)

				self.cursorLoc = self.newlines[self.cursorRow] + self.cursorCol

				self:refreshCursorColRowForLoc()	-- just in case?
			elseif keycode == keyCodeForName.left
			or keycode == keyCodeForName.right
			then
				local dx = keycode == keyCodeForName.left and -1 or 1
				self.cursorLoc = math.clamp(self.cursorLoc + dx, 1, #self.text+1)
				self:refreshCursorColRowForLoc()
			end
		end
	end
end

-- be sure to call self:refreshNewlines() and self:refreshCursorColRowForLoc() afterwards...
function EditCode:deleteSelection()
	if not self.selectStart then return end

	self.text = self.text:sub(1, self.selectStart-1)..self.text:sub(self.selectEnd)
	if self.cursorLoc >= self.selectStart and self.cursorLoc < self.selectEnd then
		self.cursorLoc = self.selectStart
	elseif self.cursorLoc >= self.selectEnd then
		self.cursorLoc = self.cursorLoc - (self.selectEnd - self.selectStart)
	end
	self.selectStart = nil
	self.selectEnd = nil
	self.selectDownLoc = nil
	self.selectCurLoc = nil
end

function EditCode:addCharToText(ch)
	-- if we have selection then delete it
	if self.selectStart then
		self:deleteSelection()

		-- and if we're pressing backspace on selection then quit while you're ahead
		if ch == 8 then ch = nil end
	end

	if ch == slashRByte then
		ch = newlineByte	-- store \n's instead of \r's
	end
	if ch == 8 then
		self.text = self.text:sub(1, self.cursorLoc - 2) .. self.text:sub(self.cursorLoc)
		self.cursorLoc = math.max(1, self.cursorLoc - 1)
	elseif ch then
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

return EditCode
