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
local assertle = require 'ext.assert'.le
local assertlt = require 'ext.assert'.lt
local string = require 'ext.string'
local table = require 'ext.table'
local math = require 'ext.math'
local path = require 'ext.path'
local getTime = require 'ext.timer'.getTime
local vec2s = require 'vec-ffi.vec2s'
local vec2i = require 'vec-ffi.vec2i'
local matrix_ffi = require 'matrix.ffi'
local struct = require 'struct'
local sdl = require 'sdl'
local gl = require 'gl'
local GLApp = require 'glapp'
local GLTex2D = require 'gl.tex2d'

local keyCodeNames = require 'numo9.keys'.keyCodeNames
local keyCodeForName = require 'numo9.keys'.keyCodeForName
local sdlSymToKeyCode = require 'numo9.keys'.sdlSymToKeyCode
local firstJoypadKeyCode = require 'numo9.keys'.firstJoypadKeyCode

-- n = num args to pack
-- also in image/luajit/image.lua
local function packptr(n, ptr, value, ...)
	if n <= 0 then return end
	ptr[0] = value or 0
	return packptr(n-1, ptr+1, ...)
end

local function unpackptr(n, p)
	if n <= 0 then return end
	return p[0], unpackptr(n-1, p+1)
end

-- TODO use either settable or packptr ... ?

local function settableindex(t, i, ...)
	if select('#', ...) == 0 then return end
	t[i] = ...
	settableindex(t, i+1, select(2, ...))
end

local function settable(t, ...)
	settableindex(t, 1, ...)
end

local function hexdump(ptr, len)
	return string.hexdump(ffi.string(ptr, len))
end

local function imageToHex(image)
	return string.hexdump(ffi.string(image.buffer, image.width * image.height * ffi.sizeof(image.format)))
end

local paletteSize = 256
local spriteSize = vec2i(8, 8)
local frameBufferType = 'uint16_t'	-- rgb565
--local frameBufferType = 'uint8_t'		-- rgb332 or indexed
local frameBufferSize = vec2i(256, 256)
local frameBufferSizeInTiles = vec2i(frameBufferSize.x / spriteSize.x, frameBufferSize.y / spriteSize.y)
local spriteSheetSize = vec2i(256, 256)
local spriteSheetSizeInTiles = vec2i(spriteSheetSize.x / spriteSize.x, spriteSheetSize.y / spriteSize.y)
local tilemapSize = vec2i(256, 256)
local tilemapSizeInSprites = vec2i(tilemapSize.x /  spriteSize.x, tilemapSize.y /  spriteSize.y)
local codeSize = 0x10000	-- tic80's size ... but with my langfix shorthands like pico8 has
--local fontWidth = spriteSize.x
local fontWidth = 5

local keyCount = #keyCodeNames
-- number of bytes to represent all bits of the keypress buffer
local keyPressFlagSize = math.ceil(keyCount / 8)

local ROM = struct{
	name = 'ROM',
	union = true,
	fields = {
		{name='v', type='uint8_t[1]', no_iter=true},
		{type=struct{
			anonymous = true,
			packed = true,
			fields = {
				{name='spriteSheet', type='uint8_t['..spriteSheetSize:volume()..']'},
				{name='tileSheet', type='uint8_t['..spriteSheetSize:volume()..']'},
				{name='tilemap', type='uint16_t['..tilemapSize:volume()..']'},
				{name='palette', type='uint16_t['..paletteSize..']'},
				{name='code', type='uint8_t['..codeSize..']'},
			},
		}},
	},
}
--DEBUG:print(ROM.code)
--DEBUG:print('ROM size', ffi.sizeof(ROM))

local RAM = struct{
	name = 'RAM',
	union = true,
	fields = {
		{name='v', type='uint8_t[1]', no_iter=true},
		{type=struct{
			anonymous = true,
			packed = true,

			-- does C let you inherit classes?  anonymous fields with named types?
			-- they let you have named fields with anonymous (inline-defined) types ...
			-- until then, just wedge in the fields here and assert their offsets match.
			fields = table(
				ROM.fields[2].type.fields
			):append{
				-- graphics

				-- I know, I know, old consoles didn't have a framebuffer
				-- but how would we properly emulate our non-sprite graphics without one?
				-- maybe I'll do rgb332+dithering to save space ...
				-- maybe I'll say rgb565 is maximum but if the user chooses they can change modes to rgb332, indexed, heck why not 4bit or 2bit ...
				{name='framebuffer', type=frameBufferType..'['..frameBufferSize:volume()..']'},
				{name='clipRect', type='uint8_t[4]'},
				{name='mvMat', type='float[16]'},	-- tempting to do float16 ... or fixed16 ... lol the rom api ittself doesn't even have access to floats ...

				-- timer
				{name='updateCounter', type='uint32_t[1]'},	-- how many updates() overall, i.e. system clock
				{name='romUpdateCounter', type='uint32_t[1]'},	-- how many updates() for the current ROM.  reset upon run()

				-- keyboard

				-- bitflags of keyboard:
				{name='keyPressFlags', type='uint8_t['..keyPressFlagSize..']'},
				{name='lastKeyPressFlags', type='uint8_t['..keyPressFlagSize..']'},

				-- hold counter
				-- this is such a waste of space, an old console would never do this itself, it'd make you implement the behavior yourself.
				-- on the old Apple 2 console they did this by keeping only a count for the current key, such that if you held on it it'd pause, then repeat, then if you switched keys there would be no pause-and-repeat ...
				-- I guess I'll dedicate 16 bits per hold counter to every key ...
				-- TODO mayyybbee ... just dedicate one to every button, and an extra one for keys that aren't buttons
				{name='keyHoldCounter', type='uint16_t['..keyCount..']'},

				{name='mousePos', type='vec2s_t'},			-- frambuffer coordinates ... should these be [0,255] FBO constrained or should it allow out of FBO coordinates?
				{name='lastMousePos', type='vec2s_t'},		-- ... " " last frame.  Should these be in RAM?  Or should they be a byproduct of the environment <-> the delta is in RAM?
				{name='lastMousePressPos', type='vec2s_t'},	-- " " at last mouse press.  Same question...
			},
		}},
	},
}


