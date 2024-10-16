--[[
Here's all the common functions
I think I'll separate out the builtin states:
	console
	code editor
	sprite editor
	map editor
	sfx editor
	music editor
	run
--]]
local ffi = require 'ffi'
local assertindex = require 'ext.assert'.index
local asserttype = require 'ext.assert'.type
local assertlen = require 'ext.assert'.len
local asserteq = require 'ext.assert'.eq
local assertlt = require 'ext.assert'.lt
local string = require 'ext.string'
local table = require 'ext.table'
local range = require 'ext.range'
local math = require 'ext.math'
local path = require 'ext.path'
local tolua = require 'ext.tolua'
local fromlua = require 'ext.fromlua'
local getTime = require 'ext.timer'.getTime
local vec2s = require 'vec-ffi.vec2s'
local vec2i = require 'vec-ffi.vec2i'
local template = require 'template'
local matrix_ffi = require 'matrix.ffi'
local sdl = require 'sdl'
local gl = require 'gl'
local GLApp = require 'glapp'
local ThreadManager = require 'threadmanager'

local Server = require 'numo9.net'.Server
local ClientConn = require 'numo9.net'.ClientConn

local numo9_rom = require 'numo9.rom'
local updateHz = numo9_rom.updateHz
local updateIntervalInSeconds = numo9_rom.updateIntervalInSeconds
local ROM = numo9_rom.ROM	-- define RAM, ROM, etc
local RAM = numo9_rom.RAM
local spriteSize = numo9_rom.spriteSize
local frameBufferSize = numo9_rom.frameBufferSize
local spriteSheetSizeInTiles = numo9_rom.spriteSheetSizeInTiles
local tilemapSize = numo9_rom.tilemapSize
local keyPressFlagSize = numo9_rom.keyPressFlagSize
local keyCount = numo9_rom.keyCount
local codeSize = numo9_rom.codeSize
local persistentCartridgeDataSize  = numo9_rom.persistentCartridgeDataSize
local spriteSheetAddr = numo9_rom.spriteSheetAddr
local spriteSheetAddrEnd = numo9_rom.spriteSheetAddrEnd
local tileSheetAddr = numo9_rom.tileSheetAddr
local tileSheetAddrEnd = numo9_rom.tileSheetAddrEnd
local tilemapAddr = numo9_rom.tilemapAddr
local tilemapAddrEnd = numo9_rom.tilemapAddrEnd
local paletteAddr = numo9_rom.paletteAddr
local paletteAddrEnd = numo9_rom.paletteAddrEnd
local framebufferAddr = numo9_rom.framebufferAddr
local framebufferAddrEnd = numo9_rom.framebufferAddrEnd
local packptr = numo9_rom.packptr

local numo9_keys = require 'numo9.keys'
local maxLocalPlayers = numo9_keys.maxLocalPlayers
local keyCodeNames = numo9_keys.keyCodeNames
local keyCodeForName = numo9_keys.keyCodeForName
local sdlSymToKeyCode = numo9_keys.sdlSymToKeyCode
local firstJoypadKeyCode = numo9_keys.firstJoypadKeyCode
local buttonCodeForName = numo9_keys.buttonCodeForName

local netcmds = require 'numo9.net'.netcmds

local function hexdump(ptr, len)
	return string.hexdump(ffi.string(ptr, len))
end

local function imageToHex(image)
	return string.hexdump(ffi.string(image.buffer, image.width * image.height * ffi.sizeof(image.format)))
end


local App = GLApp:subclass()

App.title = 'NuMo9'
App.width = 720
App.height = 512

App.sdlInitFlags = bit.bor(App.sdlInitFlags, sdl.SDL_INIT_AUDIO)

local numo9_video = require 'numo9.video'
local rgba5551_to_rgba8888_4ch = numo9_video.rgba5551_to_rgba8888_4ch

-- copy in video behavior
for k,v in pairs(numo9_video.AppVideo) do
	App[k] = v
end

-- copy in audio behavior
for k,v in pairs(require 'numo9.audio'.AppAudio) do
	App[k] = v
end

local defaultSaveFilename = 'last.n9'	-- default name of save/load if you don't provide one ...

App.cfgpath = path'config.lua'

-- fps vars
local lastTime = getTime()
local fpsFrames = 0
local fpsSeconds = 0
local drawsPerSecond = 0

-- update interval vars
local lastUpdateTime = getTime()	-- TODO resetme upon resuming from a pause state
local needDrawCounter = 0
local needUpdateCounter = 0

local drawCounterNeededToRedraw = 1	-- 1 for single buffer,
--local drawCounterNeededToRedraw = 2 -- 2 for double buffer

-- TODO ypcall that is xpcall except ...
-- ... 1) error strings don't have source/line in them (that goes in backtrace)
-- ... 2) no error callback <-> default, which simply appends backtrace
-- ... 3) new debug.traceback() that includes that error line as the top line.
local function errorHandler(err)
	return err..'\n'..debug.traceback()
end
App.errorHandler = errorHandler

-- NOTICE NOTICE NOTICE (is this a sdl bug? or is this actually correct behavior)
-- IF YOU SET SDL_GL DOUBLEBUFFER=1 ... THEN IMMEDIATELY SET IT TO ZERO ... WHATEVER IT IS, IT ISNT SINGLE-BUFFER
-- INSTEAD I COPIED THE WHOLE SDL SET ATTRIBUTE SECTION AND CHANGED DOUBLEBUFFER THERE TO ALWAYS ONLY SET TO ZERO AND IT WORKS FINE.
-- [[ how come I can't disable double-buffering?
local sdlAssertZero = require 'sdl.assert'.zero
function App:sdlGLSetAttributes()
	--[=[
	-- I should be able to just call super (which sets everything ... incl doublebuffer=1) .. and then set it back to zero right?
	App.super.sdlGLSetAttributes(self)
	sdlAssertZero(sdl.SDL_GL_SetAttribute(sdl.SDL_GL_DOUBLEBUFFER, 0))
	-- ... but no, it seems some state info (drawbuffer?) is changed immediatley upon setting GL_DOUBLEBUFFER=1,
	-- and not when I expected it to be: when the window or the gl context is created.
	-- and the change is permanent and is not reset when you set back GL_DOUBLEBUFFER=0
	--]=]
	-- [=[ maybe sdl/gl doens't forget once you set it the first time?
	-- so here's a copy of GLApp:sdlGLSetAttributes but withotu setting double buffer ...
	sdlAssertZero(sdl.SDL_GL_SetAttribute(sdl.SDL_GL_RED_SIZE, 8))
	sdlAssertZero(sdl.SDL_GL_SetAttribute(sdl.SDL_GL_GREEN_SIZE, 8))
	sdlAssertZero(sdl.SDL_GL_SetAttribute(sdl.SDL_GL_BLUE_SIZE, 8))
	sdlAssertZero(sdl.SDL_GL_SetAttribute(sdl.SDL_GL_ALPHA_SIZE, 8))
	sdlAssertZero(sdl.SDL_GL_SetAttribute(sdl.SDL_GL_DEPTH_SIZE, 24))
	--sdlAssertZero(sdl.SDL_GL_SetAttribute(sdl.SDL_GL_DOUBLEBUFFER, 1))	-- THE ONE LINE I CHANGED ...
	if ffi.os == 'OSX' then
		local version = {4, 1}
		sdlAssertZero(sdl.SDL_GL_SetAttribute(sdl.SDL_GL_CONTEXT_MAJOR_VERSION, version[1]))
		sdlAssertZero(sdl.SDL_GL_SetAttribute(sdl.SDL_GL_CONTEXT_MINOR_VERSION, version[2]))
		sdlAssertZero(sdl.SDL_GL_SetAttribute(sdl.SDL_GL_CONTEXT_PROFILE_MASK, sdl.SDL_GL_CONTEXT_PROFILE_CORE))
		sdlAssertZero(sdl.SDL_GL_SetAttribute(sdl.SDL_GL_CONTEXT_FLAGS, sdl.SDL_GL_CONTEXT_FORWARD_COMPATIBLE_FLAG))
		sdlAssertZero(sdl.SDL_GL_SetAttribute(sdl.SDL_GL_ACCELERATED_VISUAL, 1))
	end
	--]=]
end
--]]

-- don't gl swap every frame - only do after draws
function App:postUpdate() end

