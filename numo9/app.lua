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
local template = require 'template'
local assertindex = require 'ext.assert'.index
local asserttype = require 'ext.assert'.type
local assertlen = require 'ext.assert'.len
local asserteq = require 'ext.assert'.eq
local assertne = require 'ext.assert'.ne
local assertle = require 'ext.assert'.le
local assertlt = require 'ext.assert'.lt
local string = require 'ext.string'
local table = require 'ext.table'
local math = require 'ext.math'
local path = require 'ext.path'
local getTime = require 'ext.timer'.getTime
local tolua = require 'ext.tolua'
local fromlua = require 'ext.fromlua'
local vec2s = require 'vec-ffi.vec2s'
local vec2i = require 'vec-ffi.vec2i'
local matrix_ffi = require 'matrix.ffi'
local Image = require 'image'
local sdl = require 'sdl'
local clnumber = require 'cl.obj.number'
local gl = require 'gl'
local glreport = require 'gl.report'
local GLApp = require 'glapp'
local GLTex2D = require 'gl.tex2d'
local GLFBO = require 'gl.fbo'
local GLGeometry = require 'gl.geometry'
local GLProgram = require 'gl.program'
local GLSceneObject = require 'gl.sceneobject'
local vector = require 'ffi.cpp.vector-lua'
local struct = require 'struct'

local keyCodeNames = require 'numo9.keys'.keyCodeNames
local keyCodeForName = require 'numo9.keys'.keyCodeForName
local sdlSymToKeyCode = require 'numo9.keys'.sdlSymToKeyCode

-- I was hoping I could do this all in integer, but maybe not for the fragment output, esp with blending ...
-- glsl unsigned int fragment colors and samplers really doesn't do anything predictable...
local fragColorUseFloat = false
--local fragColorUseFloat = true

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
--local frameBufferType = 'uint8_t'		-- rgb332
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
				{name='lastMouseButtons', type='uint8_t[1]'},	-- same question...
				{name='mouseButtons', type='uint8_t[1]'},	-- mouse button flags.  using SDL atm so flags 0 1 2 = left middle right
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



function App:initGL()

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

	local function makeImageAtPtr(ptr, x, y, ch, type, ...)
		assertne(ptr, nil)
		local image = Image(x, y, ch, type, ...)
		local size = x * y * ch * ffi.sizeof(type)
		if select('#', ...) > 0 then	-- if we specified a generator...
			ffi.copy(ptr, image.buffer, size)
		end
		image.buffer = ptr
		return image
	end

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

		-- math
		cos = math.cos,
		sin = math.sin,

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
	local state = require 'langfix.env'(self.loadenv)
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

	self.fb = GLFBO{
		width = frameBufferSize.x,
		height = frameBufferSize.y,
	}:unbind()

	-- redirect the image buffer to our virtual system rom
	self.spriteTex = self:makeTexFromImage{
		image = makeImageAtPtr(self.ram.spriteSheet, spriteSheetSize.x, spriteSheetSize.y, 1, 'unsigned char'):clear(),
		internalFormat = gl.GL_R8UI,
		format = gl.GL_RED_INTEGER,
		type = gl.GL_UNSIGNED_BYTE,
	}

	self.tileTex = self:makeTexFromImage{
		image = makeImageAtPtr(self.ram.tileSheet, spriteSheetSize.x, spriteSheetSize.y, 1, 'unsigned char'):clear(),
		internalFormat = gl.GL_R8UI,
		format = gl.GL_RED_INTEGER,
		type = gl.GL_UNSIGNED_BYTE,
	}

	--[[
	16bpp ...
	- 10 bits of lookup into spriteTex
	- 4 bits high palette nibble
	- 1 bit hflip
	- 1 bit vflip
	- .... 2 bits rotate ... ? nah
	- .... 8 bits palette offset ... ? nah
	--]]
	self.mapTex = self:makeTexFromImage{
		image = makeImageAtPtr(self.ram.tilemap, tilemapSize.x, tilemapSize.y, 1, 'unsigned short'):clear(),
		internalFormat = gl.GL_R16UI,
		format = gl.GL_RED_INTEGER,
		type = gl.GL_UNSIGNED_SHORT,
	}
	self.mapMem = self.mapTex.image.buffer

	-- palette is 256 x 1 x 16 bpp (5:5:5:1)
	self.palTex = self:makeTexFromImage{
		image = makeImageAtPtr(self.ram.palette, paletteSize, 1, 1, 'unsigned short'),
		internalFormat = gl.GL_RGB5_A1,
		format = gl.GL_RGBA,
		type = gl.GL_UNSIGNED_SHORT_1_5_5_5_REV,	-- 'REV' means first channel first bit ... smh
	}
