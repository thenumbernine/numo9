--[[
This used to be the editor base
but it grew too abstract and now it's the UI base
I could separate them, but meh, at what point do you stop smashing things into smaller pieces
TODO tempted to use my lua-gui ...
--]]
local ffi = require 'ffi'
local math = require 'ext.math'
local table = require 'ext.table'
local assert = require 'ext.assert'
local getTime = require 'ext.timer'.getTime
local class = require 'ext.class'
local sdl = require 'sdl'

local numo9_rom = require 'numo9.rom'
local paletteSize = numo9_rom.paletteSize
local spriteSize = numo9_rom.spriteSize
local frameBufferSize = numo9_rom.frameBufferSize
local spriteSheetSize = numo9_rom.spriteSheetSize
local spriteSheetSizeInTiles = numo9_rom.spriteSheetSizeInTiles
local tilemapSize = numo9_rom.tilemapSize
local menuFontWidth = numo9_rom.menuFontWidth

local numo9_keys = require 'numo9.keys'
local keyCodeNames = numo9_keys.keyCodeNames
local getAsciiForKeyCode = numo9_keys.getAsciiForKeyCode

local numo9_blobs = require 'numo9.blobs'
local blobClassForName = numo9_blobs.blobClassForName
local minBlobPerType = numo9_blobs.minBlobPerType

local editModes = table{
	'code',
	'sheet',
	'tilemap',
	'sfx',
	'music',
	'brush',
	--'brushmap',
}

local editFieldForMode = {
	code = 'editCode',
	sheet = 'editSheet',
	tilemap = 'editTilemap',
	sfx = 'editSFX',
	music = 'editMusic',
	brush = 'editBrushes',
}


local UI = class()

function UI:init(args)
	self.app = assert.index(args, 'app')

	self.menuTabCounter = 0
	self.menuTabIndex = 0

	-- thread that busy loops update and yields?
	-- vs just calling update instead of resuming the thread?
	-- the thread will store its errors separately
	-- and that means no need to wrap all the updates in xpcall
	-- likewise the error call stacks won't go back into the calling App's code
	self.thread = coroutine.create(function()
		while true do
			coroutine.yield()
			self:update()
		end
	end)
end

function UI:guiButton(str, x, y, isset, tooltip)
	local app = self.app

	local onThisMenuItem = self.menuTabIndex == self.menuTabCounter

	local fg, bg
	if isset and onThisMenuItem then
		fg, bg = 0xfc, 0xf9
	elseif isset then
		fg, bg = 0xfc, 0xf8
	elseif onThisMenuItem then
		fg, bg = 0xfd, 0xf9
	else
		fg, bg = 0xfd, 0xf8
	end

	local w = app:drawMenuText(str, x, y, fg, bg)

	local mouseX, mouseY = app.ram.mousePos:unpack()
	local mouseOver =
		mouseX >= x and mouseX < x + w
		and mouseY >= y and mouseY < y + spriteSize.y
	if tooltip and mouseOver then
		self:setTooltip(tooltip, mouseX - 12, mouseY - 12, 12, 6)
	end
	local result
	if mouseOver then
		self.menuTabIndex = self.menuTabCounter
	end

	if (mouseOver and app:keyp'mouse_left')
	or (self.execMenuTab and onThisMenuItem)
	then
		self.menuTabIndex = self.menuTabCounter
		-- only clear it once its been handled
		self.execMenuTab = false
		result = true
	end
	self.menuTabCounter = self.menuTabCounter + 1
	return result
end

function UI:guiSpinner(x, y, cb, tooltip)
	local app = self.app

	local leftButtonDown = app:key'mouse_left'
	local leftButtonPress = app:keyp'mouse_left'
	local leftButtonRelease = app:keyr'mouse_left'
	local mouseX, mouseY = app.ram.mousePos:unpack()

	if self:guiButton('<', x, y, nil, tooltip) then
		cb(-1)
	end

	local fontWidth = 5
	x = x + fontWidth + 1
	if self:guiButton('>', x, y, nil, tooltip) then
		cb(1)
	end
end

function UI:guiRadio(x, y, options, selected, cb)
	for _,name in ipairs(options) do
		if self:guiButton(
			name:sub(1,1):upper(),
			x,
			y,
			selected == name,
			name
		) then
			cb(name)
		end
		x = x + 6
	end
end

