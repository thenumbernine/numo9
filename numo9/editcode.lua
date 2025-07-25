--[[
This will be the code editor
--]]
local ffi = require 'ffi'
local table = require 'ext.table'
local math = require 'ext.math'
local getTime = require 'ext.timer'.getTime
local clip = require 'numo9.clipboard'

local numo9_keys = require 'numo9.keys'
local keyCodeNames = numo9_keys.keyCodeNames
local keyCodeForName = numo9_keys.keyCodeForName
local getAsciiForKeyCode = numo9_keys.getAsciiForKeyCode

local numo9_rom = require 'numo9.rom'
local frameBufferSize = numo9_rom.frameBufferSize
local spriteSize = numo9_rom.spriteSize
local frameBufferSizeInTiles = numo9_rom.frameBufferSizeInTiles
local menuFontWidth = numo9_rom.menuFontWidth

local EditCode = require 'numo9.ui':subclass()

local colors = {
	fg = 0xfc,
	bg = 0,
	fgSel = 0xff,
	bgSel = 0xfc,
	fgFooter = 0xfc,
	bgFooter = 0xf1,
}


function EditCode:init(args)
	EditCode.super.init(self, args)

	-- text cursor loc
	self.cursorLoc = 0	-- 0-based index of our cursor
	--self.selectDownLoc = 0
	--self.selectCurLoc = 0
	self.scrollX = 0
	self.scrollY = 0
	self.useLineNumbers = true
	self:setText''
	self.undoBuffer = table()
	self.undoIndex = #self.undoBuffer
end

