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
local vec2d = require 'vec-ffi.vec2d'
local sdl = require 'sdl'

local numo9_rom = require 'numo9.rom'
local paletteSize = numo9_rom.paletteSize
local spriteSize = numo9_rom.spriteSize
local spriteSheetSize = numo9_rom.spriteSheetSize
local spriteSheetSizeInTiles = numo9_rom.spriteSheetSizeInTiles
local tilemapSizeInBits = numo9_rom.tilemapSizeInBits
local tilemapSize = numo9_rom.tilemapSize
local menuFontWidth = numo9_rom.menuFontWidth

local numo9_keys = require 'numo9.keys'
local keyCodeNames = numo9_keys.keyCodeNames
local keyCodeForName = numo9_keys.keyCodeForName
local getAsciiForKeyCode = numo9_keys.getAsciiForKeyCode

local numo9_blobs = require 'numo9.blobs'
local blobClassForName = numo9_blobs.blobClassForName
local minBlobPerType = numo9_blobs.minBlobPerType

local UIRadio = require 'numo9.ui.radio'
local UIButton = require 'numo9.ui.button'

local uint8_t = ffi.typeof'uint8_t'
local uint8_t_p = ffi.typeof'uint8_t*'
local uint16_t = ffi.typeof'uint16_t'
local uint16_t_p = ffi.typeof'uint16_t*'
local int32_t = ffi.typeof'int32_t'
local uint32_t = ffi.typeof'uint32_t'
local uint32_t_p = ffi.typeof'uint32_t*'

local UI = class()

UI.editModes = table{
	'code',
	'sheet',
	'tilemap',
	'sfx',
	'music',
	--'brush',	-- just script at the moment ...
	'brushmap',
	'mesh3d',
	'voxelmap',
}

-- app fields for each editor for each blob type
UI.editFieldForMode = {
	code = 'editCode',
	sheet = 'editSheet',
	tilemap = 'editTilemap',
	sfx = 'editSFX',
	music = 'editMusic',
	--brush = 'editBrushes',
	brushmap = 'editBrushmap',
	mesh3d = 'editMesh3D',
	voxelmap = 'editVoxelmap',
}


function UI:init(args)
	self.app = assert.index(args, 'app')

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

function UI:setTooltip(s, mouseX, mouseY, fg, bg)
	-- TODO clamp to menu space max, which is setup in the menu transform in numo9/app.lua
	--mouseX = math.clamp(mouseX, 8, 256-8)
	mouseY = math.clamp(mouseY, 8, 256-8)
	self.tooltip = {s, mouseX, mouseY, fg, bg}
end

function UI:drawTooltip()
	if not self.tooltip then return end
	self.app:drawMenuText(table.unpack(self.tooltip))
	self.tooltip = nil
end

function UI:update()
	local app = self.app

	app:matMenuReset()
	app:clearScreen(0, app.paletteMenuTex)
end