--print('palTex\n'..imageToHex(self.palTex.image))

	local fbMask = bit.lshift(1, ffi.sizeof(frameBufferType)) - 1
	local fbImage = makeImageAtPtr(
		self.ram.framebuffer,
		frameBufferSize.x,
		frameBufferSize.y,
		1,
		frameBufferType,
		function(i,j) return math.random(0, fbMask) end
	)
	-- [=[ framebuffer is 256 x 256 x 16bpp rgb565
	self.fbTex = self:makeTexFromImage{
		image = fbImage,
		internalFormat = gl.GL_RGB565,
		format = gl.GL_RGB,
		type = gl.GL_UNSIGNED_SHORT_5_6_5,
	}
	--]=]
	--[=[ framebuffer is 256 x 256 x 16bpp rgba4444
	self.fbTex = self:makeTexFromImage{
		image = fbImage,
		internalFormat = gl.GL_RGBA4,
		format = gl.GL_RGBA,
		type = gl.GL_UNSIGNED_SHORT_4_4_4_4,
	}
	--]=]
	--[=[ framebuffer is 256 x 256 x 8bpp rgb332
	self.fbTex = self:makeTexFromImage{
		image = fbImage,
		internalFormat = gl.GL_R8UI,
		format = gl.GL_RED_INTEGER,
		type = gl.GL_UNSIGNED_BYTE,
	}
	--]=]
