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
local asserteq = require 'ext.assert'.eq
local assertne = require 'ext.assert'.ne
local assertle = require 'ext.assert'.le
local assertlt = require 'ext.assert'.lt
local string = require 'ext.string'
local table = require 'ext.table'
local path = require 'ext.path'
local getTime = require 'ext.timer'.getTime
local tolua = require 'ext.tolua'
local fromlua = require 'ext.fromlua'
local vec2i = require 'vec-ffi.vec2i'
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

local keyCodeNames = require 'numo9.keys'.keyCodeNames
local keyCodeForName = require 'numo9.keys'.keyCodeForName
local sdlSymToKeyCode = require 'numo9.keys'.sdlSymToKeyCode

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

local function errorHandler(err)
	return err..'\n'..debug.traceback()
end

local paletteSize = 256
local spriteSize = vec2i(8, 8)
--local frameBufferType = 'uint16_t'	-- rgb565
local frameBufferType = 'uint8_t'		-- rgb332
local frameBufferSize = vec2i(256, 256)
local frameBufferSizeInTiles = vec2i(frameBufferSize.x / spriteSize.x, frameBufferSize.y / spriteSize.y)
local spriteSheetSize = vec2i(256, 256)
local spriteSheetSizeInTiles = vec2i(spriteSheetSize.x / spriteSize.x, spriteSheetSize.y / spriteSize.y)
local tilemapSize = vec2i(256, 256)
local tilemapSizeInSprites = vec2i(tilemapSize.x /  spriteSize.x, tilemapSize.y /  spriteSize.y)
local codeSize = 0x10000	-- tic80's size ... but with my langfix shorthands like pico8 has

local keyBufferSize = math.ceil(#keyCodeNames / 8)

local struct = require 'struct'
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
				{name='framebuffer', type=frameBufferType..'['..frameBufferSize:volume()..']'},
				{name='clipRect', type='uint8_t[4]'},
				{name='mvMat', type='float[16]'},	-- tempting to do float16 ... or fixed16 ...
				{name='keyBuffer', type='uint8_t['..keyBufferSize..']'},
				{name='lastKeyBuffer', type='uint8_t['..keyBufferSize..']'},
			},
		}},
	},
}
--DEBUG:print(RAM.code)
--DEBUG:print('RAM size', ffi.sizeof(RAM))

for _,field in ipairs(ROM.fields[2].type.fields) do
	assert(xpcall(function()
		asserteq(ffi.offsetof('ROM', field.name), ffi.offsetof('RAM', field.name))
	end, function(err)
		return errorHandler('for field '..field.name..'\n')
	end))
end


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

App.keyBufferSize = keyBufferSize

local function settableindex(t, i, ...)
	if select('#', ...) == 0 then return end
	t[i] = ...
	settableindex(t, i+1, select(2, ...))
end

local function settable(t, ...)
	settableindex(t, 1, ...)
end

local function imageToHex(image)
	return string.hexdump(ffi.string(image.buffer, image.width * image.height * ffi.sizeof(image.format)))
end

-- when I say 'reverse' i mean reversed order of bitfields
-- when opengl says 'reverse' it means reversed order of reading hex numbers or something stupid
function rgb888revto5551(rgba)
	local r = bit.band(bit.rshift(rgba, 16), 0xff)
	local g = bit.band(bit.rshift(rgba, 8), 0xff)
	local b = bit.band(rgba, 0xff)
	local abgr = bit.bor(
		bit.rshift(r, 3),
		bit.lshift(bit.rshift(g, 3), 5),
		bit.lshift(bit.rshift(b, 3), 10),
		bit.lshift(1, 15)	-- hmm always on?  used only for blitting screen?  why not just do 565 or something?  why even have a restriction at all, why not just 888?
	)
	assert(abgr >= 0 and abgr <= 0xffff, ('%x'):format(abgr))
	return abgr
end

local updateFreq = 60
local defaultSaveFilename = 'last.n9'	-- default name of save/load if you don't provide one ...

