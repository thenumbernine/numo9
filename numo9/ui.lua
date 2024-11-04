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

local numo9_rom = require 'numo9.rom'
local paletteSize = numo9_rom.paletteSize
local spriteSize = numo9_rom.spriteSize
local frameBufferSize = numo9_rom.frameBufferSize
local frameBufferSizeInTiles = numo9_rom.frameBufferSizeInTiles
local spriteSheetSize = numo9_rom.spriteSheetSize
local spriteSheetSizeInTiles = numo9_rom.spriteSheetSizeInTiles
local tilemapSize = numo9_rom.tilemapSize
local menuFontWidth = numo9_rom.menuFontWidth

local numo9_keys = require 'numo9.keys'
local keyCodeNames = numo9_keys.keyCodeNames
local getAsciiForKeyCode = numo9_keys.getAsciiForKeyCode

-- TODO make the editor a rom itself
-- TODO make roms that hold all the necessary stuff

local editModesWithoutNet = table{
	'code',
	'sprites',
	'tilemap',
	'sfx',
	'music',
}

local editModesWithNet = table{'net'}:append(editModesWithoutNet)

local editFieldForMode = {
	code = 'editCode',
	sprites = 'editSprites',
	tilemap = 'editTilemap',
	sfx = 'editSFX',
	music = 'editMusic',
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

	local w = self:drawText(str, x, y, fg, bg)

	local mouseX, mouseY = app.ram.mousePos:unpack()
	local mouseOver =
		mouseX >= x and mouseX < x + w
		and mouseY >= y and mouseY < y + spriteSize.y
	if tooltip and mouseOver then
		self:setTooltip(tooltip, mouseX - 12, mouseY - 12, 12, 6)
	end
	local result
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

	x = x + spriteSize.x
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

function UI:guiTextField(x, y, w, t, k, tooltip)
	-- TODO here ... only if we have tab-focus ... read our input.
	-- TODO color by tab-focus or not
	-- TODO can i share any code with editcode.lua ?  or nah, too much for editing a single field?
	assert.type(assert.index(t, k), 'string')
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

	if self.menuTabIndex ~= self.cursorMenuTabIndex then
		-- if we just switched to this tabitem then reset the cursor position
		self.textFieldCursorLoc = #t[k]
	end

	local fg, bg
	if onThisMenuItem then
		fg, bg = 0xfd, 0xf9
	else
		fg, bg = 0xfd, 0xf8
	end

	local w = app:drawText(t[k], x, y, fg, bg)

	local changed
	if onThisMenuItem then
		if getTime() % 1 < .5 then
			app:drawSolidRect(
				x + self.textFieldCursorLoc * menuFontWidth,
				y,
				menuFontWidth,
				spriteSize.y,
				0xfc
			)
		end

		-- TODO lots in common with editcode ... hmmm ...
		local shift = app:key'lshift' or app:key'rshift'
		local function addCharToText(ch)
			if ch == 8 then
				t[k] = t[k]:sub(1, self.textFieldCursorLoc - 1) .. t[k]:sub(self.textFieldCursorLoc+1)
				self.textFieldCursorLoc = math.max(0, self.textFieldCursorLoc - 1)
			elseif ch then
				t[k] = t[k]:sub(1, self.textFieldCursorLoc) .. string.char(ch) .. t[k]:sub(self.textFieldCursorLoc+1)
				self.textFieldCursorLoc = math.min(#t[k], self.textFieldCursorLoc + 1)
			end
		end

		-- handle input here ...
		for keycode=0,#keyCodeNames-1 do
			if app:keyp(keycode,30,5) then
				local ch = getAsciiForKeyCode(keycode, shift)
				if ch then
					changed = true
					addCharToText(ch)
				end
			end
		end
	end

	self.menuTabCounter = self.menuTabCounter + 1

	return changed
end

function UI:setTooltip(s, x, y, fg, bg)
	x = math.clamp(x, 8, frameBufferSize.x-8)
	y = math.clamp(y, 8, frameBufferSize.y-8)
	self.tooltip = {s, x, y, fg, bg}
end

function UI:drawTooltip()
	if not self.tooltip then return end
	self:drawText(table.unpack(self.tooltip))
	self.tooltip = nil
end

-- this and the :gui stuff really is Gui more than UI ...
function UI:initMenuTabs()
	self.menuTabMax = self.menuTabCounter
	self.menuTabCounter = 0
end

function UI:update()
	local app = self.app
	local editModes = app.server and editModesWithNet or editModesWithoutNet

	self:initMenuTabs()

	app:clearScreen(0xf0)
	app:drawSolidRect(
		0, 0,	-- x,y,
		frameBufferSize.x, spriteSize.y,	-- w, h,
		self:color(0)
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

	local titlebar = '  '..app.editMode
	self:drawText(
		titlebar,
		#editModes*6,
		0,
		12,
		-1
	)

	-- TODO current bank vs editing ROM vs editing RAM ...
	local x = 230
	if self:guiButton('R', x, 0, nil, 'reset RAM') then
		app:checkDirtyGPU()
		ffi.copy(app.ram.v, app.banks.v[0].v, ffi.sizeof'ROM')
		app:setDirtyCPU()
	end
	x=x+6
	if self:guiButton('\223', x, 0, nil, 'run') then
		app:runROM()
	end
	x=x+6
	if self:guiButton('S', x, 0, nil, 'save') then
		app:saveROM(app.currentLoadedFilename)	-- if none is loaded this will save over 'defaultSaveFilename' = 'last.n9'
	end
	x=x+6
	if self:guiButton('L', x, 0, nil, 'load') then
		app:loadROM(app.currentLoadedFilename)	-- if none is loaded this will save over 'defaultSaveFilename' = 'last.n9'
	end
end

-- put editor palette in the last entry
-- so that people dont touch it
-- but still make sure they can use it
-- cuz honestly I'm aiming to turn the editor into a ROM itself and stash it in console 'memory'
function UI:color(i)
	if i == -1 then return -1 end	-- -1 for transparency meant don't use a valid color ...
	return bit.bor(bit.band(i,0xf),0xf0)
end

function UI:drawText(s,x,y,fg,bg)
	return self.app:drawText(
		s,x,y,
		self:color(fg),
		self:color(bg))
end

--[[
Editing will go on in RAM, for live cpu/gpu sprite/palette update's sake
but it'll always reflect the cartridge state

When the user sets the editCode to focus,
copy from the app.banks.v[i].code to the editor,
so we can use Lua string functinoality.

While playing, assume .banks.v[i] has the baseline content of the game,
and assume whatever's in .ram is dirty.

But while editing, assume .ram has the baseline content of the game,
and assume whatever's in .banks.v[i] is stale.


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

-- setters from editor that write to both .ram and .banks.v[0]
-- TODO how about flags in the editor for which you write to?

function UI:edit_poke(addr, value)
	local app = self.app
	app:net_poke(addr, value)
	app.banks.v[0].v[addr] = value
end

function UI:edit_pokew(addr, value)
	local app = self.app
	app:net_pokew(addr, value)
	ffi.cast('uint16_t*', app.banks.v[0].v + addr)[0] = value
end

function UI:edit_pokel(addr, value)
	local app = self.app
	app:net_pokel(addr, value)
	ffi.cast('uint32_t*', app.banks.v[0].v + addr)[0] = value
end

-- used by the editsfx and editmusic

local sfxTableSize = numo9_rom.sfxTableSize
local musicTableSize = numo9_rom.musicTableSize

function UI:calculateAudioSize()
	local app = self.app
	self.totalAudioBytes = 0
	for i=0,sfxTableSize-1 do
		self.totalAudioBytes = self.totalAudioBytes + app.ram.sfxAddrs[i].len
	end
	for i=0,musicTableSize-1 do
		self.totalAudioBytes = self.totalAudioBytes + app.ram.musicAddrs[i].len
	end
end

return UI