--print('fbTex\n'..imageToHex(self.fbTex.image))


	self.quadGeom = GLGeometry{
		mode = gl.GL_TRIANGLE_STRIP,
		vertexes = {
			data = {
				0, 0,
				1, 0,
				0, 1,
				1, 1,
			},
			dim = 2,
		},
	}

	-- desktop-GL versions ...
	-- https://www.khronos.org/opengl/wiki/Core_Language_(GLSL)
	--local glslVersion = '110'	-- gl 2.0
	--local glslVersion = '120'	-- gl 2.1
	--local glslVersion = '130'	-- gl 3.0
	--local glslVersion = '140'	-- gl 3.1	-- lowest working version on my osx before it complains that the version (too low) aren't supported ...
	--local glslVersion = '150'	-- gl 3.2
	--local glslVersion = '330'	-- gl 3.3
	--local glslVersion = '400'	-- gl 4.0
	local glslVersion = '410'	-- gl 4.1	-- highest working version on my osx before it complains ...
	--local glslVersion = '420'	-- gl 4.2
	--local glslVersion = '430'	-- gl 4.3
	--local glslVersion = '440'	-- gl 4.4
	--local glslVersion = '450'	-- gl 4.5
	--local glslVersion = '460'	-- gl 4.6

	-- GLES versions ...
	--local glslVersion = '100 es'
	--local glslVersion = '300 es'
	--local glslVersion = '310 es'
	--local glslVersion = '320 es'

	-- used for drawing our 8bpp framebuffer to the screen
	self.blitScreenObj = GLSceneObject{
		program = {
			version = glslVersion,
			precision = 'best',
			vertexCode = [[
layout(location=0) in vec2 vertex;
out vec2 tcv;
uniform mat4 mvProjMat;
void main() {
	tcv = vertex;
	gl_Position = mvProjMat * vec4(vertex, 0., 1.);
}
]],
			fragmentCode = template([[
in vec2 tcv;
<? if fragColorUseFloat then ?>
layout(location=0) out vec4 fragColor;
<? else ?>
layout(location=0) out uvec4 fragColor;
<? end ?>
uniform usampler2DRect fbTex;

const float frameBufferSizeX = <?=clnumber(frameBufferSize.x)?>;
const float frameBufferSizeY = <?=clnumber(frameBufferSize.y)?>;

void main() {
	ivec2 fbTc = ivec2(
		int(tcv.x * frameBufferSizeX),
		int(tcv.y * frameBufferSizeY)
	);
#if 1 // rgb565 just copy over
<? if fragColorUseFloat then ?>
#if 1	// how many bits does uvec4 get from texture() ?
	fragColor = texture(fbTex, fbTc) / float((1u<<31)-1u);
#else	// or does gl just magically know the conversion?
	fragColor = texture(fbTex, fbTc);
#endif
<? else ?>
	fragColor = texture(fbTex, fbTc);
<? end ?>
#endif
#if 0 // rgb332 translate the 8bpp single-channel

	// how come this gives me [0,2^8) ?
	// meanwhile ffragment output must be [0,2^32) ?
	// does texture() output in 8bpp while fragments output in 32bpp?
	// and how come I can say 'fragColor = texture()' above where the texture is rgb565 and it works fine?
	// where exactly does the conversion/normalization take place? esp for render buffer(everyone writes about what fbos do depending on the fbo format...)
	uint rgb332 = texture(fbTex, fbTc).r;

	uint r = rgb332 & 7u;			// 3 bits of red ...
	uint g = (rgb332 >> 3) & 7u;	// 3 bits of green ...
	uint b = (rgb332 >> 6) & 3u;	// 2 bits of blue ...
	fragColor = uvec4(
		r << 29,
		g << 29,
		b << 30,
		0xFFFFFFFFu
	);
#endif
}
]],			{
				fragColorUseFloat = fragColorUseFloat,
				clnumber = clnumber,
				frameBufferSize = frameBufferSize,
			}),
			uniforms = {
				fbTex = 0,
			},
		},
		texs = {self.fbTex},
		geometry = self.quadGeom,
		-- glUniform()'d every frame
		uniforms = {
			mvProjMat = self.blitScreenView.mvProjMat.ptr,
		},
	}

	self.lineSolidObj = GLSceneObject{
		program = {
			version = glslVersion,
			precision = 'best',
			vertexCode = template([[
layout(location=0) in vec2 vertex;
uniform vec4 line;	//x1,y1,x2,y2
uniform mat4 mvMat;

//instead of a projection matrix, here I'm going to convert from framebuffer pixel coordinates to GL homogeneous coordinates.
const float frameBufferSizeX = <?=clnumber(frameBufferSize.x)?>;
const float frameBufferSizeY = <?=clnumber(frameBufferSize.y)?>;

const float lineThickness = 1.;

void main() {
	vec2 delta = line.zw - line.xy;
	vec2 pc = line.xy
		+ delta * vertex.x
		+ normalize(vec2(-delta.y, delta.x)) * (vertex.y - .5) * lineThickness;
	gl_Position = mvMat * vec4(pc, 0., 1.);
	gl_Position.xy /= vec2(frameBufferSizeX, frameBufferSizeY);
	gl_Position.xy *= 2.;
	gl_Position.xy -= 1.;
}
]],			{
				clnumber = clnumber,
				frameBufferSize = frameBufferSize,
			}),
			fragmentCode = template([[
<? if fragColorUseFloat then ?>
layout(location=0) out vec4 fragColor;
<? else ?>
layout(location=0) out uvec4 fragColor;
<? end ?>

uniform uint colorIndex;
uniform usampler2DRect palTex;

float sqr(float x) { return x * x; }

void main() {
	ivec2 palTc = ivec2(
<? assert(math.log(paletteSize, 2) % 1 == 0)
?>		colorIndex & <?=('0x%Xu'):format(paletteSize-1)?>,
		0
	);
#if 1	// rgb565
<? if fragColorUseFloat then ?>
	fragColor = texture(palTex, palTc) / float((1u<<31)-1u);
<? else ?>
	fragColor = texture(palTex, palTc);
<? end ?>

	// TODO THIS? or should we just rely on the transparentIndex==0 for that? or both?
	//for draw-solid it's not so useful because we can already specify the color and the transparency alpha here
	// so there's no point in having an alpha-by-color since it will be all-solid or all-transparent.
	//if (fragColor.a == 0) discard;
#endif
#if 0	// rgb332
	uvec4 color = texture(palTex, palTc);
	if (color.a == 0) discard;
	fragColor = uvec4(
		(color.r >> 5) & 0x07u
		| (color.g >> 2) & 0x38u
		| color.b & 0xC0u,
		0, 0, 0xFFu
	);
#endif
}
]],			{
				clnumber = clnumber,
				paletteSize = paletteSize,
				fragColorUseFloat = fragColorUseFloat,
			}),
			uniforms = {
				palTex = 0,
				--mvMat = self.mvMat.ptr,
			},
		},
		texs = {self.palTex},
		geometry = self.quadGeom,
		-- glUniform()'d every frame
		uniforms = {
			mvMat = self.mvMat.ptr,
			colorIndex = 0,
			line = {0, 0, 8, 8},
		},
	}


	self.quadSolidObj = GLSceneObject{
		program = {
			version = glslVersion,
			precision = 'best',
			vertexCode = template([[
layout(location=0) in vec2 vertex;
out vec2 pcv;	// unnecessary except for the sake of 'round' ...
uniform vec4 box;	//x,y,w,h
uniform mat4 mvMat;

//instead of a projection matrix, here I'm going to convert from framebuffer pixel coordinates to GL homogeneous coordinates.
const float frameBufferSizeX = <?=clnumber(frameBufferSize.x)?>;
const float frameBufferSizeY = <?=clnumber(frameBufferSize.y)?>;

void main() {
	pcv = box.xy + vertex * box.zw;
	gl_Position = mvMat * vec4(pcv, 0., 1.);
	gl_Position.xy /= vec2(frameBufferSizeX, frameBufferSizeY);
	gl_Position.xy *= 2.;
	gl_Position.xy -= 1.;
}
]],			{
				clnumber = clnumber,
				frameBufferSize = frameBufferSize,
			}),
			fragmentCode = template([[
// framebuffer pixel coordinates
in vec2 pcv;

uniform vec4 box;	//x,y,w,h

<? if fragColorUseFloat then ?>
layout(location=0) out vec4 fragColor;
<? else ?>
layout(location=0) out uvec4 fragColor;
<? end ?>

uniform uint colorIndex;
uniform usampler2DRect palTex;
uniform bool borderOnly;
uniform bool round;

float sqr(float x) { return x * x; }

void main() {
	if (round) {
		// midpoint-circle / Bresenham algorithm, like Tic80 uses:
		// figure out which octant of the circle you're in
		// then compute deltas based on if |dy| / |dx|
		// (x/a)^2 + (y/b)^2 = 1
		// x/a = √(1 - (y/b)^2)
		// x = a√(1 - (y/b)^2)
		// y = b√(1 - (x/a)^2)
		vec2 radius = .5 * box.zw;
		vec2 center = box.xy + radius;
		vec2 delta = pcv - center;
		if (box.w < box.z) {	// TODO consider the mvMat transform ...
			// top/bottom quadrant
			float by = radius.y * sqrt(1. - sqr(delta.x / radius.x));
			if (delta.y > by || delta.y < -by) discard;
			if (borderOnly && delta.y < by-1. && delta.y > -by+1.) discard;
		} else {
			// left/right quadrant
			float bx = radius.x * sqrt(1. - sqr(delta.y / radius.y));
			if (delta.x > bx || delta.x < -bx) discard;
			if (borderOnly && delta.x < bx-1. && delta.x > -bx+1.) discard;
		}
	} else {
		if (borderOnly) {
			if (pcv.x > box.x+1.
				&& pcv.x < box.x+box.z-1.
				&& pcv.y > box.y+1.
				&& pcv.y < box.y+box.w-1.
			) discard;
		}
		// else default solid rect
	}

	ivec2 palTc = ivec2(
<? assert(math.log(paletteSize, 2) % 1 == 0)
?>		colorIndex & <?=('0x%Xu'):format(paletteSize-1)?>,
		0
	);
#if 1	// rgb565
<? if fragColorUseFloat then ?>
	fragColor = texture(palTex, palTc) / float((1u<<31)-1u);
<? else ?>
	fragColor = texture(palTex, palTc);
<? end ?>
#endif
#if 0	// rgb332
	uvec4 color = texture(palTex, palTc);
	fragColor = uvec4(
		(color.r >> 5) & 0x07u
		| (color.g >> 2) & 0x38u
		| color.b & 0xC0u,
		0, 0, color.a==0 ? 0 : 0xFFu
	);
#endif

	// TODO THIS? or should we just rely on the transparentIndex==0 for that? or both?
	//for draw-solid it's not so useful because we can already specify the color and the transparency alpha here
	// so there's no point in having an alpha-by-color since it will be all-solid or all-transparent.
	//if (fragColor.a == 0) discard;
}
]],			{
				clnumber = clnumber,
				paletteSize = paletteSize,
				fragColorUseFloat = fragColorUseFloat,
			}),
			uniforms = {
				palTex = 0,
				borderOnly = false,
				round = false,
				--mvMat = self.mvMat.ptr,
			},
		},
		texs = {self.palTex},
		geometry = self.quadGeom,
		-- glUniform()'d every frame
		uniforms = {
			mvMat = self.mvMat.ptr,
			colorIndex = 0,
			box = {0, 0, 8, 8},
		},
	}

	self.quadSpriteObj = GLSceneObject{
		program = {
			version = glslVersion,
			precision = 'best',
			vertexCode = template([[
in vec2 vertex;
out vec2 tcv;
uniform vec4 box;	//x,y,w,h
uniform vec4 tcbox;	//x,y,w,h

uniform mat4 mvMat;

const float frameBufferSizeX = <?=clnumber(frameBufferSize.x)?>;
const float frameBufferSizeY = <?=clnumber(frameBufferSize.y)?>;

void main() {
	tcv = tcbox.xy + vertex * tcbox.zw;
	vec2 pc = box.xy + vertex * box.zw;
	gl_Position = mvMat * vec4(pc, 0., 1.);
	gl_Position.x /= frameBufferSizeX;
	gl_Position.y /= frameBufferSizeY;
	gl_Position.xy *= 2.;
	gl_Position.xy -= 1.;
}
]],			{
				clnumber = clnumber,
				frameBufferSize = frameBufferSize,
			}),
			fragmentCode = template([[
in vec2 tcv;

<? if fragColorUseFloat then ?>
layout(location=0) out vec4 fragColor;
<? else ?>
layout(location=0) out uvec4 fragColor;
<? end ?>

//For now this is an integer added to the 0-15 4-bits of the sprite tex.
//You can set the top 4 bits and it'll work just like OR'ing the high color index nibble.
//Or you can set it to low numbers and use it to offset the palette.
//Should this be high bits? or just an offset to OR? or to add?
uniform uint paletteIndex;

// Reads 4 bits from wherever shift location you provide.
uniform usampler2DRect spriteTex;

// Specifies which bit to read from at the sprite.
//  0 = read sprite low nibble.
//  4 = read sprite high nibble.
//  other = ???
uniform uint spriteBit;

// specifies the mask after shifting the sprite bit
//  0x01u = 1bpp
//  0x03u = 2bpp
//  0x07u = 3bpp
//  0x0Fu = 4bpp
//  0xFFu = 8bpp
uniform uint spriteMask;

// Specifies which colorIndex to use as transparency.
// This is the value of the sprite texel post sprite bit shift & mask, but before applying the paletteIndex shift / high bits.
// If you want fully opaque then just choose an oob color index.
uniform uint transparentIndex;

uniform usampler2DRect palTex;

const float spriteSheetSizeX = <?=clnumber(spriteSheetSize.x)?>;
const float spriteSheetSizeY = <?=clnumber(spriteSheetSize.y)?>;

void main() {
	// TODO provide a shift uniform for picking lo vs hi nibble
	// only use the lower 4 bits ...
	uint colorIndex = (texture(
		spriteTex,
		ivec2(
			tcv.x * spriteSheetSizeX,
			tcv.y * spriteSheetSizeY
		)
	).r >> spriteBit) & spriteMask;

	// TODO HERE MAYBE
	// lookup the colorIndex in the palette to determine the alpha channel
	// but really, why an extra tex read here?
	// how about instead I do the TIC-80 way and just specify which index per-sprite is transparent?
	// then I get to use all my colors
	if (colorIndex == transparentIndex) discard;

	//colorIndex should hold
	colorIndex += paletteIndex;
	colorIndex &= 0XFFu;

	// write the 8bpp colorIndex to the screen, use tex to draw it
	ivec2 palTc = ivec2(colorIndex, 0);
#if 1	// rgb565
<? if fragColorUseFloat then ?>
	fragColor = texture(palTex, palTc) / float((1u<<31)-1u);
<? else ?>
	fragColor = texture(palTex, palTc);
<? end ?>
	if (fragColor.a == 0) discard;
#endif
#if 0	// rgb332
	uvec4 color = texture(palTex, palTc);
	if (color.a == 0) discard;
	fragColor = uvec4(
		(color.r >> 5) & 0x07u
		| (color.g >> 2) & 0x38u
		| color.b & 0xC0u,
		0, 0, 0xFFu
	);
#endif
}
]], 		{
				clnumber = clnumber,
				spriteSheetSize = spriteSheetSize,
				fragColorUseFloat = fragColorUseFloat,
			}),
			uniforms = {
				spriteTex = 0,
				palTex = 1,
				paletteIndex = 0,
				transparentIndex = -1,
				spriteBit = 0,
				spriteMask = 0x0F,
				--mvMat = self.mvMat.ptr,
			},
		},
		texs = {
			self.spriteTex,
			self.palTex,
		},
		geometry = self.quadGeom,
		-- glUniform()'d every frame
		uniforms = {
			mvMat = self.mvMat.ptr,
			box = {0, 0, 8, 8},
			tcbox = {0, 0, 1, 1},
		},
	}

	self.quadMapObj = GLSceneObject{
		program = {
			version = glslVersion,
			precision = 'best',
			vertexCode = template([[
in vec2 vertex;
out vec2 tcv;
uniform vec4 box;		//x y w h
uniform vec4 tcbox;		//tx ty tw th
uniform mat4 mvMat;

const float frameBufferSizeX = <?=clnumber(frameBufferSize.x)?>;
const float frameBufferSizeY = <?=clnumber(frameBufferSize.y)?>;

void main() {
	tcv = tcbox.xy + vertex * tcbox.zw;
	vec2 pc = box.xy + vertex * box.zw;
	gl_Position = mvMat * vec4(pc, 0., 1.);
	gl_Position.x /= frameBufferSizeX;
	gl_Position.y /= frameBufferSizeY;
	gl_Position.xy *= 2.;
	gl_Position.xy -= 1.;
}
]],			{
				clnumber = clnumber,
				frameBufferSize = frameBufferSize,
			}),
			fragmentCode = template([[
in vec2 tcv;
<? if fragColorUseFloat then ?>
layout(location=0) out vec4 fragColor;
<? else ?>
layout(location=0) out uvec4 fragColor;
<? end ?>

// tilemap texture
uniform usampler2DRect mapTex;
uniform uint mapIndexOffset;

uniform usampler2DRect tileTex;

uniform usampler2DRect palTex;

const float spriteSheetSizeX = <?=clnumber(spriteSheetSize.x)?>;
const float spriteSheetSizeY = <?=clnumber(spriteSheetSize.y)?>;
const float tilemapSizeX = <?=clnumber(tilemapSize.x)?>;
const float tilemapSizeY = <?=clnumber(tilemapSize.y)?>;

void main() {
	// convert from input normalized coordinates to tilemap texel coordinates
	// [0, tilemapSize)^2
	uvec2 tci = uvec2(
		uint(tcv.x * tilemapSizeX),
		uint(tcv.y * tilemapSizeY)
	);

	// convert to map texel coordinate
	// [0, tilemapSize)^2
	uvec2 tileTC = uvec2(
		(tci.x >> 3) & 0xFFu,
		(tci.y >> 3) & 0xFFu
	);

	//read the tileIndex in mapTex at tileTC
	//mapTex is R16, so red channel should be 16bpp (right?)
	// how come I don't trust that and think I'll need to switch this to RG8 ...
	uint tileIndex = texture(mapTex, tileTC).r;

	//[0, 31)^2 = 5 bits for tile tex sprite x, 5 bits for tile tex sprite y
	uvec2 tileTexTC = uvec2(
		tileIndex & 0x1Fu,					// tilemap bits 0..4
		(tileIndex >> 5) & 0x1Fu			// tilemap bits 5..9
	);
	uint palHi = (tileIndex >> 10) & 0xFu;	// tilemap bits 10..13
	if ((tileIndex & (1u<<14)) != 0u) tci.x = ~tci.x;	// tilemap bit 14
	if ((tileIndex & (1u<<15)) != 0u) tci.y = ~tci.y;	// tilemap bit 15

	// [0, spriteSize)^2
	tileTexTC = uvec2(
		(tci.x & 7u) | (tileTexTC.x << 3),
		(tci.y & 7u) | (tileTexTC.y << 3)
	);

	// tileTex is R8 indexing into our palette ...
	uint colorIndex = texture(tileTex, tileTexTC).r;
	colorIndex |= palHi << 4;

//debug:
//colorIndex = tileIndex;

	ivec2 palTc = ivec2(colorIndex, 0);
#if 1	// rgb565
<? if fragColorUseFloat then ?>
	fragColor = texture(palTex, palTc) / float((1u<<31)-1u);
<? else ?>
	fragColor = texture(palTex, palTc);
<? end ?>
	if (fragColor.a == 0) discard;
#endif
#if 0	// rgb332
	uvec4 color = texture(palTex, palTc);
	if (color.a == 0) discard;
	fragColor = uvec4(
		(color.r >> 5) & 0x07u
		| (color.g >> 2) & 0x38u
		| color.b & 0xC0u,
		0, 0, 0xFFu
	);
#endif
}
]],			{
				clnumber = clnumber,
				spriteSheetSize = spriteSheetSize,
				tilemapSize = tilemapSize,
				fragColorUseFloat = fragColorUseFloat,
			}),
			uniforms = {
				mapTex = 0,
				tileTex = 1,
				palTex = 2,
				mapIndexOffset = 0,
				--mvMat = self.mvMat.ptr,
			},
		},
		texs = {self.mapTex, self.tileTex, self.palTex},
		geometry = self.quadGeom,
		-- glUniform()'d every frame
		uniforms = {
			mvMat = self.mvMat.ptr,
			box = {0, 0, 8, 8},
			tcbox = {0, 0, 1, 1},
		},
	}

	local fb = self.fb
	fb:bind()
	fb:setColorAttachmentTex2D(self.fbTex.id, 0, self.fbTex.target)
	local res,err = fb.check()
	if not res then
		print(err)
		print(debug.traceback())
	end
	fb:unbind()

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

				for i=1,5 do
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
	require 'numo9.resetgfx'.resetFont(self.ram)
	ffi.copy(self.cartridge.spriteSheet, self.ram.spriteSheet, spriteSheetInBytes)

	--self.palTex:prepForCPU()
	require 'numo9.resetgfx'.resetPalette(self.ram)
	ffi.copy(self.cartridge.palette, self.ram.palette, paletteInBytes)
