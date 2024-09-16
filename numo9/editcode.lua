--[[
This will be the code editor
--]]
local sdl = require 'sdl'
local table = require 'ext.table'
local math = require 'ext.math'
local getTime = require 'ext.timer'.getTime

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
	--self.selectStart = 0
	--self.selectEnd = 0
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

	-- clear the background

	local textareaY = spriteSize.y
	app:drawSolidRect(
		0,
		textareaY,
		frameBufferSize.x,
		frameBufferSize.y - 2 * spriteSize.y,
		self:color(8)
	)

	-- add text

	local textareaX = 0	-- offset into textarea where we start drawing text
	if self.useLineNumbers then
		for y=1,frameBufferSizeInTiles.y-2 do
			if y + self.editLineOffset < 1
			or y + self.editLineOffset >= #self.newlines-1
			then break end

			local i = self.newlines[y + self.editLineOffset] + 1
			local j = self.newlines[y + self.editLineOffset + 1]
			textareaX = math.max(textareaX, self:drawText(
				tostring(y + self.editLineOffset),
				0,
				y * spriteSize.y,
				self:color(12),
				-1
			))
		end
		textareaX = textareaX + 2
	end
	for y=1,frameBufferSizeInTiles.y-2 do
		if y + self.editLineOffset < 1
		or y + self.editLineOffset >= #self.newlines-1
		then break end

		local i = self.newlines[y + self.editLineOffset] + 1
		local j = self.newlines[y + self.editLineOffset + 1]
		self:drawText(
			self.text:sub(i, j-1),
			textareaX,
			y * spriteSize.y,
			self:color(12),
			-1
		)
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
	self:drawText(
		footer,
		0,
		frameBufferSize.y - spriteSize.y,
		self:color(12),
		self:color(1)
	)

	-- handle mouse

	local shift = app:key'lshift' or app:key'rshift'

	if leftButtonDown
	then
		-- find cursor
		local y = math.floor((mouseY-textareaY)/spriteSize.y)+1+self.editLineOffset
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

	if leftButtonPress
	--or shift	-- TODO
	then
		self.selectStart = self.cursorLoc
	end


	-- handle keyboard

	for keycode=0,#keyCodeNames-1 do
		if app:keyp(keycode,30,5) then
			local ch = getAsciiForKeyCode(keycode, shift)
			if ch then
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

return EditCode