function EditCode:setText(text)
	self.text = text
	self.cursorLoc = math.clamp(self.cursorLoc, 0, #self.text)
	self:refreshNewlines()
	self:refreshCursorColRowForLoc()
end

local slashRByte = ('\r'):byte()
local newlineByte = ('\n'):byte()
local tabByte = ('\t'):byte()
local backspaceByte = 8
function EditCode:refreshNewlines()
	-- refresh newlines
	self.newlines = table()
	self.newlines:insert(0)	-- newline is [inclusive, exclusive) the range of 0-based indexes of the text per line
	for i=1,#self.text do
		if self.text:byte(i) == newlineByte then
			self.newlines:insert(i)
		end
	end
	self.newlines:insert(#self.text+1)	-- len+1 so that len is a valid range on the last line
end

function EditCode:refreshCursorColRowForLoc()
	self.cursorRow = nil
	for i=1,#self.newlines-1 do
		local start = self.newlines[i]
		local finish = self.newlines[i+1]
		if start <= self.cursorLoc and self.cursorLoc < finish then
			self.cursorRow = i
			break
		end
	end
	self.cursorRow = self.cursorRow or 1								-- 1-based, also norm for UIs, also convenient with Lua 1-based indexing ...
	self.cursorCol = self.cursorLoc+1 - self.newlines[self.cursorRow]	-- 1-based  like all UI show it as
end

function EditCode:update()
	local app = self.app

	local leftButtonDown = app:key'mouse_left'
	local leftButtonPress = app:keyp'mouse_left'
	local leftButtonRelease = app:keyr'mouse_left'
	local mouseX, mouseY = app.ram.mousePos:unpack()

	EditCode.super.update(self)

	-- ui controls

	if self:guiButton('N', 120, 0, self.useLineNumbers) then
		self.useLineNumbers = not self.useLineNumbers
	end

	-- draw text
	local textareaX = 0	-- offset into textarea where we start drawing text
	local textareaY = spriteSize.y
	local textareaWidth = frameBufferSize.x
	local textareaHeight = frameBufferSize.y - 2*spriteSize.y

	if self.useLineNumbers then
		-- clear the background incl line numbers
		app:drawSolidRect(
			textareaX,
			textareaY,
			textareaWidth,
			textareaHeight,
			0xf9,
			nil,
			nil,
			app.paletteMenuTex
		)

		-- determine line number width while we draw line numbers
		for y=1,frameBufferSizeInTiles.y-2 do
			if y + self.scrollY < 1
			or y + self.scrollY >= #self.newlines
			then break end

			local i = self.newlines[y + self.scrollY] + 1
			local j = self.newlines[y + self.scrollY + 1]
			textareaX = math.max(textareaX, app:drawMenuText(
				tostring(y + self.scrollY),
				0,
				y * spriteSize.y,
				colors.fg,
				colors.bg
			))
		end
		textareaX = textareaX + 2
	end
	textareaWidth = textareaWidth - textareaX

	-- 2nd text background apart from the line numbers
	app:drawSolidRect(
		textareaX,
		textareaY,
		textareaWidth,
		textareaHeight,
		0xf8,
		nil,
		nil,
		app.paletteMenuTex
	)

	for y=1,frameBufferSizeInTiles.y-2 do
		if y + self.scrollY < 1
		or y + self.scrollY >= #self.newlines
		then break end

		local i = self.newlines[y + self.scrollY] + 1
		local j = self.newlines[y + self.scrollY + 1]

		-- TODO use scissors and TODO use the mv transform
		local lineX = textareaX - self.scrollX * menuFontWidth
		local lineY = y * spriteSize.y
		local selLineStart = math.clamp(self.selectStart and self.selectStart or (#self.text+1), i, j)
		local selLineEnd = math.clamp(self.selectEnd and self.selectEnd or (#self.text+1), i, j)

		if selLineStart-1 >= i then
			lineX = lineX + app:drawMenuText(
				self.text:sub(i, selLineStart-1),
				lineX,
				lineY,
				colors.fg,
				colors.bg
			)
		end
		if selLineEnd-1 >= selLineStart then
			lineX = lineX + app:drawMenuText(
				self.text:sub(selLineStart,selLineEnd-1),
				lineX,
				lineY,
				colors.fgSel,
				colors.bgSel
			)
		end
		if j-1 >= selLineEnd then
			lineX = lineX + app:drawMenuText(
				self.text:sub(selLineEnd, j-1),
				lineX,
				lineY,
				colors.fg,
				colors.bg
			)
		end
	end

	-- if you want variable font width then TODO store cursor x and y pixel as well as row and col
	if self.cursorRow < self.scrollY+1 then
		self.scrollY = math.max(0, self.cursorRow-1)
	elseif self.cursorRow - (frameBufferSizeInTiles.y-2) > self.scrollY then
		self.scrollY = math.max(0, self.cursorRow - (frameBufferSizeInTiles.y-2))
	end
	local textAreaWidthInLetters = math.ceil(textareaWidth / menuFontWidth)
	if self.cursorCol < self.scrollX+1 then
		self.scrollX = math.max(0, self.cursorCol-1)
	elseif self.cursorCol - textAreaWidthInLetters > self.scrollX then
		self.scrollX = math.max(0, self.cursorCol - textAreaWidthInLetters)
	end

	-- cursor

	if getTime() % 1 < .5 then
		app:drawSolidRect(
			textareaX + (self.cursorCol-1 - self.scrollX) * menuFontWidth,
			(self.cursorRow - self.scrollY) * spriteSize.y,
			menuFontWidth,
			spriteSize.y,
			self:color(12),
			nil,
			nil,
			app.paletteMenuTex
		)
	end

	-- footer

	local footer = 'line '..self.cursorRow..'/'..(#self.newlines-2)..' col '..self.cursorCol
	app:drawMenuText(footer, 0, frameBufferSize.y - spriteSize.y, colors.fgFooter, colors.bgFooter)

	footer = self.cursorLoc..'/'..#self.text
	self.footerWidth = app:drawMenuText(footer, frameBufferSize.x - (self.footerWidth or 0), frameBufferSize.y - spriteSize.y, colors.fgFooter, colors.bgFooter)

	-- handle mouse

	-- find cursor - do this before we start selection
	if leftButtonDown
	then
		local y = math.floor((mouseY-textareaY)/spriteSize.y)+1
		if y >= 1	-- no clicks on top row
		and y + self.scrollY >= 1
		and y + self.scrollY < #self.newlines-1
		then
			local i = self.newlines[y + self.scrollY] + 1
			local j = self.newlines[y + self.scrollY + 1]
			local x = math.floor((mouseX - textareaX - self.scrollX) / menuFontWidth) + i
			x = math.clamp(x, i,j)	-- TODO add scrolling left/right, and consider the offset here
			self.cursorLoc = x-1
			self:refreshCursorColRowForLoc()	-- just in case?
		end
	end

	if leftButtonPress then
		local y = math.floor((mouseY-textareaY)/spriteSize.y)+1
		if y >= 1	-- no clicks on top row
		and y + self.scrollY >= 1
		and y + self.scrollY < #self.newlines-1
		then
			self:startSelect()
		end
	end
	if leftButtonDown then
		if self.selectDownLoc then
			self:growSelect()
		end
	end

	-- handle keyboard

	-- TODO shift+arrows to select text
	local shift = app:key'lshift' or app:key'rshift'
	local uikey
	if ffi.os == 'OSX' then
		uikey = app:key'lgui' or app:key'rgui'
	else
		uikey = app:key'lctrl' or app:key'rctrl'
	end

	if uikey then
		-- trap all uikey+keys here, throw out the ones we won't handle
		if app:keyp'a' then						-- select-all
			-- select all
			self.selectStart = 1
			self.selectEnd = #self.text+1		-- how did i end up using an exclusive, 1-based range ... smh
		elseif app:keyp'x' or app:keyp'c' then 	-- cut/copy
			if self.selectStart then
				local sel = self.text:sub(self.selectStart, self.selectEnd-1)
				if not clip.text(sel) then
					print'failed to copy text'
				end

				if app:keyp'x' then -- cut only
					self:pushUndo()
					self:deleteSelection()
					self:refreshNewlines()
					self:refreshCursorColRowForLoc()
				end
			end
		elseif app:keyp'v' then 				-- paste
			local paste = clip.text()
			if self.selectStart or paste then 
				-- only save undo if we're (a) going to be deleting selected text with this paste or (b) going to be pasting text
				-- if there's an empty clipboard, don't let repeated ctrl+v's stack up in the undo buffer
				-- TODO or I can just have pushUndo check the last undo buffer and see if the text changed ... but for big text that might be slow?
				self:pushUndo()
			end
			self:deleteSelection()
			if paste then
				self.text = self.text:sub(1, self.cursorLoc)..paste..self.text:sub(self.cursorLoc+1)
				self.cursorLoc = self.cursorLoc + #paste
			end
			self:refreshNewlines()
			self:refreshCursorColRowForLoc()
		elseif app:keyp'z' then
			-- ui+z = undo, shift+ui+z = redo
			self:popUndo(shift)
		end
	else
		for keycode=0,#keyCodeNames-1 do
			if app:keyp(keycode,30,5) then
				local ch = getAsciiForKeyCode(keycode, shift)
				if keycode == keyCodeForName.tab then
					self:pushUndoTyping()
					if self.selectStart ~= nil then
						-- search the selectStart back to the start of the current line
						while self.text:byte(self.selectStart-1) ~= newlineByte do
							self.selectStart = self.selectStart - 1
							if self.selectStart == 0 then
								self.selectStart = 1
								break
							end
						end
						-- add tab and do indent up there
						local oldTabbedText = self.text:sub(self.selectStart, self.selectEnd-1)
						local tabbedText
						if shift then
							tabbedText = oldTabbedText:gsub('\n\t', '\n')
							-- if our current line starts with \t then remove that too ...
							if tabbedText:byte(self.selectStart) == tabByte then
								tabbedText = tabbedText:sub(2)
							end
						else
							tabbedText = '\t' .. oldTabbedText:gsub('\n', '\n\t')
						end
						self.text = self.text:sub(1, self.selectStart-1)
							.. tabbedText
							.. self.text:sub(self.selectEnd)
						self.selectEnd = self.selectEnd + #tabbedText - #oldTabbedText
						self:refreshNewlines()
						self:refreshCursorColRowForLoc()
					else
						-- just insert a tab or space character ...
						self:addCharToText(tabByte)
					end
				elseif ch then
					self:pushUndoTyping()
					self:addCharToText(ch)
				elseif keycode == keyCodeForName['return'] then
					self:pushUndoTyping()
					self:addCharToText(newlineByte)
				elseif keycode == keyCodeForName.up
				or keycode == keyCodeForName.down
				or keycode == keyCodeForName.left
				or keycode == keyCodeForName.right
				or keycode == keyCodeForName.pageup
				or keycode == keyCodeForName.pagedown
				then
					if shift then
						if not self.selectDownLoc then	-- how will mouse drag + kbd shift+move work together?
							self:startSelect()
						end
					else
						self:clearSelect()
					end
					local dx =
					self:moveCursor(
						({
							[keyCodeForName.left] = -1,
							[keyCodeForName.right] = 1,
						})[keycode] or 0, --dx,
						({
							[keyCodeForName.up] = -1,
							[keyCodeForName.down] = 1,
							[keyCodeForName.pageup] = -30,
							[keyCodeForName.pagedown] = 30,
						})[keycode] or 0	--dy
					)
					if shift and self.selectDownLoc then
						self:growSelect()
					end
				elseif keycode == keyCodeForName.home then
					self.cursorCol = 1
					-- TODO refresh cursorLoc from cursorRow/cursorCol
					self.cursorLoc = self.newlines[self.cursorRow] + self.cursorCol-1
					self:refreshCursorColRowForLoc()
				elseif keycode == keyCodeForName['end'] then
					self.cursorCol = self.newlines[self.cursorRow+1] - self.newlines[self.cursorRow]
					-- TODO refresh cursorLoc from cursorRow/cursorCol
					self.cursorLoc = self.newlines[self.cursorRow] + self.cursorCol-1
					self:refreshCursorColRowForLoc()
				end
			end
		end
	end

	self:drawTooltip()
end

function EditCode:moveCursor(dx, dy)
	-- advance row ...
	self.cursorRow = self.cursorRow + dy
	if self.cursorRow < 1 then
		self.cursorRow = 1
		self.cursorCol = 1
	elseif self.cursorRow > #self.newlines-1 then
		self.cursorRow = #self.newlines-1
		self.cursorCol = self.newlines[self.cursorRow+1] - self.newlines[self.cursorRow]
	else
		local currentLineCols = self.newlines[self.cursorRow+1] - self.newlines[self.cursorRow]
		self.cursorCol = math.clamp(self.cursorCol, 1, currentLineCols)
	end
	self.cursorLoc = self.newlines[self.cursorRow] + self.cursorCol-1

	-- advance col left/right without bounds so we can use left/right to wrap lines
	self.cursorLoc = math.clamp(self.cursorLoc + dx, 0, #self.text)

	self:refreshCursorColRowForLoc()	-- in case we did wrap lines
end

function EditCode:clearSelect()
	self.selectStart = nil
	self.selectEnd = nil
	self.selectDownLoc = nil
	self.selectCurLoc = nil
end
function EditCode:startSelect()
	self:clearSelect()
	self.selectDownLoc = self.cursorLoc+1
end
function EditCode:growSelect()
	self.selectCurLoc = self.cursorLoc+1
	self.selectStart = math.min(self.selectDownLoc, self.selectCurLoc)
	self.selectEnd = math.max(self.selectDownLoc, self.selectCurLoc)
end

-- be sure to call self:refreshNewlines() and self:refreshCursorColRowForLoc() afterwards...
function EditCode:deleteSelection()
	if not self.selectStart then return end

	self.text = self.text:sub(1, self.selectStart-1)..self.text:sub(self.selectEnd)
	if self.cursorLoc+1 >= self.selectStart and self.cursorLoc+1 < self.selectEnd then
		self.cursorLoc = self.selectStart-1
	elseif self.cursorLoc+1 >= self.selectEnd then
		self.cursorLoc = self.cursorLoc - (self.selectEnd - self.selectStart)
	end
	self:clearSelect()
end

function EditCode:addCharToText(ch)
	-- if we have selection then delete it
	if self.selectStart
	and self.selectEnd > self.selectStart -- end is exclusive, so this is an empty selection
	then
		self:deleteSelection()

		-- and if we're pressing backspace on selection then quit while you're ahead
		if ch == backspaceByte then ch = nil end
	end

	if ch == slashRByte then
		ch = newlineByte	-- store \n's instead of \r's
	end
	if ch == backspaceByte then
		self.text = self.text:sub(1, math.max(0, self.cursorLoc - 1)) .. self.text:sub(self.cursorLoc+1)
		self.cursorLoc = math.max(0, self.cursorLoc - 1)
	elseif ch then
		self.text = self.text:sub(1, self.cursorLoc) .. string.char(ch) .. self.text:sub(self.cursorLoc+1)
		self.cursorLoc = math.min(#self.text, self.cursorLoc + 1)
	end

	self:refreshNewlines()
	self:refreshCursorColRowForLoc()
end

-- push undo
-- a separate one for typing that doesn't insert if the last insert was within a few milliseconds
EditCode.typeUndoDelay = 1
EditCode.lastPushUndo = -math.huge
function EditCode:pushUndoTyping()
	if getTime() - self.lastPushUndo < self.typeUndoDelay then return end
	self:pushUndo()
end
-- and a separate call for copy/paste that always inserts into here
function EditCode:pushUndo()
	self.lastPushUndo = getTime()
	-- erase subsequent undo stack
	for i=self.undoIndex+1,#self.undoBuffer do
		self.undoBuffer[i] = nil
	end
	-- add this entry and set it as the current undo location
	self.undoBuffer:insert{text=self.text, cursorLoc=self.cursorLoc}
	self.undoIndex = #self.undoBuffer
end
function EditCode:popUndo(redo)
	-- if we are push-undo-ing from the top of the undo stack and the text doesn't match the top stack text then insert it at the top
	-- that way if the pushUndoTyping hadn't yet recorded it and we then get a 'redo' we will go back to the top
	if self.undoIndex == #self.undoBuffer 
	and self.undoIndex > 0
	and self.undoBuffer:last().text ~= self.text
	then
		self:pushUndo()
	end
	self.undoIndex = math.clamp(self.undoIndex + (redo and 1 or -1), 0, #self.undoBuffer)
	local undo = self.undoBuffer[self.undoIndex]
	-- test here because if it's zero then there won't be an entry ... and we should be at a blank text ...
	if undo then
		self.text = undo.text
		self.cursorLoc = undo.cursorLoc
	else
		self.text = ''
		self.cursorLoc = 0
	end
	self:clearSelect()
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

return EditCode