--[[
	self.spriteTex:bind()
		:subimage()
		:unbind()
	self.spriteTex.dirtyCPU = false

	self.palTex:bind()
		:subimage()
		:unbind()
	self.palTex.dirtyCPU = false
	-- TODO maybe, just set 'dirtyGPU' and track that or something ...
--]]
-- [[
	assert(not self.spriteTex.dirtyGPU)
	self.spriteTex.dirtyCPU = true
	assert(not self.palTex.dirtyGPU)
	self.palTex.dirtyCPU = true
--]]
end


-- [[ also in sand-attack ... hmmmm ...
-- consider putting somewhere common, maybe in gl.tex2d ?
-- maybe just save .image in gltex2d?
function App:makeTexFromImage(args)
glreport'here'
	local image = assert(args.image)
	if image.channels ~= 1 then print'DANGER - non-single-channel Image!' end
	local tex = GLTex2D{
		target = args.target or gl.GL_TEXTURE_RECTANGLE,
		internalFormat = args.internalFormat or gl.GL_RGBA,
		format = args.format or gl.GL_RGBA,
		type = args.type or gl.GL_UNSIGNED_BYTE,

		width = tonumber(image.width),
		height = tonumber(image.height),
		wrap = args.wrap or { -- texture_rectangle doens't support repeat ...
			s = gl.GL_CLAMP_TO_EDGE,
			t = gl.GL_CLAMP_TO_EDGE,
		},
		minFilter = args.minFilter or gl.GL_NEAREST,
		magFilter = args.magFilter or gl.GL_NEAREST,
		data = image.buffer,	-- stored
	}:unbind()
	-- TODO move this store command to gl.tex2d ctor if .image is used?
	tex.image = image

	-- TODO gonna subclass this soon ...
	local app = self
	-- assumes it is being called from within the render loop
	function tex:checkDirtyCPU()
		if not self.dirtyCPU then return end
		-- we should never get in a state where both CPU and GPU are dirty
		-- if someone is about to write to one then it shoudl test the other and flush it if it's dirty, then set the one
		assert(not self.dirtyGPU)
		local fb = app.fb
		app.fb:unbind()
		self:bind()
			:subimage()
			:unbind()
		app.fb:bind()
		self.dirtyCPU = false
	end
glreport'here'

	return tex
end

function App:update()
	App.super.update(self)

	local thisTime = getTime()

	-- [[ fps counter
	local deltaTime = thisTime - lastTime
	fpsFrames = fpsFrames + 1
	fpsSeconds = fpsSeconds + deltaTime
	if fpsSeconds > 1 then
		print('FPS: '..fpsFrames / fpsSeconds)
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
			self.ram.lastMouseButtons[0] = self.ram.mouseButtons[0]
			self.ram.mouseButtons[0] = sdl.SDL_GetMouseState(self.screenMousePos.s, self.screenMousePos.s+1)
			local x1, x2, y1, y2, z1, z2 = self.blitScreenView:getBounds(self.width / self.height)
			local x = tonumber(self.screenMousePos.x) / tonumber(self.width)
			local y = tonumber(self.screenMousePos.y) / tonumber(self.height)
			x = x1 * (1 - x) + x2 * x
			y = y1 * (1 - y) + y2 * y
			x = x * .5 + .5
			y = y * .5 + .5
			self.ram.mousePos.x = x * tonumber(frameBufferSize.x)
			self.ram.mousePos.y = y * tonumber(frameBufferSize.y)
			local leftButtonLastDown = bit.band(self.ram.lastMouseButtons[0], 1) == 1
			local leftButtonDown = bit.band(self.ram.mouseButtons[0], 1) == 1
			local leftButtonPress = leftButtonDown and not leftButtonLastDown
			if leftButtonPress then
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

		-- do this every frame or only on updates?
		-- how about no more than twice after an update (to please the double-buffers)
		needDrawCounter = 2
	end

	if needDrawCounter > 0 then
		needDrawCounter = needDrawCounter - 1

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
	end
end

function App:peek(addr)
	if addr < 0 or addr >= ffi.sizeof(self.ram) then return end

	-- if we're writing to a dirty area then flush it to cpu
	-- assume the GL framebuffer is bound to the fbTex
	if self.fbTex.dirtyGPU and addr >= framebufferAddr and addr < framebufferAddrEnd then
		gl.glReadPixels(0, 0, frameBufferSize.x, frameBufferSize.y, self.fbTex.format, self.fbTex.type, self.fbTex.image.buffer)
		self.fbTex.dirtyGPU = false
	end

	return self.ram.v[addr]
end
function App:peekw(addr)
	local addrend = addr+1
	if addr < 0 or addrend >= ffi.sizeof(self.ram) then return end

	if self.fbTex.dirtyGPU and addrend >= framebufferAddr and addr < framebufferAddr+framebufferInBytes then
		gl.glReadPixels(0, 0, frameBufferSize.x, frameBufferSize.y, self.fbTex.format, self.fbTex.type, self.fbTex.image.buffer)
		self.fbTex.dirtyGPU = false
	end

	return ffi.cast('uint16_t*', self.ram.v + addr)[0]
end
function App:peekl(addr)
	local addrend = addr+3
	if addr < 0 or addrend >= ffi.sizeof(self.ram) then return end

	if self.fbTex.dirtyGPU and addrend >= framebufferAddr and addr < framebufferAddr+framebufferInBytes then
		gl.glReadPixels(0, 0, frameBufferSize.x, frameBufferSize.y, self.fbTex.format, self.fbTex.type, self.fbTex.image.buffer)
		self.fbTex.dirtyGPU = false
	end

	return ffi.cast('uint32_t*', self.ram.v + addr)[0]
end

function App:poke(addr, value)
	--addr = math.floor(addr) -- TODO just never pass floats in here or its your own fault
	if addr < 0 or addr >= ffi.sizeof(self.ram) then return end

	-- if we're writing to a dirty area then flush it to cpu
	-- assume the GL framebuffer is bound to the fbTex
	if self.fbTex.dirtyGPU and addr >= framebufferAddr and addr < framebufferAddrEnd then
		assert(not self.fbTex.dirtyCPU)
		gl.glReadPixels(0, 0, frameBufferSize.x, frameBufferSize.y, self.fbTex.format, self.fbTex.type, self.fbTex.image.buffer)
		self.fbTex.dirtyGPU = false
		self.fbTex.dirtyCPU = true
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
		assert(not self.fbTex.dirtyCPU)
		gl.glReadPixels(0, 0, frameBufferSize.x, frameBufferSize.y, self.fbTex.format, self.fbTex.type, self.fbTex.image.buffer)
		self.fbTex.dirtyGPU = false
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
		assert(not self.fbTex.dirtyCPU)
		gl.glReadPixels(0, 0, frameBufferSize.x, frameBufferSize.y, self.fbTex.format, self.fbTex.type, self.fbTex.image.buffer)
		self.fbTex.dirtyGPU = false
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
	self.spriteTex:checkDirtyCPU()
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
	spriteMask = spriteMask or 0xF
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
end

-- TODO go back to tileIndex instead of tileX tileY.  That's what mset() issues after all.
function App:drawMap(
	tileX,
	tileY,
	tilesWide,
	tilesHigh,
	screenX,
	screenY,
	mapIndexOffset
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
	settable(uniforms.box,
		screenX or 0,
		screenY or 0,
		tilesWide * spriteSize.x,
		tilesHigh * spriteSize.y
	)
	sceneObj:draw()
	self.fbTex.dirtyGPU = true
end

-- draw transparent-background text
function App:drawText1bpp(text, x, y, color, scaleX, scaleY)
	for i=1,#text do
		local ch = text:byte(i)
		local by = bit.rshift(ch, 3)	-- get the byte offset
		local bi = bit.band(ch, 7)		-- get the bit offset
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
	self:resetROM()
	return true
end

--[[
This resets everything from the last loaded .cartridge ROM into .ram
Equivalent of loading the previous ROM again.
That means code too - save your changes!
--]]
function App:resetROM()
	ffi.copy(self.ram.v, self.cartridge.v, ffi.sizeof'ROM')

	self.cartridgeName = filename	-- TODO display this somewhere

	-- TODO more dirty flags
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
	local result = table.pack(assert(self:loadCmd(cmd))())
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

		local result = table.pack(assert(self:loadCmd(code, env, self.cartridgeName))())

print('LOAD RESULT', result:unpack())
print('RUNNING CODE')
print('update:', env.update)

		if not env.update then return end
		while true do
			coroutine.yield()
			env.update()
		end
	end)

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
		bit.band(self.ram.mouseButtons[0], sdl.SDL_BUTTON_LMASK) ~= 0,
		bit.band(self.ram.mouseButtons[0], sdl.SDL_BUTTON_MMASK) ~= 0,
		bit.band(self.ram.mouseButtons[0], sdl.SDL_BUTTON_RMASK) ~= 0,
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
	or sdl.SDL_KEYDOWN
	then
		local down = e[0].type == sdl.SDL_KEYDOWN
		local sdlsym = e[0].key.keysym.sym
		if down and sdlsym == sdl.SDLK_ESCAPE then
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
				assert(by >= 0 and by < keyPressFlagSize)
				local mask = bit.bnot(bit.lshift(1, bi))
				self.ram.keyPressFlags[by] = bit.bor(
					bit.band(mask, self.ram.keyPressFlags[by]),
					down and bit.lshift(1, bi) or 0
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
	end
end

return App