local App = GLApp:subclass()

App.title = 'NuMo9'
App.width = 720
App.height = 512

App.paletteSize = paletteSize
App.spriteSize = spriteSize
App.frameBufferType = frameBufferType
App.frameBufferSize = frameBufferSize
App.frameBufferSizeInTiles = frameBufferSizeInTiles
App.spriteSheetSize = spriteSheetSize
App.spriteSheetSizeInTiles = spriteSheetSizeInTiles
App.tilemapSize = tilemapSize
App.tilemapSizeInSprites = tilemapSizeInSprites
App.codeSize = codeSize
App.fontWidth = fontWidth

local spriteSheetAddr = ffi.offsetof('ROM', 'spriteSheet')
local spriteSheetInBytes = spriteSheetSize:volume() * 1--ffi.sizeof(ffi.cast('ROM*',0)[0].spriteSheet[0])
local spriteSheetAddrEnd = spriteSheetAddr + spriteSheetInBytes
local tileSheetAddr = ffi.offsetof('ROM', 'tileSheet')
local tileSheetInBytes = spriteSheetSize:volume() * 1--ffi.sizeof(ffi.cast('ROM*',0)[0].tileSheet[0])
local tileSheetAddrEnd = tileSheetAddr + tileSheetInBytes
local tilemapAddr = ffi.offsetof('ROM', 'tilemap')
local tilemapInBytes = tilemapSize:volume() * 2--ffi.sizeof(ffi.cast('ROM*',0)[0].tilemap[0])
local tilemapAddrEnd = tilemapAddr + tilemapInBytes
local paletteAddr = ffi.offsetof('ROM', 'palette')
local paletteInBytes = paletteSize * 2--ffi.sizeof(ffi.cast('ROM*',0)[0].palette[0])
local paletteAddrEnd = paletteAddr + paletteInBytes
local framebufferAddr = ffi.offsetof('RAM', 'framebuffer')
local framebufferInBytes = frameBufferSize:volume() * ffi.sizeof(frameBufferType)
local framebufferAddrEnd = framebufferAddr + framebufferInBytes

local defaultSaveFilename = 'last.n9'	-- default name of save/load if you don't provide one ...

-- fps vars
local lastTime = getTime()
local fpsFrames = 0
local fpsSeconds = 0
local drawsPerSecond = 0

-- update interval vars
local lastUpdateTime = getTime()	-- TODO resetme upon resuming from a pause state
local updateInterval = 1 / 60
local needDrawCounter = 0
local needUpdateCounter = 0

-- TODO ypcall that is xpcall except ...
-- ... 1) error strings don't have source/line in them (that goes in backtrace)
-- ... 2) no error callback <-> default, which simply appends backtrace
-- ... 3) new debug.traceback() that includes that error line as the top line.
local function errorHandler(err)
	return err..'\n'..debug.traceback()
end
App.errorHandler = errorHandler


--[[ how come I can't disable double-buffering?
local sdlAssertZero = require 'sdl.assert'.zero
function App:sdlGLSetAttributes()
	App.super.sdlGLSetAttributes(self)
	-- no need for double-buffering if we're framebuffering
	sdlAssertZero(sdl.SDL_GL_SetAttribute(sdl.SDL_GL_DOUBLEBUFFER, 0))
end
--]]

-- don't gl swap every frame - only do after draws
function App:postUpdate() end