function UI:guiTextField(
	x, y, w,
	t, k,	-- provide t and k to just read and write to t[k].  provide just 't' to use it as a value and then write with 'write' next.
	write,	-- if this is nil then t[k] is assigned currentEditValue.  otherwise write(currentEditValue) is called for assignment.
	tooltip,
	fgDesel, bgDesel, fgSel, bgSel	-- fg and bg when not-selected and when selected
)
	fgDesel = fgDesel or 0xfd
	bgDesel = bgDesel or 0xf8
	fgSel = fgSel or 0xfd
	bgSel = bgSel or 0xf9

	-- TODO here ... only if we have tab-focus ... read our input.
	-- TODO color by tab-focus or not
	-- TODO can i share any code with editcode.lua ?  or nah, too much for editing a single field?
	local str
	if k == nil then
		str = tostring(t)
	else
		str = tostring(t[k])
	end
	local app = self.app

	local onThisMenuItem = self.menuTabIndex == self.menuTabCounter

	local mouseX, mouseY = app.ram.mousePos:unpack()
	local mouseOver =
		mouseX >= x and mouseX < x + w
		and mouseY >= y and mouseY < y + spriteSize.y
	if tooltip and mouseOver then
		self:setTooltip(tooltip, mouseX - 12, mouseY - 12, 12, 6)
	end

	-- TODO like some UIs, push enter to enable/disable editing? or nah
	if mouseOver and app:keyp'mouse_left' then
		self.menuTabIndex = self.menuTabCounter
		onThisMenuItem = true
	end

	-- if we're on this and we're editing this then use what's in the edit-buffer
	if onThisMenuItem then
		-- if we just selected then setup state for editing
		if self.lastMenuTabIndex ~= self.menuTabCounter then
			self.lastMenuTabIndex = self.menuTabCounter
			self.currentEditValue = str
		else
			str = self.currentEditValue
		end
	end

	if self.menuTabIndex ~= self.cursorMenuTabIndex then
		-- if we just switched to this tabitem then reset the cursor position
		self.textFieldCursorLoc = #str
	end

	local fg, bg
	if onThisMenuItem then
		fg, bg = fgSel, bgSel
	else
		fg, bg = fgDesel, bgDesel
	end

	local w = app:drawMenuText(str, x, y, fg, bg)

	local enter
	if onThisMenuItem then
		if getTime() % 1 < .5 then
			app:drawSolidRect(
				x + self.textFieldCursorLoc * menuFontWidth,
				y,
				menuFontWidth,
				spriteSize.y,
				0xfc,
				nil,
				nil,
				app.paletteMenuTex
			)
		end

		-- TODO lots in common with editcode ... hmmm ...
		local shift = app:key'lshift' or app:key'rshift'

		-- handle input here ...
		for keycode=0,#keyCodeNames-1 do
			if app:keyp(keycode,30,5) then
				local ch = getAsciiForKeyCode(keycode, shift)
				if ch then
					if ch == 10 or ch == 13 then
						enter = true
					elseif ch == 8 then
						self.currentEditValue = self.currentEditValue:sub(1, self.textFieldCursorLoc - 1) .. self.currentEditValue:sub(self.textFieldCursorLoc+1)
						self.textFieldCursorLoc = math.max(0, self.textFieldCursorLoc - 1)
					elseif ch then
						self.currentEditValue = self.currentEditValue:sub(1, self.textFieldCursorLoc) .. string.char(ch) .. self.currentEditValue:sub(self.textFieldCursorLoc+1)
						self.textFieldCursorLoc = math.min(#self.currentEditValue, self.textFieldCursorLoc + 1)
					end
				end
			end
		end
	end

	local changed
	if enter then
		if not write then
			t[k] = self.currentEditValue
		else
			write(self.currentEditValue)
		end
		changed = true
		self.currentEditValue = nil
		self.lastMenuTabIndex = nil
		self.menuTabIndex = self.menuTabIndex + 1		-- enter = select next
	end

	-- [[
	self.menuTabCounter = self.menuTabCounter + 1
	--]]
	--[[ how to get enter to deselect the textfield ...
	-- two menu-tab-counters per text-field, one for in-edit mode, one for not
	self.menuTabCounter = self.menuTabCounter + 2

	if enter and onThisMenuItem then
		self.menuTabIndex = self.menuTabIndex + 1
	end
	--]]

	return changed
end

function UI:guiBlobSelect(x, y, blobName, t, indexKey, cb)
	local app = self.app
	local popupKey = indexKey..'_popupOpen'
	local buttonMenuTabCounter = self.menuTabCounter
	local sel = self.menuTabIndex == buttonMenuTabCounter
	self:guiButton('#'..t[indexKey], x, y, nil, blobName)
	if sel then
		t[popupKey] = true
	end
	if t[popupKey] then
		local w = 25
		local h = 10
		app:drawBorderRect(x, y + 8, w+2, h+2, 0x0c)
		app:drawSolidRect(x+1, y + 9, w, h, self:color(0))

		self:guiSpinner(x + 2, y + 10, function(dx)
			t[indexKey] = math.clamp(t[indexKey] + dx, 0, #app.blobs[blobName]-1)
			if cb then cb(dx) end
		end)
		-- TODO input number selection?

		local changed
		if self:guiButton('+', x + 14, y + 10, nil) then
			app.blobs[blobName]:insert(t[indexKey]+2, blobClassForName[blobName]())
			t[indexKey] = t[indexKey] + 1
			changed = true
		end

		local len = #app.blobs[blobName]
		if len > (minBlobPerType[blobName] or 0) then	-- TODO if not then grey out the - sign?
			if self:guiButton('-', x + 20, y + 10, nil) then
				app.blobs[blobName]:remove(t[indexKey]+1)
				changed = true
				if t[indexKey] > 0 then
					t[indexKey] = t[indexKey] - 1
				end
			end
		end
		-- TODO controls for moving blobs in order?

		if changed then
			app:updateBlobChanges()
			app:net_resetCart()
		end
	end

	if self.menuTabIndex < buttonMenuTabCounter
	or self.menuTabIndex >= self.menuTabCounter
	then
		t[popupKey] = false
	end
end

function UI:setTooltip(s, x, y, fg, bg)
	x = math.clamp(x, 8, frameBufferSize.x-8)
	y = math.clamp(y, 8, frameBufferSize.y-8)
	self.tooltip = {s, x, y, fg, bg}
end

function UI:drawTooltip()
	if not self.tooltip then return end
	self.app:drawMenuText(table.unpack(self.tooltip))
	self.tooltip = nil
end

-- this and the :gui stuff really is Gui more than UI ...
function UI:initMenuTabs()
	self.menuTabMax = self.menuTabCounter
	self.menuTabCounter = 0
end

function UI:update()
	local app = self.app

	self:initMenuTabs()

	app:clearScreen(0xf0, app.paletteMenuTex)
	app:drawSolidRect(
		0, 0,	-- x,y,
		frameBufferSize.x, spriteSize.y,	-- w, h,
		self:color(0),
		nil,
		nil,
		app.paletteMenuTex
	)

	self:guiRadio(
		0,
		0,
		editModes,
		app.editMode,
		function(x)
			app.editMode = x
			if editFieldForMode[x] then
				app:setMenu(app[editFieldForMode[x]])
			end
		end
	)

	local titlebar = app.editMode
	app:drawMenuText(
		titlebar,
		#editModes*6,
		0,
		12,
		-1
	)

	-- TODO current blob vs editing ROM vs editing RAM ...
	local x = 230
	if self:guiButton('R', x, 0, nil, 'reset RAM') then
		app:checkDirtyGPU()
		app:copyBlobsToROM()
		app:setDirtyCPU()
	end
	x=x+6
	if self:guiButton('\223', x, 0, nil, 'run') then
		app:setFocus{
			thread = coroutine.create(function()
				app:runCart()
			end),
		}
		app.isPaused = false
	end
	x=x+6
	if self:guiButton('S', x, 0, nil, 'save') then
		-- if none is loaded this will save over 'defaultSaveFilename' = 'last.n9'
		app:saveCart(app.currentLoadedFilename)
		-- TODO this will rearrange the blobs
		-- so TODO it should net_resetCart as well (net_saveCart maybe?)
		app:net_resetCart()
	end
	x=x+6
	if self:guiButton('L', x, 0, nil, 'load') then
		app:setFocus{
			thread = coroutine.create(function()
				-- do this from runFocus thread, not UI thread
				app:net_openCart(app.currentLoadedFilename)	-- if none is loaded this will save over 'defaultSaveFilename' = 'last.n9'
				--app:runCart() ?
			end),
		}
		app.isPaused = false	-- make sure the setFocus does run
	end
end

-- TODO I changed this, now I use a separate UI palette texture, so this isnt needed.
-- put editor palette in the last entry
-- so that people dont touch it
-- but still make sure they can use it
-- cuz honestly I'm aiming to turn the editor into a ROM itself and stash it in console 'memory'
function UI:color(i)
	if i == -1 then return -1 end	-- -1 for transparency meant don't use a valid color ...
	return bit.bor(bit.band(i,0xf),0xf0)
end

--[[
Editing will go on in RAM, for live cpu/gpu sprite/palette update's sake
but it'll always reflect the cartridge state

When the user sets the editCode to focus,
copy from the app.blobs.code[1].data to the editor,
so we can use Lua string functinoality.

While playing, assume .blobs.code[1].data has the baseline content of the game,
and assume whatever's in .ram is dirty.

But while editing, assume .ram has the baseline content of the game,
and assume whatever's in .blobs.code[1].data is stale.


HMMMMmmm
This is a thorn in the side of live-editing DM style
cuz what are we editing?  the current RAM copy of the game, or the cartridge/ROM copy of the game?
For game design you want the latter, for live-editing you want the former.
We can always have it edit *both* ... *simultaneously* ... and then trust the editor user to reset() the game when needed to tell the difference between runtime edits and editor edits ...
In that situation, what do we do here?
How about nothing - not a thing - and once again rely on the editor-user to manually reset() to flush cartridge->RAM data.
... maybe provide them with a 'dirty' warning if the game has been run, or if any ROM-area writes have been detected?
... until I do that, might as well reset everything here and just claim that 'DM-realtime-editor is WIP'
--]]
function UI:gainFocus()
	local app = self.app

	-- if an editor tab gains focus, make sure to select it
	for name,field in pairs(editFieldForMode) do
		if self == app[field] then
			app.editMode = name
		end
	end
end

-- setters from editor that write to both .ram and .blobs
-- TODO how about flags in the editor for which you write to?

function UI:edit_poke(addr, value)
	local app = self.app
	app:net_poke(addr, value)

	-- TODO what about pokes to the blob FAT?
	-- JUST DON'T DO THAT from the edit_poke* API (which is only called through the editor here)
	for _,blobs in pairs(app.blobs) do
		for _,blob in ipairs(blobs) do
			if addr >= blob.addr and addr+1 <= blob.addr + blob:getSize() then
				ffi.cast('uint8_t*', blob:getPtr() + (addr - blob.addr))[0] = value
			end
		end
	end
end

function UI:edit_pokew(addr, value)
	local app = self.app
	app:net_pokew(addr, value)

	for _,blobs in pairs(app.blobs) do
		for _,blob in ipairs(blobs) do
			if addr >= blob.addr and addr+2 <= blob.addr + blob:getSize() then
				ffi.cast('uint16_t*', blob:getPtr() + (addr - blob.addr))[0] = value
			end
		end
	end
end

function UI:edit_pokel(addr, value)
	local app = self.app
	app:net_pokel(addr, value)

	for _,blobs in pairs(app.blobs) do
		for _,blob in ipairs(blobs) do
			if addr >= blob.addr and addr+4 <= blob.addr + blob:getSize() then
				ffi.cast('uint32_t*', blob:getPtr() + (addr - blob.addr))[0] = value
			end
		end
	end
end

-- in any menu, press escape or gamepad start to exit menu
function UI:event(e)
	--[[ is it just my controllers that register dpad as axis motion?
	-- or do they all?
	if (e[0].type == sdl.SDL_EVENT_GAMEPAD_BUTTON_DOWN
		and e[0].gbutton.button == sdl.SDL_GAMEPAD_BUTTON_DPAD_UP)
	--]]
	-- [[
	if (e[0].type == sdl.SDL_EVENT_GAMEPAD_AXIS_MOTION
		and e[0].gaxis.axis == 1
		and e[0].gaxis.value < -10000)
	--]]
	or (e[0].type == sdl.SDL_EVENT_KEY_DOWN and e[0].key.key == sdl.SDLK_UP)
	--or app:btnp'up'	-- should I use the user-configured up/down here too? meh?
	then
		self.menuTabIndex = self.menuTabIndex - 1
		if self.menuTabMax and self.menuTabMax > 0 then
			self.menuTabIndex = self.menuTabIndex % self.menuTabMax
		end
		return true
	end

	--[[
	if (e[0].type == sdl.SDL_EVENT_GAMEPAD_BUTTON_DOWN
		and e[0].gbutton.button == sdl.SDL_GAMEPAD_BUTTON_DPAD_DOWN)
	--]]
	-- [[
	if (e[0].type == sdl.SDL_EVENT_GAMEPAD_AXIS_MOTION
		and e[0].gaxis.axis == 1
		and e[0].gaxis.value > 10000)
	--]]
	or (e[0].type == sdl.SDL_EVENT_KEY_DOWN and e[0].key.key == sdl.SDLK_DOWN)
	then
		self.menuTabIndex = self.menuTabIndex + 1
		if self.menuTabMax and self.menuTabMax > 0 then
			self.menuTabIndex = self.menuTabIndex % self.menuTabMax
		end
		return true
	end

	if (e[0].type == sdl.SDL_EVENT_GAMEPAD_BUTTON_DOWN and e[0].gbutton.button == sdl.SDL_GAMEPAD_BUTTON_SOUTH)
	or (e[0].type == sdl.SDL_EVENT_KEY_DOWN and e[0].key.key == sdl.SDLK_RETURN)
	then
		self.execMenuTab = true
		return true
	end
end

return UI
