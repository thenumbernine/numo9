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
local assert = require 'ext.assert'
local string = require 'ext.string'
local table = require 'ext.table'
local range = require 'ext.range'
local math = require 'ext.math'
local path = require 'ext.path'
local tolua = require 'ext.tolua'
local fromlua = require 'ext.fromlua'
local getTime = require 'ext.timer'.getTime
local vector = require 'ffi.cpp.vector-lua'
local vec2s = require 'vec-ffi.vec2s'
local vec2i = require 'vec-ffi.vec2i'
local vec2f = require 'vec-ffi.vec2f'
local template = require 'template'
local matrix_ffi = require 'matrix.ffi'
local sha2 = require 'sha2'
local sdl = require 'sdl'
local gl = require 'gl'
local glreport = require 'gl.report'
--DEBUG(glquery):local GLQuery = require 'gl.query'
local GLApp = require 'glapp'
local View = require 'glapp.view'
local ThreadManager = require 'threadmanager'

local numo9_archive = require 'numo9.archive'
local cartImageToBlobs = numo9_archive.cartImageToBlobs
local blobStrToCartImage = numo9_archive.blobStrToCartImage
local blobsToCartImage = numo9_archive.blobsToCartImage

local numo9_net = require 'numo9.net'
local Server = numo9_net.Server
local ClientConn = numo9_net.ClientConn
local netcmds = numo9_net.netcmds

local numo9_rom = require 'numo9.rom'
local versionStr = numo9_rom.versionStr
local updateHz = numo9_rom.updateHz
local updateIntervalInSeconds = numo9_rom.updateIntervalInSeconds
local ROM = numo9_rom.ROM	-- define RAM, ROM, etc
local RAM = numo9_rom.RAM
local spriteSize = numo9_rom.spriteSize
local spriteSheetSizeInTiles = numo9_rom.spriteSheetSizeInTiles
local tilemapSizeInBits = numo9_rom.tilemapSizeInBits
local tilemapSize = numo9_rom.tilemapSize
local clipMax = numo9_rom.clipMax
local keyPressFlagSize = numo9_rom.keyPressFlagSize
local keyCount = numo9_rom.keyCount
local sizeofRAMWithoutROM = numo9_rom.sizeofRAMWithoutROM
local voxelmapSizeType = numo9_rom.voxelmapSizeType
local voxelMapEmptyValue = numo9_rom.voxelMapEmptyValue
local mvMatType = numo9_rom.mvMatType
local mvMatAddr = numo9_rom.mvMatAddr
local mvMatAddrEnd = numo9_rom.mvMatAddrEnd
local clipRectAddr = numo9_rom.clipRectAddr
local clipRectAddrEnd = numo9_rom.clipRectAddrEnd
local blendColorAddr = numo9_rom.blendColorAddr
local blendColorAddrEnd = numo9_rom.blendColorAddrEnd

local numo9_keys = require 'numo9.keys'
local maxPlayersPerConn = numo9_keys.maxPlayersPerConn
local maxPlayersTotal = numo9_keys.maxPlayersTotal
local keyCodeNames = numo9_keys.keyCodeNames
local keyCodeForName = numo9_keys.keyCodeForName
local sdlSymToKeyCode = numo9_keys.sdlSymToKeyCode
local firstJoypadKeyCode = numo9_keys.firstJoypadKeyCode
local buttonNames = numo9_keys.buttonNames
local buttonCodeForName = numo9_keys.buttonCodeForName

local numo9_blobs = require 'numo9.blobs'
local blobClassForName = numo9_blobs.blobClassForName
local blobClassNameForType = numo9_blobs.blobClassNameForType
local blobsToStr = numo9_blobs.blobsToStr

local numo9_video = require 'numo9.video'
local resetLogoOnSheet = numo9_video.resetLogoOnSheet


local function hexdump(ptr, len)
	return string.hexdump(ffi.string(ptr, len))
end

local function imageToHex(image)
	return string.hexdump(ffi.string(image.buffer, image.width * image.height * ffi.sizeof(image.format)))
end


local App = GLApp:subclass()
App.title = 'NuMo9'
App.width = cmdline and cmdline.window and cmdline.window[1] or 720
App.height = cmdline and cmdline.window and cmdline.window[2] or 512

App.sdlInitFlags = bit.bor(App.sdlInitFlags, sdl.SDL_INIT_AUDIO, sdl.SDL_INIT_GAMEPAD)

-- copy in video behavior
for k,v in pairs(numo9_video.AppVideo) do
	App[k] = v
end

-- copy in audio behavior
for k,v in pairs(require 'numo9.audio'.AppAudio) do
	App[k] = v
end

for k,v in pairs(numo9_blobs.AppBlobs) do
	App[k] = v
end

local defaultSaveFilename = 'last.n9'	-- default name of save/load if you don't provide one ...

do
	local cfg = cmdline.config
	if cfg then
		cfg = path(cfg)
		-- complain if it's not there?
		-- complain here or later?
		-- complain if its dir isn't there?
		-- complain if mkdir to it fails?
	else
		local pathIfExists = function(s)
			if not s then return end			-- if we got a nil (i.e. from os.getenv that wasn't defined) then bail
			local p = path(s)
			if not p:exists() then return end	-- if the dir isn't there then bail
			return p
		end

		local home = pathIfExists(os.getenv'HOME' or os.getenv'USERPROFILE')	-- tempted to just save this in the 'home' variable ...
		local cfgdir = pathIfExists(os.getenv'XDG_CONFIG_HOME')
			or (ffi.os == 'Windows' and pathIfExists(os.getenv'LOCALAPPDATA'))
			-- special-cas for OSX, try $HOME/Library/Preferences
			or (ffi.os == 'OSX' and home and pathIfExists(home/'Library/Preferences'))	-- use pathIfExists <=> don't make this dir if it's not there
			--fallback further on Linux style env -- try $HOME/.config
			-- I would put just Linux here, but it looks like in OSX enough apps write to .config/$appname/ for their stuff, so
			or (home and home/'.config')		-- don't pathIfExists ... if the .config folder is missing then make it
			or path'.' 							-- nothing worked? try ./
		cfg = cfgdir/'numo9/config.lua'
	end
	App.cfgpath = cfg
	App.cfgdir = App.cfgpath:getdir()
	App.cfgdir:mkdir(true)
end

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
function App:sdlGLSetAttributes()
	--[=[
	-- I should be able to just call super (which sets everything ... incl doublebuffer=1) .. and then set it back to zero right?
	App.super.sdlGLSetAttributes(self)
	self.sdlAssert(sdl.SDL_GL_SetAttribute(sdl.SDL_GL_DOUBLEBUFFER, 0))
	-- ... but no, it seems some state info (drawbuffer?) is changed immediatley upon setting GL_DOUBLEBUFFER=1,
	-- and not when I expected it to be: when the window or the gl context is created.
	-- and the change is permanent and is not reset when you set back GL_DOUBLEBUFFER=0
	--]=]
	-- [=[ maybe sdl/gl doens't forget once you set it the first time?
	-- so here's a copy of GLApp:sdlGLSetAttributes but withotu setting double buffer ...
	self.sdlAssert(sdl.SDL_GL_SetAttribute(sdl.SDL_GL_RED_SIZE, 8))
	self.sdlAssert(sdl.SDL_GL_SetAttribute(sdl.SDL_GL_GREEN_SIZE, 8))
	self.sdlAssert(sdl.SDL_GL_SetAttribute(sdl.SDL_GL_BLUE_SIZE, 8))
	self.sdlAssert(sdl.SDL_GL_SetAttribute(sdl.SDL_GL_ALPHA_SIZE, 8))
	self.sdlAssert(sdl.SDL_GL_SetAttribute(sdl.SDL_GL_DEPTH_SIZE, 24))
	--self.sdlAssert(sdl.SDL_GL_SetAttribute(sdl.SDL_GL_DOUBLEBUFFER, 1))	-- THE ONE LINE I CHANGED ...
	if ffi.os == 'OSX' then
		local glVersion = {4, 1}
		self.sdlAssert(sdl.SDL_GL_SetAttribute(sdl.SDL_GL_CONTEXT_MAJOR_VERSION, glVersion[1]))
		self.sdlAssert(sdl.SDL_GL_SetAttribute(sdl.SDL_GL_CONTEXT_MINOR_VERSION, glVersion[2]))
		self.sdlAssert(sdl.SDL_GL_SetAttribute(sdl.SDL_GL_CONTEXT_PROFILE_MASK, sdl.SDL_GL_CONTEXT_PROFILE_CORE))
		self.sdlAssert(sdl.SDL_GL_SetAttribute(sdl.SDL_GL_CONTEXT_FLAGS, sdl.SDL_GL_CONTEXT_FORWARD_COMPATIBLE_FLAG))
		self.sdlAssert(sdl.SDL_GL_SetAttribute(sdl.SDL_GL_ACCELERATED_VISUAL, 1))
	end
	--]=]
end
--]]

-- don't gl swap every frame - only do after draws
function App:postUpdate() end

-- TODO what's the best way to cast to int in luajit ... floor() ? ffi.cast('int') ? ffi.new('int') ? bit.bor(0) ?
local function toint(x)
	--return bit.bor(x, 0)	-- seems nice but I think it rounds instead of truncates ...
	return ffi.cast('int32_t', x)	-- use int32 so Lua has no problem with it
end
local function tofloat(x)
	return ffi.cast('float', x)
end

