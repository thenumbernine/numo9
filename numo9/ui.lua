--[[
This used to be the editor base
but it grew too abstract and now it's the UI base
I could separate them, but meh, at what point do you stop smashing things into smaller pieces
TODO tempted to use my lua-gui ...
--]]
local ffi = require 'ffi'
local math = require 'ext.math'
local table = require 'ext.table'
local assertindex = require 'ext.assert'.index
local class = require 'ext.class'

local numo9_rom = require 'numo9.rom'
local paletteSize = numo9_rom.paletteSize
local spriteSize = numo9_rom.spriteSize
local frameBufferSize = numo9_rom.frameBufferSize
local frameBufferSizeInTiles = numo9_rom.frameBufferSizeInTiles
local spriteSheetSize = numo9_rom.spriteSheetSize
local spriteSheetSizeInTiles = numo9_rom.spriteSheetSizeInTiles
local tilemapSize = numo9_rom.tilemapSize
local tilemapSizeInSprites = numo9_rom.tilemapSizeInSprites
local codeSize = numo9_rom.codeSize

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
	net = 'editNet',
	code = 'editCode',
	sprites = 'editSprites',
	tilemap = 'editTilemap',
	sfx = 'editSFX',
	music = 'editMusic',
}


local UI = class()

function UI:init(args)
	self.app = assertindex(args, 'app')

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
	self.menuTabCounter = self.menuTabCounter + 1

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
	if (mouseOver and app:keyp'mouse_left')
	or (self.execMenuTab and onThisMenuItem)
	then
		-- only clear it once its been handled
		self.execMenuTab = false
		return true
	end
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

	if self:guiButton(
		'R',
		240,
		0,
		nil,
		'reset RAM'
	) then
		app:checkDirtyGPU()
		ffi.copy(app.ram.v, app.cartridge.v, ffi.sizeof'ROM')
		app:setDirtyCPU()
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
copy from the app.cartridge.code to the editor,
so we can use Lua string functinoality.

While playing, assume .cartridge has the baseline content of the game,
and assume whatever's in .ram is dirty.

But while editing, assume .ram has the baseline content of the game,
and assume whatever's in .cartridge is stale.


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

--[====[
	app:checkDirtyGPU()
	-- copy everything from cartridge to RAM (where it'll be edited & the engine can live-update the edits)
	ffi.copy(app.ram, app.cartridge, ffi.sizeof'ROM')
	-- set all dirty flags too
	app.spriteTex.dirtyCPU = true
	app.tileTex.dirtyCPU = true
	app.mapTex.dirtyCPU = true
	app.palTex.dirtyCPU = true
	app.fbTex.dirtyCPU = true
	app.fbTex.changedSinceDraw = true

	-- copy cartridge code to editCode (where we can use Lua string functionality)
	local code = ffi.string(app.cartridge.code, math.min(codeSize, tonumber(ffi.C.strlen(app.cartridge.code))))
	app.editCode:setText(code)
--]====]
end

--[====[
function UI:loseFocus()
	local app = self.app

	-- sync with RAM as well for when we run stuff ... tho calling run() or reset() should do this copy ROM->RAM for us
	ffi.copy(app.cartridge, app.ram, ffi.sizeof'ROM')

	-- sync us back from editor to cartridge so everyone else sees the console code where it belongs
	ffi.fill(app.cartridge.code, ffi.sizeof(app.cartridge.code))
	ffi.copy(app.cartridge.code, app.editCode.text:sub(1,codeSize-1))
end
--]====]

-- setters from editor that write to both .ram and .cartridge
-- TODO how about flags in the editor for which you write to?

function UI:edit_poke(addr, value)
	local app = self.app
	app:net_poke(addr, value)
	app.cartridge.v[addr] = value
end

function UI:edit_pokew(addr, value)
	local app = self.app
	app:net_pokew(addr, value)
	ffi.cast('uint16_t*', app.cartridge.v + addr)[0] = value
end

function UI:edit_pokel(addr, value)
	local app = self.app
	app:net_pokel(addr, value)
	ffi.cast('uint32_t*', app.cartridge.v + addr)[0] = value
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
