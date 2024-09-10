--[[
This will be the code editor
--]]
local sdl = require 'sdl'
local table = require 'ext.table'
local math = require 'ext.math'
local getTime = require 'ext.timer'.getTime

local App = require 'numo9.app'
local paletteSize = App.paletteSize
local frameBufferSize = App.frameBufferSize
local spriteSheetSize = App.spriteSheetSize
local spriteSize = App.spriteSize
local spritesPerSheet = App.spritesPerSheet
local spritesPerFrameBuffer = App.spritesPerFrameBuffer


local EditCode = require 'numo9.editor':subclass()

function EditCode:init(args)
	EditCode.super.init(self, args)

	-- text cursor loc
	self.cursorLoc = 1
	self.editLineOffset = 0
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

	EditCode.super.update(self)

	app:drawSolidRect(
		spriteSize.x,
		spriteSize.y,
		frameBufferSize.x - spriteSize.x,
		frameBufferSize.y - 2 * spriteSize.y,
		8
	)

	for y=1,spritesPerFrameBuffer.y-2 do
		if y >= #self.newlines then break end
		local i = self.newlines[y + self.editLineOffset] + 1
		local j = self.newlines[y + self.editLineOffset + 1]
		app:drawTextFgBg(
			spriteSize.x,
			y * spriteSize.y,
			self.text:sub(i, j-1),
			12,
			-1
		)
	end

	if self.cursorRow < self.editLineOffset+1 then
		self.editLineOffset = math.max(0, self.cursorRow-1)
	elseif self.cursorRow - (spritesPerFrameBuffer.y-2) > self.editLineOffset then
		self.editLineOffset = math.max(0, self.cursorRow - (spritesPerFrameBuffer.y-2))
	end

	if getTime() % 1 < .5 then
		app:drawSolidRect(
			self.cursorCol * spriteSize.x,
			(self.cursorRow - self.editLineOffset) * spriteSize.y,
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
	
	-- handle input

	local shift = app:key'lshift' or app:key'rshift'
	for keycode=0,#app.keyCodeNames-1 do
		if app:keyp(keycode) then
			local ch = app:getAsciiForKeyCode(keycode, shift)
			if ch then
				self:addCharToText(ch)
			elseif keycode == app.keyCodeForName['return'] then
				self:addCharToText(('\n'):byte())
			elseif keycode == app.keyCodeForName.tab then
				-- TODO add tab and do indent up there,
				-- until then ...
				self:addCharToText((' '):byte())
			elseif keycode == app.keyCodeForName.up
			or keycode == app.keyCodeForName.down
			then
				local dy = keycode == app.keyCodeForName.up and -1 or 1
				self.cursorRow = math.clamp(self.cursorRow + dy, 1, #self.newlines-2)

				local currentLineCols = self:countRowCols(self.cursorRow)
				self.cursorCol = math.clamp(self.cursorCol, 1, currentLineCols)

				self.cursorLoc = self.newlines[self.cursorRow] + self.cursorCol

				self:refreshCursorColRowForLoc()	-- just in case?
			elseif keycode == app.keyCodeForName.left
			or keycode == app.keyCodeForName.right
			then
				local dx = keycode == app.keyCodeForName.left and -1 or 1
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