function App:initGL()
	--[[ getting single-buffer to work
	gl.glDrawBuffer(gl.GL_BACK)
	--]]

	--[[ boy does enabling blend make me regret using uvec4 as a fragment color output
	gl.glEnable(gl.GL_BLEND)
	gl.glBlendFunc(gl.GL_SRC_ALPHA, gl.GL_ONE)
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
		local size = ffi.sizeof(self.ram[field.name])
		print(('0x%06x - 0x%06x = '):format(offset, offset + size)..field.name)
	end

	print('system dedicated '..('0x%x'):format(ffi.sizeof(self.ram))..' of RAM')

	-- TODO use fixed-precision here ... or ... expose floating-precision poke/peeks?
	self.mvMat = matrix_ffi({4,4}, 'float'):zeros():setIdent()
	self.mvMat.ptr = self.ram.mvMat

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
	self.ram.updateCounter[0] = 0
	self.ram.romUpdateCounter[0] = 0

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
		save = function(...) return self:save(...) end,
		load = function(...) return self:load(...) end,
		reset = function(...) return self:resetROM(...) end,
		quit = function(...) self:requestExit() end,

		-- timer
		time = function()
			return self.ram.romUpdateCounter[0] * updateInterval
		end,

		-- pico8 has poke2 as word, poke4 as dword
		-- tic80 has poke2 as 2bits, poke4 as 4bits
		-- I will leave bit operations up to the user, but for ambiguity rename my word and dword into pokew and pokel
		-- signed or unsigned? unsigned.
		peek = function(addr) return self:peek(addr) end,
		peekw = function(addr) return self:peekw(addr) end,
		peekl = function(addr) return self:peekl(addr) end,
		poke = function(addr, value) return self:poke(addr, value) end,
		pokew = function(addr, value) return self:pokew(addr, value) end,
		pokel = function(addr, value) return self:pokel(addr, value) end,

		-- why does tic-80 have mget/mset like pico8 when tic-80 doesn't have pget/pset or sget/sset ...
		mget = function(x, y)
			x = math.floor(x)
			y = math.floor(y)
			if x >= 0 and x < self.tilemapSize.x
			and y >= 0 and y < self.tilemapSize.y
			then
				return self.ram.tilemap[x + self.tilemapSize.x * y]
			end
			-- TODO return default oob value
			return 0
		end,
		mset = function(x, y, value)
			x = math.floor(x)
			y = math.floor(y)
			if x >= 0 and x < self.tilemapSize.x
			and y >= 0 and y < self.tilemapSize.y
			then
				self.ram.tilemap[x + self.tilemapSize.x * y] = value
				self.mapTex.dirtyCPU = true
			end
		end,

		-- graphics

		-- fun fact, if the API calls cls() it clears with color zero
		-- but color zero is a game color, not an editor color, that'd be color 240
		-- but at the moment the console is routed to directly call the API,
		-- so if you type "cls" at the console then you could get a screen full of some nonsense color
		flip = coroutine.yield,	-- simple as
		cls = function(...)
			local con = self.con
			con.cursorPos:set(0, 0)
			self:clearScreen(...)
		end,
		clip = function(...)
			if select('#', ...) == 0 then
				packptr(4, self.clipRect, 0, 0, 0xff, 0xff)
			else
				-- assert num args is 4 ?
				packptr(4, self.clipRect, ...)
			end
			gl.glScissor(
				self.clipRect[0],
				self.clipRect[1],
				self.clipRect[2]+1,
				self.clipRect[3]+1)
		end,

		-- TODO tempting to just expose flags for ellipse & border to the 'cartridge' api itself ...
		rect = function(x, y, w, h, colorIndex)
			return self:drawSolidRect(x, y, w, h, colorIndex, false, false)
		end,
		rectb = function(x, y, w, h, colorIndex)
			return self:drawSolidRect(x, y, w, h, colorIndex, true, false)
		end,
		-- choosing tic80's api naming here.  but the rect api: width/height, not radA/radB
		elli = function(x, y, w, h, colorIndex)
			return self:drawSolidRect(x, y, w, h, colorIndex, false, true)
		end,
		ellib = function(x, y, w, h, colorIndex)
			return self:drawSolidRect(x, y, w, h, colorIndex, true, true)
		end,

		line = function(...) return self:drawSolidLine(...) end,

		spr = function(...) return self:drawSprite(...) end,		-- (spriteIndex, x, y, paletteIndex)
		-- TODO maybe maybe not expose this? idk?  tic80 lets you expose all its functionality via spr() i think, though maybe it doesn't? maybe this is only pico8 equivalent sspr? or pyxel blt() ?
		quad = function(x,y,w,h,tx,ty,tw,th,pal,transparent,spriteBit,spriteMask)
			return self:drawQuad(x,y,w,h,tx,ty,tw,th,self.spriteTex,pal,transparent,spriteBit,spriteMask)
		end,
		map = function(...) return self:drawMap(...) end,
		text = function(...) return self:drawText(...) end,		-- (text, x, y, fgColorIndex, bgColorIndex)


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

		tostring = tostring,
		tonumber = tonumber,
		select = select,
		type = type,
		error = error,
		assert = assert,
		pairs = pairs,
		ipairs = ipairs,

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

	-- me cheating and exposing opengl modelview matrix functions:
	-- matident mattrans matrot matscale matortho matfrustum matlookat
	-- matrix math because i'm cheating
	self.env.matident = function(...) self.mvMat:setIdent(...) end
	self.env.mattrans = function(...) self.mvMat:applyTranslate(...) end
	self.env.matrot = function(...) self.mvMat:applyRotate(...) end
	self.env.matscale = function(...) self.mvMat:applyScale(...) end
	self.env.matortho = function(...) self.mvMat:applyOrtho(...) end
	self.env.matfrustum = function(...) self.mvMat:applyFrustum(...) end
	self.env.matlookat = function(...) self.mvMat:applyLookAt(...) end

	require 'numo9.draw'.initDraw(self)

	-- 4 uint8 bytes ...
	-- x, y, w, h ... width and height are inclusive so i can do 0 0 ff ff and get the whole screen
	self.clipRect = self.ram.clipRect
	packptr(4, self.clipRect, 0, 0, 0xff, 0xff)

	-- keyboard init
	-- make sure our keycodes are in bounds
	for sdlSym,keyCode in pairs(sdlSymToKeyCode) do
		if not (keyCode >= 0 and math.floor(keyCode/8) < keyPressFlagSize) then
			error('got oob keyCode '..keyCode..' named '..(keyCodeNames[keyCode+1])..' for sdlSym '..sdlSym)
		end
	end

	-- filesystem init

	FileSystem = require 'numo9.filesystem'
	self.fs = FileSystem{app=self}
	-- copy over a local filetree somewhere in the app ...
	for fn in path:dir() do
		if select(2, fn:getext()) == 'n9' then
			self.fs:addFromHost(fn.path)
		end
	end

	-- editor init

	self.editMode = 'code'	-- matches up with Editor's editMode's

	local EditCode = require 'numo9.editcode'
	local EditSprites = require 'numo9.editsprites'
	local EditTilemap = require 'numo9.edittilemap'
	local Console = require 'numo9.console'

	self:runInEmu(function()
		self:resetView()	-- reset mat and clip
		self.editCode = EditCode{app=self}
		self.editSprites = EditSprites{app=self}
		self.editTilemap = EditTilemap{app=self}
		self.con = Console{app=self}
	end)

	self.screenMousePos = vec2i()	-- host coordinates ... don't put this in RAM

	self:setFocus{
		thread = coroutine.create(function()
			self:resetGFX()		-- needed to initialize UI colors
			self.con:reset()	-- needed for palette .. tho its called in init which is above here ...
			for i=1,30 do
				coroutine.yield()
			end
			for i=0,15 do
				self.con.fgColor = bit.bor(0xf0,i)	-- bg = i, fg = i + 15 at the moemnt thanks to the font.png storage ...
				self.con.bgColor = bit.bor(0xf0,bit.band(0xf,i+1))
				self.con:print'hello world'

				for i=1,3 do
					coroutine.yield()
				end
			end
			self.con.fgColor = 0xfc			-- 11 = bg, 12 = fg
			self.con.bgColor = 0xf0

			self.con:print('loading', cmdline[1] or 'hello.n9')
			self:load(cmdline[1] or 'hello.n9')
			self:runROM()
		end),
	}
end

-- this re-inserts the font and default palette
-- and copies those changes back into the cartridge too (stupid idea of keeping two copies of the cartridge in RAM and ROM ...)
function App:resetGFX()
	--self.spriteTex:prepForCPU()
	require 'numo9.draw'.resetFont(self.ram)
	ffi.copy(self.cartridge.spriteSheet, self.ram.spriteSheet, spriteSheetInBytes)

	--self.palTex:prepForCPU()
	require 'numo9.draw'.resetPalette(self.ram)
	ffi.copy(self.cartridge.palette, self.ram.palette, paletteInBytes)

	assert(not self.spriteTex.dirtyGPU)
	self.spriteTex.dirtyCPU = true
	assert(not self.palTex.dirtyGPU)
	self.palTex.dirtyCPU = true
end

function App:resize()
	needDrawCounter = 2
end

function App:update()
	App.super.update(self)

	local thisTime = getTime()

	--[[ fps counter ... now that I've moved the swap out of the parent class and only draw on dirty bit, this won't show useful information
	-- TODO only redraw the editor when the cursor blinks or a UI overlay changes ... that should reduce our draws
	local deltaTime = thisTime - lastTime
	fpsFrames = fpsFrames + 1
	fpsSeconds = fpsSeconds + deltaTime
	if fpsSeconds > 1 then
		print(
			--'FPS: '..fpsFrames / fpsSeconds	this will show you how fast a busy loop runs
			'draws/second '..drawsPerSecond	-- TODO make this single-buffered
		)
		drawsPerSecond = 0
		fpsFrames = 0
		fpsSeconds = 0
	end
	lastTime = thisTime	-- TODO this at end of update in case someone else needs this var
	--]]

	if thisTime > lastUpdateTime + updateInterval then
		-- [[ doing this means we need to reset lastUpdateTime when resuming from the app being paused
		-- and indeed the in-console fps first readout is high (67), then drops back down to 60 consistently
		lastUpdateTime = lastUpdateTime + updateInterval
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

		-- system update refresh timer
		self.ram.updateCounter[0] = self.ram.updateCounter[0] + 1
		self.ram.romUpdateCounter[0] = self.ram.romUpdateCounter[0] + 1

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

		local fb = self.fb
		fb:bind()
		self.inUpdateCallback = true	-- tell 'runInEmu' not to set up the fb:bind() to do gfx stuff
		gl.glViewport(0,0,frameBufferSize:unpack())
		gl.glEnable(gl.GL_SCISSOR_TEST)
		gl.glScissor(
			self.clipRect[0],
			self.clipRect[1],
			self.clipRect[2]+1,
			self.clipRect[3]+1)

		-- TODO here run this only 60 fps
		local runFocus = self.runFocus
		if runFocus and runFocus.thread then
			if coroutine.status(runFocus.thread) == 'dead' then
print('dead thread - switching to con')
				self:setFocus(self.con)
			else
				local success, msg = coroutine.resume(runFocus.thread)
				if not success then
					print(msg)
					print(debug.traceback(runFocus.thread))
					self.con:resetThread()
					self:setFocus(self.con)
					self.con:print(msg)
					-- TODO these errors are a good argument for scrollback console buffers
					-- they're also a good argument for coroutines (though speed might be an argument against coroutines)
				end
			end
		else
print('no runnable focus!')
			self:setFocus(self.con)
		end

		gl.glDisable(gl.GL_SCISSOR_TEST)
		self.inUpdateCallback = false
		fb:unbind()

		-- update vram to gpu every frame?
		-- or nah, how about I only do when dirty bit set?
		-- so this copies CPU changes -> GPU changes
		-- TODO nothing is copying the GPU back to CPU after we do our sprite renders ...
		-- double TODO I don't have framebuffer memory
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
			needDrawCounter = 2
		end
	end

	if needDrawCounter > 0 then
		needDrawCounter = needDrawCounter - 1
		drawsPerSecond = drawsPerSecond + 1

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
end

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

	if self.fbTex.dirtyGPU and addrend >= framebufferAddr and addr < framebufferAddr+framebufferInBytes then
		self.fbTex:checkDirtyGPU()
	end

	return ffi.cast('uint16_t*', self.ram.v + addr)[0]
end
function App:peekl(addr)
	local addrend = addr+3
	if addr < 0 or addrend >= ffi.sizeof(self.ram) then return end

	if self.fbTex.dirtyGPU and addrend >= framebufferAddr and addr < framebufferAddr+framebufferInBytes then
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
		self.fbTex.changedSinceDraw = true
	end

	self.ram.v[addr] = tonumber(value)

	-- TODO none of the others happen period, only the palette texture
	-- makes me regret DMA exposure of my palette ... would be easier to just hide its read/write behind another function...
	if addr >= spriteSheetAddr and addr < spriteSheetAddrEnd then
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
		self.fbTex.changedSinceDraw = true
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
		self.fbTex.changedSinceDraw = true
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

function App:drawSolidRect(
	x,
	y,
	w,
	h,
	colorIndex,
	borderOnly,
	round
)
	self.palTex:checkDirtyCPU() -- before any GPU op that uses palette...
	self.fbTex:checkDirtyCPU()

	local sceneObj = self.quadSolidObj
	local uniforms = sceneObj.uniforms

	uniforms.mvMat = self.ram.mvMat
	uniforms.colorIndex = math.floor(colorIndex)
	uniforms.borderOnly = borderOnly or false
	uniforms.round = round or false
	if w < 0 then x,w = x+w,-w end
	if h < 0 then y,h = y+h,-h end
	settable(uniforms.box, x, y, w, h)

	sceneObj:draw()
	self.fbTex.dirtyGPU = true
	self.fbTex.changedSinceDraw = true
end
-- TODO get rid of this function
function App:drawBorderRect(
	x,
	y,
	w,
	h,
	colorIndex,
	...	-- round
)
	return self:drawSolidRect(x,y,w,h,colorIndex,true,...)
end

function App:drawSolidLine(x1,y1,x2,y2,colorIndex)
	self.palTex:checkDirtyCPU() -- before any GPU op that uses palette...
	self.fbTex:checkDirtyCPU()

	local sceneObj = self.lineSolidObj
	local uniforms = sceneObj.uniforms

	uniforms.mvMat = self.ram.mvMat
	uniforms.colorIndex = colorIndex
	settable(uniforms.line, x1,y1,x2,y2)

	sceneObj:draw()
	self.fbTex.dirtyGPU = true
	self.fbTex.changedSinceDraw = true
end

local mvMatCopy = ffi.new('float[16]')
function App:clearScreen(colorIndex)
--	self.quadSolidObj.uniforms.mvMat = ident4x4.ptr
	gl.glDisable(gl.GL_SCISSOR_TEST)
	ffi.copy(mvMatCopy, self.ram.mvMat, ffi.sizeof(mvMatCopy))
	self.mvMat:setIdent()
	self:drawSolidRect(
		0,
		0,
		frameBufferSize.x,
		frameBufferSize.y,
		colorIndex or 0)
	gl.glEnable(gl.GL_SCISSOR_TEST)
	ffi.copy(self.ram.mvMat, mvMatCopy, ffi.sizeof(mvMatCopy))
--	self.quadSolidObj.uniforms.mvMat = self.ram.mvMat
end

--[[
'lower level' functionality than 'drawSprite'
args:
	x y w h = quad rectangle on screen
	tx ty tw th = texcoord rectangle
	paletteIndex,
	transparentIndex,
	spriteBit,
	spriteMask
--]]
function App:drawQuad(
	x, y, w, h,	-- quad box
	tx, ty, tw, th,	-- texcoord bbox
	tex,
	paletteIndex,
	transparentIndex,
	spriteBit,
	spriteMask
)
	self.spriteTex:checkDirtyCPU()		-- \_ we don't know which it is so ...
	self.tileTex:checkDirtyCPU()		-- /
	self.palTex:checkDirtyCPU() -- before any GPU op that uses palette...
	self.fbTex:checkDirtyCPU()

	paletteIndex = paletteIndex or 0
	transparentIndex = transparentIndex or -1
	spriteBit = spriteBit or 0
	spriteMask = spriteMask or 0xFF

	local sceneObj = self.quadSpriteObj
	local uniforms = sceneObj.uniforms
	sceneObj.texs[1] = tex

	uniforms.mvMat = self.ram.mvMat
	uniforms.paletteIndex = paletteIndex	-- user has to specify high-bits
	uniforms.transparentIndex = transparentIndex
	uniforms.spriteBit = spriteBit
	uniforms.spriteMask = spriteMask
	settable(uniforms.tcbox, tx, ty, tw, th)
	settable(uniforms.box, x, y, w, h)

	sceneObj:draw()
	self.fbTex.dirtyGPU = true
	self.fbTex.changedSinceDraw = true
end

--[[
spriteIndex =
	bits 0..4 = x coordinate in sprite sheet
	bits 5..9 = y coordinate in sprite sheet
spritesWide = width in sprites
spritesHigh = height in sprites
paletteIndex =
	byte value with high 4 bits that holds which palette to use
	... this is added to the sprite color index so really it's a palette shift.
	(should I OR it?)
transparentIndex = which color index in the sprite to use as transparency.  default -1 = none
spriteBit = index of bit (0-based) to use, default is zero
spriteMask = mask of number of bits to use, default is 0xF <=> 4bpp
scaleX = how much to scale the drawn width, default is 1
scaleY = how much to scale the drawn height, default is 1
--]]
function App:drawSprite(
	spriteIndex,
	screenX,
	screenY,
	spritesWide,
	spritesHigh,
	paletteIndex,
	transparentIndex,
	spriteBit,
	spriteMask,
	scaleX,
	scaleY
)
	self.spriteTex:checkDirtyCPU()			-- before we read from the sprite tex, make sure we have most updated copy
	self.palTex:checkDirtyCPU() 			-- before any GPU op that uses palette, make sure we have the most update copy
	self.fbTex:checkDirtyCPU()		-- before we write to framebuffer, make sure we have most updated copy

	spritesWide = spritesWide or 1
	spritesHigh = spritesHigh or 1
	paletteIndex = paletteIndex or 0
	transparentIndex = transparentIndex or -1
	spriteBit = spriteBit or 0
	spriteMask = spriteMask or 0xFF
	scaleX = scaleX or 1
	scaleY = scaleY or 1

	local sceneObj = self.quadSpriteObj
	local uniforms = sceneObj.uniforms
	sceneObj.texs[1] = self.spriteTex

	uniforms.mvMat = self.ram.mvMat
	uniforms.paletteIndex = paletteIndex	-- user has to specify high-bits
	uniforms.transparentIndex = transparentIndex
	uniforms.spriteBit = spriteBit
	uniforms.spriteMask = spriteMask

	-- vram / sprite sheet is 32 sprites wide ... 256 pixels wide, 8 pixels per sprite
	spriteIndex = math.floor(spriteIndex)
	local tx = spriteIndex % spriteSheetSizeInTiles.x
	local ty = (spriteIndex - tx) / spriteSheetSizeInTiles.x
	-- TODO do I normalize it here or in the shader?
	settable(uniforms.tcbox,
		tx / tonumber(spriteSheetSizeInTiles.x),
		ty / tonumber(spriteSheetSizeInTiles.y),
		spritesWide / tonumber(spriteSheetSizeInTiles.x),
		spritesHigh / tonumber(spriteSheetSizeInTiles.y)
	)
	settable(uniforms.box,
		screenX,
		screenY,
		spritesWide * spriteSize.x * scaleX,
		spritesHigh * spriteSize.y * scaleY
	)
	sceneObj:draw()
	self.fbTex.dirtyGPU = true
	self.fbTex.changedSinceDraw = true
end

-- TODO go back to tileIndex instead of tileX tileY.  That's what mset() issues after all.
function App:drawMap(
	tileX,			-- \_ upper-left position in the tilemap
	tileY,			-- /
	tilesWide,		-- \_ how many tiles wide & high to draw
	tilesHigh,		-- /
	screenX,		-- \_ where in the screen to draw
	screenY,		-- /
	mapIndexOffset,	-- general shift to apply to all read map indexes in the tilemap
	draw16Sprites	-- set to true to draw 16x16 sprites instead of 8x8 sprites.  You still index tileX/Y with the 8x8 position. tilesWide/High are in terms of 16x16 sprites.
)
	self.tileTex:checkDirtyCPU()	-- TODO just use multiple sprite sheets and let the map() function pick which one
	self.palTex:checkDirtyCPU() -- before any GPU op that uses palette...
	self.mapTex:checkDirtyCPU()
	self.fbTex:checkDirtyCPU()

	tilesWide = tilesWide or 1
	tilesHigh = tilesHigh or 1
	mapIndexOffset = mapIndexOffset or 0

	local sceneObj = self.quadMapObj
	local uniforms = sceneObj.uniforms
	sceneObj.texs[1] = self.mapTex

	uniforms.mvMat = self.ram.mvMat
	uniforms.mapIndexOffset = mapIndexOffset	-- user has to specify high-bits

	settable(uniforms.tcbox,
		tileX / tonumber(tilemapSizeInSprites.x),
		tileY / tonumber(tilemapSizeInSprites.y),
		tilesWide / tonumber(tilemapSizeInSprites.x),
		tilesHigh / tonumber(tilemapSizeInSprites.y)
	)
	local draw16As0or1 = draw16Sprites and 1 or 0
	uniforms.draw16Sprites = draw16As0or1
	settable(uniforms.box,
		screenX or 0,
		screenY or 0,
		tilesWide * bit.lshift(spriteSize.x, draw16As0or1),
		tilesHigh * bit.lshift(spriteSize.y, draw16As0or1)
	)
	sceneObj:draw()
	self.fbTex.dirtyGPU = true
	self.fbTex.changedSinceDraw = true
end

-- draw transparent-background text
function App:drawText1bpp(text, x, y, color, scaleX, scaleY)
	for i=1,#text do
		local ch = text:byte(i)
		local bi = bit.band(ch, 7)		-- get the bit offset
		local by = bit.rshift(ch, 3)	-- get the byte offset
		self:drawSprite(
			spriteSheetSizeInTiles.x * (spriteSheetSizeInTiles.y-1)
			+ by,                     -- spriteIndex is th last row
			x,						-- x
			y,                      -- y
			1,                      -- spritesWide
			1,                      -- spritesHigh
			-- font color is 0 = background, 1 = foreground
			-- so shift this by 1 so the font tex contents shift it back
			-- TODO if compression is a thing then store 8 letters per 8x8 sprite
			-- 		heck why not store 2 letters per left and right half as well?  that's half the alphaet in a single 8x8 sprite black.
			color-1,           		-- paletteIndex ... 'color index offset' / 'palette high bits'
			0,				       	-- transparentIndex
			bi,                     -- spriteBit
			1,                      -- spriteMask
			scaleX,                 -- scaleX
			scaleY                  -- scaleY
		)
		-- TODO font widths per char?
		x = x + fontWidth
	end
	return x
end

-- draw a solid background color, then draw the text transparent
-- specify an oob bgColorIndex to draw with transparent background
-- and default x, y to the last cursor position
function App:drawText(text, x, y, fgColorIndex, bgColorIndex, scaleX, scaleY)
	x = x or 0
	y = y or 0
	fgColorIndex = fgColorIndex or 13
	bgColorIndex = bgColorIndex or 0
	scaleX = scaleX or 1
	scaleY = scaleY or 1
	local x0 = x
	if bgColorIndex >= 0 and bgColorIndex < 255 then
		for i=1,#text do
			-- TODO the ... between drawSolidRect and drawSprite is not the same...
			self:drawSolidRect(
				x,
				y,
				scaleX * fontWidth, --spriteSize.x,
				scaleY * spriteSize.y,
				bgColorIndex
			)
			x = x + fontWidth
		end
	end

	return self:drawText1bpp(
		text,
		x0+1,
		y+1,
		fgColorIndex,
		scaleX,
		scaleY
	) - x0
end

-- save from cartridge to filesystem
function App:save(filename)

	local n = #self.editCode.text
	assertlt(n+1, codeSize)
--print('saving code', self.editCode.text, 'size', n)
	ffi.copy(self.ram.code, self.editCode.text, n)
	self.ram.code[n] = 0	-- null term

	if not select(2, path(filename):getext()) then
		filename = path(filename):setext'n9'.path
	end
	filename = filename or defaultSaveFilename
	local basemsg = 'failed to save file '..tostring(filename)

	-- TODO xpcall?
	local toCartImage = require 'numo9.archive'.toCartImage
	local success, s = xpcall(
		toCartImage,
		errorHandler,
		self.ram.v
	)
	if not success then
		return nil, basemsg..(s or '')
	end

	-- [[ do I bother implement fs:open'w' ?
	local f, msg = self.fs:create(filename)
	if not f then return nil, basemsg..' fs:create failed: '..msg end
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
function App:load(filename)
	filename = filename or defaultSaveFilename
	local basemsg = 'failed to load file '..tostring(filename)

	local f
	local checked = table()
	for _,suffix in ipairs{'', '.n9'} do
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

	-- [[ TODO image stuck reading and writing to disk, FIXME
	local fromCartImage = require 'numo9.archive'.fromCartImage
	local romStr = fromCartImage(d)
	assertlen(romStr, ffi.sizeof'ROM')
	ffi.copy(self.cartridge.v, romStr, ffi.sizeof'ROM')

	self.cartridgeName = filename	-- TODO display this somewhere
	self:resetROM()
	return true
end

--[[
This resets everything from the last loaded .cartridge ROM into .ram
Equivalent of loading the previous ROM again.
That means code too - save your changes!
--]]
function App:resetROM()
	--[[
	self.spriteTex:checkDirtyGPU()
	self.tileTex:checkDirtyGPU()
	self.mapTex:checkDirtyGPU()
	self.palTex:checkDirtyGPU()
	self.fbTex:checkDirtyGPU()
	--]]
	ffi.copy(self.ram.v, self.cartridge.v, ffi.sizeof'ROM')
	-- [[ TODO more dirty flags
	self.spriteTex:bind()
		:subimage()
		:unbind()
	self.spriteTex.dirtyCPU = false
	self.tileTex:bind()
		:subimage()
		:unbind()
	self.tileTex.dirtyCPU = false
	self.mapTex:bind()
		:subimage()
		:unbind()
	self.mapTex.dirtyCPU = false
	self.palTex:bind()
		:subimage()
		:unbind()
	self.palTex.dirtyCPU = false
	--]]
	--[[
	self.spriteTex.dirtyCPU = true
	self.tileTex.dirtyCPU = true
	self.mapTex.dirtyCPU = true
	self.palTex.dirtyCPU = true
	self.fbTex.dirtyCPU = true
	--]]

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
		--self.cartridgeEnv or -- would be nice but cartridgeEnv doesn't have langfix, i.e. self.env
		self.env,
		'con'
	))())
	print('RESULT', result:unpack())
	--assert(result:unpack())
	return result:unpack()
	--]]
end

-- initialize our projection to framebuffer size
-- do this every time we run a new rom
function App:resetView()
	self.mvMat:setIdent()
	packptr(4, self.clipRect, 0, 0, 0xff, 0xff)
end

-- TODO ... welp what is editor editing?  the cartridge?  the virtual-filesystem disk image?
-- once I figure that out, this should make sure the cartridge and RAM have the correct changes
function App:runROM()
	self:setFocus(self.con)
	self:resetROM()

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
print('code is', #code, 'bytes')

	-- TODO also put the load() in here so it runs in our virtual console update loop
	env.thread = coroutine.create(function()
		self.ram.romUpdateCounter[0] = 0
		self:resetView()

		-- here, if the assert fails then it's an (ugly) parse error, and you can just pcall / pick out the offender
		local f = assert(self:loadCmd(code, env, self.cartridgeName))
		local result = table.pack(f())

print('LOAD RESULT', result:unpack())
print('RUNNING CODE')
print('update:', env.update)

		if not env.update then return end
		while true do
			coroutine.yield()
			env.update()
		end
	end)

	-- save the cartridge's last-env for console support until next ... idk what function should clear the console env?
	self.cartridgeEnv = env

	self:setFocus(env)
end

-- set the focus of whats running ... between the cartridge, the console, or the emulator
function App:setFocus(focus)
	if self.runFocus then
		if self.runFocus.loseFocus then self.runFocus:loseFocus() end
	end
	self.runFocus = focus or assert(self.con, "how did you lose the console?")
	if self.runFocus then
		if self.runFocus.gainFocus then self.runFocus:gainFocus() end
	end
end

function App:stop()
	self:setFocus(self.con)

	-- this is fine right? nobody is calling stop() from the main thread right?
	-- I can assert that, but then it's an error, just like yield()'ing from main thread is an error so ...
	coroutine.yield()
end

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


-- TODO make this configurable
-- let's use tic80's standard for button codes
-- but ofc I gotta tweak it to my own mapping
-- https://gamefaqs.gamespot.com/snes/916396-super-nintendo/faqs/5395
-- fun fact, SNES's keys in-order are:
-- B Y Sel Start Up Down Left Right A X L R
local keyCodeForButtonIndex = {
	-- player 1
	[0] = keyCodeForName.up,		-- UP
	[1] = keyCodeForName.down,		-- DOWN
	[2] = keyCodeForName.left,		-- LEFT
	[3] = keyCodeForName.right,		-- RIGHT
	[4] = keyCodeForName.s,			-- A
	[5] = keyCodeForName.x,			-- B
	[6] = keyCodeForName.a,			-- X
	[7] = keyCodeForName.z,			-- Y
	-- TODO player 2 player 3 player 4 ...
	-- L R? start select?  or nah? or just one global menu button?
}
local buttonIndexForKeyCode = table.map(keyCodeForButtonIndex, function(keyCode, buttonIndex)
	return buttonIndex, keyCode
end):setmetatable(nil)

-- TODO named support just like key() keyp() keyr()
-- double TODO - just use key/p/r, and just use extra flags
function App:btn(buttonCode, ...)
	return self:key(keyCodeForButtonIndex[buttonCode], ...)
end
function App:btnp(buttonCode, ...)
	return self:keyp(keyCodeForButtonIndex[buttonCode], ...)
end
function App:btnr(buttonCode, ...)
	return self:keyr(keyCodeForButtonIndex[buttonCode], ...)
end

function App:mouse()
	return
		self.ram.mousePos.x,
		self.ram.mousePos.y,
		0,	-- TODO scrollX
		0	-- TODO scrollY
end

-- run but make sure the vm is set up
-- esp the framebuffer
-- TODO might get rid of this now that i just upload cpu->gpu the vram every frame
function App:runInEmu(cb, ...)
	if not self.inUpdateCallback then
		self.fb:bind()
		gl.glViewport(0, 0, frameBufferSize.x, frameBufferSize.y)
		gl.glScissor(
			self.clipRect[0],
			self.clipRect[1],
			self.clipRect[2]+1,
			self.clipRect[3]+1)
	end
	-- TODO if we're in the update callback then maybe we'd want to push/pop the viewport and scissors?
	-- meh I'll leave that up to the callback

	cb(...)

	if not self.inUpdateCallback then
		self.fb:unbind()
	end
end

function App:event(e)
	local Editor = require 'numo9.editor'
	if e[0].type == sdl.SDL_KEYUP
	or e[0].type == sdl.SDL_KEYDOWN
	then
		local down = e[0].type == sdl.SDL_KEYDOWN
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
			if self.runFocus == self.con then
				self:setFocus(self.editCode)
			elseif Editor:isa(self.runFocus) then
				self:setFocus(self.con)
			else
				-- assume it's a game
				self:setFocus(self.con)
			end
			self:runInEmu(function()
				self:resetView()
				-- TODO re-init the con?  clear? special per runFocus?
				if self.runFocus == self.con then
					self.con:reset()
				end
			end)
		else
			local keycode = sdlSymToKeyCode[sdlsym]
			if keycode then
				local bi = bit.band(keycode, 7)
				local by = bit.rshift(keycode, 3)
				-- TODO turn this into raw mem like those other virt cons
				local flag = bit.lshift(1, bi)
				local mask = bit.bnot(flag)
				self.ram.keyPressFlags[by] = bit.bor(
					bit.band(mask, self.ram.keyPressFlags[by]),
					down and flag or 0
				)
			end

			--[[
			-- Keys can have multiple bindings - both to keys and to joypad buttons
			-- TODO also handle them in other events like SDL_BUTTONDOWN
			local buttonCode = buttonForKeyCode[keycode]
			if buttonCode then
			end
			--]]
		end
	elseif e[0].type == sdl.SDL_MOUSEBUTTONDOWN
	or e[0].type == sdl.SDL_MOUSEBUTTONUP
	then
		local down = e[0].type == sdl.SDL_MOUSEBUTTONDOWN
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

			local buttonCode = buttonIndexForKeyCode[keycode]
			-- gets us the 0-based keys
			if buttonCode then
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

return App