function App:initGL()
	self.mainThread = coroutine.running()
	gl.glPixelStorei(gl.GL_PACK_ALIGNMENT, 1)
	gl.glPixelStorei(gl.GL_UNPACK_ALIGNMENT, 1)

	gl.glDepthFunc(gl.GL_LEQUAL)

	--[[ getting single-buffer to work
	gl.glDrawBuffer(gl.GL_BACK)
	--]]

	-- do this before initBlobs -> buildRAMFromBlobs
	self.mvMat = matrix_ffi({4,4}, mvMatType):zeros()

	self:initBlobs()

	self.blitScreenView = View()
	self.blitScreenView.ortho = true
	self.blitScreenView.orthoSize = 1

	self.menuSizeInSprites = vec2f()
	self.orthoMin = vec2f()
	self.orthoMax = vec2f()

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
		trace = _G.print,

		run = function(...) return self:runCart(...) end,
		stop = function(...) return self:stop(...) end,
		cont = function(...) return self:cont(...) end,
		save = function(...) return self:saveCart(...) end,
		open = function(...) return self:net_openCart(...) end,
		reset = function(...) return self:net_resetCart(...) end,
		quit = function(...) self:requestExit() end,

		-- [[ this is for the console, but this means the cart can call it as well ...
		listen = function(...) return self:listen(...) end,
		connect = function(...) return self:connect(...) end,
		disconnect = function(...) return self:disconnect(...) end,
		--]]

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
		peekf = function(addr) return self:peekf(addr) end,
		poke = function(addr, value) return self:net_poke(addr, value) end,
		pokew = function(addr, value) return self:net_pokew(addr, value) end,
		pokel = function(addr, value) return self:net_pokel(addr, value) end,
		pokef = function(addr, value) return self:net_pokef(addr, value) end,
		memcpy = function(...) return self:net_memcpy(...) end,
		memset = function(...) return self:net_memset(...) end,

		-- why does tic-80 have mget/mset like pico8 when tic-80 doesn't have pget/pset or sget/sset ...
		mget = function(...) return self:mget(...) end,
		mset = function(...) return self:net_mset(...) end,

		pset = function(x, y, color)
			x = toint(x)
			y = toint(y)
			color = toint(color)
			local fbRAM = self.framebufferRAM
			local fbTex = fbRAM.tex
			local width, height = fbTex.width, fbTex.height
			if x < 0 or x >= width or y < 0 or y >= height then
				return
			end
			if fbRAM.ctype == 'uint16_t' then	-- 16bpp rgb565
				local addr = self.framebufferRAM.addr + 2 * (x + width * y)
				self:net_pokew(addr, color)
			else	-- 8bpp indexed or 8bpp rgb332
				local addr = self.framebufferRAM.addr + x + width * y
				self:net_poke(addr, color)
			end
		end,
		pget = function(x, y)
			x = toint(x)
			y = toint(y)
			local fbRAM = self.framebufferRAM
			local fbTex = fbRAM.tex
			local width, height = fbTex.width, fbTex.height
			if x < 0 or x >= width or y < 0 or y >= height then
				return 0
			end
			if fbRAM.ctype == 'uint16_t' then	-- 16bpp rgb565
				local addr = self.framebufferRAM.addr + 2 * (x + width * y)
				return self:peekw(addr)
			else
				local addr = self.framebufferRAM.addr + x + width * y
				return self:peek(addr)
			end
		end,

		drawbrush = function(...)
			return self:drawBrush(...)
		end,
		blitbrush = function(...)
			return self:blitBrush(...)
		end,
		blitbrushmap = function(...)
			return self:blitBrushMap(...)
		end,
		mesh = function(...)
			return self:drawMesh3D(...)
		end,
		drawvoxel = function(...)
			return self:drawVoxel(...)
		end,
		voxelmap = function(...)
			return self:drawVoxelMap(...)
		end,
		vget = function(voxelmapIndex, x, y, z)
			local voxelmap = self.blobs.voxelmap[(tonumber(voxelmapIndex) or 0)+1]
			if not voxelmap then return voxelMapEmptyValue end
			local addr = voxelmap:getVoxelAddr(x,y,z)
			if not addr then return voxelMapEmptyValue end
			return self:peekl(addr)
		end,
		vset = function(voxelmapIndex, x, y, z, value)
			local voxelmap = self.blobs.voxelmap[(tonumber(voxelmapIndex) or 0)+1]
			if not voxelmap then return end
			-- does mget/mset send through net?
			-- yeah cuz clients need that info for tilemap texture updates
			-- same with voxels?  they don't have any GPU backing, so not much of a need, unless we're relocating the textures or framebuffer or something ...
			local addr = voxelmap:getVoxelAddr(x,y,z)
			if not addr then return end
			self:net_pokel(addr, value)
		end,

		-- graphics

		flip = coroutine.yield,	-- simple as
		cls = function(colorIndex, depthOnly)
			colorIndex = toint(colorIndex or 0)
			if self.server then
				local cmd = self.server:pushCmd().clearScreen
				cmd.type = netcmds.clearScreen
				cmd.colorIndex = colorIndex
			end
			self:clearScreen(colorIndex, nil, depthOnly)
		end,
		fillp = function(dither)
			if dither then
				return self:net_pokew(ffi.offsetof('RAM', 'dither'), dither)
			else
				return self:peekw(ffi.offsetof('RAM', 'dither'))
			end
		end,

		pal = function(colorIndex, value)
			if value then
				return self:net_pokew(self.blobs.palette[1].ramgpu.addr + bit.lshift(colorIndex, 1), value)
			else
				return self:peekw(self.blobs.palette[1].ramgpu.addr + bit.lshift(colorIndex, 1))
			end
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
			return self:drawSolidTri3D(x1, y1, z1, x2, y2, z2, x3, y3, z3, colorIndex)
		end,

		ttri3d = function(
			x1, y1, z1, u1, v1,
			x2, y2, z2, u2, v2,
			x3, y3, z3, u3, v3,
			sheetIndex, paletteIndex, transparentIndex, spriteBit, spriteMask
		)
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
				cmd.u1 = u1
				cmd.v1 = v1
				cmd.u2 = u2
				cmd.v2 = v2
				cmd.u3 = u3
				cmd.v3 = v3
				cmd.sheetIndex = sheetIndex or 0
				cmd.paletteIndex = paletteIndex or 0
				cmd.transparentIndex = transparentIndex or -1
				cmd.spriteBit = spriteBit or 0
				cmd.spriteMask = spriteMask or 0xFF
			end
			return self:drawTexTri3D(x1, y1, z1, u1, v1, x2, y2, z2, u2, v2, x3, y3, z3, u3, v3, sheetIndex, paletteIndex, transparentIndex, spriteBit, spriteMask)
		end,

		line = function(x1,y1,x2,y2,colorIndex,thickness)
			if self.server then
				local cmd = self.server:pushCmd().solidLine
				cmd.type = netcmds.solidLine
				cmd.x1 = x1
				cmd.y1 = y1
				cmd.x2 = x2
				cmd.y2 = y2
				cmd.colorIndex = colorIndex
				cmd.thickness = thickness or 1
			end
			return self:drawSolidLine(x1,y1,x2,y2,colorIndex,thickness)
		end,

		line3d = function(x1,y1,z1,x2,y2,z2,colorIndex,thickness)
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
				cmd.thickness = thickness or 1
			end
			return self:drawSolidLine3D(x1,y1,z1,x2,y2,z2,colorIndex,thickness)
		end,

		spr = function(spriteIndex, screenX, screenY, tilesWide, tilesHigh, paletteIndex, transparentIndex, spriteBit, spriteMask, scaleX, scaleY)
			if self.server then
				-- TODO I'm calculating default values twice ...
				-- TODO move the server netcmd stuff into a separate intermediate function
				-- TODO same with all the drawSolidRect stuff
				tilesWide = tilesWide or 1
				tilesHigh = tilesHigh or 1
				scaleX = scaleX or 1
				scaleY = scaleY or 1
				-- vram / sprite sheet is 32 sprites wide ... 256 pixels wide, 8 pixels per sprite
				spriteIndex = math.floor(spriteIndex or 0)
				local tx = bit.band(spriteIndex, 0x1f)
				local ty = bit.band(bit.rshift(spriteIndex, 5), 0x1f)
				local sheetIndex = bit.rshift(spriteIndex, 10)

				paletteIndex = paletteIndex or 0
				transparentIndex = transparentIndex or -1
				spriteBit = spriteBit or 0
				spriteMask = spriteMask or 0xFF

				local cmd = self.server:pushCmd().quad
				cmd.type = netcmds.quad
				cmd.x = screenX
				cmd.y = screenY
				cmd.w = tilesWide * spriteSize.x * scaleX
				cmd.h = tilesHigh * spriteSize.y * scaleY
				cmd.tx = bit.lshift(tx, 3)
				cmd.ty = bit.lshift(ty, 3)
				cmd.tw = bit.lshift(tilesWide, 3)
				cmd.th = bit.lshift(tilesHigh, 3)
				cmd.paletteIndex = paletteIndex
				cmd.transparentIndex = transparentIndex
				cmd.spriteBit = spriteBit
				cmd.spriteMask = spriteMask
				cmd.sheetIndex = sheetIndex
			end
			return self:drawSprite(
				spriteIndex,
				screenX, screenY,
				tilesWide, tilesHigh,
				paletteIndex, transparentIndex,
				spriteBit, spriteMask,
				scaleX, scaleY)
		end,

		-- like spr() but for inter-tile rendering
		quad = function(x, y, w, h, tx, ty, tw, th, sheetIndex, paletteIndex, transparentIndex, spriteBit, spriteMask)
			if self.server then
				sheetIndex = sheetIndex or 0
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
				cmd.sheetIndex = sheetIndex
			end
			return self:drawQuad(x, y, w, h, tx, ty, tw, th, sheetIndex, paletteIndex, transparentIndex, spriteBit, spriteMask)
		end,

		-- TODO maybe make draw16Sprites a poke'd value
		-- TODO a map() that uses a callback for permuting drawn indexes .... even if it's slow .. . make it separate
		map = function(tileX, tileY, tilesWide, tilesHigh, screenX, screenY, mapIndexOffset, draw16Sprites, sheetIndex)
			if self.server then
				tilesWide = tilesWide or 1
				tilesHigh = tilesHigh or 1
				mapIndexOffset = mapIndexOffset or 0
				sheetIndex = sheetIndex or 1
				local cmd = self.server:pushCmd().map
				cmd.type = netcmds.map
				cmd.tileX, cmd.tileY, cmd.tilesWide, cmd.tilesHigh = tileX, tileY, tilesWide, tilesHigh
				cmd.screenX, cmd.screenY = screenX, screenY
				cmd.mapIndexOffset = mapIndexOffset
				cmd.draw16Sprites = draw16Sprites or false
				cmd.sheetIndex = sheetIndex
			end
			return self:drawMap(tileX, tileY, tilesWide, tilesHigh, screenX, screenY, mapIndexOffset, draw16Sprites, sheetIndex)
		end,
		text = function(text, x, y, fgColorIndex, bgColorIndex, scaleX, scaleY)
			text = tostring(text)	-- convert?
			--assert.type(text, 'string')	-- or assert?
			if self.server then
				x = x or 0
				y = y or 0
				fgColorIndex = fgColorIndex or self.ram.textFgColor
				bgColorIndex = bgColorIndex or self.ram.textBgColor
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

		mode = function(modeIndex)
			if type(modeIndex) == 'string' then
				modeIndex = self.videoModes:find(nil, function(modeObj)
					return modeObj.formatDesc == modeIndex
				end)
				if not modeIndex then
					return false, "failed to find video mode"
				end
			end

			-- just poke here so mode is set next frame
			-- for net play's sake ,how about just doing a peek/poke?
			self:net_poke(ffi.offsetof('RAM', 'videoMode'), modeIndex)
		end,

		clip = function(...)
			local x, y, w, h
			if select('#', ...) == 0 then
				x, y, w, h = 0, 0, clipMax, clipMax
			else
				assert.eq(select('#', ...), 4)
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
			local c, s = math.cos(theta), math.sin(theta)
			if self.server then
				local cmd = self.server:pushCmd().matrotcs
				cmd.type = netcmds.matrotcs
				cmd.c, cmd.s, cmd.x, cmd.y, cmd.z = c, s, x, y, z
			end
			self:matrotcs(c, s, x, y, z)
		end,
		matrotcs = function(c, s, x, y, z)
			if self.server then
				local cmd = self.server:pushCmd().matrotcs
				cmd.type = netcmds.matrotcs
				cmd.c, cmd.s, cmd.x, cmd.y, cmd.z = c, s, x, y, z
			end
			self:matrotcs(c, s, x, y, z)
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

		screenshot = function() self.takeScreenshot = true end,
		saveLabel = function() self.takeScreenshot = 'label' end,

		-- TODO tempting to do like pyxel and just remove key/keyp and only use btn/btnp, and just lump the keyboard flags in after the player joypad button flags
		key = function(...) return self:key(...) end,
		keyp = function(...) return self:keyp(...) end,
		keyr = function(...) return self:keyr(...) end,

		btn = function(...) return self:btn(...) end,
		btnp = function(...) return self:btnp(...) end,
		btnr = function(...) return self:btnr(...) end,

		-- TODO merge mouse buttons with btpn as well so you get added fnctionality of press/release detection
		mouse = function(...) return self:getMouseState(...) end,

		bit = bit,
		assert = require 'ext.assert',
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
		next = next,
		pairs = pairs,
		ipairs = ipairs,
		getmetatable = getmetatable,
		setmetatable = setmetatable,
		traceback = debug.traceback,	-- useful for threads

		-- use this in place of ffi.offsetof('RAM', field)
		ramaddr = function(name)
			return ffi.offsetof('RAM', name)
		end,
		ramsize = function(name)
			return ffi.sizeof(ffi.cast('RAM*', 0)[name])
		end,
		numblobs = function(name)
			local blobsForType = self.blobs[name]
			if not blobsForType then return 0 end
			return #blobsForType
		end,
		blobaddr = function(name, index)
			local blobsForType = self.blobs[name]
			if not blobsForType then
--DEBUG:print("blobaddr found no blobs of type "..tostring(name))
				return
			end
			index = tonumber(toint(index))
			-- special case - addr of 1+ last blob is the last addr
			if index == #blobsForType then
				-- if there are no blobs of this type ...
				if index == 0 then return 0 end	-- TODO return start of blob section for this type?
				local blob = blobsForType[index]
				return blob.addrEnd
			end
			local blob = blobsForType[index+1]
			if not blob then
--DEBUG:print("blobaddr("..tostring(name)..") couldn't find index "..tostring(index))
				return
			end
			return blob.addr
		end,
		blobsize = function(name, index)
			local blobsForType = self.blobs[name]
			if not blobsForType then return end
			local blob = blobsForType[tonumber(toint(index))+1]
			if not blob then return end
			return blob:getSize()
		end,
		int8_t = ffi.typeof'int8_t',
		uint8_t = ffi.typeof'uint8_t',
		int8_t = ffi.typeof'int8_t',
		int16_t = ffi.typeof'int16_t',
		uint16_t = ffi.typeof'uint16_t',
		int16_t = ffi.typeof'int16_t',
		int32_t = ffi.typeof'int32_t',
		uint32_t = ffi.typeof'uint32_t',
		int32_t = ffi.typeof'int32_t',

		-- TODO don't let the ROM see the App...
		app = self,
		getfenv = getfenv,	-- maybe ... needed for _ENV replacement, but maybe can break out of sandbox ...
		setfenv = setfenv,	-- \_ fair warning, getfenv(0) breaks out of the sandbox and gets numo9's _G

		-- sandboxed load

		load = function(cmd, ...)
			-- ok so ... load() is Lua's load()
			-- but in pico8 and tic80, `load` is also the console command for loading carts
			-- which is where my open() function comes in
			-- but sometimes I forget,
			--[[ so for moments like those, I'm tempted to have a check here to see if the file exists, and then just do an open() instead if it does ...
			for _,suffix in ipairs{'', '.n9', '.n9.png'} do
				local checkfn = cmd..suffix
				if self.fs:get(checkfn) then
					return self:openCart(cmd) -- or net_openCart?
				end
			end
			--]]

			return self:loadCmd(cmd, ...)
			--return self:loadCmd(cmd, source, self.gameEnv)  -- should it use the game's env, or the app's default env? or should it be an arg?
		end,
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
--assert.eq(self.loadenv.langfix, self.langfixState)
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

	self:initVideo()

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

	self.screenMousePos = vec2f()	-- host coordinates ... don't put this in RAM

	-- TODO app.editMode is the field name, app.activeMenu is the value, merge these two ...
	self.editMode = 'code'	-- matches up with UI's editMode's

	local EditCode = require 'numo9.edit.code'
	local EditSheet = require 'numo9.edit.sheet'
	local EditTilemap = require 'numo9.edit.tilemap'
	local EditSFX = require 'numo9.edit.sfx'
	local EditMusic = require 'numo9.edit.music'
	local EditBrushmap = require 'numo9.edit.brushmap'
	local EditMesh3D = require 'numo9.edit.mesh3d'
	local EditVoxelmap = require 'numo9.edit.voxelmap'
	local Console = require 'numo9.console'
	local MainMenu = require 'numo9.mainmenu'
	local CartBrowser = require 'numo9.cartbrowser'

	-- reset mat and clip
	self:matident()
	self:setClipRect(0, 0, clipMax, clipMax)

	self.editCode = EditCode{app=self}
	self.editSheet = EditSheet{app=self}
	self.editTilemap = EditTilemap{app=self}
	self.editSFX = EditSFX{app=self}
	self.editMusic = EditMusic{app=self}
	self.editBrushmap = EditBrushmap{app=self}
	self.editMesh3D = EditMesh3D{app=self}
	self.editVoxelmap = EditVoxelmap{app=self}
	self.con = Console{app=self}
	self.mainMenu = MainMenu{app=self}
	self.cartBrowser = CartBrowser{app=self}

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

	local initializingConfig = not self.cfg
	setdefault(self, 'cfg', {})

	-- set this and only clear it once the player has pushed their first input event so we can know what kind of controller they're using
	self.cfg.initializingConfig = initializingConfig

	setdefault(self.cfg, 'volume', 255)

	-- notice on my osx, even 'localhost' and '127.0.0.1' aren't interchangeable
	-- TODO use a proper ip ...
	setdefault(self.cfg, 'serverListenAddr', 'localhost')
	setdefault(self.cfg, 'serverListenPort', tostring(Server.defaultListenPort))
	setdefault(self.cfg, 'lastConnectAddr', 'localhost')	-- TODO ... eh ... LAN search?  idk
	setdefault(self.cfg, 'lastConnectPort', tostring(Server.defaultListenPort))
	setdefault(self.cfg, 'numLocalPlayers', 1)	-- # local players to use, default at 1 so that servers dont needlessly fill up player spots.
	setdefault(self.cfg, 'playerInfos', {})
	for i=1,maxPlayersPerConn do
		setdefault(self.cfg.playerInfos, i, {})
		-- for netplay, shows up in the net menu
		setdefault(self.cfg.playerInfos[i], 'name', i == 1 and 'steve' or '')
		setdefault(self.cfg.playerInfos[i], 'buttonBinds', {})
	end
	-- don't let the config put us in a bad state -- erase invalid playerInfos
	for _,k in ipairs(table.keys(self.cfg.playerInfos)) do
		if k > maxPlayersPerConn then
			self.cfg.playerInfos[k] = nil
		end
	end
	setdefault(self.cfg, 'screenButtonRadius', 10)

	-- this is for server netplay, it says who to associate this conn's player with
	-- it is convenient to put it here ...
	-- but is it information worth saving? maybe not -- maybe reset it every time.
	for i=1,maxPlayersPerConn do
		self.cfg.playerInfos[i].hostPlayerIndex = i-1
	end
	-- allow the player to leave keys unbound?  only set them to defaults when setting the initial cfg?
	self:buildPlayerEventsMap()