function App:initGL()

	gl.glPixelStorei(gl.GL_UNPACK_ALIGNMENT, 1)

	--[[ getting single-buffer to work
	gl.glDrawBuffer(gl.GL_BACK)
	--]]

	self.ram = ffi.new'RAM'

	-- tic80 has a reset() function for resetting RAM data to original cartridge data
	-- pico8 has a reset function that seems to do something different: reset the color and console state
	-- but pico8 does support a reload() function for copying data from cartridge to RAM ... if you specify range of the whole ROM memory then it's the same (right?)
	-- but pico8 also supports cstore(), i.e. writing to sections of a cartridge while the code is running ... now we're approaching fantasy land where you can store disk quickly - didn't happen on old Apple2's ... or in the NES case where reading was quick, the ROM was just that so there was no point to allow writing and therefore no point to address both the ROM and the ROM's copy in RAM ...
	-- with all that said, 'cartridge' here will be inaccessble by my api except a reset() function
	self.cartridge = ffi.new'ROM'
	-- TODO maybe ... keeping separate 'ROM' and 'RAM' space?  how should the ROM be accessible? with a 0xC00000 (SNES)?
	-- and then 'save' would save the ROM to virtual-filesystem, and run() and reset() would copy the ROM to RAM
	-- and the editor would edit the ROM ...

	--DEBUG:print(RAM.code)
	--DEBUG:print('RAM size', ffi.sizeof(RAM))

	for _,field in ipairs(ROM.fields[2].type.fields) do
		assert(xpcall(function()
			asserteq(ffi.offsetof('ROM', field.name), ffi.offsetof('RAM', field.name))
		end, function(err)
			return errorHandler('for field '..field.name..'\n')
		end))
	end
	print'memory layout:'
	for _,field in ipairs(RAM.fields[2].type.fields) do
		local offset = ffi.offsetof('RAM', field.name)
		local size = ffi.sizeof(field.type)
		print(('0x%06x - 0x%06x = '):format(offset, offset + size)..field.name)
	end

	print('system dedicated '..('0x%x'):format(ffi.sizeof(self.ram))..' of RAM')

	--[[
	TODO use fixed-precision here ... or ... expose floating-precision poke/peeks? nahhh
	fixed precision 8.8 like SNES Mode7 uses?
	whatever it is, how to get it to work with my matrix_ffi library?  I could ...
	*) use float, and convert (might have weird precision issues in some places .. then again, double I'm convinced it's safe)
	*) make my own ffi.cdef struct with a custom mul ... use it for fixed-precision ...
	*) use int and shift bits after the fact ... no conversion errors ...
	float conversion one sounds best ...
	--]]
	self.mvMat = matrix_ffi({4,4}, 'float'):zeros():setIdent()
	self:mvMatToRAM()

	local View = require 'glapp.view'
	self.blitScreenView = View()
	self.blitScreenView.ortho = true
	self.blitScreenView.orthoSize = 1

	--[[
	when will this loop?
	uint8 <=> 255 frames @ 60 fps = 4.25 seconds
	uint16 <=> 65536 frames = 1092.25 seconds = 18.2 minutes
	uint24 <=> 279620.25 frames = 4660.3 seconds = 77.7 minutes = 1.3 hours
	uint32 <=> 2147483647 frames = 35791394.1 seconds = 596523.2 minutes = 9942.1 hours = 414.3 days = 13.7 months = 1.1 years
	... and does it even matter if it loops?  if people store 'timestamps' and subtract,
	then these time constraints (or half of them for signed) will give you the maximum delta-time capable of being stored.
	--]]
	self.ram.updateCounter = 0
	self.ram.romUpdateCounter = 0

	-- TODO soooo tempting to treat 'app' as a global
	-- It would cut down on *all* these glue functions
	self.env = {
		-- filesystem functions ...
		ls = function(...) return self.fs:ls(...) end,
		dir = function(...) return self.fs:ls(...) end,
		cd = function(...) return self.fs:cd(...) end,
		mkdir = function(...) return self.fs:mkdir(...) end,
		-- console API (TODO make console commands separate of the Lua API ... or not ...)

-- TODO just use drawText
-- and then implement auto-scroll
-- none of this console buffering crap
		print = function(...) return self.con:print(...) end,
		--write = function(...) return self.con:write(...) end,
		trace = _G.print,

		run = function(...) return self:runROM(...) end,
		stop = function(...) return self:stop(...) end,
		cont = function(...) return self:cont(...) end,
		save = function(...) return self:save(...) end,
		load = function(...)
			local result = table.pack(self:loadROM(...))
			if self.server then
				-- TODO consider order of events
				-- this is goign to sendRAM to all clients
				-- but it's executed mid-frame on the server, while server is building a command-buffer
				-- where will deltas come into play?
				-- how about new-frame messages too?
				for _,serverConn in ipairs(self.server.conns) do
					self.server:sendRAM(serverConn)
				end
			end
			return result:unpack()
		end,
		reset = function(...)
			local result = table.pack(self:resetROM(...))

			-- TODO this or can I get by
			-- 1) backing up the client's cartridge state upon load() then ...
			-- 2) ... upon client reset() just copy that over?
			-- fwiw the initial sendRAM doesn't include the cartridge state, just the RAM state ...
			if self.server then
				for _,serverConn in ipairs(self.server.conns) do
					self.server:sendRAM(serverConn)
				end
			end
			return result:unpack()
		end,
		quit = function(...) self:requestExit() end,

		listen = function(...) return self:listen(...) end,
		connect = function(...) return self:connect(...) end,
		disconnect = function(...) return self:disconnect(...) end,

		-- timer
		time = function()
			return self.ram.romUpdateCounter * updateIntervalInSeconds
		end,

		-- pico8 has poke2 as word, poke4 as dword
		-- tic80 has poke2 as 2bits, poke4 as 4bits
		-- I will leave bit operations up to the user, but for ambiguity rename my word and dword into pokew and pokel
		-- signed or unsigned? unsigned.
		peek = function(addr) return self:peek(addr) end,
		peekw = function(addr) return self:peekw(addr) end,
		peekl = function(addr) return self:peekl(addr) end,
		poke = function(addr, value) return self:net_poke(addr, value) end,
		pokew = function(addr, value) return self:net_pokew(addr, value) end,
		pokel = function(addr, value) return self:net_pokel(addr, value) end,

		-- why does tic-80 have mget/mset like pico8 when tic-80 doesn't have pget/pset or sget/sset ...
		mget = function(...) return self:mget(...) end,
		mset = function(x, y, value) return self:net_mset(x, y, value) end,

		-- graphics

		-- fun fact, if the API calls cls() it clears with color zero
		-- but color zero is a game color, not an editor color, that'd be color 240
		-- but at the moment the console is routed to directly call the API,
		-- so if you type "cls" at the console then you could get a screen full of some nonsense color
		flip = coroutine.yield,	-- simple as
		cls = function(colorIndex)
			colorIndex = colorIndex or 0
			if self.server then
				local cmd = self.server:pushCmd().clearScreen
				cmd.type = netcmds.clearScreen
				cmd.colorIndex = colorIndex
			end
			self:clearScreen(colorIndex)
		end,

		-- TODO tempting to just expose flags for ellipse & border to the 'cartridge' api itself ...
		rect = function(x, y, w, h, colorIndex)
			if self.server then
				local cmd = self.server:pushCmd().solidRect
				cmd.type = netcmds.solidRect
				cmd.x = x
				cmd.y = y
				cmd.w = w
				cmd.h = h
				cmd.colorIndex = colorIndex
				cmd.borderOnly = false
				cmd.round = false
			end
			return self:drawSolidRect(x, y, w, h, colorIndex, false, false)
		end,
		rectb = function(x, y, w, h, colorIndex)
			if self.server then
				local cmd = self.server:pushCmd().solidRect
				cmd.type = netcmds.solidRect
				cmd.x = x
				cmd.y = y
				cmd.w = w
				cmd.h = h
				cmd.colorIndex = colorIndex
				cmd.borderOnly = true
				cmd.round = false
			end
			return self:drawSolidRect(x, y, w, h, colorIndex, true, false)
		end,
		-- choosing tic80's api naming here.  but the rect api: width/height, not radA/radB
		elli = function(x, y, w, h, colorIndex)
			if self.server then
				local cmd = self.server:pushCmd().solidRect
				cmd.type = netcmds.solidRect
				cmd.x = x
				cmd.y = y
				cmd.w = w
				cmd.h = h
				cmd.colorIndex = colorIndex
				cmd.borderOnly = false
				cmd.round = true
			end
			return self:drawSolidRect(x, y, w, h, colorIndex, false, true)
		end,
		ellib = function(x, y, w, h, colorIndex)
			if self.server then
				local cmd = self.server:pushCmd().solidRect
				cmd.type = netcmds.solidRect
				cmd.x = x
				cmd.y = y
				cmd.w = w
				cmd.h = h
				cmd.colorIndex = colorIndex
				cmd.borderOnly = true
				cmd.round = true
			end
			return self:drawSolidRect(x, y, w, h, colorIndex, true, true)
		end,

		tri = function(x1,y1,x2,y2,x3,y3,colorIndex)
			if self.server then
				local cmd = self.server:pushCmd().solidTri
				cmd.type = netcmds.solidLine
				cmd.x1 = x1
				cmd.y1 = y1
				cmd.x2 = x2
				cmd.y2 = y2
				cmd.x3 = x3
				cmd.y3 = y3
				cmd.colorIndex = colorIndex
			end
			return self:drawSolidTri(x1,y1,x2,y2,x3,y3,colorIndex)
		end,

		tri3d = function(x1,y1,z1,x2,y2,z2,x3,y3,z3,colorIndex)
			if self.server then
				local cmd = self.server:pushCmd().solidTri3D
				cmd.type = netcmds.solidLine
				cmd.x1 = x1
				cmd.y1 = y1
				cmd.z1 = z1
				cmd.x2 = x2
				cmd.y2 = y2
				cmd.z2 = z2
				cmd.x3 = x3
				cmd.y3 = y3
				cmd.z3 = z3
				cmd.colorIndex = colorIndex
			end
			return self:drawSolidTri3D(x1,y1,z1,x2,y2,z2,x3,y3,z3,colorIndex)
		end,

		line = function(x1,y1,x2,y2,colorIndex)
			if self.server then
				local cmd = self.server:pushCmd().solidLine
				cmd.type = netcmds.solidLine
				cmd.x1 = x1
				cmd.y1 = y1
				cmd.x2 = x2
				cmd.y2 = y2
				cmd.colorIndex = colorIndex
			end
			return self:drawSolidLine(x1,y1,x2,y2,colorIndex)
		end,

		line3d = function(x1,y1,z1,x2,y2,z2,colorIndex)
			if self.server then
				local cmd = self.server:pushCmd().solidLine3D
				cmd.type = netcmds.solidLine3D
				cmd.x1 = x1
				cmd.y1 = y1
				cmd.z1 = z1
				cmd.x2 = x2
				cmd.y2 = y2
				cmd.z2 = z2
				cmd.colorIndex = colorIndex
			end
			return self:drawSolidLine3D(x1,y1,z1,x2,y2,z2,colorIndex)
		end,

		spr = function(spriteIndex, screenX, screenY, spritesWide, spritesHigh, paletteIndex, transparentIndex, spriteBit, spriteMask, scaleX, scaleY)
			if self.server then
				-- TODO I'm calculating default values twice ...
				-- TODO move the server netcmd stuff into a separate intermediate function
				-- TODO same with all the drawSolidRect stuff
				spritesWide = spritesWide or 1
				spritesHigh = spritesHigh or 1
				scaleX = scaleX or 1
				scaleY = scaleY or 1
				-- vram / sprite sheet is 32 sprites wide ... 256 pixels wide, 8 pixels per sprite
				spriteIndex = math.floor(spriteIndex)
				local tx = spriteIndex % spriteSheetSizeInTiles.x
				local ty = (spriteIndex - tx) / spriteSheetSizeInTiles.x

				paletteIndex = paletteIndex or 0
				transparentIndex = transparentIndex or -1
				spriteBit = spriteBit or 0
				spriteMask = spriteMask or 0xFF

				local cmd = self.server:pushCmd().quad
				cmd.type = netcmds.quad
				cmd.x = screenX
				cmd.y = screenY
				cmd.w = spritesWide * spriteSize.x * scaleX
				cmd.h = spritesHigh * spriteSize.y * scaleY
				cmd.tx = tx / tonumber(spriteSheetSizeInTiles.x)
				cmd.ty = ty / tonumber(spriteSheetSizeInTiles.y)
				cmd.tw = spritesWide / tonumber(spriteSheetSizeInTiles.x)
				cmd.th = spritesHigh / tonumber(spriteSheetSizeInTiles.y)
				cmd.paletteIndex = paletteIndex
				cmd.transparentIndex = transparentIndex
				cmd.spriteBit = spriteBit
				cmd.spriteMask = spriteMask
			end
			return self:drawSprite(spriteIndex, screenX, screenY, spritesWide, spritesHigh, paletteIndex, transparentIndex, spriteBit, spriteMask, scaleX, scaleY)
		end,

		-- TODO maybe maybe not expose this? idk?  tic80 lets you expose all its functionality via spr() i think, though maybe it doesn't? maybe this is only pico8 equivalent sspr? or pyxel blt() ?
		quad = function(x, y, w, h, tx, ty, tw, th, paletteIndex, transparentIndex, spriteBit, spriteMask)
			if self.server then
				paletteIndex = paletteIndex or 0
				transparentIndex = transparentIndex or -1
				spriteBit = spriteBit or 0
				spriteMask = spriteMask or 0xFF

				local cmd = self.server:pushCmd().quad
				cmd.type = netcmds.quad
				cmd.x, cmd.y, cmd.w, cmd.h = x, y, w, h
				cmd.tx, cmd.ty, cmd.tw, cmd.th = tx, ty, tw, th
				cmd.paletteIndex = paletteIndex
				cmd.transparentIndex = transparentIndex
				cmd.spriteBit = spriteBit
				cmd.spriteMask = spriteMask
			end
			return self:drawQuad(x, y, w, h, tx, ty, tw, th, self.spriteTex, paletteIndex, transparentIndex, spriteBit, spriteMask)
		end,
		-- TODO make draw16Sprites a poke'd value
		map = function(tileX, tileY, tilesWide, tilesHigh, screenX, screenY, mapIndexOffset, draw16Sprites)
			if self.server then
				tilesWide = tilesWide or 1
				tilesHigh = tilesHigh or 1
				mapIndexOffset = mapIndexOffset or 0
				local cmd = self.server:pushCmd().map
				cmd.type = netcmds.map
				cmd.tileX, cmd.tileY, cmd.tilesWide, cmd.tilesHigh = tileX, tileY, tilesWide, tilesHigh
				cmd.screenX, cmd.screenY = screenX, screenY
				cmd.mapIndexOffset = mapIndexOffset
				cmd.draw16Sprites = draw16Sprites or false
			end
			return self:drawMap(tileX, tileY, tilesWide, tilesHigh, screenX, screenY, mapIndexOffset, draw16Sprites)
		end,
		text = function(text, x, y, fgColorIndex, bgColorIndex, scaleX, scaleY)
			if self.server then
				x = x or 0
				y = y or 0
				fgColorIndex = fgColorIndex or 13
				bgColorIndex = bgColorIndex or 0
				scaleX = scaleX or 1
				scaleY = scaleY or 1

				local cmd = self.server:pushCmd().text
				cmd.type = netcmds.text
				cmd.x, cmd.y = x, y
				cmd.fgColorIndex = fgColorIndex
				cmd.bgColorIndex = bgColorIndex
				cmd.scaleX, cmd.scaleY = scaleX, scaleY
				ffi.copy(cmd.text, text, math.min(#text+1, ffi.sizeof(cmd.text)))
			end
			return self:drawText(text, x, y, fgColorIndex, bgColorIndex, scaleX, scaleY)
		end,		-- (text, x, y, fgColorIndex, bgColorIndex)

		mode = function(videoMode)
			-- for net play's sake ,how about just doing a peek/poke?
			self:net_poke(ffi.offsetof('RAM', 'videoMode'), videoMode)
		end,

		clip = function(...)
			local x, y, w, h
			if select('#', ...) == 0 then
				x, y, w, h = 0, 0, 0xff, 0xff
			else
				asserteq(select('#', ...), 4)
				x, y, w, h = ...
			end
			if self.server then
				local cmd = self.server:pushCmd().clipRect
				cmd.type = netcmds.clipRect
				cmd.x = x
				cmd.y = y
				cmd.w = w
				cmd.h = h
			end
			self:setClipRect(x, y, w, h)
		end,

		-- for now, like clipRect, you gotta do this through the game API for it to work, not by directly writing to RAM like mode()
		-- why? because mode can change modes fine between frames, but blend and clip have to change gl state between draw calls
		blend = function(blendMode)
			blendMode = blendMode or 0xff
			if self.server then
				local cmd = self.server:pushCmd().blendMode
				cmd.type = netcmds.blendMode
				cmd.blendMode = blendMode
			end

			self.ram.blendMode = blendMode or 0xff
			blendMode = self.ram.blendMode

			self:setBlendMode(blendMode)
		end,

		-- me cheating and exposing opengl modelview matrix functions:
		-- matident mattrans matrot matscale matortho matfrustum matlookat
		-- matrix math because i'm cheating
		matident = function()
			if self.server then
				local cmd = self.server:pushCmd().matident
				cmd.type = netcmds.matident
			end
			self:matident()
		end,
		mattrans = function(x, y, z)
			x = x or 0
			y = y or 0
			z = z or 0
			if self.server then
				local cmd = self.server:pushCmd().mattrans
				cmd.type = netcmds.mattrans
				cmd.x, cmd.y, cmd.z = x, y, z
			end
			self:mattrans(x, y, z)
		end,
		matrot = function(theta, x, y, z)
			x = x or 0
			y = y or 0
			z = z or 1
			if self.server then
				local cmd = self.server:pushCmd().matrot
				cmd.type = netcmds.matrot
				cmd.theta, cmd.x, cmd.y, cmd.z = theta, x, y, z
			end
			self:matrot(theta, x, y, z)
		end,
		matscale = function(x, y, z)
			x = x or 1
			y = y or 1
			z = z or 1
			if self.server then
				local cmd = self.server:pushCmd().matscale
				cmd.type = netcmds.matscale
				cmd.x, cmd.y, cmd.z = x, y, z
			end
			self:matscale(x, y, z)
		end,
		matortho = function(l, r, t, b, n, f)
			n = n or -1000
			f = f or 1000
			if self.server then
				local cmd = self.server:pushCmd().matortho
				cmd.type = netcmds.matortho
				cmd.l, cmd.r, cmd.t, cmd.b, cmd.n, cmd.f = l, r, t, b, n, f
			end
			self:matortho(l, r, t, b, n, f)
		end,
		matfrustum = function(l, r, t, b, n, f)
			if self.server then
				local cmd = self.server:pushCmd().matfrustum
				cmd.type = netcmds.matfrustum
				cmd.l, cmd.r, cmd.t, cmd.b, cmd.n, cmd.f = l, r, t, b, n, f
			end
			self:matfrustum(l, r, t, b, n, f)
		end,
		matlookat = function(ex, ey, ez, cx, cy, cz, upx, upy, upz)
			if self.server then
				local cmd = self.server:pushCmd().matlookat
				cmd.type = netcmds.matlookat
				cmd.ex, cmd.ey, cmd.ez, cmd.cx, cmd.cy, cmd.cz, cmd.upx, cmd.upy, cmd.upz = ex, ey, ez, cx, cy, cz, upx, upy, upz
			end
			self:matlookat(ex, ey, ez, cx, cy, cz, upx, upy, upz)
		end,

		sfx = function(sfxID, channelIndex, pitch, volL, volR, looping)
			if self.server then
				channelIndex = channelIndex or -1
				pitch = pitch or 0x1000
				volL = volL or 0xff
				volR = volR or 0xff
				local cmd = self.server:pushCmd().sfx
				cmd.type = assert(netcmds.sfx)
				cmd.sfxID, cmd.channelIndex, cmd.pitch, cmd.volL, cmd.volR, cmd.looping = sfxID, channelIndex, pitch, volL, volR, looping
			end
			self:playSound(sfxID, channelIndex, pitch, volL, volR, looping)
		end,

		music = function(musicID, musicPlayingIndex, channelOffset)
			if self.server then
				musicID = math.floor(musicID or -1)
				musicPlayingIndex = musicPlayingIndex or 0
				channelOffset = channelOffset or 0
				local cmd = self.server:pushCmd().music
				cmd.type = assert(netcmds.music)
				cmd.musicID, cmd.musicPlayingIndex, cmd.channelOffset = musicID, musicPlayingIndex, channelOffset
			end
			self:playMusic(musicID, musicPlayingIndex, channelOffset)
		end,

		-- this just falls back to glapp saving the OpenGL draw buffer
		screenshot = function() return self:screenshotToFile'ss.png' end,

		-- TODO tempting to do like pyxel and just remove key/keyp and only use btn/btnp, and just lump the keyboard flags in after the player joypad button flags
		key = function(...) return self:key(...) end,
		keyp = function(...) return self:keyp(...) end,
		keyr = function(...) return self:keyr(...) end,

		btn = function(...) return self:btn(...) end,
		btnp = function(...) return self:btnp(...) end,
		btnr = function(...) return self:btnr(...) end,

		-- TODO merge mouse buttons with btpn as well so you get added fnctionality of press/release detection
		mouse = function(...) return self:mouse(...) end,

		bit = bit,
		math = require 'ext.math',
		table = require 'ext.table',
		string = require 'ext.string',
		coroutine = coroutine,	-- TODO need a threadmanager ...
		tstamp = os.time,

		tostring = tostring,
		tonumber = tonumber,
		select = select,
		type = type,
		error = error,
		assert = assert,
		next = next,
		pairs = pairs,
		ipairs = ipairs,
		getmetatable = getmetatable,
		setmetatable = setmetatable,

		-- TODO don't let the ROM see the App...
		app = self,
		ffi = ffi,
		getfenv = getfenv,
		setfenv = setfenv,
		_G = _G,
	}

--[[ debugging - trace all calls
local oldenv = self.env
self.env = setmetatable({
}, {
	__index = function(t,k)
		--print('get env.'..k..'()')
		local v = oldenv[k]
		if type(v) == 'function' then
			-- return *another* trace wrapper
			return function(...)
				print('call env.'..k..'('..table{...}:mapi(tostring):concat', '..')')
				return v(...)
			end
		else
			return v
		end
	end,
})
--]]


	-- modify let our env use special operators
	-- this will modify the env's load xpcall etc
	-- so let's try to do this without modifying _G or our global env
	-- but also without exposing load() to the game api ... then again why not?
	self.loadenv = setmetatable({
		-- it is going to modify `package`, so lets give it a dummy copy
		-- in fact TODO all this needs to be replaced for virtual filesystem stuff or not at all ...
		package = {
			searchpath = package.searchpath,
			-- replace this or else langfix.env will modify the original require()
			searchers = table(package.searchers or package.loaders):setmetatable(nil),
			path = package.path,
			cpath = package.cpath,
			loaded = {},
		},
		require = function(...)
			error"require not implemented"
		end,
	}, {
		--[[ don't do this, the game API self.env.load messes with our Lua load() override
		__index = self.env,
		--]]
		-- [[
		__index = _G,
		--]]
	})

--[[
print()
print'before'
print('xpcall', xpcall)
print('require', require)
print('load', load)
print('dofile', dofile)
print('loadfile', loadfile)
print('loadstring', loadstring)
print('package', package)
print('package.searchpath', package.searchpath)
print('package.searchers', package.searchers)
for i,v in ipairs(package.searchers) do
	print('package.searchers['..i..']', v)
end
print('package.path', package.path)
print('package.cpath', package.cpath)
print('package.loaded', package.loaded)
--]]

-- [[ using langfix
	self.langfixState = require 'langfix.env'(self.loadenv)
--asserteq(self.loadenv.langfix, self.langfixState)
	self.env.langfix = self.loadenv.langfix	-- so langfix can do its internal calls
--]]
--[[ not using it
	self.loadenv.load = load
--]]

--[[ debugging side-effects of langfix / what I didn't properly setup in self.loadenv ...
print()
print'after'
print('xpcall', xpcall)
print('require', require)
print('load', load)
print('dofile', dofile)
print('loadfile', loadfile)
print('loadstring', loadstring)
print('package', package)
print('package.searchpath', package.searchpath)
print('package.searchers', package.searchers)
for i,v in ipairs(package.searchers) do
	print('package.searchers['..i..']', v)
end
print('package.path', package.path)
print('package.cpath', package.cpath)
print('package.loaded', package.loaded)
--]]


	self:initDraw()

	-- keyboard init
	-- make sure our keycodes are in bounds
	for sdlSym,keyCode in pairs(sdlSymToKeyCode) do
		if not (keyCode >= 0 and math.floor(keyCode/8) < keyPressFlagSize) then
			error('got oob keyCode '..keyCode..' named '..(keyCodeNames[keyCode+1])..' for sdlSym '..sdlSym)
		end
	end

	-- TODO use this for setFocus as well, so you don't have to call resume so often?
	self.threads = ThreadManager()

	self:initAudio()

	-- filesystem init

	FileSystem = require 'numo9.filesystem'
	self.fs = FileSystem{app=self}
	-- copy over a local filetree somewhere in the app ...
	for fn in path:dir() do
		if select(2, fn:getext()) == 'n9'
		or (select(2, fn:getext()) == 'png'
			and select(2, fn:getext():getext()) == 'n9')
		then
			self.fs:addFromHost(fn.path)
		end
	end

	-- editor init

	self.screenMousePos = vec2i()	-- host coordinates ... don't put this in RAM

	-- TODO app.editMode is the field name, app.activeMenu is the value, merge these two ...
	self.editMode = 'code'	-- matches up with UI's editMode's

	local EditCode = require 'numo9.editcode'
	local EditSprites = require 'numo9.editsprites'
	local EditTilemap = require 'numo9.edittilemap'
	local EditSFX = require 'numo9.editsfx'
	local EditMusic = require 'numo9.editmusic'
	local Console = require 'numo9.console'
	local MainMenu = require 'numo9.mainMenu'

	self:runInEmu(function()
		self:resetView()	-- reset mat and clip
		self.editCode = EditCode{app=self}
		self.editSprites = EditSprites{app=self}
		self.editTilemap = EditTilemap{app=self}
		self.editSFX = EditSFX{app=self}
		self.editMusic = EditMusic{app=self}
		self.con = Console{app=self}
		self.mainMenu = MainMenu{app=self}
	end)

	-- load config if it exists
	xpcall(function()
		if self.cfgpath:exists() then
			self.cfg = fromlua(assert(self.cfgpath:read()))
		end
	end, function(err)
		print('failed to read lua from file '..tostring(self.cfgpath)..'\n'
			..tostring(err)..'\n'
			..debug.traceback())
	end)


	-- initialize config or any of its properties if they were missing
	local function setdefault(t,k,v)
		if t[k] == nil then t[k] = v end
	end

	setdefault(self, 'cfg', {})
	setdefault(self.cfg, 'volume', 255)

	-- notice on my osx, even 'localhost' and '127.0.0.1' aren't interchangeable
	-- TODO use a proper ip ...
	setdefault(self.cfg, 'serverListenAddr', 'localhost')
	setdefault(self.cfg, 'serverListenPort', tostring(Server.defaultListenPort))
	setdefault(self.cfg, 'lastConnectAddr', 'localhost')	-- TODO ... eh ... LAN search?  idk
	setdefault(self.cfg, 'lastConnectPort', tostring(Server.defaultListenPort))
	setdefault(self.cfg, 'playerInfos', {})
	for i=1,maxLocalPlayers do
		setdefault(self.cfg.playerInfos, i, {})
		-- for netplay, shows up in the net menu
		setdefault(self.cfg.playerInfos[i], 'name', i == 1 and 'steve' or '')
		setdefault(self.cfg.playerInfos[i], 'buttonBinds', {})
	end
	setdefault(self.cfg, 'screenButtonRadius', 10)

	-- this is for server netplay, it says who to associate this conn's player with
	-- it is convenient to put it here ... but is it information worth saving?
	setdefault(self.cfg.playerInfos[1], 'localPlayer', 1)
	-- fake-gamepad key bindings
	--[[
Some default keys options:
	Snes9x	ZSNES	LibRetro
A	D		X		X
B	C		Z		Z
X	S		S		S
Y	X		A		A
L	A/V		D		Q
R	Z		C		W
looks like I'm a Snes9x-default-keybinding fan.
	--]]
	setdefault(self.cfg.playerInfos[1].buttonBinds, buttonCodeForName.up, {768, 1073741906, name="keyUp"})
	setdefault(self.cfg.playerInfos[1].buttonBinds, buttonCodeForName.down, {768, 1073741905, name="keyDown"})
	setdefault(self.cfg.playerInfos[1].buttonBinds, buttonCodeForName.left, {768, 1073741904, name="keyLeft"})
	setdefault(self.cfg.playerInfos[1].buttonBinds, buttonCodeForName.right, {768, 1073741903, name="keyRight"})
	setdefault(self.cfg.playerInfos[1].buttonBinds, buttonCodeForName.a, {768, ('s'):byte(), name="keyS"})
	setdefault(self.cfg.playerInfos[1].buttonBinds, buttonCodeForName.b, {768, ('x'):byte(), name="keyX"})
	setdefault(self.cfg.playerInfos[1].buttonBinds, buttonCodeForName.x, {768, ('a'):byte(), name="keyA"})
	setdefault(self.cfg.playerInfos[1].buttonBinds, buttonCodeForName.y, {768, ('z'):byte(), name="keyZ"})

	-- can have 3 more ... at least I've only allocated enough for 4 players worth of keys ...
	-- and right now netplay operates by reflecting keys and draw-commands ...


-- setFocus has been neglected ...
-- ... this will cause the menu to open once its done playing
-- TODO I need a good boot screen or something ...
-- [[
	self:setFocus{
		thread = coroutine.create(function()
			local env = self.env
			-- set state to paused initially
			-- then if we get a loadROM command it'll unpause
			-- or if we get a setmenu command in init this will remain paused and not kick us back to console when this finishes
			--self.isPaused = true
			-- HOWEVER doing this makes it so starting to the console requires TWO ESCAPE (one to stop this startup) to enter the main menu ...
			-- the trade off is that when this finishes, even if it got another load cmd in .initCmd, it still waits to finish and kicks to console even though another rom is loaded
			-- I could work around *that too* with a yield after load here ...
			-- edge case behavior getting too out of hand yet?

			self:resetGFX()		-- needed to initialize UI colors
			self.con:reset()	-- needed for palette .. tho its called in init which is above here ...
			--[[ print or so something cheesy idk
			--for i=1,30 do env.flip() end
			for i=0,15 do
				self.con.fgColor = bit.bor(0xf0,i)	-- bg = i, fg = i + 15 at the moemnt thanks to the font.png storage ...
				self.con.bgColor = bit.bor(0xf0,bit.band(0xf,i+1))
				self.con:print'hello world'
				--for i=1,3 do env.flip() end
			end
			self.con.fgColor = 0xfc			-- 11 = bg, 12 = fg
			self.con.bgColor = 0xf0
			--]]

			-- also for init, do the splash screen
			numo9_video.resetLogoOnSheet(self.ram.tileSheet)
			self.tileTex.dirtyCPU = true
			for j=0,31 do
				for i=0,31 do
					env.mset(i, j, bit.bor(
						i,
						bit.lshift(j, 5)
					))
				end
			end

			for sleep=1,60 do
				env.flip()
			end

			-- do splash screen fanfare ...
			local s = ('NuMo9=-\t '):rep(3)
			--local s = ('9'):rep(27)
			local colors = range(0xf1, 0xfe)
			for t=0,63+#s do		-- t = time = leading diagonal
				env.cls()
				for i=t,0,-1 do		-- i = across all diagonals so far
					for j=0,i do	-- j = along diagonal
						local x = bit.lshift(i-j, 3)
						local y = bit.lshift(j, 3)
						--env.blend(1)	-- average
						env.matident()
						env.mattrans(x+4, y+4)
						local r = ((t-i)/16 + .5)*2*math.pi
						env.matrot(r)
						local w = 2*math.exp(-((t- i+ 4)/30)^2)
						env.matscale(w, w)
						env.mattrans(-4, -4)
						self:drawSolidRect(0,0,8,8, colors[(i+1)%#colors+1])
						local l = t - i + 1
						env.blend(2)	-- subtract
						self:drawText(s:sub(l,l),1,0,0xf7,-1)
						env.matident()
						env.blend(2)	-- subtract
						-- if I draw this as a sprite then I can draw as a low bpp and shift the palette ...
						-- if I draw it as a tilemap then I can use the upper 4 bits of the tilemap entries for shifting the palette ...
						self:drawMap(0, 0, 32, 32, 0, 0, 0, false)
						env.blend(-1)
					end
				end
				--[[ pause and watch
				for i=0,3 do
					env.flip()
					if env.keyp'space' then
						env.flip()
						repeat
							env.flip()
						until env.keyp'space'
					end
				end
				--]]
				-- [[
				if bit.band(t,3) == 0 then env.flip() end
				--]]
			end
			env.flip()

			-- and clear the tilemap now that we're done with it
			ffi.fill(self.ram.tileSheet, ffi.sizeof(self.ram.tileSheet))
			ffi.fill(self.ram.tilemap, ffi.sizeof(self.ram.tilemap))
			self.tileTex.dirtyCPU = true

			-- assign to console
			self:setMenu(self.con)

			-- how to make it start with console open if there's no rom ...
			-- then run our cmdline file ... ?
			if cmdline[1] then
				self:loadROM(cmdline[1])
				self:runROM()
			end

			-- then let us run cmds
			if cmdline.initCmd then
print('running cmd', cmdline.initCmd)
				self:runCmd(cmdline.initCmd)
			end

			-- yield before quit in case initCmd or load has a better runFocus and we dont need to end-thread and drop to console
			env.flip()
		end),
	}
--]]
end

function App:exit()
	self.cfgpath:write(tolua(self.cfg, {indent=true}))

	App.super.exit(self)
end

-------------------- ENV NETPLAY LAYER --------------------
-- when I don't want to write server cmds twice
-- leave the :(not net_)functionName stuff for the client to also call and not worry about requesting another server refresh
--  (tho the client shouldnt have a server and that shouldnt happen anyways)

-- TODO what's the best way to cast to int in luajit ... floor() ? ffi.cast('int') ? ffi.new('int') ? bit.bor(0) ?
local function toint(x)
	--return bit.bor(x, 0)	-- seems nice but I think it rounds instead of truncates ...
	return ffi.cast('int32_t', x)	-- use int32 so Lua has no problem with it
end

function App:net_poke(addr, value)
	-- TODO hwy not move the server test down into App:poke() istelf? meh? idk
	if self.server then
		-- spare us reocurring messages
		addr = toint(addr)
		value = toint(value)
		if self:peek(addr) ~= value then
			local cmd = self.server:pushCmd().poke
			cmd.type = netcmds.poke
			cmd.addr = addr
			cmd.value = value
			cmd.size = 1
		end
	end
	return self:poke(addr, value)
end

function App:net_pokew(addr, value)
	if self.server then
		addr = toint(addr)
		value = toint(value)
		if self:peekw(addr) ~= value then
			local cmd = self.server:pushCmd().poke
			cmd.type = netcmds.poke
			cmd.addr = addr
			cmd.value = value
			cmd.size = 2
		end
	end
	return self:pokew(addr, value)
end

function App:net_pokel(addr, value)
	if self.server then
		addr = toint(addr)
		value = toint(value)
		if self:peekl(addr) ~= value then
			local cmd = self.server:pushCmd().poke
			cmd.type = netcmds.poke
			cmd.addr = addr
			cmd.value = value
			cmd.size = 4
		end
	end
	return self:pokel(addr, value)
end

function App:net_mset(x, y, value)
	x = toint(x)
	y = toint(y)
	value = toint(value)
	if x >= 0 and x < tilemapSize.x
	and y >= 0 and y < tilemapSize.y
	then
		local index = x + tilemapSize.x * y
		-- use poke over netplay, cuz i'm lazy.
		-- I'm thinking poke is slower than mset singleplayer because it has more dirty GPU tests
		if self.server then
			if self.ram.tilemap[index]~=value then
				local cmd = self.server:pushCmd().poke
				cmd.type = netcmds.poke
				cmd.addr = tilemapAddr + bit.lshift(index, 1)
				cmd.value = value
				cmd.size = 2
			end
		end
		self.ram.tilemap[index] = value
		self.mapTex.dirtyCPU = true
	end
end

-------------------- LOCAL ENV API --------------------

function App:mget(x, y)
	x = toint(x)
	y = toint(y)
	if x >= 0 and x < tilemapSize.x
	and y >= 0 and y < tilemapSize.y
	then
		-- should I use peek so we make sure to flush gpu->cpu?
		-- nah, right now we only have framebuffer to check for gpu-writes ...
		-- and the framebuffer is not (yet?) relocatable
		return self.ram.tilemap[x + tilemapSize.x * y]
	end
	-- TODO return default oob value
	return 0
end

-------------------- MULTIPLAYER --------------------

-- stop all client and server stuff from going on
function App:disconnect()
	if self.server then
		self.con:print('closing server ...')
		self.server:close()
		self.server = nil
	end
	if self.remoteClient then
		self.con:print('disconnecting from server ...')
		self.remoteClient:close()
		self.remoteClient = nil
	end
end

-- server listen
function App:listen()
	self:disconnect()

	-- listens upon init
	self.server = Server(self)
end

-- client connect
-- TODO save addr and port in config also, for next time you connect?
function App:connect(addr, port)
	self:disconnect()

	-- clear set run focus before connecting so the connection's initial update of the framebuffer etc wont get dirtied by a loseFocus() from the last runFocus
	self:setFocus()

	self.remoteClient = ClientConn{
		app = self,
		playerInfos = self.cfg.playerInfos,
		addr = assert(addr, "expected addr"),

		-- default to the system default port, not the configured server listen port
		-- since odds are wherever you're connecting is using the default
		-- TODO silent default, or error?  same as in Server:init
		port = tonumber(port) or Server.defaultListenPort,

		fail = function(...)
			print('connect fail', ...)
		end,
		success = function(...)
			print('connect success', ...)
		end,
	}

	-- and now that we've hopefully recieved the initial RAM state ...
	-- ... set the focus to the remoteClient so that its thread can handle net updates (and con won't)
	-- TODO what happens if a remote client pushes escape to exit to its own console?  the game will go out of sync ...
	-- how about (for now) ESC = kill connection ... sounds dramatic ... but meh?
print('app:setFocus(remoteClient)')
	self:setFocus(self.remoteClient)
assert(self.runFocus == self.remoteClient)
	if not self.runFocus.thread then
		-- failed to connect?
		self.con:print'failed to connect'
		self.runFocus = nil
		self.remoteClient = nil
		return nil, 'failed to connect'
	end
assert(coroutine.status(self.runFocus.thread) ~= 'dead')
	self:setMenu(nil)
	return true
end

-------------------- MAIN UPDATE CALLBACK --------------------

function App:update()
	App.super.update(self)

	if self.currentVideoMode ~= self.ram.videoMode then
		self:setVideoMode(self.ram.videoMode)
	end

	-- update threadpool, clients or servers
	self.threads:update()

	local thisTime = getTime()

--[==[ per-second-tick debug display
	-- ... now that I've moved the swap out of the parent class and only draw on dirty bit, this won't show useful information
	-- TODO get rid of double-buffering.  you've got the framebuffer.
	local deltaTime = thisTime - lastTime
	fpsFrames = fpsFrames + 1
	fpsSeconds = fpsSeconds + deltaTime
	if fpsSeconds > 1 then
		print(
		--	'FPS: '..(fpsFrames / fpsSeconds)	--	this will show you how fast a busy loop runs ... 130,000 hits/second on my machine ... should I throw in some kind of event to lighten the cpu load a bit?
		--	'draws/second '..drawsPerSecond	-- TODO make this single-buffered
			'channels active '..range(0,7):mapi(function(i) return self.ram.channels[i].flags.isPlaying end):concat' '
			..' tracks active '..range(0,7):mapi(function(i) return self.ram.musicPlaying[i].isPlaying end):concat' '
			..' SDL_GetQueuedAudioSize', sdl.SDL_GetQueuedAudioSize(self.audio.deviceID)
		)
		if self.server then
			--[[
docs say:
	master:getstats()
	client:getstats()
	server:getstats()
but error says:
	self.server.socket	tcp{server}: 0x119b958e8
	./numo9/app.lua:923: calling 'getstats' on bad self (tcp{client} expected)
... does this mean :getstats() does not work on tcp server sockets?
			if self.server.socket then
print('self.server.socket', self.server.socket)
				io.write('server sock '..require'ext.tolua'(self.server.socket:getstats())..' ')
			end
			--]]
-- [[ show server's last delta
print'DELTA'
print(
	string.hexdump(
		ffi.string(
			ffi.cast('char*', self.server.frames[1].deltas.v),
			#self.server.frames[1].deltas * ffi.sizeof(self.server.frames[1].deltas.type)
		), nil, 2
	)
)
--]]
-- [[ show server's last render state:
print'STATE'
print(
	string.hexdump(
		ffi.string(
			ffi.cast('char*', self.server.frames[1].cmds.v),
			#self.server.frames[1].cmds * ffi.sizeof'Numo9Cmd'
		), nil, 2
	)
)
--]]
			io.write('net frames='..#self.server.frames..' ')
			io.write(' cmds/frame='..#((self.server.frames[1] or {}).cmds or {})..' ')
			io.write(' deltas/sec='..tostring(self.server.numDeltasSentPerSec)..' ')
			io.write(' idlechecks/sec='..tostring(self.server.numIdleChecksPerSec)..' ')
self.server.numDeltasSentPerSec = 0
self.server.numIdleChecksPerSec = 0
			if self.server.conns[1] then
				local conn = self.server.conns[1]
				io.write('serverconn stats '..require'ext.tolua'{self.server.conns[1].socket:getstats()}
					..' msgs='..#conn.toSend
					..' sized='..#conn.toSend:concat()
					..' send/sec='..conn.sendsPerSecond
					..' recv/sec='..conn.receivesPerSecond
				)
conn.sendsPerSecond = 0
conn.receivesPerSecond = 0
			end
			io.write(' conn updates: '..self.server.updateConnCount..' ')
			self.server.updateConnCount = 0
		end
		if self.remoteClient then
			io.write('client cmdbuf size: '..self.remoteClient.cmds.size)
		end
		if self.server or self.remoteClient then
			print()
		end

		drawsPerSecond = 0
		fpsFrames = 0
		fpsSeconds = 0
	end
	lastTime = thisTime	-- TODO this at end of update in case someone else needs this var
	--]==]

	if thisTime > lastUpdateTime + updateIntervalInSeconds then
		-- [[ doing this means we need to reset lastUpdateTime when resuming from the app being paused
		-- and indeed the in-console fps first readout is high (67), then drops back down to 60 consistently
		lastUpdateTime = lastUpdateTime + updateIntervalInSeconds
		--]]
		--[[ doing this means we might lose fractions of time resolution during our updates
		-- and indeed the in-console fps bounces between 59 and 60
		lastUpdateTime = thisTime
		--]]
		-- TODO increment so that we can have frame drops to keep framerate
		-- but I guess this can snowball or something idk
		-- on my system I'm getting 2400 fps so I think this'll be no problem
		needUpdateCounter = 1
	end

	if needUpdateCounter > 0 then
		-- TODO decrement to use framedrops
		needUpdateCounter = 0

		-- [[ where should I even put this?  in here to make sure runs once per frame
		-- outside the 1/60 block to make sure it runs as often as possible?
		self:updateAudio()
		--]]

		-- system update refresh timer
		self.ram.updateCounter = self.ram.updateCounter + 1
		self.ram.romUpdateCounter = self.ram.romUpdateCounter + 1


		-- tell netplay we have a new frame
		if self.server then
			self.server:beginFrame()
		end

		-- update input between frames
		do
			self.ram.lastMousePos:set(self.ram.mousePos:unpack())
			sdl.SDL_GetMouseState(self.screenMousePos.s, self.screenMousePos.s+1)
			local x1, x2, y1, y2, z1, z2 = self.blitScreenView:getBounds(self.width / self.height)
			local x = tonumber(self.screenMousePos.x) / tonumber(self.width)
			local y = tonumber(self.screenMousePos.y) / tonumber(self.height)
			x = x1 * (1 - x) + x2 * x
			y = y1 * (1 - y) + y2 * y
			x = x * .5 + .5
			y = y * .5 + .5
			self.ram.mousePos.x = x * tonumber(frameBufferSize.x)
			self.ram.mousePos.y = y * tonumber(frameBufferSize.y)
			if self:keyp'mouse_left' then
				self.ram.lastMousePressPos:set(self.ram.mousePos:unpack())
			end
		end

		-- flush any cpu changes to gpu before updating
		self.fbTex:checkDirtyCPU()

		local fb = self.fb
		fb:bind()
		self.inUpdateCallback = true	-- tell 'runInEmu' not to set up the fb:bind() to do gfx stuff
		gl.glViewport(0,0,frameBufferSize:unpack())
		gl.glEnable(gl.GL_SCISSOR_TEST)
		gl.glScissor(
			self.ram.clipRect[0],
			self.ram.clipRect[1],
			self.ram.clipRect[2]+1,
			self.ram.clipRect[3]+1)
		-- see if we need to re-enable it ...
		if self.ram.blendMode ~= 0xff then
			self:setBlendMode(self.ram.blendMode)
		end

		-- run the cartridge thread
		local runFocus = self.runFocus
		if runFocus then
			local thread = runFocus.thread
			if thread
			and not self.isPaused
			then
				if coroutine.status(thread) == 'dead' then
print('cartridge thread dead')
					self:setFocus(nil)
					-- if the cart dies it's cuz of an exception (right?) so best to show the console (right?)
					self:setMenu(self.con)
				else
					local success, msg = coroutine.resume(thread)
					if not success then
						print(msg)
						print(debug.traceback(thread))
						self.con:print(msg)
						-- TODO these errors are a good argument for scrollback console buffers
						-- they're also a good argument for coroutines (though speed might be an argument against coroutines)
					end
				end
			end
		else
			-- nothign in focus , let the console know by drawing some kind of background pattern ... or meh ...
			self:clearScreen(0xf0)
		end

		-- now run the console and editor, separately, if it's open
		-- this way server can issue console commands while the game is running
		gl.glDisable(gl.GL_BLEND)

		-- TODO don't use a table, and don't use an inline lambda
		local function updateThread(thread)
			if not thread then return end
			gl.glDisable(gl.GL_SCISSOR_TEST)
			self.mvMat:setIdent()
			if coroutine.status(thread) == 'dead' then
				self:setMenu(nil)
				return
			end
			local success, msg = coroutine.resume(thread)
			if not success then
				if thread == self.con.thread then
					print'CONSOLE THREAD ERROR'
				end
				print(msg)
				print(debug.traceback(thread))
				if thread == self.con.thread then
					self.con:resetThread()	-- this could become a negative feedback loop...
				end
				self.con:print(msg)
			end
		end
		if self.activeMenu then updateThread(self.activeMenu.thread) end

		self:mvMatFromRAM()

		self.inUpdateCallback = false
		fb:unbind()

		-- update vram to gpu every frame?
		-- or nah, how about I only do when dirty bit set?
		-- so this copies CPU changes -> GPU changes
		-- TODO nothing is copying the GPU back to CPU after we do our sprite renders ...
		-- double TODO I don't have framebuffer memory

		if self.server then
			self.server:endFrame()
		end

	--[[
	TODO ... upload framebuf, download framebuf after
	that'll make sure graphics stays in synx
	and then if I do that here (and every other quad:draw())
	 then there's no longer a need to do that at the update loop
	 unless someone poke()'s mem
	 then I should introduce dirty bits
	and I should be testing those dirty bits here to see if I need to upload here
	... or just write my own rasterizer
	or
	dirty bits both directions
	cpuDrawn = flag 'true' if someone touches fb vram
	gpuDrawn = flag 'true' in any of these GL calls
	... then in both cases ...
		if someone poke()'s vram, test gpu dirty, if set then copy to cpu
		if someone draw()'s here, test cpu dirty, if set then upload here
	... though honestly, i'm getting 5k fps with and without my per-frame-gpu-uploads ...
		I'm suspicious that doing a few extra GPU uploads here before and after sceneObj:draw()  might not make a difference...
	--]]
		-- increment hold counters
		-- TODO do this here or before update() ?
		do
			local holdptr = self.ram.keyHoldCounter
			for keycode=0,keyCount-1 do
				local bi = bit.band(keycode, 7)
				local by = bit.rshift(keycode, 3)
	--DEBUG:assert(by >= 0 and by < keyPressFlagSize)
				local keyFlag = bit.lshift(1, bi)
				local down = 0 ~= bit.band(self.ram.keyPressFlags[by], keyFlag)
				local lastDown = 0 ~= bit.band(self.ram.lastKeyPressFlags[by], keyFlag)
				if down and lastDown then
					holdptr[0] = holdptr[0] + 1
				else
					holdptr[0] = 0
				end
				holdptr = holdptr + 1
			end
		end

		-- copy last key buffer to key buffer here after update()
		-- so that sdl event can populate changes to current key buffer while execution runs outside this callback
		ffi.copy(self.ram.lastKeyPressFlags, self.ram.keyPressFlags, keyPressFlagSize)

--print('press flags', (ffi.string(self.ram.lastKeyPressFlags, keyPressFlagSize):gsub('.', function(ch) return ('%02x'):format(ch:byte()) end)))
--print('mouse_left', self:key'mouse_left')

		-- do this every frame or only on updates?
		-- how about no more than twice after an update (to please the double-buffers)
		-- TODO don't do it unless we've changed the framebuffer since the last draw
		-- 	so any time fbTex is modified (wherever dirtyCPU/GPU is set/cleared), also set a changedSinceDraw=true flag
		-- then here test for that flag and only re-increment 'needDraw' if it's set
		if self.fbTex.changedSinceDraw then
			self.fbTex.changedSinceDraw = false
			needDrawCounter = drawCounterNeededToRedraw
		end
	end

	if needDrawCounter > 0 then
		needDrawCounter = needDrawCounter - 1
		drawsPerSecond = drawsPerSecond + 1

		-- for mode-1 8bpp-indexed video mode - we will need to flush the palette as well, before every blit too
		if self.ram.videoMode == 1 then
			self.palTex:checkDirtyCPU()
		end

		gl.glDisable(gl.GL_SCISSOR_TEST)
		gl.glViewport(0, 0, self.width, self.height)
		gl.glClearColor(.1, .2, .3, 1.)
		gl.glClear(bit.bor(gl.GL_COLOR_BUFFER_BIT, gl.GL_DEPTH_BUFFER_BIT))

	-- [[ redo ortho projection matrix
	-- every frame for us to use a proper rectangle
		local view = self.blitScreenView
		local orthoSize = view.orthoSize
		local wx, wy = self.width, self.height
		if wx > wy then
			local rx = wx / wy
			view.projMat:setOrtho(
				-orthoSize * (rx - 1) / 2,
				orthoSize * (((rx - 1) / 2) + 1),
				orthoSize,
				0,
				-1,
				1
			)
		else
			local ry = wy / wx
			view.projMat:setOrtho(
				0,
				orthoSize,
				orthoSize * (((ry - 1) / 2) + 1),
				-orthoSize * (ry - 1) / 2,
				-1,
				1
			)
		end
		view.mvMat:setIdent()
		view.mvProjMat:mul4x4(view.projMat, view.mvMat)
		local sceneObj = self.blitScreenObj
		sceneObj.uniforms.mvProjMat = view.mvProjMat.ptr
--]]

		-- draw from framebuffer to screen
		sceneObj:draw()
		-- [[ and swap ... or just don't use backbuffer at all ...
		sdl.SDL_GL_SwapWindow(self.window)
		--]]
	end
--DEBUG:require 'gl.report' 'here'
end

-------------------- MEMORY PEEK/POKE (and draw dirty bits) --------------------

function App:peek(addr)
	if addr < 0 or addr >= ffi.sizeof(self.ram) then return end

	-- if we're writing to a dirty area then flush it to cpu
	-- assume the GL framebuffer is bound to the fbTex
	if self.fbTex.dirtyGPU and addr >= framebufferAddr and addr < framebufferAddrEnd then
		self.fbTex:checkDirtyGPU()
	end

	return self.ram.v[addr]
end
function App:peekw(addr)
	local addrend = addr+1
	if addr < 0 or addrend >= ffi.sizeof(self.ram) then return end

	if self.fbTex.dirtyGPU and addrend >= framebufferAddr and addr < framebufferAddrEnd then
		self.fbTex:checkDirtyGPU()
	end

	return ffi.cast('uint16_t*', self.ram.v + addr)[0]
end
function App:peekl(addr)
	local addrend = addr+3
	if addr < 0 or addrend >= ffi.sizeof(self.ram) then return end

	if self.fbTex.dirtyGPU and addrend >= framebufferAddr and addr < framebufferAddrEnd then
		self.fbTex:checkDirtyGPU()
	end

	return ffi.cast('uint32_t*', self.ram.v + addr)[0]
end

function App:poke(addr, value)
	--addr = math.floor(addr) -- TODO just never pass floats in here or its your own fault
	if addr < 0 or addr >= ffi.sizeof(self.ram) then return end

	-- if we're writing to a dirty area then flush it to cpu
	-- assume the GL framebuffer is bound to the fbTex
	if self.fbTex.dirtyGPU and addr >= framebufferAddr and addr < framebufferAddrEnd then
		self.fbTex:checkDirtyGPU()
		self.fbTex.dirtyCPU = true
	end

	self.ram.v[addr] = tonumber(value)

	-- TODO none of the others happen period, only the palette texture
	-- makes me regret DMA exposure of my palette ... would be easier to just hide its read/write behind another function...
	if addr >= spriteSheetAddr and addr < spriteSheetAddrEnd then
		-- TODO if we ever allow redirecting the framebuffer ... to overlap the spritesheet ... then checkDirtyGPU() here too
		self.spriteTex.dirtyCPU = true
	end
	if addr >= tileSheetAddr and addr < tileSheetAddrEnd then
		self.tileTex.dirtyCPU = true
	end
	if addr >= tilemapAddr and addr < tilemapAddrEnd then
		self.mapTex.dirtyCPU = true
	end
	-- a few options with dirtying palette entries
	-- 1) consolidate calls, so write this separately in pokew and pokel
	-- 2) dirty flag, and upload pre-draw.  but is that for uploading all the palette pre-draw?  or just the range of dirty entries?  or just the individual entries (multiple calls again)?
	--   then before any render that uses palette, check dirty flag, and if it's set then re-upload
	if addr >= paletteAddr and addr < paletteAddrEnd then
		self.palTex.dirtyCPU = true
	end
	-- TODO if we poked the code
	if addr >= framebufferAddr and addr < framebufferAddrEnd then
		self.fbTex.dirtyCPU = false
	end
end
function App:pokew(addr, value)
	local addrend = addr+1
	if addr < 0 or addrend >= ffi.sizeof(self.ram) then return end

	if self.fbTex.dirtyGPU and addrend >= framebufferAddr and addr < framebufferAddrEnd then
		self.fbTex:checkDirtyGPU()
		self.fbTex.dirtyCPU = true
	end

	ffi.cast('uint16_t*', self.ram.v + addr)[0] = tonumber(value)

	if addrend >= spriteSheetAddr and addr < spriteSheetAddrEnd then
		self.spriteTex.dirtyCPU = true
	end
	if addrend >= tileSheetAddr and addr < tileSheetAddrEnd then
		self.tileTex.dirtyCPU = true
	end
	if addrend >= tilemapAddr and addr < tilemapAddrEnd then
		self.mapTex.dirtyCPU = true
	end
	if addrend >= paletteAddr and addr < paletteAddrEnd then
		self.palTex.dirtyCPU = true
	end
	-- TODO if we poked the code
	if addrend >= framebufferAddr and addr < framebufferAddrEnd then
		self.fbTex.dirtyCPU = false
	end
end
function App:pokel(addr, value)
	local addrend = addr+3
	if addr < 0 or addrend >= ffi.sizeof(self.ram) then return end

	if self.fbTex.dirtyGPU and addrend >= framebufferAddr and addr < framebufferAddrEnd then
		self.fbTex:checkDirtyGPU()
		self.fbTex.dirtyCPU = true
	end

	ffi.cast('uint32_t*', self.ram.v + addr)[0] = tonumber(value)

	if addrend >= spriteSheetAddr and addr < spriteSheetAddrEnd then
		self.spriteTex.dirtyCPU = true
	end
	if addrend >= tileSheetAddr and addr < tileSheetAddrEnd then
		self.tileTex.dirtyCPU = true
	end
	if addrend >= tilemapAddr and addr < tilemapAddrEnd then
		self.mapTex.dirtyCPU = true
	end
	if addrend >= paletteAddr and addr < paletteAddrEnd then
		self.palTex.dirtyCPU = true
	end
	-- TODO if we poked the code
	if addrend >= framebufferAddr and addr < framebufferAddrEnd then
		self.fbTex.dirtyCPU = false
	end
end

-------------------- ROM STATE STUFF --------------------

-- initialize our projection to framebuffer size
-- do this every time we run a new rom
function App:resetView()
	self.mvMat:setIdent()
	packptr(4, self.ram.clipRect, 0, 0, 0xff, 0xff)
end

-- save from cartridge to filesystem
function App:save(filename)
--	self:checkDirtyGPU()

	-- flush that back to .cartridge ...
	-- ... or not? idk.  handle this by the editor?
	--ffi.copy(self.cartridge.v, self.ram.v, ffi.sizeof'ROM')
	-- TODO self.ram vs self.cartridge ... editor puts .cartridge into .ram before editing
	-- or at least it used to ... now with multiplayer editing idk even ...

	-- and then that to the virtual filesystem ...
	-- and then that to the real filesystem ...

	local n = #self.editCode.text
	assertlt(n+1, codeSize)
--print('saving code', self.editCode.text, 'size', n)
	ffi.copy(self.cartridge.code, self.editCode.text, n)
	self.cartridge.code[n] = 0	-- null term

	if not select(2, path(filename):getext()) then
		filename = path(filename):setext'n9'.path
		-- TODO try twice? as .n9 and .n9.png?  or don't add extensions at all?
	end
	filename = filename or defaultSaveFilename
	local basemsg = 'failed to save file '..tostring(filename)

	-- TODO xpcall?
	local toCartImage = require 'numo9.archive'.toCartImage
	local success, s = xpcall(
		toCartImage,
		errorHandler,
		self.cartridge
	)
	if not success then
print('save failed:', basemsg..(s or ''))
		return nil, basemsg..(s or '')
	end

	-- [[ do I bother implement fs:open'w' ?
	local f, msg = self.fs:create(filename)
	if not f then
print('save failed:', basemsg..' fs:create failed: '..msg)
		return nil, basemsg..' fs:create failed: '..msg
	end
	f.data = s
	--]]

	-- [[ while we're here, also save to filesystem
	local success2, msg = path(filename):write(s)
	if not success2 then
		print('warning: filesystem backup write to '..tostring(filename)..' failed')
	end
	--]]

	return true
end

--[[
Load from filesystem to cartridge
then call resetROM which loads
TODO maybe ... have the editor modify the cartridge copy as well
(this means it wouldn't live-update palettes and sprites, since they are gathered from RAM
	... unless I constantly copy changes across as the user edits ... maybe that's best ...)
(or it would mean upon entering editor to copy the cartridge back into RAM, then edit as usual (live updates on palette and sprites)
	and then when done editing, copy back from RAM to cartridge)
--]]
function App:loadROM(filename)
	-- if there was an old ROM loaded then write its persistent data ...
	self:writePersistent()

	filename = filename or defaultSaveFilename
	self.con:print('loading', filename)
	local basemsg = 'failed to load file '..tostring(filename)

	local f
	local checked = table()
	for _,suffix in ipairs{'', '.n9', '.n9.png'} do
		local checkfn = filename..suffix
		checked:insert(checkfn)
		f = self.fs:get(checkfn)
		if f then break end
		f = nil
	end
	if not f then return nil, basemsg..': failed to find file.  checked '..checked:concat', ' end

	-- [[ do I bother implement fs:open'r' ?
	local d = f.data
	local msg = not d and 'is not a file' or nil
	--]]
	if not d then return nil, basemsg..(msg or '') end

	local fromCartImage = require 'numo9.archive'.fromCartImage
	self.cartridge = fromCartImage(d)

	self.cartridgeName = filename	-- TODO display this somewhere
	self:resetROM()
	return true
end

function App:writePersistent()
	--if not self.cartridgeName then return end	-- should not I bother if there's no cartridge loaded? or still allow saving of persistent data if ppl are messing around on the editor?
	self.cfg.persistent = self.cfg.persistent or {}

	-- TODO this when you read cart header ... or should we put it in ROM somewhere?
	self.cartridgeSaveID = self.cartridgeSaveID or ''--md5(self.cartridge.v, ffi.sizeof'ROM')

	-- save a string up to the last non-zero value ... opposite  of C-strings
	local len = persistentCartridgeDataSize
	while len > 0 do
		if self.ram.persistentCartridgeData[len-1] ~= 0 then break end
		len = len - 1
	end
	if len > 0 then
		self.cfg.persistent[self.cartridgeSaveID] = ffi.string(self.ram.persistentCartridgeData, len)
	end
end

--[[
This resets everything from the last loaded .cartridge ROM into .ram
Equivalent of loading the previous ROM again.
That means code too - save your changes!
--]]
function App:resetROM()
	ffi.copy(self.ram.v, self.cartridge.v, ffi.sizeof'ROM')
	self:resetVideo()

	-- calling reset() live will kill all sound ...
	-- ... unless I move resetAudio() into load()
	return true
end

-- returns the function to run the code
function App:loadCmd(cmd, env, source)
	-- Lua is wrapping [string "  "] around my source always ...
	return self.loadenv.load(cmd, source, 't', env or self.env)
end

-- system() function
-- TODO fork this between console functions and between running "rom" code
function App:runCmd(cmd)
	--[[ suppress always
	local f, msg = self:loadCmd(cmd)
	if not f then return f, msg end
	return xpcall(f, errorHandler)
	--]]
	-- [[ error always
	local result = table.pack(assert(self:loadCmd(
		cmd,
		-- TODO if there's a cartridge loaded then why not use its env, for debugging eh?
		--self.gameEnv or -- would be nice but gameEnv doesn't have langfix, i.e. self.env
		self.env,
		'con'
	))())
	-- print without newline ...
	for i=1,result.n do
		if i>1 then self.con:write'\t' end
		self.con:write(tostring(result[i]))
	end
	print(result:unpack())
	--assert(result:unpack())
	return result:unpack()
	--]]
end

-- TODO ... welp what is editor editing?  the cartridge?  the virtual-filesystem disk image?
-- once I figure that out, this should make sure the cartridge and RAM have the correct changes
function App:runROM()
	self:resetROM()
	self:resetAudio()
	self.isPaused = false
	self:setMenu(nil)

	-- TODO setfenv instead?
	local env = setmetatable({}, {
		__index = self.env,
	})

	local code = ffi.string(self.ram.code, self.codeSize)	-- TODO max size on this ...
	local i = code:find('\0', 1, true)
	if i then code = code:sub(1, i-1) end
--DEBUG:print'**** GOT CODE ****'
--DEBUG:print(require 'template.showcode'(code))
--DEBUG:print('**** CODE LEN ****', #code)
--DEBUG:print('code is', #code, 'bytes')

	-- TODO also put the load() in here so it runs in our virtual console update loop
	env.thread = coroutine.create(function()
		self.ram.romUpdateCounter = 0
		self:resetView()

		-- here, if the assert fails then it's an (ugly) parse error, and you can just pcall / pick out the offender
		local f = assert(self:loadCmd(code, env, self.cartridgeName))
		local result = table.pack(f())

--DEBUG:print('LOAD RESULT', result:unpack())
--DEBUG:print('RUNNING CODE')
--DEBUG:print('update:', env.update)

		if not env.update then return end
		while true do
			coroutine.yield()
			env.update()
		end
	end)

	-- save the cartridge's last-env for console support until next ... idk what function should clear the console env?
	self.gameEnv = env

	self:setFocus(env)
end

-- set the focus of whats running ... between the cartridge, the console, or the emulator
-- TODO this whole system got split up between the rom's env as runFocus, and the activeMenu - now both can exist simultaneously
function App:setFocus(focus)
	if self.runFocus then
		if self.runFocus.loseFocus then self.runFocus:loseFocus() end
	end
	self.runFocus = focus
	if self.runFocus then
		if self.runFocus.gainFocus then self.runFocus:gainFocus() end
	end
end

-- can the menu and editor coexist?
-- should the menu be one of these?
-- (menu & gameplay can coexist ... editor & gameplay can coexist ...)
function App:setMenu(editTab)
	if self.activeMenu and self.activeMenu.loseFocus then
		self.activeMenu:loseFocus()
	end
	self.activeMenu = editTab
	if self.activeMenu and self.activeMenu.gainFocus then
		self.activeMenu:gainFocus()
	end
end

function App:stop()
	self.isPaused = true
	coroutine.yield()
end

function App:cont()
	self.isPaused = false
	self:setFocus(self.gameEnv)
end

-- run but make sure the vm is set up
-- esp the framebuffer
-- TODO might get rid of this now that i just upload cpu->gpu the vram every frame
function App:runInEmu(cb, ...)
	if not self.inUpdateCallback then
		self.fb:bind()
		gl.glViewport(0, 0, frameBufferSize.x, frameBufferSize.y)
		gl.glScissor(
			self.ram.clipRect[0],
			self.ram.clipRect[1],
			self.ram.clipRect[2]+1,
			self.ram.clipRect[3]+1)
	end
	-- TODO if we're in the update callback then maybe we'd want to push/pop the viewport and scissors?
	-- meh I'll leave that up to the callback

	cb(...)

	if not self.inUpdateCallback then
		self.fb:unbind()
	end
end

-------------------- INPUT HANDLING --------------------

function App:keyForBuffer(keycode, buffer)
	local bi = bit.band(keycode, 7)
	local by = bit.rshift(keycode, 3)
	if by < 0 or by >= keyPressFlagSize then return end
	local keyFlag = bit.lshift(1, bi)
	return bit.band(buffer[by], keyFlag) ~= 0
end

function App:key(keycode)
	if type(keycode) == 'string' then
		keycode = assertindex(keyCodeForName, keycode, 'keyCodeForName')
	end
	asserttype(keycode, 'number')
	return self:keyForBuffer(keycode, self.ram.keyPressFlags)
end

-- tic80 has the option that no args = any button pressed ...
function App:keyp(keycode, hold, period)
	if type(keycode) == 'string' then
		keycode = keyCodeForName[keycode]
	end
	asserttype(keycode, 'number')
	keycode = math.floor(keycode)	-- or cast int? which is faster?
	if keycode < 0 or keycode >= keyCount then return end
	if hold and period
	and self.ram.keyHoldCounter[keycode] >= hold
	and not (period > 0 and self.ram.keyHoldCounter[keycode] % period > 0) then
		return self:keyForBuffer(keycode, self.ram.keyPressFlags)
	end
	return self:keyForBuffer(keycode, self.ram.keyPressFlags)
	and not self:keyForBuffer(keycode, self.ram.lastKeyPressFlags)
end

-- pyxel had this idea, pico8 and tic80 don't have it
function App:keyr(keycode)
	if type(keycode) == 'string' then
		keycode = keyCodeForName[keycode]
	end
	asserttype(keycode, 'number')
	return not self:keyForBuffer(keycode, self.ram.keyPressFlags)
	and self:keyForBuffer(keycode, self.ram.lastKeyPressFlags)
end

-- TODO - just use key/p/r, and just use extra flags
-- TODO dont use keyboard keycode for determining fake-joypad button keycode
-- instead do this down in the SDL event handling ...
function App:btn(buttonCode, player, ...)
	if type(buttonCode) == 'string' then
		buttonCode = buttonCodeForName[buttonCode]
	end
	asserttype(buttonCode, 'number')
	if buttonCode < 0 or buttonCode >= 8 then return end
	player = player or 0
	if player < 0 or player >= maxLocalPlayers then return end
	local keyCode = self.cfg.playerInfos[player+1].buttonBinds[buttonCode]
	if not keyCode then return end
	local buttonKeyCode = buttonCode + 8 * player + firstJoypadKeyCode
	return self:key(buttonKeyCode, ...)
end
function App:btnp(buttonCode, player, ...)
	if type(buttonCode) == 'string' then
		buttonCode = buttonCodeForName[buttonCode]
	end
	asserttype(buttonCode, 'number')
	if buttonCode < 0 or buttonCode >= 8 then return end
	player = player or 0
	if player < 0 or player >= maxLocalPlayers then return end
	local keyCode = self.cfg.playerInfos[player+1].buttonBinds[buttonCode]
	if not keyCode then return end
	local buttonKeyCode = buttonCode + 8 * player + firstJoypadKeyCode
	return self:keyp(buttonKeyCode, ...)
end
function App:btnr(buttonCode, player, ...)
	if type(buttonCode) == 'string' then
		buttonCode = buttonCodeForName[buttonCode]
	end
	asserttype(buttonCode, 'number')
	if buttonCode < 0 or buttonCode >= 8 then return end
	player = player or 0
	if player < 0 or player >= maxLocalPlayers then return end
	local keyCode = self.cfg.playerInfos[player+1].buttonBinds[buttonCode]
	if not keyCode then return end
	local buttonKeyCode = buttonCode + 8 * player + firstJoypadKeyCode
	return self:keyr(buttonKeyCode, ...)
end

function App:mouse()
	return
		self.ram.mousePos.x,
		self.ram.mousePos.y,
		0,	-- TODO scrollX
		0	-- TODO scrollY
end

function App:event(e)
	if e[0].type == sdl.SDL_KEYUP
	or e[0].type == sdl.SDL_KEYDOWN
	then
		local down = e[0].type == sdl.SDL_KEYDOWN
		self:processButtonEvent(down, sdl.SDL_KEYDOWN, e[0].key.keysym.sym)

		local sdlsym = e[0].key.keysym.sym
		if down
		and sdlsym == sdl.SDLK_ESCAPE
		then
			-- special handle the escape key
			-- game -> escape -> console
			-- console -> escape -> editor
			-- editor -> escape -> console
			-- ... how to cycle back to the game without resetting it?
			-- ... can you not issue commands while the game is loaded without resetting the game?
			if self.waitingForEvent then
				-- if key config is waiting for this event then let it handle it ... it'll clear the binding
				-- already handled probably
				-- TODO need a last-down for ESC (tho i'm not tracking it in the virt console key state stuff ... cuz its not supposed to be accessible by the cartridge code)
				-- TODO why does sdl handle multiple keydowns for single keyups?
			elseif self.activeMenu == self.mainMenu then
				-- [[ go to game?
				self:setMenu(nil)
				self.isPaused = false
				if not self.runFocus then
					self:setMenu(self.con)
				end
				--]]
			elseif self.activeMenu == self.con then
				--[[ con -> editor?
				self:setMenu(self.editCode)
				--]]
				-- [[ con -> game if it's available ?
				if self.runFocus then
					self:setMenu(nil)
					self.isPaused = false
				else
				--]]
				-- [[ con -> menu?
					self.mainMenu:open()
				--]]
				end
			elseif self.activeMenu then
				self:setMenu(nil)
				-- [[ editor -> game?
				if not self.server then
					-- ye ol fps behavior: console + single-player implies pause, console + multiplayer doesn't
					-- TODO what about single-player who types 'stop()' and 'cont()' at the console?  meh, redundant cmds.
					--  the cmds still serve a purpose in single-player for the game to use if it wan't i guess ...
					self.isPaused = false
					if not self.runFocus then
						self:setMenu(self.con)
					end
				end
				--]]
			else
				-- assume it's a game pushing esc ...
				-- go to the menu
				self:setMenu(nil)
				self.mainMenu:open()
				if not self.server then
					self.isPaused = true
				end
			end
		else
			local keycode = sdlSymToKeyCode[sdlsym]
			if keycode then
				local bi = bit.band(keycode, 7)
				local by = bit.rshift(keycode, 3)
				local flag = bit.lshift(1, bi)
				local mask = bit.bnot(flag)
				self.ram.keyPressFlags[by] = bit.bor(
					bit.band(mask, self.ram.keyPressFlags[by]),
					down and flag or 0
				)
			end
		end
	elseif e[0].type == sdl.SDL_MOUSEBUTTONDOWN
	or e[0].type == sdl.SDL_MOUSEBUTTONUP
	then
		local down = e[0].type == sdl.SDL_MOUSEBUTTONDOWN
		self:processButtonEvent(down, sdl.SDL_MOUSEBUTTONDOWN, tonumber(e[0].button.x)/self.width, tonumber(e[0].button.y)/self.height, e[0].button.button)

		local keycode
		if e[0].button.button == sdl.SDL_BUTTON_LEFT then
			keycode = keyCodeForName.mouse_left
		elseif e[0].button.button == sdl.SDL_BUTTON_MIDDLE then
			keycode = keyCodeForName.mouse_middle
		elseif e[0].button.button == sdl.SDL_BUTTON_RIGHT then
			keycode = keyCodeForName.mouse_right
		end
		if keycode then
			local bi = bit.band(keycode, 7)
			local by = bit.rshift(keycode, 3)
			local flag = bit.lshift(1, bi)
			local mask = bit.bnot(flag)
			self.ram.keyPressFlags[by] = bit.bor(
				bit.band(mask, self.ram.keyPressFlags[by]),
				down and flag or 0
			)
		end
	elseif e[0].type == sdl.SDL_JOYHATMOTION then
		for i=0,3 do
			local dirbit = bit.lshift(1,i)
			local press = bit.band(dirbit, e[0].jhat.value) ~= 0
			self:processButtonEvent(press, sdl.SDL_JOYHATMOTION, e[0].jhat.which, e[0].jhat.hat, dirbit)
		end
	elseif e[0].type == sdl.SDL_JOYAXISMOTION then
		-- -1,0,1 depend on the axis press
		local lr = math.floor(3 * (tonumber(e[0].jaxis.value) + 32768) / 65536) - 1
		local press = lr ~= 0
		if not press then
			-- clear both left and right movement
			self:processButtonEvent(press, sdl.SDL_JOYAXISMOTION, e[0].jaxis.which, e[0].jaxis.axis, -1)
			self:processButtonEvent(press, sdl.SDL_JOYAXISMOTION, e[0].jaxis.which, e[0].jaxis.axis, 1)
		else
			-- set movement for the lr direction
			self:processButtonEvent(press, sdl.SDL_JOYAXISMOTION, e[0].jaxis.which, e[0].jaxis.axis, lr)
		end
	elseif e[0].type == sdl.SDL_JOYBUTTONDOWN or e[0].type == sdl.SDL_JOYBUTTONUP then
		-- e[0].jbutton.mainMenu is 0/1 for up/down, right?
		local press = e[0].type == sdl.SDL_JOYBUTTONDOWN
		self:processButtonEvent(press, sdl.SDL_JOYBUTTONDOWN, e[0].jbutton.which, e[0].jbutton.button)
	elseif e[0].type == sdl.SDL_CONTROLLERAXISMOTION then
		-- -1,0,1 depend on the axis press
		local lr = math.floor(3 * (tonumber(e[0].caxis.value) + 32768) / 65536) - 1
		local press = lr ~= 0
		if not press then
			-- clear both left and right movement
			self:processButtonEvent(press, sdl.SDL_CONTROLLERAXISMOTION, e[0].caxis.which, e[0].jaxis.axis, -1)
			self:processButtonEvent(press, sdl.SDL_CONTROLLERAXISMOTION, e[0].caxis.which, e[0].jaxis.axis, 1)
		else
			-- set movement for the lr direction
			self:processButtonEvent(press, sdl.SDL_CONTROLLERAXISMOTION, e[0].caxis.which, e[0].jaxis.axis, lr)
		end
	elseif e[0].type == sdl.SDL_CONTROLLERBUTTONDOWN or e[0].type == sdl.SDL_CONTROLLERBUTTONUP then
		local press = e[0].type == sdl.SDL_CONTROLLERBUTTONDOWN
		self:processButtonEvent(press, sdl.SDL_CONTROLLERBUTTONDOWN, e[0].cbutton.which, e[0].cbutton.button)
	elseif e[0].type == sdl.SDL_FINGERDOWN or e[0].type == sdl.SDL_FINGERUP then
		local press = e[0].type == sdl.SDL_FINGERDOWN
		self:processButtonEvent(press, sdl.SDL_FINGERDOWN, e[0].tfinger.x, e[0].tfinger.y)
	end
end

function App:processButtonEvent(down, ...)
	-- TODO radius per-button
	local buttonRadius = self.width * self.cfg.screenButtonRadius

	-- TODO put the callback somewhere, not a global
	-- it's used by the New Game menu
	if self.waitingForEvent then
		-- this callback system is only used for editing keyboard binding
		if down then
			local ev = {...}
			ev.name = self:getEventName(...)
			self.waitingForEvent.callback(ev)
			self.waitingForEvent = nil
		end
	else
		-- this branch is only used in gameplay
		-- for that reason, if we're not in the gameplay menu-state then bail
		--if not PlayingMenu:isa(self.mainMenu) then return end
		local etype, ex, ey = ...
		local descLen = select('#', ...)
		for playerIndexPlusOne, playerInfo in ipairs(self.cfg.playerInfos) do
			local playerIndex = playerIndexPlusOne-1
			for buttonIndex, buttonBind in pairs(playerInfo.buttonBinds) do
				-- special case for mouse/touch, test within a distanc
				local match = descLen == #buttonBind
				if match then
					local istart = 1
					-- special case for mouse/touch, click within radius ...
					if etype == sdl.SDL_MOUSEBUTTONDOWN
					or etype == sdl.SDL_FINGERDOWN
					then
						match = etype == buttonBind[1]
						if match then
							local dx = (ex - buttonBind[2]) * self.width
							local dy = (ey - buttonBind[3]) * self.height
							if dx*dx + dy*dy >= buttonRadius*buttonRadius then
								match = false
							end
							-- skip the first 2 for values
							istart = 4
						end
					end
					if match then
						for i=istart,descLen do
							if select(i, ...) ~= buttonBind[i] then
								match = false
								break
							end
						end
					end
				end
				if match then
					local buttonCode = buttonIndex + bit.lshift(playerIndex, 3)
					local keycode = buttonCode + firstJoypadKeyCode
					local bi = bit.band(keycode, 7)
					local by = bit.rshift(keycode, 3)
					local flag = bit.lshift(1, bi)
					local mask = bit.bnot(flag)
					self.ram.keyPressFlags[by] = bit.bor(
						bit.band(mask, self.ram.keyPressFlags[by]),
						down and flag or 0
					)
				end
			end
		end
	end
end

-- static, used by gamestate and app
function App:getEventName(sdlEventID, a,b,c)
	if not a then return '?' end
	local function dir(d)
		local s = table()
		local ds = 'udlr'
		for i=1,4 do
			if 0 ~= bit.band(d,bit.lshift(1,i-1)) then
				s:insert(ds:sub(i,i))
			end
		end
		return s:concat()
	end
	local function key(k)
		return ffi.string(sdl.SDL_GetKeyName(k))
	end
	return template(({
		[sdl.SDL_JOYHATMOTION] = 'jh<?=a?> <?=b?> <?=dir(c)?>',
		[sdl.SDL_JOYAXISMOTION] = 'ja<?=a?> <?=b?> <?=c?>',
		[sdl.SDL_JOYBUTTONDOWN] = 'jb<?=a?> <?=b?>',
		[sdl.SDL_CONTROLLERAXISMOTION] = 'ga<?=a?> <?=b?> <?=c?>',
		[sdl.SDL_CONTROLLERBUTTONDOWN] = 'gb<?=a?> <?=b?>',
		[sdl.SDL_KEYDOWN] = 'key<?=key(a)?>',
		[sdl.SDL_MOUSEBUTTONDOWN] = 'mb<?=c?> x<?=math.floor(a*100)?> y<?=math.floor(b*100)?>',
		[sdl.SDL_FINGERDOWN] = 't x<?=math.floor(a*100)?> y<?=math.floor(b*100)?>',
	})[sdlEventID], {
		a=a, b=b, c=c,
		dir=dir, key=key,
	})
end

return App