--[[
Editing will go on in RAM, for live cpu/gpu sprite/palette update's sake
but it'll always reflect the cartridge state

When the user sets the editCode to focus,
copy from the app.blobs.code[1].vec to the editor,
so we can use Lua string functinoality.

While playing, assume .blobs.code[1].vec has the baseline content of the game,
and assume whatever's in .ram is dirty.

But while editing, assume .ram has the baseline content of the game,
and assume whatever's in .blobs.code[1].vec is stale.


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
	for name,field in pairs(UI.editFieldForMode) do
		if self == app[field] then
			app.editMode = name
		end
	end
end

-- setters from editor that write to both .ram and .blobs
-- TODO how about flags in the editor for which you write to?

function UI:edit_poke(addr, value)
	local app = self.app
	value = ffi.cast(uint8_t, value)

	-- this is done in net_poke but not in app:poke
	-- I would move it to app:poke but there are some resources that depend on poking same-value memory to initialize (like the mvMat uniform shader upload)
	if app:peek(addr) == value then return end

	-- TODO what about pokes to the blob FAT?
	-- JUST DON'T DO THAT from the edit_poke* API (which is only called through the editor here)
	for _,blobs in pairs(app.blobs) do
		for _,blob in ipairs(blobs) do
			if addr >= blob.addr and addr+1 <= blob.addrEnd then
				ffi.cast(uint8_t_p, blob:getPtr() + (addr - blob.addr))[0] = value
			end
		end
	end

	app:net_poke(addr, value)
end

function UI:edit_pokew(addr, value)
	local app = self.app
	value = ffi.cast(uint16_t, value)

	-- this is done in net_poke but not in app:poke
	-- I would move it to app:poke but there are some resources that depend on poking same-value memory to initialize (like the mvMat uniform shader upload)
	if app:peekw(addr) == value then return end

	for _,blobs in pairs(app.blobs) do
		for _,blob in ipairs(blobs) do
			if addr >= blob.addr and addr+2 <= blob.addrEnd then
				ffi.cast(uint16_t_p, blob:getPtr() + (addr - blob.addr))[0] = value
			end
		end
	end

	app:net_pokew(addr, value)
end

function UI:edit_pokel(addr, value)
	local app = self.app
	value = ffi.cast(uint32_t, value)

	-- this is done in net_poke but not in app:poke
	-- I would move it to app:poke but there are some resources that depend on poking same-value memory to initialize (like the mvMat uniform shader upload)
	if app:peekl(addr) == value then return end

	for _,blobs in pairs(app.blobs) do
		for _,blob in ipairs(blobs) do
			if addr >= blob.addr and addr+4 <= blob.addrEnd then
				ffi.cast(uint32_t_p, blob:getPtr() + (addr - blob.addr))[0] = value
			end
		end
	end

	app:net_pokel(addr, value)
end

-- also in numo9/app.lua
local function toint(x)
	return ffi.cast(int32_t, x)	-- use int32 so Lua has no problem with it
end
function UI:edit_tset(tilemapBlobIndex, x, y, value)
	local app = self.app
	tilemapBlobIndex = tonumber(toint(tilemapBlobIndex))
	x = toint(x)
	y = toint(y)
	value = ffi.cast(uint16_t, value)
	if not (x >= 0 and x < tilemapSize.x
		and y >= 0 and y < tilemapSize.y
		and tilemapBlobIndex >= 0 and tilemapBlobIndex < #app.blobs.tilemap
	)
	then
		return
	end

	local addr = app.blobs.tilemap[tilemapBlobIndex+1].addr
		+ bit.lshift(bit.bor(x, bit.lshift(y, tilemapSizeInBits.x)), 1)

	if app:peekw(addr) == value then return end

	for _,blobs in pairs(app.blobs) do
		for _,blob in ipairs(blobs) do
			if addr >= blob.addr and addr+2 <= blob.addrEnd then
				ffi.cast(uint16_t_p, blob:getPtr() + (addr - blob.addr))[0] = value
			end
		end
	end

	app:net_pokew(addr, value)
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
	or (e[0].type == sdl.SDL_EVENT_KEY_DOWN
	and e[0].key.key == sdl.SDLK_UP)
	--or app:btnp'up'	-- should I use the user-configured up/down here too? meh?
	then
		self.menuTabIndex = self.menuTabIndex - 1
		if self.menuTabCounter and self.menuTabCounter > 0 then
			self.menuTabIndex = self.menuTabIndex % self.menuTabCounter
		else
			self.menuTabIndex = 0
		end
		local w = self.widgetForTabIndex[self.menuTabIndex]
		if w then self.uiRoot:setFocusWidget(w) end
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
	or (e[0].type == sdl.SDL_EVENT_KEY_DOWN
	and e[0].key.key == sdl.SDLK_DOWN)
	then
		self.menuTabIndex = self.menuTabIndex + 1
		if self.menuTabCounter and self.menuTabCounter > 0 then
			self.menuTabIndex = self.menuTabIndex % self.menuTabCounter
		else
			self.menuTabIndex = 0
		end
		local w = self.widgetForTabIndex[self.menuTabIndex]
		if w then self.uiRoot:setFocusWidget(w) end
		return true
	end

	-- TODO TODO TODO
	-- I'm switching to a gui scenegraph
	-- so now tabbing is broken
	-- so convert everything to the gui scenegraph to fix it.
	--[[
	-- TODO this is blocking 'return's in the text editors in the menu ...
	-- tempting to switch all ui controls over to :event()'s
	-- tempting to just use a tree based ui ... and give them event-capturing and bubble in and out and everything
	if (e[0].type == sdl.SDL_EVENT_GAMEPAD_BUTTON_DOWN and e[0].gbutton.button == sdl.SDL_GAMEPAD_BUTTON_SOUTH)
	or (e[0].type == sdl.SDL_EVENT_KEY_DOWN and e[0].key.key == sdl.SDLK_RETURN)
	then
		self.execMenuTab = true
		return true
	end
	--]]
end

-- editor calsl this when it replaces a blob
-- TODO straighten out this vs App:updateBlobChanges ...
function UI:updateBlobChanges()
	local app = self.app
	-- refresh changes ... (same as in UI when the guiBlobSelect changes...)
	-- do this in main loop and outside inUpdateCallback so that framebufferRAM's checkDirtyGPU's can use the right framebuffer (and not the currently bound one)

	--app:allRAMRegionsCheckDirtyGPU()
	-- but flushing framebuffer GPU causes problems....
	-- so just flush all others
	app:allRAMRegionsExceptFramebufferCheckDirtyGPU()
	-- and just clear the framebuffers'
	app.currentVideoMode.framebufferRAM.dirtyGPU = false

	--app:copyBlobsToROM()
	app:updateBlobChanges()

--[[ this resets ... everything .... so why would I do that.
	app:resetVideo()
--]]
-- [[  but I need to update all pointers from their addresses ...
	local framebufferAddr = numo9_rom.framebufferAddr
	local ram = app.ram

	app:allRAMRegionsCheckDirtyGPU()

	local spriteSheetBlob = app.blobs.sheet[1]
	local spriteSheet1Blob = app.blobs.sheet[2]
	local tilemapBlob = app.blobs.tilemap[1]
	local paletteBlob = app.blobs.palette[1]
	local fontBlob = app.blobs.font[1]
	-- TODO relocatable animSheet or nah is this relocatable thing all a dumb idea?

	-- TODO how should tehse work if I'm using flexible # blobs and that means not always enough?
	local spriteSheetAddr = spriteSheetBlob and spriteSheetBlob.addr or 0
	local spriteSheet1Addr = spriteSheet1Blob and spriteSheet1Blob.addr or 0
	local tilemapAddr = tilemapBlob and tilemapBlob.addr or 0
	local paletteAddr = paletteBlob and paletteBlob.addr or 0
	local fontAddr = fontBlob and fontBlob.addr or 0

	-- reset these
	ram.framebufferAddr = framebufferAddr
	ram.spriteSheetAddr = spriteSheetAddr
	ram.spriteSheet1Addr = spriteSheet1Addr
	ram.tilemapAddr = tilemapAddr
	ram.paletteAddr = paletteAddr
	ram.fontAddr = fontAddr
	-- and these, which are the ones that can be moved

	-- reset framebufferRAM objects' addresses:
	app.currentVideoMode.framebufferRAM:updateAddr(framebufferAddr)

	if spriteSheetBlob then
		local sheetRAM = spriteSheetBlob.ramgpu
		if sheetRAM then sheetRAM:updateAddr(spriteSheetAddr) end
	end
	if spriteSheet1Blob then
		local spriteSheet1RAM = spriteSheet1Blob.ramgpu
		if spriteSheet1RAM then spriteSheet1RAM:updateAddr(spriteSheet1Addr) end
	end
	if tilemapBlob then
		local tilemapRAM = tilemapBlob.ramgpu
		if tilemapRAM then tilemapRAM:updateAddr(tilemapAddr) end
	end
	if paletteBlob then
		local paletteRAM = paletteBlob.ramgpu
		if paletteRAM then paletteRAM:updateAddr(paletteAddr) end
	end
	if fontBlob then
		local fontRAM = fontBlob.ramgpu
		if fontRAM then fontRAM:updateAddr(fontAddr) end
	end

	--[[
	app:setVideoMode(app.ram.videoMode)
	--]]
	-- [[
	app:onModelMatChange()	-- the drawObj changed so make sure it refreshes its modelMat
	app:onViewMatChange()
	app:onProjMatChange()
	app:onPaletteOffsetChange()
	app:onTransparentIndexChange()
	app:onSpriteBitChange()
	app:onSpriteMaskChange()
	app:onClipRectChange()
	app:onBlendColorChange()
	app:onDitherChange()
	app:onCullFaceChange()
	app:onFrameBufferSizeChange()
	--]]

	for _,blob in ipairs(app.blobs.sheet) do
		blob.ramgpu.dirtyCPU = true
		blob.ramgpu:checkDirtyCPU()
	end
	for _,blob in ipairs(app.blobs.tilemap) do
		blob.ramgpu.dirtyCPU = true
		blob.ramgpu:checkDirtyCPU()
	end
	for _,blob in ipairs(app.blobs.palette) do
		blob.ramgpu.dirtyCPU = true
		blob.ramgpu:checkDirtyCPU()
	end
	for _,blob in ipairs(app.blobs.font) do
		blob.ramgpu.dirtyCPU = true
		blob.ramgpu:checkDirtyCPU()
	end
	for _,blob in ipairs(app.blobs.animsheet) do
		blob.ramgpu.dirtyCPU = true
		blob.ramgpu:checkDirtyCPU()
	end

	app.lastAnimSheetTex = app.blobs.animsheet[1].ramgpu.tex
	app.lastTilemapTex = app.blobs.tilemap[1].ramgpu.tex
	app.lastSheetTex = app.blobs.sheet[1].ramgpu.tex
	app.lastPaletteTex = app.blobs.palette[1].ramgpu.tex
	app.lastAnimSheetTex:bind(3)
	app.lastTilemapTex:bind(2)
	app.lastSheetTex:bind(1)
	app.lastPaletteTex:bind(0)
--]]
end

-- hmm...
-- TODO this will bug if it's not the matrix from matMenuReset
function UI:guiSetClipRect(x,y,w,h)
	local app = self.app
	local sx1, sy1 = app:transform(x, y)
	local sx2, sy2 = app:transform(x + w, y + h)
	-- flip y
	sy1, sy2 =
		app.ram.screenHeight - 1 - sy2,
		app.ram.screenHeight - 1 - sy1
	app:setClipRect(sx1, sy1, sx2 - sx1, sy2 - sy1)
end


-- to-be-widget functionality:

function UI:newUI_setup()
	-- all created widgets need their owner to have menuTabCounter initialized
	self.menuTabIndex = 0
	self.menuTabCounter = 0
	self.widgetForTabIndex = {}

	self.uiRoot = require 'numo9.ui.root'{
		owner = self,
	}
end

function UI:newUI_addEditTabs()
	local app = self.app

	--[[ TODO represent a rect with blue background in the UI...
	do
		-- TODO if cull face affects this, how much more?
		-- TODO TODO this isn't it.
		-- somehow something in voxelmap is affecting cull face and is preventing the grey background when cullface==1 in menu
		local pushCullFace = app.ram.cullFace
		app.ram.cullFace = 0
		if app.ram.cullFace ~= pushCullFace then
			app:onCullFaceChange()
		end
		app:triBuf_flush()
		app:drawSolidRect(
			0, 0,	-- x,y,
			app.ram.screenWidth, app.ram.screenHeight,	-- w, h,
			0,
			nil,
			nil,
			app.paletteMenuTex
		)
		if app.ram.cullFace ~= pushCullFace then
			app.ram.cullFace = pushCullFace
			app:onCullFaceChange()
		end
		app:triBuf_flush()
	end
	--]]

	self:addChild(UIRadio{
		owner = self,
		pos = {0, 0},
		options = UI.editModes,
		getSelected = function()
			return app.editMode
		end,
		setSelected = function(x)
			app.editMode = x
			if UI.editFieldForMode[x] then
				app:setMenu(app[UI.editFieldForMode[x]])
			end
		end,
	})

	-- TODO current blob vs editing ROM vs editing RAM ...
	local x = 230
	self:addChild(UIButton{
		owner = self,
		pos = {x, 0},
		text = 'R',
		tooltip = 'reset RAM',
		events = {
			click = function()
				handled = true
				app:checkDirtyGPU()
				app:copyBlobsToROM()
				app:setDirtyCPU()
			end,
		},
	})
	x=x+6
	self:addChild(UIButton{
		owner = self,
		pos = {x, 0},
		text = '\223',
		tooltip = 'run',
		events = {
			click = function()
				handled = true
				app:runCart()
			end,
		},
	})
	x=x+6
	self:addChild(UIButton{
		owner = self,
		pos = {x, 0},
		text = 'S',
		tooltip = 'save',
		events = {
			click = function()
				app:saveCart(app.currentLoadedFilename)
			end,
		},
	})
	x=x+6
	self:addChild(UIButton{
		owner = self,
		pos = {x, 0},
		text = 'L',
		tooltip = 'load',
		events = {
			click = function()
				app:net_openCart(app.currentLoadedFilename)
			end,
		},
	})
end

function UI:newUI_update()
	local app = self.app

	app:matMenuReset()

	local uiRoot = self.uiRoot

	uiRoot.pos.x, uiRoot.pos.y = app:invTransform(0, 0, 0, 0)
	uiRoot.size.x, uiRoot.size.y = app:invTransform(app.width, app.height, 0, 0)
	uiRoot.size.x = uiRoot.size.x - uiRoot.pos.x
	uiRoot.size.y = uiRoot.size.y - uiRoot.pos.y

	-- reset the menu tab state of 'owner' of all widgets:
	self.menuTabCounter = 0
	for k in pairs(self.widgetForTabIndex) do
		self.widgetForTabIndex[k] = nil
	end

	-- this will refresh all widgets' .menuTabIndex
	uiRoot:rootUpdateAndDraw()

	self:drawTooltip()
end

function UI:newUI_event(sdlEvent, skipSuper)
	self.uiRoot:rootEvent(sdlEvent, not skipSuper and function()
		return UI.event(self, sdlEvent)
	end)
end

-- this is a pre-update call
function UI:newUI_realignChildren()
	-- TODO gotta do this to align children to the the immediate-mode radio-buttons for switching blob type
	-- until I switch those immediate-mode radio-buttons
	-- but to do that I have to switch all editor tabs to the new sytsem.
	for _,ch in ipairs(self.uiRoot.children) do
		if not ch.origPosX then ch.origPosX = ch.pos.x end
		ch.pos.x = ch.origPosX - self.uiRoot.pos.x
	end
end

function UI:addChild(...)
	return self.uiRoot:addChild(...)
end

return UI