function App:initGL()

	self.ram = ffi.new'RAM'
	self.rom = ffi.cast('ROM*', self.ram.v)[0]
	
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

	local matrix_ffi = require 'matrix.ffi'
	self.mvMat = matrix_ffi({4,4}, 'float'):zeros():setIdent()
	self.mvMat.ptr = self.ram.mvMat

	local View = require 'glapp.view'
	self.blitScreenView = View()
	self.blitScreenView.ortho = true
	self.blitScreenView.orthoSize = 1

	-- TODO delta updates
	self.startTime = getTime()

	self.env = setmetatable({
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
		write = function(...) return self.con:write(...) end,

		run = function(...) return self:runCode(...) end,
		save = function(...) return self:save(...) end,
		load = function(...) return self:load(...) end,
		quit = function(...) self:requestExit() end,

		peek = function(addr)
			if addr < 0 or addr >= ffi.sizeof(self.ram) then return end
			return self.ram.v[addr]
		end,
		poke = function(addr, value)
			if addr < 0 or addr >= ffi.sizeof(self.ram) then return end
			self.ram.v[addr] = tonumber(value)
		end,

		-- why does tic-80 have mget/mset like pico8 when tic-80 doesn't have pget/pset or sget/sset ...
		mget = function(x, y)
			if x < 0 or x >= self.tilemapSize.x
			or y < 0 or y >= self.tilemapSize.y
			then
				return
			end
			return ffi.cast('unsigned short*', mapMem)[x + self.tilemapSize.x * y]
		end,
		mset = function(x, y, value)
			if x < 0 or x >= self.tilemapSize.x
			or y < 0 or y >= self.tilemapSize.y
			then
				return
			end
			ffi.cast('unsigned short*', mapMem)[x + self.tilemapSize.x * y]	= value
		end,

		-- other stuff
		time = function()
			-- TODO fixed-framerate and internal app clock
			-- until then ...
			return math.floor((getTime() - self.startTime) * updateFreq) / updateFreq
		end,

		-- math
		cos = math.cos,
		sin = math.sin,

		-- graphics

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
			gl.glViewport(
				self.clipRect[0],
				self.clipRect[1],
				self.clipRect[2]+1,
				self.clipRect[3]+1)
		end,

		rect = function(x1,y1,x2,y2, ...)
			return self:drawSolidRect(x1, y1, x2 - x1 + 1, y2 - y1 + 1, ...)
		end,
		rectb = function(x1,y1,x2,y2, ...)
			return self:drawBorderRect(x1, y1, x2 - x1 + 1, y2 - y1 + 1, ...)
		end,
		spr = function(...) return self:drawSprite(...) end,		-- (x, y, spriteIndex, paletteIndex)
		map = function(...) return self:drawMap(...) end,
		text = function(...) return self:drawText(...) end,		-- (x, y, text, fgColorIndex, bgColorIndex)

		-- TODO don't do this
		app = self,
	}, {
		-- TODO don't __index=_G and sandbox it instead
		__index = _G,
	})


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
	self.env.spriteMem = self.spriteTex.image.buffer

	-- paste our font letters one bitplane at a time ...
	do
		local spriteImg = self.spriteTex.image
		local fontImg = Image'font.png'
		local srcx, srcy = 0, 0
		local dstx, dsty = 0, 0
		local function inc2d(x, y, w, h)
			x = x + 8
			if x < w then return x, y end
			x = 0
			y = y + 8
			if y < h then return x, y end
		end
		for i=0,255 do
			local b = bit.band(i, 7)
			local mask = bit.bnot(bit.lshift(1, b))
			for by=0,7 do
				for bx=0,7 do
					local srcp = fontImg.buffer
						+ srcx + bx
						+ fontImg.width * (
							srcy + by
						)
					local dstp = spriteImg.buffer
						+ dstx + bx
						+ spriteImg.width * (
							dsty + by
						)
					dstp[0] = bit.bor(
						bit.band(mask, dstp[0]),
						bit.lshift(srcp[0], b)
					)
				end
			end
			srcx, srcy = inc2d(srcx, srcy, fontImg.width, fontImg.height)
			if not srcx then break end
			if b == 7 then
				dstx, dsty = inc2d(dstx, dsty, spriteImg.width, spriteImg.height)
				if not dstx then break end
			end
		end
	end
	self.spriteTex
		:bind()
		:subimage()
		:unbind()

	self.tileTex = self:makeTexFromImage{
		image = makeImageAtPtr(self.ram.tileSheet, spriteSheetSize.x, spriteSheetSize.y, 1, 'unsigned char'):clear(),
		internalFormat = gl.GL_R8UI,
		format = gl.GL_RED_INTEGER,
		type = gl.GL_UNSIGNED_BYTE,
	}
	self.env.tileMem = self.tileTex.image.buffer

	for i=0,15 do
		for j=0,15 do
			self.tileTex.image.buffer[
				i + self.tileTex.image.width * j
			] = i + j
		end
	end
	self.tileTex
		:bind()
		:subimage()
		:unbind()

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
	self.env.mapMem = self.mapMem

	for i=0,1 do
		for j=0,1 do
			self.mapTex.image.buffer[
				i + tilemapSize.x * j
			] = i + spriteSheetSizeInTiles.x * j
		end
	end
	self.mapTex
		:bind()
		:subimage()
		:unbind()

	-- palette is 256 x 1 x 16 bpp (5:5:5:1)
	self.palTex = self:makeTexFromImage{
		image = makeImageAtPtr(self.ram.palette, paletteSize, 1, 1, 'unsigned short',
		--[[ garbage colors
		function(i)
			return math.floor(math.random() * 0xffff)
		end
		--]]
		-- [[ builtin palette
		table{
			-- tic80
			0x000000,
			0x562b5a,
			0xa44654,
			0xe08260,
			0xf7ce82,
			0xb7ed80,
			0x60b46c,
			0x3b7078,
			0x2b376b,
			0x415fc2,
			0x5ca5ef,
			0x93ecf5,
			0xf4f4f4,
			0x99afc0,
			0x5a6c84,
			0x343c55,
			-- https://en.wikipedia.org/wiki/List_of_software_palettes
			0x000000,
			0x75140c,
			0x377d22,
			0x807f26,
			0x00097a,
			0x75197c,
			0x367e7f,
			0xc0c0c0,
			0x7f7f7f,
			0xe73123,
			0x74f84b,
			0xfcfa53,
			0x001ef2,
			0xe63bf3,
			0x71f7f9,
			0xfafafa,
			-- ega palette: https://moddingwiki.shikadi.net/wiki/EGA_Palette
			0x000000,
			0x0000AA,
			0x00AA00,
			0x00AAAA,
			0xAA0000,
			0xAA00AA,
			0xAA5500,
			0xAAAAAA,
			0x555555,
			0x5555FF,
			0x55FF55,
			0x55FFFF,
			0xFF5555,
			0xFF55FF,
			0xFFFF55,
			0xFFFFFF,
		}:mapi(rgb888revto5551):rep(6)
		--]]
		),
		internalFormat = gl.GL_RGB5_A1,
		format = gl.GL_RGBA,
		type = gl.GL_UNSIGNED_SHORT_1_5_5_5_REV,	-- 'REV' means first channel first bit ... smh
	}
	self.env.palMem = self.palTex.image.buffer