-- setFocus has been neglected ...
-- ... this will cause the menu to open once its done playing
-- boot screen or something ...
-- [[
	self:setFocus{
		thread = coroutine.create(function()
			local env = self.env
			-- set state to paused initially
			-- then if we get a openCart command it'll unpause
			-- or if we get a setmenu command in init this will remain paused and not kick us back to console when this finishes
			--self.isPaused = true
			-- HOWEVER doing this makes it so starting to the console requires TWO ESCAPE (one to stop this startup) to enter the main menu ...
			-- the trade off is that when this finishes, even if it got another load cmd in .initCmd, it still waits to finish and kicks to console even though another rom is loaded
			-- I could work around *that too* with a yield after load here ...
			-- edge case behavior getting too out of hand yet?

			self:resetGFX()		-- needed to initialize UI colors
			self.con:reset()	-- needed for palette .. tho its called in init which is above here ...
			self:clearScreen()	-- without this, with depth test, the text console copy in coolPrint() doesn't work
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

			if not cmdline.nosplash then

				local fgColor = 0xf9
				local bgColor --= 0xf1
				local cursorPosX, cursorPosY = 0, 0
				local function addChar(ch)
					env.text(ch, cursorPosX, cursorPosY, fgColor, bgColor)
					cursorPosX = cursorPosX + 5
				end
				-- TODO print with auto framebuffer copy for scroll? (pico8)
				-- or if I use a real console text buffer then when to render it? (tic80)
				local function coolPrint(...)
					print(...)
					local ofs = 9
					local function inc(d)
						fgColor = bit.bor((fgColor-ofs+d)%4+ofs,0xf0)
						--bgColor = bit.bor((self.bgColor-ofs+d)%3+ofs,0xf0)
					end
					inc(bit.rshift(cursorPosX,3)+bit.rshift(cursorPosY,3))
					for i=1,select('#', ...) do
						if i > 1 then
							addChar'\t'
							inc(1)
						end
						local s = tostring(select(i, ...))
						for j=1,#s do
							addChar(s:sub(j,j))
							inc(1)
						end
					end
					local fbWidth = self.ram.screenWidth
					local fbHeight = self.ram.screenHeight
					local pixelSize = 2
					local charHeight = 8

					cursorPosX = 0
					cursorPosY = cursorPosY + charHeight
					if cursorPosY > fbHeight - charHeight then
						cursorPosY = cursorPosY - charHeight
						local fbaddr = env.ramaddr'framebuffer'
						local scanlineSize = fbWidth * pixelSize
						local textRowSize = charHeight * scanlineSize
						local fbSize = scanlineSize * fbHeight
						-- reading from this should flush framebuffer gpu->cpu
						env.memcpy(
							fbaddr,		 			-- dst
							fbaddr + textRowSize,	-- src
							fbSize - textRowSize)	-- len
						env.memset(
							fbSize - textRowSize,	-- dst
							0,						-- val
							textRowSize)			-- len
						-- and writing to it should dirty cpu to later flush cpu->gpu
					end
					env.flip()
				end

				for sleep=1,60 do
					env.flip()
				end

				coolPrint('NuMo-9 ver. '..versionStr)
				for i=1,30 do env.flip() end
				coolPrint'https://github.com/thenumbernine/numo9 (c) 2025'
				for i=1,30 do env.flip() end
				coolPrint'...OpenResty LuaJIT w/5.2 compat'
				for i=1,30 do env.flip() end

				-- [[ list screen modes? or nah?
				for _,i in ipairs(self.videoModes:keys():sort()) do
					local v = self.videoModes[i]
					coolPrint(i..'...'..v.formatDesc)
				end
				--]]

				-- [[ list RAM layout? or nah?
				--DEBUG:print(RAM.code)
				coolPrint(('RAM size: 0x%x'):format(ffi.sizeof'RAM'))
				coolPrint(('ROM size: 0x%x'):format(self.memSize - ffi.sizeof'RAM'))
				coolPrint'memory layout:'
				coolPrint'- RAM -'
				for name,ctype in RAM:fielditer() do	-- TODO struct iterable fields ...
					local offset = ffi.offsetof('RAM', name)
					local size = ffi.sizeof(ctype)
					coolPrint(('0x%06x - 0x%06x = '):format(offset, offset + size)..name)
				end
				coolPrint'- ROM -'
				for i=0,self.ram.blobCount-1 do
					local blobEntry = self.ram.blobEntries + i
					local name = assert.index(blobClassNameForType, blobEntry.type)
					coolPrint(('0x%06x - 0x%06x = '):format(blobEntry.addr, blobEntry.addr + blobEntry.size)..name)
				end
				--]=]

				--self.con:print"type help() for help" -- not really
				env.flip()

				-- flag 'needsPrompt' then write the prompt in update if it's needed
--				for sleep=1,60 do env.flip() end

				-- also for init, do the splash screen
				resetLogoOnSheet(self.blobs.sheet[1].ramptr)
				self.blobs.sheet[1].ramgpu.dirtyCPU = true
				for j=0,31 do
					for i=0,31 do
						env.mset(i, j, bit.bor(
							i,
							bit.lshift(j, 5)
						))
					end
				end

				-- do splash screen fanfare ...
				local s = ('NuMo9=-\t '):rep(3)
				--local s = ('9'):rep(27)
				local colors = range(0xf1, 0xfe)
				for t=0,31+#s do		-- t = time = leading diagonal
					env.cls()
					for i=t,0,-1 do		-- i = across all diagonals so far
						for j=0,i do	-- j = along diagonal
							local x = bit.lshift(i-j, 3)
							local y = bit.lshift(j, 3)
							env.matident()
							env.mattrans(x+4, y+4)
							local r = ((t-i)/16 + .5)*2*math.pi
							env.matrot(r)
							local w = 3*math.exp(-((t - i + 4) / 15)^2)
							local l = t - i + 1
							self:drawText(s:sub(l,l), -3 * w, -4 * w, 0x0f, colors[(i+1)%#colors+1], w, w)
						end
					end

					env.matident()
					env.blend(2)	-- subtract
					-- if I draw this as a sprite then I can draw as a low bpp and shift the palette ...
					-- if I draw it as a tilemap then I can use the upper 4 bits of the tilemap entries for shifting the palette ...
					self:drawMap(0, 0, 32, 32, 0, 0, 0, false, 0)
					env.blend(-1)

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
					env.flip()
					--]]
				end
				env.flip()

				-- and clear the tilemap now that we're done with it
				local sheetBlob = self.blobs.sheet[1]
				ffi.fill(sheetBlob.ramptr, sheetBlob:getSize())
				sheetBlob.ramgpu.dirtyCPU = true

				local tilemapBlob = self.blobs.tilemap[1]
				ffi.fill(tilemapBlob.ramptr, tilemapBlob:getSize())
				tilemapBlob.ramgpu.dirtyCPU = true
			end

			-- initially assign to cartBrowser
			self:setMenu(self.cartBrowser)

			-- how to make it start with console open if there's no rom ...
			-- then run our cmdline file ... ?
			if cmdline and cmdline[1] then
				self:openCart(cmdline[1])	-- or what about starting a server game?  and then net_openCart?
				self:runCart()
			end

			-- then let us run cmds
			if cmdline and cmdline.initCmd then
				self:runCmd(cmdline.initCmd)
			end

			if cmdline.editor then
				self:setMenu(self.editCode)
			end

			-- yield before quit in case initCmd or load has a better runFocus and we dont need to end-thread and drop to console
			coroutine.yield()

		end),
	}
--]]

	-- maps from "joystick instance ID" to "SDL_Gamepad*"
	self.controllers = {}
	self.controllerForJoystickID = {}

-- webgl doesn't support these ...
--DEBUG(glquery):updateQuery = GLQuery(gl.GL_TIME_ELAPSED)
--DEBUG(glquery):updateQueryTotal = 0
--DEBUG(glquery):updateQueryFrames = 0

--DEBUG(glquery):drawQuery = GLQuery(gl.GL_TIME_ELAPSED)
--DEBUG(glquery):drawQueryTotal = 0
--DEBUG(glquery):drawQueryFrames = 0
end

function App:exit()
	self:writePersistent()	-- write current running rom persistent before quitting
	self.cfgpath:write(tolua(self.cfg, {indent=true}))

	App.super.exit(self)
end


-------------------- ENV NETPLAY LAYER --------------------
-- when I don't want to write server cmds twice
-- leave the :(not net_)functionName stuff for the client to also call and not worry about requesting another server refresh
--  (tho the client shouldnt have a server and that shouldnt happen anyways)

-- ok when opening a ROM, we want to send the RAM snapshot out to all clients
function App:net_openCart(...)
	local result = table.pack(self:openCart(...))

	if self.server then
		-- TODO consider order of events
		-- this is going to sendRAM to all clients
		-- but it's executed mid-frame on the server, while server is building a command-buffer
		-- where will deltas come into play?
		-- how about new-frame messages too?
		for _,serverConn in ipairs(self.server.conns) do
			if serverConn.remote then
				self.server:sendRAM(serverConn)
			end
		end
	end
	return result:unpack()
end

function App:net_resetCart(...)
	local result = table.pack(self:resetCart(...))

	-- TODO this or can I get by
	-- 1) backing up the client's cartridge state upon load() then ...
	-- 2) ... upon client reset() just copy that over?
	-- fwiw the initial sendRAM doesn't include the cartridge state, just the RAM state ...
	if self.server then
		for _,serverConn in ipairs(self.server.conns) do
			if serverConn.remote then
				self.server:sendRAM(serverConn)
			end
		end
	end

	return result:unpack()
end

function App:net_poke(addr, value)
	-- TODO hwy not move the server test down into App:poke() istelf? meh? idk
	if self.server then
		-- spare us reocurring messages
		addr = ffi.cast('uint32_t', addr)
		value = ffi.cast('uint8_t', value)
		if self:peek(addr) ~= value then
			local cmd = self.server:pushCmd().poke
			cmd.type = netcmds.poke
			cmd.addr = addr
			cmd.value = value
		end
	end
	return self:poke(addr, value)
end
function App:net_pokew(addr, value)
	if self.server then
		addr = ffi.cast('uint32_t', addr)
		value = ffi.cast('uint16_t', value)
		if self:peekw(addr) ~= value then
			local cmd = self.server:pushCmd().pokew
			cmd.type = netcmds.pokew
			cmd.addr = addr
			cmd.value = value
		end
	end
	return self:pokew(addr, value)
end
function App:net_pokel(addr, value)
	if self.server then
		addr = ffi.cast('uint32_t', addr)
		value = ffi.cast('uint32_t', value)
		if self:peekl(addr) ~= value then
			local cmd = self.server:pushCmd().pokel
			cmd.type = netcmds.pokel
			cmd.addr = addr
			cmd.value = value
		end
	end
	return self:pokel(addr, value)
end
function App:net_pokef(addr, value)
	if self.server then
		addr = ffi.cast('float', addr)
		value = ffi.cast('float', value)
		if self:peekl(addr) ~= value then
			local cmd = self.server:pushCmd().pokel
			cmd.type = netcmds.pokel
			cmd.addr = addr
			cmd.value = value
		end
	end
	return self:pokef(addr, value)
end

function App:net_memcpy(dst, src, len)
	if self.server then
		local cmd = self.server:pushCmd().memcpy
		cmd.dst = dst
		cmd.src = src
		cmd.len = len
	end
	return self:memcpy(dst, src, len)
end

function App:net_memset(dst, val, len)
	if self.server then
		local cmd = self.server:pushCmd().memset
		cmd.dst = dst
		cmd.val = val
		cmd.len = len
	end
	return self:memset(dst, val, len)
end

function App:net_mset(x, y, value, tilemapBlobIndex)
	x = toint(x)
	y = toint(y)
	tilemapBlobIndex = tonumber(toint(tilemapBlobIndex))	-- or 0
	value = ffi.cast('uint16_t', value)
	if x >= 0 and x < tilemapSize.x
	and y >= 0 and y < tilemapSize.y
	and tilemapBlobIndex >= 0 and tilemapBlobIndex < #self.blobs.tilemap
	then
		local addr = self.blobs.tilemap[tilemapBlobIndex+1].ramgpu.addr	-- use the relocatable address
			+ bit.lshift(bit.bor(x, bit.lshift(y, tilemapSizeInBits.x)), 1)
		-- use poke over netplay, cuz i'm lazy.
		if self.server then
			local prevValue = self:peekw(addr)
			if prevValue ~= value then
				local cmd = self.server:pushCmd().pokew
				cmd.type = netcmds.pokew
				cmd.addr = addr
				cmd.value = value
			end
		end

		self:pokew(addr, value)
	end
end

-------------------- LOCAL ENV API --------------------

function App:mget(x, y, tilemapBlobIndex)
	x = toint(x)
	y = toint(y)
	tilemapBlobIndex = tonumber(toint(tilemapBlobIndex))	-- or 0
	if x >= 0 and x < tilemapSize.x
	and y >= 0 and y < tilemapSize.y
	and tilemapBlobIndex >= 0 and tilemapBlobIndex < #self.blobs.tilemap
	then
		local addr = self.blobs.tilemap[tilemapBlobIndex+1].ramgpu.addr	-- use the relocatable address
			+ bit.lshift(bit.bor(x, bit.lshift(y, tilemapSizeInBits.x)), 1)
		return self:peekw(addr)
	end
	-- TODO return default oob value?  or return nil?
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

	gl.glIndexMask(0x0000)

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
--DEBUG:print('app:setFocus(remoteClient)')
	self:setFocus(self.remoteClient)
	assert(self.runFocus == self.remoteClient)
	if not self.runFocus.thread then
		-- failed to connect?
		self.con:print'failed to connect'
		self.runFocus = nil
		-- disconnect if we're a client ... but stay connected if we are a server?
		if self.remoteClient then self.remoteClient:close() end
		self.remoteClient = nil
		return nil, 'failed to connect'
	end
assert(coroutine.status(self.runFocus.thread) ~= 'dead')
	self:setMenu(nil)
	return true
end

-------------------- MAIN UPDATE CALLBACK --------------------

local mvMatPush = ffi.new(mvMatType..'[16]')
function App:update()
	if not self.hasFocus then
		-- only pause-on-lost-focus if we're not in multiplayer
		if not self.server and not self.remoteClient then
			return
		end
	end

	-- will this hurt performance?
	if self.activeMenu then
		sdl.SDL_ShowCursor()
	else
		sdl.SDL_HideCursor()
	end

	App.super.update(self)

	local thisTime = getTime()

-- [==[ per-second-tick debug display
	-- ... now that I've moved the swap out of the parent class and only draw on dirty bit, this won't show useful information
	-- TODO get rid of double-buffering.  you've got the framebuffer.
	local deltaTime = thisTime - lastTime
	fpsFrames = fpsFrames + 1
	fpsSeconds = fpsSeconds + deltaTime
	if fpsSeconds > 1 then
		if cmdline.fps then
			print(''
--DEBUG(glquery):..'update='..(updateQueryTotal/updateQueryFrames*1e-6)
--DEBUG(glquery):..' draw='..(drawQueryTotal/drawQueryFrames*1e-6)..' '
				..'FPS: '..(fpsFrames / fpsSeconds)	--	this will show you how fast a busy loop runs ... 130,000 hits/second on my machine ... should I throw in some kind of event to lighten the cpu load a bit?
			--	..' draws/second '..drawsPerSecond	-- TODO make this single-buffered
			--	..' channels active '..range(0,7):mapi(function(i) return self.ram.channels[i].flags.isPlaying end):concat' '
			--	..' tracks active '..range(0,7):mapi(function(i) return self.ram.musicPlaying[i].isPlaying end):concat' '
			--	..' SDL_GetQueuedAudioSize', sdl.SDL_GetQueuedAudioSize(self.audio.deviceID)
--DEBUG: ..' flush calls: '..self.triBuf_flushCallsPerFrame..' flushes: '..tolua(self.triBuf_flushSizes)
--DEBUG(flushtrace): ..' flush calls: '..self.triBuf_flushCallsPerFrame..' flushes: '..table.keys(self.triBuf_flushSizesPerTrace):sort():mapi(function(tb) return '\n'..self.triBuf_flushSizesPerTrace[tb]..' from '..tb end):concat()
-- ..' clip: ['..self.ram.clipRect[0]..', '..self.ram.clipRect[1]..', '..self.ram.clipRect[2]..', '..self.ram.clipRect[3]..']'
			)
--DEBUG:self.triBuf_flushCallsPerFrame = 0
--DEBUG:self.triBuf_flushSizes = {}
--DEBUG(flushtrace): self.triBuf_flushSizesPerTrace = {}

--DEBUG(glquery):updateQueryTotal = 0
--DEBUG(glquery):updateQueryFrames = 0
--DEBUG(glquery):drawQueryTotal = 0
--DEBUG(glquery):drawQueryFrames = 0

			if self.server then
			--[[
			if self.server.socket then
print('self.server.socket', self.server.socket)
				io.write('server sock '..tolua(self.server.socket:getstats())..' ')
			end
			--]]
--[[ show server's last delta
print'DELTA'
print(
	string.hexdump(
		ffi.string(
			ffi.cast('char*', self.server.conns[1].deltas.v),
			#self.server.conns[1].deltas * ffi.sizeof(self.server.conns[1].deltas.type)
		), nil, 2
	)
)
--]]
--[[ show server's last render state:
print'STATE'
print(
	string.hexdump(
		ffi.string(
			ffi.cast('char*', self.server.conns[1].cmds.v),
			#self.server.conns[1].cmds * ffi.sizeof'Numo9Cmd'
		), nil, 2
	)
)
--]]
				io.write('netcmds='..#((self.server.conns[1] or {}).cmds or {})..' ')
				io.write('deltas/sec='..tostring(self.server.numDeltasSentPerSec)..' ')
				io.write('idlechecks/sec='..tostring(self.server.numIdleChecksPerSec)..' ')
self.server.numDeltasSentPerSec = 0
self.server.numIdleChecksPerSec = 0
				if self.server.conns[2] then
					local conn = self.server.conns[2]
					io.write('serverconn stats '..tolua{self.server.conns[2].socket:getstats()}
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
	end
	lastTime = thisTime	-- TODO this at end of update in case someone else needs this var
	--]==]

	if thisTime > lastUpdateTime + updateIntervalInSeconds then
		--[[ Doing this means we need to reset lastUpdateTime when resuming from the app being paused
		-- and indeed the in-console fps first readout is high (67), then drops back down to 60 consistently
		-- Also, there's a massive fast-forward that goes on for the first second or two of the console running.
		lastUpdateTime = lastUpdateTime + updateIntervalInSeconds
		--]]
		-- [[ doing this means we might lose fractions of time resolution during our updates
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

		collectgarbage()

--DEBUG(glquery):updateQuery:begin()

		local newFramebufferAddr = self.ram.framebufferAddr
		if self.framebufferRAM.addr ~= newFramebufferAddr then
--DEBUG:print'updating framebufferRAM addr'
			-- TODO this current method updates *all* GPU/CPU framebuffer textures
			-- but if I provide more options, I'm only going to want to update the one we're using (or things would be slow)
			for _,v in pairs(self.framebufferRAMs) do
				v:updateAddr(newFramebufferAddr)
			end
		end

		-- TODO how to handle these plus expandable ROM?  I could only have the first sheets relocatable?
		-- TODO testing for .ramgpu's existence was only in half of these, maybe I don't need that test?
		local newSpriteSheetAddr = self.ram.spriteSheetAddr
		local sheetRAM = self.blobs.sheet[1].ramgpu
		if sheetRAM and sheetRAM.addr ~= newSpriteSheetAddr then
--DEBUG:print'updating blobs.sheet[1].ramgpu addr'
			sheetRAM:updateAddr(newSpriteSheetAddr)
		end
		local newTileSheetAddr = self.ram.tileSheetAddr
		local tileSheetRAM = self.blobs.sheet[2].ramgpu
		if tileSheetRAM and tileSheetRAM.addr ~= newTileSheetAddr then
--DEBUG:print'updating blobs.sheet[2].ramgpu addr'
			tileSheetRAM:updateAddr(newTileSheetAddr)
		end
		local newTilemapAddr = self.ram.tilemapAddr
		local tilemapRAM = self.blobs.tilemap[1].ramgpu
		if tilemapRAM and tilemapRAM.addr ~= newTilemapAddr then
--DEBUG:print'updating tilemapRAM addr'
			tilemapRAM:updateAddr(newTilemapAddr)
		end
		local newPaletteAddr = self.ram.paletteAddr
		local paletteRAM = self.blobs.palette[1].ramgpu
		if paletteRAM and paletteRAM.addr ~= newPaletteAddr then
--DEBUG:print'updating paletteRAM addr'
			paletteRAM:updateAddr(newPaletteAddr)
		end
		local newFontAddr = self.ram.fontAddr
		local fontRAM = self.blobs.font[1].ramgpu
		if fontRAM and fontRAM.addr ~= newFontAddr then
--DEBUG:print'updating fontRAM addr'
			fontRAM:updateAddr(newFontAddr)
		end

		-- BIG TODO for feedback framebuffer
		-- if any of the sheets are pointed to the framebuffer then we gotta checkDirtyGPU here on the framebuffer every frame ...
		-- in fact same if the framebuffer points to any of the other system RAM addresses, in case you want to draw to the fontWidth array or something ...
		-- but we don't need to always be copying back from GPU to CPU ... only if any of the sheets overlap with it ...
		-- and if any sheets intersect with it then we need to copy the GPU back to CPU ... and then set the sheets' dirtyCPU flag ...
		local spriteSheetOverlapsFramebuffer = self.framebufferRAM:overlaps(sheetRAM)
		local tileSheetOverlapsFramebuffer = self.framebufferRAM:overlaps(tileSheetRAM)
		local tilemapOverlapsFramebuffer = self.framebufferRAM:overlaps(tilemapRAM)
		local paletteOverlapsFramebuffer = self.framebufferRAM:overlaps(paletteRAM)
		local fontOverlapsFramebuffer = self.framebufferRAM:overlaps(fontRAM)
		if spriteSheetOverlapsFramebuffer
		or tileSheetOverlapsFramebuffer
		or tilemapOverlapsFramebuffer
		or paletteOverlapsFramebuffer
		or fontOverlapsFramebuffer
		then
--DEBUG:print'syncing framebuffer'
			self.framebufferRAM:checkDirtyGPU()
			if spriteSheetOverlapsFramebuffer then sheetRAM.dirtyCPU = true end
			if tileSheetOverlapsFramebuffer then tileSheetRAM.dirtyCPU = true end
			if tilemapOverlapsFramebuffer then tilemapRAM.dirtyCPU = true end
			if paletteOverlapsFramebuffer then paletteRAM.dirtyCPU = true end
			if fontOverlapsFramebuffer then fontRAM.dirtyCPU = true end
		end

		-- update threadpool, clients or servers
		self.threads:update()

		self:setVideoMode(self.ram.videoMode)

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
			local x = self.screenMousePos.x / self.width * (self.orthoMax.x - self.orthoMin.x) + self.orthoMin.x
			local y = self.screenMousePos.y / self.height * (self.orthoMax.y - self.orthoMin.y) + self.orthoMin.y
			local mouseFbTex = self.activeMenu and self.videoModes[255].framebufferRAM.tex or self.framebufferRAM.tex
			self.ram.mousePos.x = x * tonumber(mouseFbTex.width)
			self.ram.mousePos.y = y * tonumber(mouseFbTex.height)
			if self:keyp'mouse_left' then
				self.ram.lastMousePressPos:set(self.ram.mousePos:unpack())
			end
		end

		gl.glEnable(gl.GL_DEPTH_TEST)	-- must wrap proper triBuf_flush()'s

		-- TODO why is this necessary for `mode(1) cls()` to clear screen in the console?
		-- why here and not somewhere else?
		-- and what order should it be in versus the framebufferRAM:checkDirtyCPU()?
		-- what should resolve in what order?
		self:triBuf_flush()

		-- flush any cpu changes to gpu before updating
		self.framebufferRAM:checkDirtyCPU()

		local fb = self.fb
		fb:bind()
		self.inUpdateCallback = true	-- tell video not to set up the fb:bind() to do gfx stuff
		local fbTex = self.framebufferRAM.tex
		gl.glViewport(0, 0, fbTex.width, fbTex.height)

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
print('run thread dead')
					self:setFocus(nil)
					if self.activeMenu == nil then
						-- if the cart dies it's cuz of an exception (right?) so best to show the console (right?)
						self:setMenu(self.con)
					end
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
			-- nothing in focus , let the console know by drawing some kind of background pattern ... or meh ...
			self:clearScreen()
		end

		-- now run the console and editor, separately, if it's open
		-- this way server can issue console commands while the game is running
		self:triBuf_flush()	-- flush before gl state change
		gl.glDisable(gl.GL_BLEND)
		gl.glDisable(gl.GL_DEPTH_TEST)

		-- if we're using menu then render to the framebufferMenuTex
		-- ... and don't mess with the VRAM or any draw calls that would reflect on it
		if self.activeMenu then
			local ditherPush = self.ram.dither
			self.ram.dither = 0

			-- push matrix
			ffi.copy(mvMatPush, self.ram.mvMat, ffi.sizeof(mvMatPush))

			-- push clip rect
			local pushClipX, pushClipY, pushClipW, pushClipH = self:getClipRect()

			-- set drawText font & pal to the UI's
			-- TODO not using this for drawText anymore so meh who still uses it?
			self.inMenuUpdate = true

			-- setVideoMode here to make sure we're drawing with the RGB565 shaders and not indexed palette stuff
			self:setVideoMode(255)

			gl.glViewport(0, 0, self.framebufferRAM.tex.width, self.framebufferRAM.tex.height)

			-- so as long as the framebuffer is pointed at the framebufferMenuTex while the menu is drawing then the game's VRAM won't be modified by editor draw commands and I should be fine right?
			-- the draw commands will all go to framebufferMenuTex and not the VRAM framebufferRAM
			-- and maybe the draw commands will do some extra gpu->cpu flushing of the VRAM framebufferRAM, but meh, it still won't change them.

			self:matident()
			self:setClipRect(0, 0, clipMax, clipMax)

			-- while we're here, start us off with the current framebufferRAM contents
			-- framebufferMenuTex is RGB, while framebufferRAM can vary depending on the video mode, so I'll use the blitScreenObj to draw it
			gl.glClear(bit.bor(gl.GL_COLOR_BUFFER_BIT, gl.GL_DEPTH_BUFFER_BIT))
			-- [[
			local view = self.blitScreenView
			view.projMat:setOrtho(0, 1, 0, 1, -1, 1)
			view.mvMat:setIdent()
			view.mvProjMat:mul4x4(view.projMat, view.mvMat)
			local sceneObj = self.blitScreenObj
			sceneObj.uniforms.mvProjMat = view.mvProjMat.ptr
			sceneObj.uniforms.useLighting = self.ram.useHardwareLighting
			sceneObj:draw()
			--]]

			local thread = self.activeMenu.thread
			if thread then
				self.menuSizeInSprites.y = 256
				self.menuSizeInSprites.x = 256 * self.width / self.height
				self:matMenuReset()

				if coroutine.status(thread) == 'dead' then
					self:setMenu(nil)
				else
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
			end

			self:setVideoMode(self.ram.videoMode)

			-- necessary or nah?
			local fbTex = self.framebufferRAM.tex
			gl.glViewport(0, 0, fbTex.width, fbTex.height)

			-- set drawText font & pal to the ROM's
			self.inMenuUpdate = false

			-- pop the clip rect
			self:setClipRect(pushClipX, pushClipY, pushClipW, pushClipH)

			-- pop the matrix
			ffi.copy(self.ram.mvMat, mvMatPush, ffi.sizeof(mvMatPush))
			self:onMvMatChange()

			-- pop ram dither
			self.ram.dither = ditherPush
		end

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
--DEBUG:assert(by >= 0 and by < ffi.sizeof(self.ram.keyPressFlags))
--DEBUG:assert(by >= 0 and by < ffi.sizeof(self.ram.lastKeyPressFlags))
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
--DEBUG:assert.eq(ffi.cast('uint8_t*', holdptr), ffi.cast('uint8_t*', self.ram.keyHoldCounter) + ffi.sizeof(self.ram.keyHoldCounter))
		end

		-- copy last key buffer to key buffer here after update()
		-- so that sdl event can populate changes to current key buffer while execution runs outside this callback
		ffi.copy(self.ram.lastKeyPressFlags, self.ram.keyPressFlags, keyPressFlagSize)

		-- also reset the mousewheel ...
		self.ram.mouseWheel.x = 0
		self.ram.mouseWheel.y = 0

--print('press flags', (ffi.string(self.ram.lastKeyPressFlags, keyPressFlagSize):gsub('.', function(ch) return ('%02x'):format(ch:byte()) end)))
--print('mouse_left', self:key'mouse_left')

		-- do this every frame or only on updates?
		-- how about no more than twice after an update (to please the double-buffers)
		-- TODO don't do it unless we've changed the framebuffer since the last draw
		-- 	so any time framebufferRAM is modified (wherever dirtyCPU/GPU is set/cleared), also set a changedSinceDraw=true flag
		-- then here test for that flag and only re-increment 'needDraw' if it's set
		if self.framebufferRAM.changedSinceDraw then
			self.framebufferRAM.changedSinceDraw = false
			needDrawCounter = drawCounterNeededToRedraw
		end

		if self.activeMenu then
			needDrawCounter = 1
		end

--DEBUG(glquery):updateQueryTotal = updateQueryTotal + updateQuery:doneWithResult()
--DEBUG(glquery):updateQueryFrames = updateQueryFrames + 1
	end

	if needDrawCounter > 0 then
		needDrawCounter = needDrawCounter - 1
		drawsPerSecond = drawsPerSecond + 1

		if self.activeMenu then
			self:setVideoMode(255)
		end

--DEBUG(glquery):drawQuery:begin()

		-- for mode-1 8bpp-indexed video mode - we will need to flush the palette as well, before every blit too
		local videoModeObj = self.videoModes[self.ram.videoMode]
		if videoModeObj and videoModeObj.format == '8bppIndex' then
			self.blobs.palette[1].ramgpu:checkDirtyCPU()
		end

		gl.glViewport(0, 0, self.width, self.height)
		gl.glClearColor(.1, .2, .3, 1.)
		gl.glClear(bit.bor(gl.GL_COLOR_BUFFER_BIT, gl.GL_DEPTH_BUFFER_BIT))

	-- [[ redo ortho projection matrix
	-- every frame for us to use a proper rectangle
		local view = self.blitScreenView
		local orthoSize = view.orthoSize

		local fbTex = self.activeMenu and self.videoModes[255].framebufferRAM.tex or self.framebufferRAM.tex
		--local fbTex = self.framebufferRAM.tex

		local wx, wy = self.width, self.height
		local fx = wx / fbTex.width
		local fy = wy / fbTex.height
		if fx > fy then
			local rx = fx / fy
			self.orthoMin.x = -orthoSize * (rx - 1) * .5
			self.orthoMax.x = orthoSize * (((rx - 1) * .5) + 1)
			self.orthoMax.y = orthoSize
			self.orthoMin.y = 0
			view.projMat:setOrtho(
				self.orthoMin.x,
				self.orthoMax.x,
				self.orthoMax.y,
				self.orthoMin.y,
				-1,
				1
			)
		else
			local ry = fy / fx
			self.orthoMin.x = 0
			self.orthoMax.x = orthoSize
			self.orthoMax.y = orthoSize * (((ry - 1) * .5) + 1)
			self.orthoMin.y = -orthoSize * (ry - 1) * .5
			view.projMat:setOrtho(
				self.orthoMin.x,
				self.orthoMax.x,
				self.orthoMax.y,
				self.orthoMin.y,
				-1,
				1
			)
		end
		view.mvMat:setIdent()
		view.mvProjMat:mul4x4(view.projMat, view.mvMat)
		local sceneObj = self.blitScreenObj
		sceneObj.uniforms.mvProjMat = view.mvProjMat.ptr
		if self.activeMenu then
			sceneObj.uniforms.useLighting = self.menuUseLighting and 1 or 0
		else
			sceneObj.uniforms.useLighting = self.ram.useHardwareLighting
		end

		if self.activeMenu then
			sceneObj.texs[1] = self.videoModes[255].framebufferRAM.tex
			-- TODO what should I bind texs[2], i.e. the normalTex to?
		end
--]]

		-- draw from framebuffer to screen
		sceneObj:draw()
		-- [[ and swap ... or just don't use backbuffer at all ...
		sdl.SDL_GL_SwapWindow(self.window)
		--]]
		if self.activeMenu then
			sceneObj.texs[1] = self.framebufferRAM.tex
			sceneObj.texs[2] = self.framebufferNormalTex
		end

		if self.activeMenu then
			self:setVideoMode(self.ram.videoMode)
		end

--DEBUG(glquery):drawQueryTotal = drawQueryTotal + drawQuery:doneWithResult()
--DEBUG(glquery):drawQueryFrames = drawQueryFrames + 1
	end

	if self.takeScreenshot then
		if self.takeScreenshot == 'label' then
			self:saveLabel()
		else
			self:screenshot()
		end
		self.takeScreenshot = nil
	end

	glreport'here'
end

-- ... where to put this ... in video, app, or ui?
function App:matMenuReset()
	self:matident()
	local m = math.min(self.width, self.height)
	self:mattrans((self.width - m) * .5, (self.height - m) * .5)
	self:matscale(self.width / self.menuSizeInSprites.x, self.height / self.menuSizeInSprites.y)
end

-------------------- MEMORY PEEK/POKE (and draw dirty bits) --------------------

function App:peek(addr)
	if addr < 0 or addr >= self.memSize then return end

	-- if we're writing to a dirty area then flush it to cpu
	-- assume the GL framebuffer is bound to the framebufferRAM
	if self.framebufferRAM.dirtyGPU
	and addr >= self.framebufferRAM.addr
	and addr < self.framebufferRAM.addrEnd
	then
		self:triBuf_flush()
		self.framebufferRAM:checkDirtyGPU()
	end

	return self.ram.v[addr]
end
function App:peekw(addr)
	local addrend = addr+1
	if addr < 0 or addrend >= self.memSize then return end

	if self.framebufferRAM.dirtyGPU
	and addrend >= self.framebufferRAM.addr
	and addr < self.framebufferRAM.addrEnd
	then
		self:triBuf_flush()
		self.framebufferRAM:checkDirtyGPU()
	end

	return ffi.cast('uint16_t*', self.ram.v + addr)[0]
end
function App:peekl(addr)
	local addrend = addr+3
	if addr < 0 or addrend >= self.memSize then return end

	if self.framebufferRAM.dirtyGPU
	and addrend >= self.framebufferRAM.addr
	and addr < self.framebufferRAM.addrEnd
	then
		self:triBuf_flush()
		self.framebufferRAM:checkDirtyGPU()
	end

	return ffi.cast('uint32_t*', self.ram.v + addr)[0]
end
function App:peekf(addr)
	local addrend = addr+3
	if addr < 0 or addrend >= self.memSize then return end

	if self.framebufferRAM.dirtyGPU
	and addrend >= self.framebufferRAM.addr
	and addr < self.framebufferRAM.addrEnd
	then
		self:triBuf_flush()
		self.framebufferRAM:checkDirtyGPU()
	end

	return ffi.cast('float*', self.ram.v + addr)[0]
end

function App:poke(addr, value)
	addr = toint(addr)
	value = tonumber(ffi.cast('uint32_t', value))
	if addr < 0 or addr >= self.memSize then return end

	-- if we're writing to a dirty area then flush it to cpu
	if addr >= self.framebufferRAM.addr
	and addr < self.framebufferRAM.addrEnd
	then
		self:triBuf_flush()
		self.framebufferRAM:checkDirtyGPU()
		self.framebufferRAM.dirtyCPU = true
	end

	self.ram.v[addr] = value

	-- write out tris using the mvMat before it changes
	if addr >= mvMatAddr and addr < mvMatAddrEnd then
		self:onMvMatChange()
	end
	if addr >= clipRectAddr and addr < clipRectAddrEnd then
		self:onClipRectChange()
	end
	if addr >= blendColorAddr and addr < blendColorAddrEnd then
		self:onBlendColorChange()
	end

	-- TODO none of the others happen period, only the palette texture
	-- makes me regret DMA exposure of my palette ... would be easier to just hide its read/write behind another function...
	for _,blob in ipairs(self.blobs.sheet) do
		-- use ramgpu since it is the relocatable address
		if addr >= blob.ramgpu.addr
		and addr < blob.ramgpu.addrEnd
		then
			-- TODO if we ever allow redirecting the framebuffer ... to overlap the spritesheet ... then checkDirtyGPU() here too
			--blob.ramgpu:checkDirtyGPU()
			blob.ramgpu.dirtyCPU = true
		end
	end
	for _,blob in ipairs(self.blobs.tilemap) do
		-- use ramgpu since it is the relocatable address
		if addr >= blob.ramgpu.addr
		and addr < blob.ramgpu.addrEnd
		then
			--blob.ramgpu:checkDirtyGPU()
			blob.ramgpu.dirtyCPU = true
		end
	end
	-- a few options with dirtying palette entries
	-- 1) consolidate calls, so write this separately in pokew and pokel
	-- 2) dirty flag, and upload pre-draw.  but is that for uploading all the palette pre-draw?  or just the range of dirty entries?  or just the individual entries (multiple calls again)?
	--   then before any render that uses palette, check dirty flag, and if it's set then re-upload
	for _,blob in ipairs(self.blobs.palette) do
		-- use ramgpu since it is the relocatable address
		if addr >= blob.ramgpu.addr
		and addr < blob.ramgpu.addrEnd
		then
			blob.ramgpu.dirtyCPU = true
		end
	end
	for _,blob in ipairs(self.blobs.font) do
		-- use ramgpu since it is the relocatable address
		if addr >= blob.ramgpu.addr
		and addr < blob.ramgpu.addrEnd
		then
			blob.ramgpu.dirtyCPU = true
		end
	end
	-- TODO merge the above with their respective blobs
	-- and then just cycle all blobs and flag here
	for _,voxelmap in ipairs(self.blobs.voxelmap) do
		-- TODO allow voxelmap to have relocatable addresses?
		-- merge BlobImage ramgpu into BlobImage and rename this field to 'relocAddr' and 'relocAddrEnd' ?
		if addr >= voxelmap.addr
		and addr < voxelmap.addrEnd
		then
			voxelmap.dirtyCPU = true
		end
	end
	-- TODO if we poked the code
end
function App:pokew(addr, value)
	addr = toint(addr)
	value = tonumber(ffi.cast('uint32_t', value))
	local addrend = addr+1
	if addr < 0 or addrend >= self.memSize then return end

	if addrend >= self.framebufferRAM.addr
	and addr < self.framebufferRAM.addrEnd
	then
		self:triBuf_flush()
		self.framebufferRAM:checkDirtyGPU()
		self.framebufferRAM.dirtyCPU = true
	end

	ffi.cast('uint16_t*', self.ram.v + addr)[0] = value

	-- write out tris using the mvMat before it changes
	if addrend >= mvMatAddr and addr < mvMatAddrEnd then
		self:onMvMatChange()
	end
	if addrend >= clipRectAddr and addr < clipRectAddrEnd then
		self:onClipRectChange()
	end
	if addrend >= blendColorAddr and addr < blendColorAddrEnd then
		self:onBlendColorChange()
	end

	for _,blob in ipairs(self.blobs.sheet) do
		if addrend >= blob.ramgpu.addr
		and addr < blob.ramgpu.addrEnd
		then
			blob.ramgpu.dirtyCPU = true
		end
	end
	for _,blob in ipairs(self.blobs.tilemap) do
		if addrend >= blob.ramgpu.addr
		and addr < blob.ramgpu.addrEnd
		then
			blob.ramgpu.dirtyCPU = true
		end
	end
	for _,blob in ipairs(self.blobs.palette) do
		if addrend >= blob.ramgpu.addr
		and addr < blob.ramgpu.addrEnd
		then
			blob.ramgpu.dirtyCPU = true
		end
	end
	for _,blob in ipairs(self.blobs.font) do
		if addrend >= blob.ramgpu.addr
		and addr < blob.ramgpu.addrEnd
		then
			blob.ramgpu.dirtyCPU = true
		end
	end
	-- TODO merge the above with their respective blobs
	-- and then just cycle all blobs and flag here
	for _,voxelmap in ipairs(self.blobs.voxelmap) do
		if addrend >= voxelmap.addr
		and addr < voxelmap.addrEnd
		then
			voxelmap.dirtyCPU = true
		end
	end
	-- TODO if we poked the code
end
function App:pokel(addr, value)
	addr = toint(addr)
	value = tonumber(ffi.cast('uint32_t', value))
	local addrend = addr+3
	if addr < 0 or addrend >= self.memSize then return end

	if addrend >= self.framebufferRAM.addr
	and addr < self.framebufferRAM.addrEnd
	then
		self:triBuf_flush()
		self.framebufferRAM:checkDirtyGPU()
		self.framebufferRAM.dirtyCPU = true
	end

	ffi.cast('uint32_t*', self.ram.v + addr)[0] = value

	-- write out tris using the mvMat before it changes
	if addrend >= mvMatAddr and addr < mvMatAddrEnd then
		self:onMvMatChange()
	end
	if addrend >= clipRectAddr and addr < clipRectAddrEnd then
		self:onClipRectChange()
	end
	if addrend >= blendColorAddr and addr < blendColorAddrEnd then
		self:onBlendColorChange()
	end

	for _,blob in ipairs(self.blobs.sheet) do
		if addrend >= blob.ramgpu.addr
		and addr < blob.ramgpu.addrEnd
		then
			blob.ramgpu.dirtyCPU = true
		end
	end
	for _,blob in ipairs(self.blobs.tilemap) do
		if addrend >= blob.ramgpu.addr
		and addr < blob.ramgpu.addrEnd
		then
			blob.ramgpu.dirtyCPU = true
		end
	end
	for _,blob in ipairs(self.blobs.palette) do
		if addrend >= blob.ramgpu.addr
		and addr < blob.ramgpu.addrEnd
		then
			blob.ramgpu.dirtyCPU = true
		end
	end
	for _,blob in ipairs(self.blobs.font) do
		if addrend >= blob.ramgpu.addr
		and addr < blob.ramgpu.addrEnd
		then
			blob.ramgpu.dirtyCPU = true
		end
	end
	-- TODO merge the above with their respective blobs
	-- and then just cycle all blobs and flag here
	for _,voxelmap in ipairs(self.blobs.voxelmap) do
		if addrend >= voxelmap.addr
		and addr < voxelmap.addrEnd
		then
			voxelmap.dirtyCPU = true
		end
	end
	-- TODO if we poked the code
end
function App:pokef(addr, value)
	addr = toint(addr)
	value = tofloat(value)
	local addrend = addr+3
	if addr < 0 or addrend >= self.memSize then return end

	if addrend >= self.framebufferRAM.addr
	and addr < self.framebufferRAM.addrEnd
	then
		self:triBuf_flush()
		self.framebufferRAM:checkDirtyGPU()
		self.framebufferRAM.dirtyCPU = true
	end

	ffi.cast('float*', self.ram.v + addr)[0] = value

	-- write out tris using the mvMat before it changes
	if addrend >= mvMatAddr and addr < mvMatAddrEnd then
		self:onMvMatChange()
	end
	if addrend >= clipRectAddr and addr < clipRectAddrEnd then
		self:onClipRectChange()
	end
	if addrend >= blendColorAddr and addr < blendColorAddrEnd then
		self:onBlendColorChange()
	end

	for _,blob in ipairs(self.blobs.sheet) do
		if addrend >= blob.ramgpu.addr
		and addr < blob.ramgpu.addrEnd
		then
			blob.ramgpu.dirtyCPU = true
		end
	end
	for _,blob in ipairs(self.blobs.tilemap) do
		if addrend >= blob.ramgpu.addr
		and addr < blob.ramgpu.addrEnd
		then
			blob.ramgpu.dirtyCPU = true
		end
	end
	for _,blob in ipairs(self.blobs.palette) do
		if addrend >= blob.ramgpu.addr
		and addr < blob.ramgpu.addrEnd
		then
			blob.ramgpu.dirtyCPU = true
		end
	end
	for _,blob in ipairs(self.blobs.font) do
		if addrend >= blob.ramgpu.addr
		and addr < blob.ramgpu.addrEnd
		then
			blob.ramgpu.dirtyCPU = true
		end
	end
	-- TODO merge the above with their respective blobs
	-- and then just cycle all blobs and flag here
	for _,voxelmap in ipairs(self.blobs.voxelmap) do
		if addrend >= voxelmap.addr
		and addr < voxelmap.addrEnd
		then
			voxelmap.dirtyCPU = true
		end
	end
	-- TODO if we poked the code
end

function App:memcpy(dst, src, len)
	if len <= 0 then return end

	-- truncate address ranges to valid ranges, or just discount the call altogether?  truncate
	-- if I wanted to truncate the src, what happens if the source is OOB?  read default values of zero
	if dst < 0 then
		src = src - dst
		len = len + dst
		if len <= 0 then return end
		dst = 0
	end
	if dst + len >= self.memSize then
		len = self.memSize - dst
		if len <= 0 then return end
	end
	local dstend = dst + len
	local srcend = src + len
--DEBUG:assert.ge(dst, 0)
--DEBUG:assert.ge(dstend, 0)
--DEBUG:assert.lt(dst, self.memSize)
--DEBUG:assert.lt(dstend, self.memSize)
	if srcend < 0 or src >= self.memSize
	then return end

	local touchessrc = srcend >= self.framebufferRAM.addr and src < self.framebufferRAM.addrEnd
	local touchesdst = dstend >= self.framebufferRAM.addr and dst < self.framebufferRAM.addrEnd
	if touchessrc or touchesdst then
		self:triBuf_flush()
		self.framebufferRAM:checkDirtyGPU()
		if touchesdst then
			self.framebufferRAM.dirtyCPU = true
		end
	end

	do
		local rsrc, rdst, rlen = src, dst, len
		if rsrc < 0 then
			ffi.fill(self.ram.v + rdst, math.min(-rsrc, rlen))
		end
		if not (rsrc < 0 and -rsrc <= rlen) then
			if rsrc < 0 then
				rdst = rdst - rsrc
				rlen = rlen + rsrc
				rsrc = 0
			end
			local copyLen = math.min(rlen, self.memSize - rsrc)
			ffi.copy(self.ram.v + rdst, self.ram.v + rsrc, copyLen)
			rlen = rlen - copyLen
			rdst = rdst + copyLen
			rsrc = rsrc + copyLen
			if rlen > 0 then
				-- at this point, rsrc should be at the end of memory.
				-- if it's not then we would've failed the prev if-cond in the last line
--DEBUG:assert.eq(rsrc, self.memSize)
				ffi.fill(self.ram.v + rdst, rlen)
			end
		end
	end

	-- write out tris using the mvMat before it changes
	if dstend >= mvMatAddr and dst < mvMatAddrEnd then
		self:onMvMatChange()
	end
	if dstend >= clipRectAddr and dst < clipRectAddrEnd then
		self:onClipRectChange()
	end
	if dstend >= blendColorAddr and dst < blendColorAddrEnd then
		self:onBlendColorChange()
	end

	for _,blob in ipairs(self.blobs.sheet) do
		if dstend >= blob.ramgpu.addr
		and dst < blob.ramgpu.addrEnd
		then
			blob.ramgpu.dirtyCPU = true
		end
	end
	for _,blob in ipairs(self.blobs.tilemap) do
		if dstend >= blob.ramgpu.addr
		and dst < blob.ramgpu.addrEnd
		then
			blob.ramgpu.dirtyCPU = true
		end
	end
	for _,blob in ipairs(self.blobs.palette) do
		if dstend >= blob.ramgpu.addr
		and dst < blob.ramgpu.addrEnd
		then
			blob.ramgpu.dirtyCPU = true
		end
	end
	for _,blob in ipairs(self.blobs.font) do
		if dstend >= blob.ramgpu.addr
		and dst < blob.ramgpu.addrEnd
		then
			blob.ramgpu.dirtyCPU = true
		end
	end
	-- TODO merge the above with their respective blobs
	-- and then just cycle all blobs and flag here
	for _,voxelmap in ipairs(self.blobs.voxelmap) do
		if dstend >= voxelmap.addr
		and dst < voxelmap.addrEnd
		then
			voxelmap.dirtyCPU = true
		end
	end
end

function App:memset(dst, val, len)
	if len <= 0 then return end

	-- truncate address ranges to valid ranges, or just discount the call altogether? truncate
	if dst < 0 then
		len = len + dst
		if len <= 0 then return end
		dst = 0
	end
	if dst + len >= self.memSize then
		len = self.memSize - dst
		if len <= 0 then return end
	end

	local dstend = dst + len
--DEBUG:assert.ge(dst, 0)
--DEBUG:assert.ge(dstend, 0)

	if dstend >= self.framebufferRAM.addr
	and dst < self.framebufferRAM.addrEnd
	then
		self:triBuf_flush()
		self.framebufferRAM:checkDirtyGPU()
		self.framebufferRAM.dirtyCPU = true
	end

	ffi.fill(self.ram.v + dst, len, val)

	-- write out tris using the mvMat before it changes
	if dstend >= mvMatAddr and dst < mvMatAddrEnd then
		self:onMvMatChange()
	end
	if dstend >= clipRectAddr and dst < clipRectAddrEnd then
		self:onClipRectChange()
	end
	if dstend >= blendColorAddr and dst < blendColorAddrEnd then
		self:onBlendColorChange()
	end

	for _,blob in ipairs(self.blobs.sheet) do
		if dstend >= blob.ramgpu.addr
		and dst < blob.ramgpu.addrEnd
		then
			blob.ramgpu.dirtyCPU = true
		end
	end
	for _,blob in ipairs(self.blobs.tilemap) do
		if dstend >= blob.ramgpu.addr
		and dst < blob.ramgpu.addrEnd
		then
			blob.ramgpu.dirtyCPU = true
		end
	end
	for _,blob in ipairs(self.blobs.palette) do
		if dstend >= blob.ramgpu.addr
		and dst < blob.ramgpu.addrEnd
		then
			blob.ramgpu.dirtyCPU = true
		end
	end
	for _,blob in ipairs(self.blobs.font) do
		if dstend >= blob.ramgpu.addr
		and dst < blob.ramgpu.addrEnd
		then
			blob.ramgpu.dirtyCPU = true
		end
	end
	-- TODO merge the above with their respective blobs
	-- and then just cycle all blobs and flag here
	for _,voxelmap in ipairs(self.blobs.voxelmap) do
		if dstend >= voxelmap.addr
		and dst < voxelmap.addrEnd
		then
			voxelmap.dirtyCPU = true
		end
	end
end

-------------------- ROM STATE STUFF --------------------

-- call this when you change blobs around and you wanna rebuild RAM and reset addresses
-- NOTICE only call this from outside the inUpdateCallback
-- in fact, any time you call checkDirtyGPU on a framebufferRAM that is,
-- you will need to do it from outside the inUpdateCallback
-- do this in main loop and outside inUpdateCallback so that framebufferRAM's checkDirtyGPU's can use the right framebuffer (and not the currently bound one)
function App:updateBlobChanges()
	-- rebuild RAM from blobs
	self:buildRAMFromBlobs()
	-- then reassign all pointers
	-- ... resetVideo() is similar but I don't want to reset to the default addrs
	for _,framebufferRAM in pairs(self.framebufferRAMs) do
		assert(not framebufferRAM.dirtyGPU)
		framebufferRAM:updateAddr(framebufferRAM.addr)
	end
--[[ resetVideo WORKS BUT resets everything... I just want the pointers to be reset.
	self:resetVideo()
--]]
-- [[
	self:resizeRAMGPUs()
--	self:allRAMRegionsCheckDirtyCPU()
--	self:allRAMRegionsCheckDirtyGPU()
--]]
	-- net_updateBlobChanges() ... or have all updates net updates ...
	--app:net_resetCart()
	-- TODO here and also in numo9/ui' 'save' button -> saveCart -> updateBlobChanges

	-- while we're here, if we resizeRAMGPU's / resize GPU resources of blobs
	-- first off we want to flush tris, I'm just gonna assume we already have
	-- but second, if any textures are stored in the triBuf state and are deleted then I should clear those here
	self.lastPaletteTex = nil
	self.lastSheetTex = nil
	self.lastTilemapTex = nil
end

-- save from cartridge to filesystem
function App:saveCart(filename)
--	self:checkDirtyGPU()

	-- flush that back to .blobs ...
	-- ... or not? idk.  handle this by the editor?
	--self:copyRAMToBlobs()
	-- TODO self.ram vs self.blobs ... editor puts .blobs into .ram before editing
	-- or at least it used to ... now with multiplayer editing idk even ...

	-- and then that to the virtual filesystem ...
	-- and then that to the real filesystem ...

	-- copy everything back to RAM before saving
	-- but wait, that still wont make a difference right?
	-- cuz if its in RAM, that wont affect the cart ROM ...
	self:allRAMRegionsCheckDirtyGPU()
	self:updateBlobChanges()

	if not select(2, path(filename):getext()) then
		filename = path(filename):setext'n9'.path
		-- TODO try twice? as .n9 and .n9.png?  or don't add extensions at all?
	end
	filename = filename
		--or self.currentLoadedFilename 	-- overwrite? backup? trust them to be using revision control?
		or defaultSaveFilename
	local basemsg = 'failed to save file '..tostring(filename)

	local blobstr = ffi.string(self.ram.v, self.memSize)

	-- TODO xpcall?
	local success, s = xpcall(blobStrToCartImage, errorHandler, blobstr)
	--local success, s = xpcall(blobsToCartImage, errorHandler, self.blobs)
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
then call resetCart which loads
TODO maybe ... have the editor modify the cartridge copy as well
(this means it wouldn't live-update palettes and sprites, since they are gathered from RAM
	... unless I constantly copy changes across as the user edits ... maybe that's best ...)
(or it would mean upon entering editor to copy the cartridge back into RAM, then edit as usual (live updates on palette and sprites)
	and then when done editing, copy back from RAM to cartridge)

whoever calls this should create a runFocus coroutine to load the ROM
 so that the load only takes place in the runFocus loop and not the UI loop (which pushes and pops the modelview matrix values)
--]]
function App:openCart(filename)
--DEBUG:print('App:openCart', filename)
	-- if there was an old ROM loaded then write its persistent data ...
	self:writePersistent()

	--[[ before resizing the memory range, make sure all memory is synced, so that when we move addresses later it doesn't try to sync to CPU mem that is stale / dangling
	self:allRAMRegionsCheckDirtyGPU()
	self:allRAMRegionsCheckDirtyCPU()
	--]]
	-- [[ can I just clear?  if i'm loading new data then no need to copy back
	for _,v in pairs(self.framebufferRAMs) do
		v.dirtyCPU = false
		v.dirtyGPU = false
	end
	for _,blob in ipairs(self.blobs.sheet) do
		blob.ramgpu.dirtyCPU = false
		blob.ramgpu.dirtyGPU = false
	end
	for _,blob in ipairs(self.blobs.tilemap) do
		blob.ramgpu.dirtyCPU = false
		blob.ramgpu.dirtyGPU = false
	end
	for _,blob in ipairs(self.blobs.palette) do
		blob.ramgpu.dirtyCPU = false
		blob.ramgpu.dirtyGPU = false
	end
	for _,blob in ipairs(self.blobs.font) do
		blob.ramgpu.dirtyCPU = false
		blob.ramgpu.dirtyGPU = false
	end
	--]]

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

	self:setBlobs(cartImageToBlobs(d))

	self:updateBlobChanges()

	self.currentLoadedFilename = filename	-- last loaded cartridge - display this somewhere

	for _,editField in ipairs(table.values(require 'numo9.ui'.editFieldForMode):sort()) do
		local editor = self[editField]
		if editor and editor.onCartLoad then
			editor:onCartLoad()
		end
	end

	self:matident()
	self:resetCart()

	return true
end

function App:writePersistent()
	--if not self.currentLoadedFilename then return end	-- should not I bother if there's no cartridge loaded? or still allow saving of persistent data if ppl are messing around on the editor?

	-- first call, there's no metainfo, so if it's not there then don't save anything
	if self.metainfo then
		assert(self.metainfo.saveid, "how did you get here?  in App:runCart metainfo.saveid should have been written.")
		-- TODO this when you read cart header ... or should we put it in ROM somewhere?
		-- save a string up to the last non-zero value ... opposite  of C-strings
		local data = self.blobs.persist:mapi(function(blob)
			blob:copyFromROM()
			return blob.data
		end):concat()
		local len = #data
		while len > 0 do
			if data:byte(len) ~= 0 then break end
			len = len - 1
		end
		local saveStr = data:sub(1,len)
--DEBUG:print('writePersistent self.metainfo.saveid', self.metainfo.saveid, require'ext.tolua'(saveStr))
		local cartPersistFile = self.cfgdir(self.metainfo.saveid..'.save')
		if len == 0 then
--DEBUG:print('clearing persist file: '..cartPersistFile)
			cartPersistFile:remove()
		else
--DEBUG:print('saving persist file: '..cartPersistFile)
			cartPersistFile:write(saveStr)
		end
		-- now where does self.cfg get written?
	end
end

--[[
This resets everything from the last loaded .blobs ROM into .ram
Equivalent of loading the previous ROM again.
That means code too - save your changes!

TODO
split this function between resetting the cartridge / system (i.e. RAM+ROM state + hardware)
 and resetting only the ROM
--]]
function App:resetCart()
--DEBUG:print'App:resetCart'
	self:copyBlobsToROM()

	-- NOTICE this sets the video mode to 0 ...
	self:resetVideo()

	-- calling reset() live will kill all sound ...
	-- ... unless I move resetAudio() into load()
	return true
end

-- returns the function to run the code
function App:loadCmd(cmd, source, env)
	-- Lua is wrapping [string "  "] around my source always ...
	return self.loadenv.load(cmd, source, 't', env or self.gameEnv or self.env)
end

--[[
system() function
TODO fork this between console functions and between running "rom" code
TODO 'return' prefix xpcall like interpreter does? or do that in caller?
but then the caller would risk extra prints ...
... unless I moved print outside this function too ...
This is only run from -e init and from numo9/console.lua so I'll just do it here.
--]]
function App:runCmd(cmd)
	--[[ suppress always
	local f, msg = self:loadCmd(cmd)
	if not f then return f, msg end
	return xpcall(f, errorHandler)
	--]]
	-- [[ error always
	local f, msg = self:loadCmd('return '..cmd, 'con')	-- return prepend first or second?
	-- TODO if there's a cartridge loaded then why not use its env, for debugging eh?
	--, self.gameEnv -- would be nice but gameEnv doesn't have langfix, i.e. self.env
	-- if it fails then try again with a 'return' on the front ...
	if not f then
		f = self:loadCmd(cmd, 'con')
		-- if f fails again then use the first error message (right?)
	end
	if not f then
		error(msg)
	end
	local result = table.pack(f())
	self.con:print(result:unpack())
	return result:unpack()
	--]]
end

local function indexargs(field, ...)
	if select('#', ...) == 0 then return end
	return (...)[field], indexargs(field, select(2, ...))
end

local function seq(n, i)
	i = i or 0
	if i>=n then return end
	return i, seq(n, i+1)
end

-- TODO ... welp what is editor editing?  the cartridge?  the virtual-filesystem disk image?
-- once I figure that out, this should make sure the cartridge and RAM have the correct changes
function App:runCart()

	-- when should we write the old persist?  when opening?  when resetting?  when running?
	self:writePersistent()

	self:resetCart()
	self:resetAudio()
	self.isPaused = false
	self:setMenu(nil)

	-- TODO setfenv instead?
	local env = setmetatable({}, {
		__index = self.env,
	})

	local code = self.blobs.code:mapi(function(blob, i)
		return
			-- TODO this?  pro: delineation.  con: error line #s are offset
			-- but they'll always be offset if I add more than one code blob?
			-- but I'm not doing that yet ...
			-- '-- blob #'..i..':\n'..
			blob.data
	end):concat'\n'

	-- reload the metadata while we're here
	self.metainfo = {}
	do
		local i = 1
		repeat
			local from, to, line, term = code:find('^([^\r\n]*)(\r?\n)', i)
			if not line then break end -- I guess no single-line meta tags with no code afterwards ...
			local k, v = line:match'^%-%-%s*([^%s=]+)%s*=%s*(.-)%s*$'
			if not k then break end
--DEBUG:print('setting metainfo', k, v)
			self.metainfo[k] = v
			i = to + #term
		until false
	end
	if not self.metainfo.saveid then
		self.metainfo.saveid = sha2.md5(blobsToStr(self.blobs))
	end

	-- here copy persistent into RAM ... here? or somewhere else?  reset maybe? but it persists so reset shouldn't matter ...
	local cartPersistFile = self.cfgdir(self.metainfo.saveid..'.save')
	if cartPersistFile:exists() then
--DEBUG:print('loading persist file: '..cartPersistFile)
		local saveStr = cartPersistFile:read()
		if saveStr and #saveStr > 0 then
--DEBUG:print('persist got')
--DEBUG:print(string.hexdump(saveStr))
			-- persist blobs should already be in cart ROM, even if they are empty, so ...
			local p = ffi.cast('uint8_t*', saveStr)
			local pend = p + #saveStr
			for i,blob in ipairs(self.blobs.persist) do
				-- dangerous to be copying into luajit strings?  should I replace them all with byte-vectors?
				local tocopy = math.min(blob:getSize(), pend - p)
				ffi.copy(blob:getPtr(), p, tocopy)
				blob:copyToROM()
				p = p + tocopy
				if p >= pend then break end
			end
		end
	else
--DEBUG:print('no persist file to load: '..cartPersistFile)
	end

	-- set title if it's there ...
	sdl.SDL_SetWindowTitle(self.window, self.metainfo.title or self.title)

	-- see if the ROM has any preferences on the editor ...
	do
		-- TODO just search all editors?
		for blobType,edit in pairs(require 'numo9.ui'.editFieldForMode) do
			for _,field in ipairs{'sheetBlobIndex', 'draw16Sprites', 'gridSpacing'} do
				local metakey = edit..'.'..field
				local v = self.metainfo[metakey]
				if v ~= nil then
					xpcall(function()
						self[edit][field] = fromlua(v)
					end, function(err)
						print('failed to set metakey', metakey, 'value', v)
					end)
				end
			end
		end
	end

	-- TODO also put the load() in here so it runs in our virtual console update loop
	env.thread = coroutine.create(function()
		self.ram.romUpdateCounter = 0

		-- here, if the assert fails then it's a parse error, and you can just pcall / pick out the offender
		local f, msg = self:loadCmd(code, self.currentLoadedFilename, env)
		if not f then
			--print(msg)
			self.con:print(msg)
			return
		end
		local result = table.pack(f())

--DEBUG:print('LOAD RESULT', result:unpack())
--DEBUG:print('RUNNING CODE')
--DEBUG:print('update:', env.update)

		if not env.update then return end

		-- for consistency let's do an initial onconnect for lo as well
		if not server then
			if env.onconnect then
				env.onconnect'lo'
			end
		end

		while true do
			coroutine.yield()

			env.update()

			local server = self.server
			if server then
				-- I could do a proper loopback client
				-- or I could just run the local conn last and leave the RAM state as-is
				-- TODO if anything but draw commands happen in the draw function then the RAM can go out of sync!!!
				-- how to fix this?
				-- should I fix this?
				-- should I just add a disclaimer to not put any permanent changes in the draw() function?
				-- should I be saving and loading the RAM (sans framebuffer) each time as well?
				-- what about things like the matrix?
				--for _,conn in ipairs(server.conns) do
				for i=#server.conns,1,-1 do
					local conn = server.conns[i]

					-- set our override - cmds only go to this conn
					-- NOTICE (bit of an ugly hack)
					-- but the loopback conn doesn't use messages atm
					-- and the loopback conn runs last
					-- so if it's the loopback conn then just put it in the ... general cmd stack ... ???
					-- maybe I should have the loopback conn always rendering based on its messages ...
					--server.currentCmdConn = conn.remote and conn or nil
					-- but then it doubles up remote sent messages...
					server.currentCmdConn = conn

					-- upon new game, if the server is running,
					-- then call "onconnect" on all conns connected so far.
					-- here - for all connections so far - run the 'onconnect' function if it exists
					-- TODO how about a callback for assigning / unassigning players? so the game can associate player #s with conn IDs ...
					if env.onconnect
					and not conn.hasCalledOnConnect
					then
						conn.hasCalledOnConnect = true
						env.onconnect(conn.ident)
					end

					-- see if the console supports separate drawing for multiple connections ...
					if env.draw then
						-- TODO during this function, capture all commands and send them only to the loopback conn.
						env.draw(conn.ident, indexargs('hostPlayerIndex', table.unpack(conn.playerInfos, 1, conn.numLocalPlayers)))
					end

					server.currentCmdConn = nil
				end
			else
				if env.draw then
					-- if we dont have a server then just do a draw for the loopback connection
					env.draw('lo', seq(self.cfg.numLocalPlayers))
				end
			end
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
	-- if we're closing the menu then tell it to draw one more time
	if editTab == nil then
		self.framebufferRAM.changedSinceDraw = true
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
		keycode = assert.index(keyCodeForName, keycode, 'keyCodeForName')
	end
	assert.type(keycode, 'number')
	return self:keyForBuffer(keycode, self.ram.keyPressFlags)
end

-- tic80 has the option that no args = any button pressed ...
function App:keyp(keycode, hold, period)
	if type(keycode) == 'string' then
		keycode = keyCodeForName[keycode]
	end
	assert.type(keycode, 'number')
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
	assert.type(keycode, 'number')
	return not self:keyForBuffer(keycode, self.ram.keyPressFlags)
	and self:keyForBuffer(keycode, self.ram.lastKeyPressFlags)
end

-- TODO - just use key/p/r, and just use extra flags
-- TODO dont use keyboard keycode for determining fake-joypad button keycode
-- instead do this down in the SDL event handling ...
function App:btn(buttonCode, player, ...)
	if type(buttonCode) == 'string' then
		buttonCode = buttonCodeForName[buttonCode]
			or error(string.format("unknown button string %q ... valid buttons are: %s", buttonCode, buttonNames:concat' '))
	end
	assert.type(buttonCode, 'number')
	if buttonCode < 0 or buttonCode >= 8 then return end

	player = player or 0
	if player < 0 or player >= maxPlayersTotal then return end

	local buttonKeyCode = buttonCode + 8 * player + firstJoypadKeyCode
	return self:key(buttonKeyCode, ...)
end
function App:btnp(buttonCode, player, ...)
	if type(buttonCode) == 'string' then
		buttonCode = buttonCodeForName[buttonCode]
			or error(string.format("unknown button string %q ... valid buttons are: %s", buttonCode, buttonNames:concat' '))
	end
	assert.type(buttonCode, 'number')
	if buttonCode < 0 or buttonCode >= 8 then return end

	player = player or 0
	if player < 0 or player >= maxPlayersTotal then return end

	local buttonKeyCode = buttonCode + 8 * player + firstJoypadKeyCode
	return self:keyp(buttonKeyCode, ...)
end
function App:btnr(buttonCode, player, ...)
	if type(buttonCode) == 'string' then
		buttonCode = buttonCodeForName[buttonCode]
			or error(string.format("unknown button string %q ... valid buttons are: %s", buttonCode, buttonNames:concat' '))
	end
	assert.type(buttonCode, 'number')
	if buttonCode < 0 or buttonCode >= 8 then return end

	player = player or 0
	if player < 0 or player >= maxPlayersTotal then return end

	local buttonKeyCode = buttonCode + 8 * player + firstJoypadKeyCode
	return self:keyr(buttonKeyCode, ...)
end

function App:getMouseState()
	return
		self.ram.mousePos.x,
		self.ram.mousePos.y,
		self.ram.mouseWheel.x,
		self.ram.mouseWheel.y
end

function App:toggleMenu()
	-- special handle the escape key
	-- game -> escape -> console
	-- console -> escape -> editor
	-- editor -> escape -> console
	-- ... how to cycle back to the game without resetting it?
	-- ... can you not issue commands while the game is loaded without resetting the game?
	if self.activeMenu == self.mainMenu then		-- main menu goes to conosle
		-- [[ go to game?
		self:setMenu(nil)
		self.isPaused = false
		if not self.runFocus then
			self:setMenu(self.con)
		end
		--]]
	elseif self.activeMenu == self.cartBrowser then		-- cart browser goes to main menu
		self:setMenu(nil)
		self.isPaused = false
		if not self.runFocus then
			self:setMenu(self.mainMenu)
		end
	elseif self.activeMenu == self.con then				-- console goes to main menu
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
	elseif self.activeMenu then							-- everything else goes to conosle
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
end

function App:resize()
	App.super.resize(self)
	needDrawCounter = drawCounterNeededToRedraw

	-- hack for the native-resolution videomode:
	local videoModeNative = self.videoModes[255]
	if videoModeNative then
		videoModeNative:delete()
		if videoModeNative == self.currentVideoMode then
			-- and when we rebuild we gotta reassign the stuff from our video mode to app...
			-- or maybe I shouldn't be reassigning it to begin with?
			--[[
			videoModeNative:build()

			videoModeNative.framebufferRAM = assert.index(modeObj, 'framebufferRAM')
			videoModeNative.framebufferNormalTex = assert.index(modeObj, 'framebufferNormalTex')
			videoModeNative.blitScreenObj = modeObj.blitScreenObj
			videoModeNative.drawObj = modeObj.drawObj
			videoModeNative.fb = modeObj.fb
			--]]
			-- [[ lazy
			self:setVideoMode(0)
			self:setVideoMode(255)
			--]]
		end
	end
end

-------------------- EVENTS --------------------

function App:event(e)
	if e[0].type == sdl.SDL_EVENT_WINDOW_FOCUS_GAINED then
		self.hasFocus = true
		return
	elseif e[0].type == sdl.SDL_EVENT_WINDOW_FOCUS_LOST then
		self.hasFocus = false
		return
	end

	-- handle gamepad add/remove events here
	if e[0].type == sdl.SDL_EVENT_GAMEPAD_ADDED then

		local controllerIndex
		for j=1,maxPlayersPerConn do
			if not self.controllers[j] then
				controllerIndex = j
				break
			end
		end
		if not controllerIndex then
			print('added one too many controllers.')
		else
			local joystickID = e[0].gdevice.which
--DEBUG:print('SDL_EVENT_GAMEPAD_ADDED', joystickID)
			local gamepad = sdl.SDL_OpenGamepad(joystickID)
			if gamepad == ffi.null then
				print('SDL_OpenGamepad('..joystickID..') failed: '..require 'sdl.assert'.getError())
			else
				local controller = {
					joystickID = joystickID,
					controllerIndex = controllerIndex,
					gamepad = gamepad,
				}
				self.controllers[controllerIndex] = controller
				self.controllerForJoystickID[joystickID] = controller
--DEBUG:print('...gamepad', gamepad)
			end
		end
		return
	elseif e[0].type == sdl.SDL_EVENT_GAMEPAD_REMOVED then
		local joystickID = e[0].gdevice.which
		local controller = self.controllerForJoystickID[joystickID]
--DEBUG:print('SDL_EVENT_GAMEPAD_REMOVED', joystickID, 'controller', controller)
		if not controller then
			print("removed a controller we weren't tracking")
		else
--DEBUG:print('SDL_CloseGamepad', joystickID)
			sdl.SDL_CloseGamepad(controller.gamepad)
			self.controllerForJoystickID[joystickID] = nil
			self.controllers[controller.controllerIndex] = nil
		end
		return
	end

	-- hmm here separately handle the escape / start button?
	-- in fact this is the same code as in UI:event()
	if not self.waitingForEvent then
		if (e[0].type == sdl.SDL_EVENT_KEY_DOWN
			and e[0].key.key == sdl.SDLK_ESCAPE)
		or (e[0].type == sdl.SDL_EVENT_GAMEPAD_BUTTON_DOWN
			and e[0].gbutton.button == sdl.SDL_GAMEPAD_BUTTON_START)
		then
			self:toggleMenu()
			return
		end
	end


	-- now, if the player hasn't touched anything for the very first time ever,
	-- determine what kind of default keys to give them
	if self.cfg.initializingConfig then
		if e[0].type == sdl.SDL_EVENT_KEY_DOWN
		or e[0].type == sdl.SDL_EVENT_MOUSE_MOTION
		or e[0].type == sdl.SDL_EVENT_MOUSE_BUTTON_DOWN
		or e[0].type == sdl.SDL_EVENT_FINGER_DOWN	-- TODO later - separate default for touch-screen?
		then -- default to keyboard
			self.cfg.initializingConfig = nil
			print('initializing for keyboard...')
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
			local function setPlayer1Default(buttonCode, ev)
				ev.name = self:getEventName(table.unpack(ev))
				self.cfg.playerInfos[1].buttonBinds[buttonCode] = ev
			end
			setPlayer1Default(buttonCodeForName.right, {sdl.SDL_EVENT_KEY_DOWN, sdl.SDLK_RIGHT})
			setPlayer1Default(buttonCodeForName.down, {sdl.SDL_EVENT_KEY_DOWN, sdl.SDLK_DOWN})
			setPlayer1Default(buttonCodeForName.left, {sdl.SDL_EVENT_KEY_DOWN, sdl.SDLK_LEFT})
			setPlayer1Default(buttonCodeForName.up, {sdl.SDL_EVENT_KEY_DOWN, sdl.SDLK_UP})
			setPlayer1Default(buttonCodeForName.a, {sdl.SDL_EVENT_KEY_DOWN, sdl.SDLK_S})
			setPlayer1Default(buttonCodeForName.b, {sdl.SDL_EVENT_KEY_DOWN, sdl.SDLK_X})
			setPlayer1Default(buttonCodeForName.x, {sdl.SDL_EVENT_KEY_DOWN, sdl.SDLK_A})
			setPlayer1Default(buttonCodeForName.y, {sdl.SDL_EVENT_KEY_DOWN, sdl.SDLK_Z})
			self:buildPlayerEventsMap()
		elseif e[0].type == sdl.SDL_EVENT_GAMEPAD_AXIS_MOTION
		or e[0].type == sdl.SDL_EVENT_GAMEPAD_BUTTON_DOWN
		then
			self.cfg.initializingConfig = nil
			print('initializing for gamepad...')
			-- default to gamepad
			local function setPlayer1Default(buttonCode, ev)
				ev.name = self:getEventName(table.unpack(ev))
				self.cfg.playerInfos[1].buttonBinds[buttonCode] = ev
			end
			local controllerIndex = 1
			-- TODO is it just my controller or do most/all gamepads use axis for dpad?  i'm thinking my controller is just some cheap knockoff ...
			setPlayer1Default(buttonCodeForName.right, {sdl.SDL_EVENT_GAMEPAD_AXIS_MOTION, controllerIndex, 0, 1})
			setPlayer1Default(buttonCodeForName.down, {sdl.SDL_EVENT_GAMEPAD_AXIS_MOTION, controllerIndex, 1, 1})
			setPlayer1Default(buttonCodeForName.left, {sdl.SDL_EVENT_GAMEPAD_AXIS_MOTION, controllerIndex, 0, -1})
			setPlayer1Default(buttonCodeForName.up, {sdl.SDL_EVENT_GAMEPAD_AXIS_MOTION, controllerIndex, 1, -1})
			setPlayer1Default(buttonCodeForName.a, {sdl.SDL_EVENT_GAMEPAD_BUTTON_DOWN, controllerIndex, sdl.SDL_GAMEPAD_BUTTON_EAST})
			setPlayer1Default(buttonCodeForName.b, {sdl.SDL_EVENT_GAMEPAD_BUTTON_DOWN, controllerIndex, sdl.SDL_GAMEPAD_BUTTON_SOUTH})
			setPlayer1Default(buttonCodeForName.x, {sdl.SDL_EVENT_GAMEPAD_BUTTON_DOWN, controllerIndex, sdl.SDL_GAMEPAD_BUTTON_NORTH})
			setPlayer1Default(buttonCodeForName.y, {sdl.SDL_EVENT_GAMEPAD_BUTTON_DOWN, controllerIndex, sdl.SDL_GAMEPAD_BUTTON_WEST})
			self:buildPlayerEventsMap()
		end
	end
	-- TODO how to handle initializing extra local players too ...


	-- if we're in a menu then let it capture the event
	if self.activeMenu
	and not self.waitingForEvent
	then
		if self.activeMenu:event(e) then
			return
		end
	end

	-- anything else goes to gameplay
	self:handleGameplayEvent(e)
end

function App:handleGameplayEvent(e)
	if e[0].type == sdl.SDL_EVENT_KEY_UP
	or e[0].type == sdl.SDL_EVENT_KEY_DOWN
	then
		local down = e[0].type == sdl.SDL_EVENT_KEY_DOWN
		self:processButtonEvent(down, sdl.SDL_EVENT_KEY_DOWN, e[0].key.key)

		local keycode = sdlSymToKeyCode[e[0].key.key]
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
	elseif e[0].type == sdl.SDL_EVENT_MOUSE_BUTTON_DOWN
	or e[0].type == sdl.SDL_EVENT_MOUSE_BUTTON_UP
	then
		local down = e[0].type == sdl.SDL_EVENT_MOUSE_BUTTON_DOWN
		self:processButtonEvent(down, sdl.SDL_EVENT_MOUSE_BUTTON_DOWN, tonumber(e[0].button.x)/self.width, tonumber(e[0].button.y)/self.height, e[0].button.button)

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
	elseif e[0].type == sdl.SDL_EVENT_MOUSE_WHEEL then
		-- TODO scale mousewheel?  flip mousewheel?
		-- right now right = +x, down = +y
		self.ram.mouseWheel.x = self.ram.mouseWheel.x - e[0].wheel.x
		self.ram.mouseWheel.y = self.ram.mouseWheel.y + e[0].wheel.y
	elseif e[0].type == sdl.SDL_EVENT_GAMEPAD_AXIS_MOTION then
		-- -1,0,1 depend on the axis press
		local lr = math.floor(3 * (tonumber(e[0].gaxis.value) + 32768) / 65536) - 1
		local press = lr ~= 0
		local controller = self.controllerForJoystickID[e[0].gaxis.which]
		local controllerIndex = controller and controller.controllerIndex  or '?'
		if not press then
			-- clear both left and right movement
			self:processButtonEvent(press, sdl.SDL_EVENT_GAMEPAD_AXIS_MOTION, controllerIndex, e[0].gaxis.axis, -1)
			self:processButtonEvent(press, sdl.SDL_EVENT_GAMEPAD_AXIS_MOTION, controllerIndex, e[0].gaxis.axis, 1)
		else
			-- set movement for the lr direction
			self:processButtonEvent(press, sdl.SDL_EVENT_GAMEPAD_AXIS_MOTION, controllerIndex, e[0].gaxis.axis, lr)
		end
	elseif e[0].type == sdl.SDL_EVENT_GAMEPAD_BUTTON_DOWN or e[0].type == sdl.SDL_EVENT_GAMEPAD_BUTTON_UP then
		local press = e[0].type == sdl.SDL_EVENT_GAMEPAD_BUTTON_DOWN
		local controller = self.controllerForJoystickID[e[0].gbutton.which]
		local controllerIndex = controller and controller.controllerIndex or '?'
		self:processButtonEvent(press, sdl.SDL_EVENT_GAMEPAD_BUTTON_DOWN, controllerIndex, e[0].gbutton.button)
	elseif e[0].type == sdl.SDL_EVENT_FINGER_DOWN or e[0].type == sdl.SDL_EVENT_FINGER_UP then
		local press = e[0].type == sdl.SDL_EVENT_FINGER_DOWN
		self:processButtonEvent(press, sdl.SDL_EVENT_FINGER_DOWN, e[0].tfinger.x, e[0].tfinger.y)
	end
end

-- handle the SDL event encoded as a list of ints
-- also handles overrides for things like key-configuration
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
		-- lookup events and descriptors and their map to players and buttons in the playerEvents table
		-- maybe todo, save one level of calls and move this into each event's unique handler (but then you'd have to move the waitingForEvent capture there too)
		local match, buttonIndex, playerIndex
		local etype = ...
		local h = self.playerEvents[etype]
		if h then
			if etype == sdl.SDL_EVENT_KEY_DOWN then
				local sym = select(2, ...)
				h = h[sym]
				if h then
					buttonIndex = h.buttonIndex
					playerIndex = h.playerIndex
					match = true
				end

			elseif etype == sdl.SDL_EVENT_GAMEPAD_AXIS_MOTION then
				local which, hat, dirbit = select(2, ...)
				h = h[which]
				if h then
					h = h[hat]
					if h then
						h = h[dirbit]
						if h then
							buttonIndex = h.buttonIndex
							playerIndex = h.playerIndex
							match = true
						end
					end
				end
			elseif etype == sdl.SDL_EVENT_GAMEPAD_BUTTON_DOWN then
				local which, button = select(2, ...)
				h = h[which]
				if h then
					h = h[button]
					if h then
						buttonIndex = h.buttonIndex
						playerIndex = h.playerIndex
						match = true
					end
				end
			elseif etype == sdl.SDL_EVENT_MOUSE_BUTTON_DOWN
			or e[0].type == sdl.SDL_EVENT_FINGER_DOWN
			or e[0].type == sdl.SDL_EVENT_FINGER_UP
			then
				local x, y, button = select(2, ...)
				if etype == sdl.SDL_EVENT_MOUSE_BUTTON_DOWN then
					h = h[button]
				end
				if h then
					for _,region in ipairs(h) do
						local dx = (x - region.x) * self.width
						local dy = (y - region.y) * self.height
						if dx*dx + dy*dy >= buttonRadius*buttonRadius then
							match = false
							buttonIndex = region.buttonIndex
							playerIndex = region.playerIndex
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

-- for perf's sake
-- map keys etc -> event so we don't have to searh all players every time any event occurs
-- and redo this map every time the key configs change
function App:buildPlayerEventsMap()
	self.playerEvents = {}
	for _, playerInfo in ipairs(self.cfg.playerInfos) do
		if playerInfo.hostPlayerIndex then
			local playerIndex = playerInfo.hostPlayerIndex
			for buttonIndex, buttonBind in pairs(playerInfo.buttonBinds) do
				local etype = buttonBind[1]
				self.playerEvents[etype] = self.playerEvents[etype] or {}
				if etype == sdl.SDL_EVENT_KEY_DOWN then
					local sym = buttonBind[2]
					-- TODO warn if self.playerEvents[etype][sym] is set
					-- SDL_KEYDOWN -> key -> press/release = trigger this player's this sym
					self.playerEvents[etype][sym] = {
						playerIndex = playerIndex,
						buttonIndex = buttonIndex,
					}
				--elseif etype == sdl.SDL_EVENT_MOUSE_WHEEL then
				elseif etype == sdl.SDL_EVENT_GAMEPAD_AXIS_MOTION then
					local which, hat, dirbit = table.unpack(buttonBind, 2)
					-- or which, axis, lr
					self.playerEvents[etype][which] = self.playerEvents[etype][which] or {}
					self.playerEvents[etype][which][hat] = self.playerEvents[etype][which][hat] or {}
					self.playerEvents[etype][which][hat][dirbit] = {
						playerIndex = playerIndex,
						buttonIndex = buttonIndex,
					}
				elseif etype == sdl.SDL_EVENT_GAMEPAD_BUTTON_DOWN then
					local which, button = table.unpack(buttonBind, 2)
					self.playerEvents[etype][which] = self.playerEvents[etype][which] or {}
					self.playerEvents[etype][which][button] = {
						playerIndex = playerIndex,
						buttonIndex = buttonIndex,
					}
				elseif etype == sdl.SDL_EVENT_MOUSE_BUTTON_DOWN then
					local x, y, button = table.unpack(buttonBind, 2)
					self.playerEvents[etype][button] = self.playerEvents[etype][button] or {}
					table.insert(self.playerEvents[etype][button], {
						playerIndex = playerIndex,
						buttonIndex = buttonIndex,
						x = x,
						y = y,
					})
				elseif e[0].type == sdl.SDL_EVENT_FINGER_DOWN
				or e[0].type == sdl.SDL_EVENT_FINGER_UP
				then
					local x, y = table.unpack(buttonBind, 2)
					table.insert(self.playerEvents[etype], {
						playerIndex = playerIndex,
						buttonIndex = buttonIndex,
						x = x,
						y = y,
					})
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
		[sdl.SDL_EVENT_GAMEPAD_AXIS_MOTION] = 'ga<?=a?> <?=b?> <?=c?>',
		[sdl.SDL_EVENT_GAMEPAD_BUTTON_DOWN] = 'gb<?=a?> <?=b?>',
		[sdl.SDL_EVENT_KEY_DOWN] = 'key<?=key(a)?>',
		[sdl.SDL_EVENT_MOUSE_BUTTON_DOWN] = 'mb<?=c?> x<?=math.floor(a*100)?> y<?=math.floor(b*100)?>',
		[sdl.SDL_EVENT_FINGER_DOWN] = 't x<?=math.floor(a*100)?> y<?=math.floor(b*100)?>',
	})[sdlEventID], {
		a=a, b=b, c=c,
		dir=dir, key=key,
	})
end

return App