--print('palTex\n'..imageToHex(self.palTex.image))

	local fbMask = bit.lshift(1, ffi.sizeof(frameBufferType)) - 1
	--[=[ framebuffer is 256 x 256 x 16bpp rgb565
	self.fbTex = self:makeTexFromImage{
		image = makeImageAtPtr(
			self.ram.framebuffer,
			frameBufferSize.x,
			frameBufferSize.y,
			1,
			asserteq(frameBufferType, 'uint16_t'),
			function(i,j) return math.random(0, fbMask) end
		),
		internalFormat = gl.GL_RGB565,
		format = gl.GL_RGB,
		type = gl.GL_UNSIGNED_SHORT_5_6_5,
	}
	--]=]
	-- [=[ framebuffer is 256 x 256 x 8bpp rgb332
	self.fbTex = self:makeTexFromImage{
		image = makeImageAtPtr(
			self.ram.framebuffer,
			frameBufferSize.x,
			frameBufferSize.y,
			1,
			asserteq(frameBufferType, 'uint8_t'),
			function(i,j) return math.random(0, fbMask) end
		),
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
in vec2 vertex;
out vec2 tcv;
uniform mat4 mvProjMat;
void main() {
	tcv = vertex;
	gl_Position = mvProjMat * vec4(vertex, 0., 1.);
}
]],
			fragmentCode = template([[
in vec2 tcv;
out uvec4 fragColor;
uniform usampler2DRect fbTex;

const float frameBufferSizeX = <?=clnumber(frameBufferSize.x)?>;
const float frameBufferSizeY = <?=clnumber(frameBufferSize.y)?>;

void main() {
	ivec2 fbTc = ivec2(
		int(tcv.x * frameBufferSizeX),
		int(tcv.y * frameBufferSizeY)
	);
#if 0 // rgb565 just copy over
	fragColor = texture(fbTex, fbTc);
#endif
#if 1 // rgb332 translate the 8bpp single-channel 
	
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

	self.quadSolidObj = GLSceneObject{
		program = {
			version = glslVersion,
			precision = 'best',
			vertexCode = template([[
in vec2 vertex;
uniform vec4 box;	//x,y,w,h
uniform mat4 mvMat;

//instead of a projection matrix, here I'm going to convert from framebuffer pixel coordinates to GL homogeneous coordinates.
const float frameBufferSizeX = <?=clnumber(frameBufferSize.x)?>;
const float frameBufferSizeY = <?=clnumber(frameBufferSize.y)?>;

void main() {
	vec2 rvtx = box.xy + vertex * box.zw;
	gl_Position = mvMat * vec4(rvtx, 0., 1.);
	gl_Position.xy /= vec2(frameBufferSizeX, frameBufferSizeY);
	gl_Position.xy *= 2.;
	gl_Position.xy -= 1.;
}
]],			{
				clnumber = clnumber,
				frameBufferSize = frameBufferSize,
			}),
			fragmentCode = [[
out uvec4 fragColor;
uniform uint colorIndex;
uniform usampler2DRect palTex;
void main() {
	ivec2 palTc = ivec2(colorIndex, 0);
#if 0	// rgb565
	fragColor = texture(palTex, palTc);
#endif
#if 1	// rgb332
	uvec4 color = texture(palTex, palTc);
	fragColor = uvec4(
		(color.r >> 5) & 0x07u
		| (color.g >> 2) & 0x38u
		| color.b & 0xC0u,
		0, 0, 0xFFu
	);
#endif
}
]],
			uniforms = {
				palTex = 0,
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
	vec2 rvtx = box.xy + vertex * box.zw;
	gl_Position = mvMat * vec4(rvtx, 0., 1.);
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
out uvec4 fragColor;

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
#if 0	// rgb565
	fragColor = texture(palTex, palTc);
#endif
#if 1	// rgb332
	uvec4 color = texture(palTex, palTc);
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
			}),
			uniforms = {
				spriteTex = 0,
				palTex = 1,
				paletteIndex = 0,
				transparentIndex = -1,
				spriteBit = 0,
				spriteMask = 0x0F,
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
	vec2 rvtx = box.xy + vertex * box.zw;
	gl_Position = mvMat * vec4(rvtx, 0., 1.);
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
out uvec4 fragColor;

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
#if 0	// rgb565
	fragColor = texture(palTex, palTc);
#endif
#if 1	// rgb332
	uvec4 color = texture(palTex, palTc);
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
			}),
			uniforms = {
				mapTex = 0,
				tileTex = 1,
				palTex = 2,
				mapIndexOffset = 0,
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

	self.codeMem = self.ram.code
	self.env.codeMem = self.ram.code

	-- 4 uint8 bytes ...
	-- x, y, w, h ... width and height are inclusive so i can do 0 0 ff ff and get the whole screen
	self.clipRect = self.ram.clipRect
	packptr(4, self.clipRect, 0, 0, 0xff, 0xff)

	-- keyboard init

	self.keyBuffer = self.ram.keyBuffer
	self.lastKeyBuffer = self.ram.lastKeyBuffer

	-- make sure our keycodes are in bounds
	for sdlSym,keyCode in pairs(sdlSymToKeyCode) do
		if not (keyCode >= 0 and math.floor(keyCode/8) < self.keyBufferSize) then
			error('got oob keyCode '..keyCode..' named '..(keyCodeNames[keyCode+1])..' for sdlSym '..sdlSym)
		end
	end

	-- filesystem init

	FileSystem = require 'numo9.filesystem'
	self.fs = FileSystem{app=self}

	-- editor init

	self.editMode = 'code'	-- matches up with Editor's editMode's

	local EditCode = require 'numo9.editcode'
	local EditSprites = require 'numo9.editsprites'
	local EditTilemap = require 'numo9.edittilemap'
	local Console = require 'numo9.console'

	self:runInEmu(function()
		self.editCode = EditCode{app=self}
		self.editSprites = EditSprites{app=self}
		self.editTilemap = EditTilemap{app=self}
		self.con = Console{app=self}
	end)

	self.runFocus = self.con
	--self.runFocus = self.editCode

	-- TODO copy over a local filetree somewhere in the app ...
	for fn in path:dir() do
		if select(2, fn:getext()) == 'n9' then
			self.fs:addFromHost(fn.path)
		end
	end
	local initfn = cmdline[1] or 'hello.n9'
	if self.fs:get(initfn) then
		self:load(initfn)
		self:runCode()
	end

	self.screenMousePos = vec2i()	-- host coordinates
	self.mousePos = vec2i()			-- frambuffer coordinates
	self.lastMousePos = vec2i()		-- ... position last frame
	self.lastMouseDown = vec2i()
	self.mouseButtons = 0
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
glreport'here'
	return tex
end

-- fps vars
local lastTime = getTime()
local fpsFrames = 0
local fpsSeconds = 0

-- update interval vars
local lastUpdateTime = getTime()	-- TODO resetme upon resuming from a pause state
local updateInterval = 1 / 60
local needUpdateCounter = 0

function App:update()
	App.super.update(self)

	-- [[ fps counter
	local thisTime = getTime()
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

		-- update input between frames
		do
			self.lastMousePos:set(self.mousePos:unpack())
			self.lastMouseButtons = self.mouseButtons
			self.mouseButtons = sdl.SDL_GetMouseState(self.screenMousePos.s, self.screenMousePos.s+1)
			local x1, x2, y1, y2, z1, z2 = self.blitScreenView:getBounds(self.width / self.height)
	--DEBUG:print('screen pos', self.screenMousePos:unpack())
	--DEBUG:print('ortho', 	x1, x2, y1, y2, z1, z2)
			local x = tonumber(self.screenMousePos.x) / tonumber(self.width)
			local y = tonumber(self.screenMousePos.y) / tonumber(self.height)
	--DEBUG:print('mouserfrac', x, y)
			x = x1 * (1 - x) + x2 * x
			y = y1 * (1 - y) + y2 * y
	--DEBUG:print('mouse in ortho [-1,1] space', x, y)
			x = x * .5 + .5
			y = y * .5 + .5
	--DEBUG:print('mouse in ortho [0,1] space', x, y)
			self.mousePos.x = x * tonumber(frameBufferSize.x)
			self.mousePos.y = y * tonumber(frameBufferSize.y)
	--DEBUG:print('mouse in fb space', self.mousePos:unpack())
			local leftButtonLastDown = bit.band(self.lastMouseButtons, 1) == 1
			local leftButtonDown = bit.band(self.mouseButtons, 1) == 1
			local leftButtonPress = leftButtonDown and not leftButtonLastDown
			if leftButtonPress then
				self.lastMouseDown:set(self.mousePos:unpack())
			end
		end

		local fb = self.fb
		fb:bind()
		gl.glViewport(
			self.clipRect[0],
			self.clipRect[1],
			self.clipRect[2]+1,
			self.clipRect[3]+1)

		-- TODO here run this only 60 fps
		local runFocus = self.runFocus
		if runFocus and runFocus.update then
			local success, msg = xpcall(function()
				runFocus:update()
			end, errorHandler)
			if not success then
				self.runFocus = self.con
				self.con:print(msg)
			end
		end

		fb:unbind()

		-- update vram to gpu every frame?
		-- or nah, how about I only do when dirty bit set?
		-- so this copies CPU changes -> GPU changes
		-- TODO nothing is copying the GPU back to CPU after we do our sprite renders ...
		-- double TODO I don't have framebuffer memory
		self.spriteTex:bind()
			:subimage()
			:unbind()
		self.tileTex:bind()
			:subimage()
			:unbind()
		self.mapTex:bind()
			:subimage()
			:unbind()
		self.palTex:bind()
			:subimage()
			:unbind()

		-- copy last key buffer to key buffer here after update()
		-- so that sdl event can populate changes to current key buffer while execution runs outside this callback
		ffi.copy(self.lastKeyBuffer, self.keyBuffer, self.keyBufferSize)
	end

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

	sceneObj:draw()
end

function App:drawSolidRect(x, y, w, h, colorIndex)
	local sceneObj = self.quadSolidObj
	local uniforms = sceneObj.uniforms
	uniforms.mvMat = self.mvMat.ptr
	uniforms.colorIndex = colorIndex
	settable(uniforms.box, x, y, w, h)
	sceneObj:draw()
end

function App:drawBorderRect(x, y, w, h, colorIndex)
	-- I could do another shader for this, and discard in the middle
	-- or just draw 4 thin sides ...
	local sceneObj = self.quadSolidObj
	local uniforms = sceneObj.uniforms
	uniforms.mvMat = self.mvMat.ptr
	uniforms.colorIndex = colorIndex

	settable(uniforms.box, x, y, w, 1)
	sceneObj:draw()
	settable(uniforms.box, x, y, 1, h)
	sceneObj:draw()
	settable(uniforms.box, x, y+h-1, w, 1)
	sceneObj:draw()
	settable(uniforms.box, x+w-1, y, 1, h)
	sceneObj:draw()
end

function App:clearScreen(colorIndex)
	self:drawSolidRect(0, 0, frameBufferSize.x, frameBufferSize.y, colorIndex or 0)
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
	paletteIndex = paletteIndex or 0
	transparentIndex = transparentIndex or -1
	spriteBit = spriteBit or 0
	spriteMask = spriteMask or 0xF

	local sceneObj = self.quadSpriteObj
	local uniforms = sceneObj.uniforms
	sceneObj.texs[1] = tex

	uniforms.mvMat = self.mvMat.ptr
	uniforms.paletteIndex = paletteIndex	-- user has to specify high-bits
	uniforms.transparentIndex = transparentIndex
	uniforms.spriteBit = spriteBit
	uniforms.spriteMask = spriteMask

	settable(uniforms.tcbox, tx, ty, tw, th)
	settable(uniforms.box, x, y, w, h)
	sceneObj:draw()
end

--[[
spriteIndex =
	bits 0..4 = x coordinate in sprite sheet
	bits 5..9 = y coordinate in sprite sheet
spritesWide = width in sprites
sh = height in sprites
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
	x,
	y,
	spriteIndex,
	spritesWide,
	spritesHigh,
	paletteIndex,
	transparentIndex,
	spriteBit,
	spriteMask,
	scaleX,
	scaleY
)
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

	uniforms.mvMat = self.mvMat.ptr
	uniforms.paletteIndex = paletteIndex	-- user has to specify high-bits
	uniforms.transparentIndex = transparentIndex
	uniforms.spriteBit = spriteBit
	uniforms.spriteMask = spriteMask

	-- vram / sprite sheet is 32 sprites wide ... 256 pixels wide, 8 pixels per sprite
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
		x,
		y,
		spritesWide * spriteSize.x * scaleX,
		spritesHigh * spriteSize.y * scaleY
	)
	sceneObj:draw()
end

function App:drawMap(
	x,
	y,
	tileIndex,
	tilesWide,
	tilesHigh,
	mapIndexOffset
)
	tilesWide = tilesWide or 1
	tilesHigh = tilesHigh or 1
	mapIndexOffset = mapIndexOffset or 0

	local sceneObj = self.quadMapObj
	local uniforms = sceneObj.uniforms
	sceneObj.texs[1] = self.mapTex

	uniforms.mvMat = self.mvMat.ptr
	uniforms.mapIndexOffset = mapIndexOffset	-- user has to specify high-bits

	local tx = tileIndex % tilemapSizeInSprites.x
	local ty = (tileIndex - tx) / tilemapSizeInSprites.x
	settable(uniforms.tcbox,
		tx / tonumber(tilemapSizeInSprites.x),
		ty / tonumber(tilemapSizeInSprites.y),
		tilesWide / tonumber(tilemapSizeInSprites.x),
		tilesHigh / tonumber(tilemapSizeInSprites.y)
	)
	settable(uniforms.box,
		x,
		y,
		tilesWide * spriteSize.x,
		tilesHigh * spriteSize.y
	)
	sceneObj:draw()
end

-- draw transparent-background text
function App:drawText1bpp(x, y, text, color, scaleX, scaleY)
	for i=1,#text do
		local ch = text:byte(i)
		local by = bit.rshift(ch, 3)	-- get the byte offset
		local bi = bit.band(ch, 7)		-- get the bit offset
		self:drawSprite(
			x,						-- x
			y,                      -- y
			by,                     -- spriteIndex
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
		x = x + spriteSize.x
	end
end

-- draw a solid background color, then draw the text transparent
-- specify an oob bgColorIndex to draw with transparent background
function App:drawText(x, y, text, fgColorIndex, bgColorIndex, scaleX, scaleY)
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
				spriteSize.x * scaleX,
				spriteSize.y * scaleY,
				bgColorIndex
			)
			x = x + spriteSize.x
		end
	end

	self:drawText1bpp(
		x0+1,
		y+1,
		text,
		fgColorIndex,
		scaleX,
		scaleY
	)
end

function App:save(filename)

	local n = #self.editCode.text
	assertlt(n+1, codeSize)
--print('saving code', self.editCode.text, 'size', n)
	ffi.copy(self.codeMem, self.editCode.text, n)
	self.codeMem[n] = 0	-- null term

	if not select(2, path(filename):getext()) then
		filename = path(filename):setext'n9'.path
	end
	filename = filename or defaultSaveFilename
	local basemsg = 'failed to save file '..tostring(filename)

	-- TODO xpcall?
	local success, s = xpcall(function()
		return require 'numo9.archive'.toCartImage(self.rom.v)
	end, errorHandler)
	if not success then return nil, basemsg..(s or '') end

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
	local romStr = require 'numo9.archive'.fromCartImage(d)
	ffi.copy(self.rom.v, romStr, ffi.sizeof'ROM')
	local code = ffi.string(self.codeMem, self.codeSize)	-- TODO max size on this ...
	local i = code:find('\0', 1, true)
	if i then code = code:sub(1, i-1) end
--print('got code', code, 'len', #code)
	--]]

	self.editCode:setText(code)
	return true
end

-- returns the function to run the code
function App:loadCmd(cmd, env)
	return self.loadenv.loadstring(cmd, nil, 't', env or self.env)
end

-- system() function
-- TODO fork this between console functions and between running "rom" code
function App:runCmd(cmd)
	-- TODO when to error vs when to return nil ...
	--[[ suppress always
	local f, msg = self:loadCmd(cmd)
	if not f then return f, msg end
	return xpcall(f, errorHandler)
	--]]
	-- [[ error always
	return assert(self:loadCmd(cmd))()
	--]]
end

function App:resetView()
	-- initialize our projection to framebuffer size
	-- do this every time we run a new rom
	self.mvMat:setIdent()
end

function App:runCode()
	self:resetView()

	-- TODO setfenv instead?
	local env = setmetatable({}, {
		__index = self.env,
	})

	local f, msg = self:loadCmd(self.editCode.text, env)
	if not f then
		print(msg)
		return
	end
	-- TODO setfenv to make sure our function writes globals to its own place
	local result, msg = xpcall(f, errorHandler)

	if env.draw or env.update then
		self.runFocus = env
	end
end

function App:keyForBuffer(keycode, buffer)
	local bi = bit.band(keycode, 7)
	local by = bit.rshift(keycode, 3)
	if by < 0 or by >= self.keyBufferSize then return end
	local keyFlag = bit.lshift(1, bi)
	return bit.band(buffer[by], keyFlag) ~= 0
end

function App:key(keycode)
	if type(keycode) == 'string' then
		keycode = keyCodeForName[keycode]
	end
	asserttype(keycode, 'number')
	return self:keyForBuffer(keycode, self.keyBuffer)
end

function App:keyp(keycode)
	if type(keycode) == 'string' then
		keycode = keyCodeForName[keycode]
	end
	asserttype(keycode, 'number')
	return self:keyForBuffer(keycode, self.keyBuffer)
	and not self:keyForBuffer(keycode, self.lastKeyBuffer)
end

-- run but make sure the vm is set up
-- esp the framebuffer
-- TODO might get rid of this now that i just upload cpu->gpu the vram every frame
function App:runInEmu(cb, ...)
	-- TODO maybe not ...
	local fb = self.fb
	fb:bind()
	gl.glViewport(0, 0, frameBufferSize.x, frameBufferSize.y)

	cb(...)

	fb:unbind()
end

function App:event(e)
	local Editor = require 'numo9.editor'
	if e[0].type == sdl.SDL_KEYUP
	or sdl.SDL_KEYDOWN
	then
		local down = e[0].type == sdl.SDL_KEYDOWN
		local sdlsym = e[0].key.keysym.sym
		local uiMod
		if ffi.os == 'OSX' then	-- have to be the weird ones
			uiMod = bit.band(e[0].key.keysym.mod, sdl.KMOD_GUI) ~= 0
		else
			uiMod = bit.band(e[0].key.keysym.mod, sdl.KMOD_CTRL) ~= 0
		end
		if down and sdlsym == sdl.SDLK_ESCAPE then
			-- special handle the escape key
			-- game -> escape -> console
			-- console -> escape -> editor
			-- editor -> escape -> console
			-- ... how to cycle back to the game without resetting it?
			-- ... can you not issue commands while the game is loaded without resetting the game?
			if self.runFocus == self.con then
				self.runFocus = self.editCode
			elseif Editor:isa(self.runFocus) then
				self.runFocus = self.con
			else
				-- assume it's a game
				self.runFocus = self.con
			end
			-- TODO re-init the con?  clear? special per runFocus?
			if self.runFocus == self.con then
				self:runInEmu(function()
					self.con:reset()
				end)
			end
		elseif down and sdlsym == sdl.SDLK_c and uiMod then
			-- copy selection
		elseif down and sdlsym == sdl.SDLK_v and uiMod then
			-- paste selection
			-- hmm ... upon reading further on image clipboard cross platform support, maybe not.
		else
			local keycode = sdlSymToKeyCode[sdlsym]
			if keycode then
				local bi = bit.band(keycode, 7)
				local by = bit.rshift(keycode, 3)
				-- TODO turn this into raw mem like those other virt cons
				assert(by >= 0 and by < self.keyBufferSize)
				local mask = bit.bnot(bit.lshift(1, bi))
				self.keyBuffer[by] = bit.bor(
					bit.band(mask, self.keyBuffer[by]),
					down and bit.lshift(1, bi) or 0
				)
			end
		end
	end
end

return App
