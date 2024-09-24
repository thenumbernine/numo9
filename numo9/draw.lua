--[[
TODO maybe move this into a numo9/rom.lua file
and put in that file the ROM and RAM struct defs
and all the spritesheet / tilemap specs
Or rename this to gfx.lua and put more GL stuff in it?
--]]
local ffi = require 'ffi'
local template = require 'template'
local table = require 'ext.table'
local assertlt = require 'ext.assert'.lt
local assertne = require 'ext.assert'.ne
local Image = require 'image'
local gl = require 'gl'
local glreport = require 'gl.report'
local GLFBO = require 'gl.fbo'
local GLTex2D = require 'gl.tex2d'
local GLGeometry = require 'gl.geometry'
local GLSceneObject = require 'gl.sceneobject'
local clnumber = require 'cl.obj.number'

local paletteSize = require 'numo9.rom'.paletteSize
local spriteSize = require 'numo9.rom'.spriteSize
local frameBufferType = require 'numo9.rom'.frameBufferType
local frameBufferSize = require 'numo9.rom'.frameBufferSize
local frameBufferSizeInTiles = require 'numo9.rom'.frameBufferSizeInTiles
local spriteSheetSize = require 'numo9.rom'.spriteSheetSize
local spriteSheetSizeInTiles = require 'numo9.rom'.spriteSheetSizeInTiles
local tilemapSize = require 'numo9.rom'.tilemapSize
local tilemapSizeInSprites = require 'numo9.rom'.tilemapSizeInSprites


-- I was hoping I could do this all in integer, but maybe not for the fragment output, esp with blending ...
-- glsl unsigned int fragment colors and samplers really doesn't do anything predictable...
local fragType = 'uvec4'
--local fragType = 'vec4'	-- not working

-- on = read usampler, off = read sampler
--local useTextureInt = false	-- not working
local useTextureInt = true

-- uses integer coordinates in shader.  you'd think that'd make it look more retro, but it seems shaders evolved for decades with float-only/predominant that int support is shoehorned in.
--local useTextureRect = false
local useTextureRect = true

--local texelType = (useTextureInt and 'u' or '')..'vec4'

local samplerType = (useTextureInt and 'u' or '')
	.. 'sampler2D'
	.. (useTextureRect and 'Rect' or '')


-- r,g,b,a is 8bpp
-- result is 5551 16bpp
local function rgba8888_4ch_to_5551(r,g,b,a)
	return bit.bor(
		bit.band(0x001f, bit.rshift(r, 3)),
		bit.band(0x03e0, bit.lshift(g, 2)),
		bit.band(0x7c00, bit.lshift(b, 7)),
		a == 0 and 0 or 0x8000
	)
end

-- rgba5551 is 16bpp
-- result is r,g,b,a 8bpp
local function rgba5551_to_rgba8888_4ch(rgba5551)
	-- rounding ... for 5 bits into 8 bits, OR with the upper 3 bits again shifted down 5 bits ... so its a repeated-decimal
	local r = bit.band(rgba5551, 0x1F)
	local g = bit.band(rgba5551, 0x3E0)
	local b = bit.band(rgba5551, 0x7C00)
	return
		bit.bor(
			bit.lshift(r, 3),	-- shift bit 4 to bit 7
			bit.rshift(r, 2)	-- shift bit 4 to bit 2
		),
		bit.bor(
			bit.rshift(g, 2),	-- shift bit 9 to bit 7
			bit.rshift(g, 7)	-- shift bit 9 to bit 2
		),
		bit.bor(
			bit.rshift(b, 7),	-- shift bit 14 to bit 7
			bit.rshift(b, 12)	-- shift bit 14 to bit 2
		),
		bit.band(rgba5551, 0x8000) == 0 and 0 or 0xff
end

-- rgb565 is 16bpp
-- result is r,g,b 8bpp
local function rgb565rev_to_rgba888_3ch(rgb565)
	local b = bit.band(rgb565, 0x1F)
	local g = bit.band(rgb565, 0x7E0)
	local r = bit.band(rgb565, 0xF800)
	return
		bit.bor(
			bit.rshift(r, 8),		-- shift bit 15 to bit 7
			bit.rshift(r, 13)		-- shift bit 15 to bit 2
		),
		bit.bor(
			bit.rshift(g, 3),		-- shift bit 10 to bit 7
			bit.rshift(g, 9)		-- shift bit 10 to bit 1
		),
		bit.bor(
			bit.lshift(b, 3),		-- shift bit 4 to bit 7
			bit.rshift(b, 2)		-- shift bit 4 to bit 2
		)
end

-- when I say 'reverse' i mean reversed order of bitfields
-- when opengl says 'reverse' it means reversed order of reading hex numbers or something stupid
local function argb8888revto5551(rgba)
	local a = bit.band(bit.rshift(rgba, 24), 0xff)
	local r = bit.band(bit.rshift(rgba, 16), 0xff)
	local g = bit.band(bit.rshift(rgba, 8), 0xff)
	local b = bit.band(rgba, 0xff)
	return rgba8888_4ch_to_5551(r,g,b,a)
end

local function resetFontOnSheet(spriteSheetPtr)

	-- paste our font letters one bitplane at a time ...
	-- TODO just hardcode this resource in the code?
	local fontImg = Image'font.png'
	local srcx, srcy = 0, 0
	-- store on the last row
	local dstx, dsty = 0, spriteSheetSize.y - spriteSize.y
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
		assertlt(srcx, fontImg.width)
		assertlt(srcy, fontImg.height)
		assertlt(dstx, spriteSheetSize.x)
		assertlt(dsty, spriteSheetSize.y)
		for by=0,7 do
			for bx=0,7 do
				local srcp = fontImg.buffer
					+ srcx + bx
					+ fontImg.width * (
						srcy + by
					)
				local dstp = spriteSheetPtr
					+ dstx + bx
					+ spriteSheetSize.x * (
						dsty + by
					)
				dstp[0] = bit.bor(
					bit.band(mask, dstp[0]),
					bit.lshift(srcp[0], b)
				)
			end
		end
--DEBUG:print('copied letter from', srcx, srcy,'to', dstx, dsty)
		srcx, srcy = inc2d(srcx, srcy, fontImg.width, fontImg.height)
		if not srcx then break end
		if b == 7 then
			dstx, dsty = inc2d(dstx, dsty, spriteSheetSize.x, spriteSheetSize.y)
			if not dstx then break end
		end
	end
end
local function resetFont(rom)
	return resetFontOnSheet(rom.spriteSheet)	-- uint8_t*
end

-- TODO every time App calls this, make sure its palTex.dirtyCPU flag is set
-- it would be here but this is sometimes called by n9a as well
local function resetPalette(rom)
	local ptr = rom.palette	-- uint16_t*
	for i,c in ipairs(
		--[[ garbage colors
		function(i)
			return math.floor(math.random() * 0xffff)
		end
		--]]
		-- [[ builtin palette
		table{
			-- tic80
			0x00000000,
			0xff562b5a,
			0xffa44654,
			0xffe08260,
			0xfff7ce82,
			0xffb7ed80,
			0xff60b46c,
			0xff3b7078,
			0xff2b376b,
			0xff415fc2,
			0xff5ca5ef,
			0xff93ecf5,
			0xfff4f4f4,
			0xff99afc0,
			0xff5a6c84,
			0xff343c55,
			-- https://en.wikipedia.org/wiki/List_of_software_palettes
			0x00000000,
			0xff75140c,
			0xff377d22,
			0xff807f26,
			0xff00097a,
			0xff75197c,
			0xff367e7f,
			0xffc0c0c0,
			0xff7f7f7f,
			0xffe73123,
			0xff74f84b,
			0xfffcfa53,
			0xff001ef2,
			0xffe63bf3,
			0xff71f7f9,
			0xfffafafa,
			-- ega palette: https://moddingwiki.shikadi.net/wiki/EGA_Palette
			0x00000000,
			0xff0000AA,
			0xff00AA00,
			0xff00AAAA,
			0xffAA0000,
			0xffAA00AA,
			0xffAA5500,
			0xffAAAAAA,
			0xff555555,
			0xff5555FF,
			0xff55FF55,
			0xff55FFFF,
			0xffFF5555,
			0xffFF55FF,
			0xffFFFF55,
			0xffFFFFFF,
		}:mapi(argb8888revto5551)

		--]]
		:rep(16)	-- make sure it fills 0-255
		:sub(1, 240)	-- make sure we don't iterate across too many colors and ptr goes oob ...
		:append(table{
			-- editor palette
			0x00000000,
			0xff562b5a,
			0xffa44654,
			0xffe08260,
			0xfff7ce82,
			0xffb7ed80,
			0xff60b46c,
			0xff3b7078,
			0xff2b376b,
			0xff415fc2,
			0xff5ca5ef,
			0xff93ecf5,
			0xfff4f4f4,
			0xff99afc0,
			0xff5a6c84,
			0xff343c55,
		}:mapi(argb8888revto5551))
	) do
		ptr[0] = c
		ptr = ptr + 1
	end
end

-- [[ also in sand-attack ... hmmmm ...
-- consider putting somewhere common, maybe in gl.tex2d ?
-- maybe just save .image in gltex2d?
function makeTexFromImage(app, args)
glreport'here'
	local image = assert(args.image)
	if image.channels ~= 1 then print'DANGER - non-single-channel Image!' end
	local tex = GLTex2D{
		target = args.target or (
			useTextureRect and gl.GL_TEXTURE_RECTANGLE or nil	-- nil defaults to TEXTURE_2D
		),
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
	-- assumes it is being called from within the render loop
	function tex:checkDirtyCPU()
		if not self.dirtyCPU then return end
		-- we should never get in a state where both CPU and GPU are dirty
		-- if someone is about to write to one then it shoudl test the other and flush it if it's dirty, then set the one
		assert(not self.dirtyGPU, "someone dirtied both cpu and gpu without flushing either")
		local fb = app.fb
		if app.inUpdateCallback then
			fb:unbind()
		end
		self:bind()
			:subimage()
			:unbind()
		if app.inUpdateCallback then
			fb:bind()
		end
		self.dirtyCPU = false
		app.fbTex.changedSinceDraw = true
	end

	-- TODO is this only applicable for fbTex?
	-- if anything else has a dirty GPU ... it'd have to be because the framebuffer was rendering to it
	-- and right now, the fb is only outputting to fbTex ...
	function tex:checkDirtyGPU()
		if not self.dirtyGPU then return end
		assert(not self.dirtyCPU, "someone dirtied both cpu and gpu without flushing either")
		-- assert that fb is bound to fbTex ...
		local fb = app.fb
		if not app.inUpdateCallback then
			fb:bind()
		end
		gl.glReadPixels(0, 0, self.width, self.height, self.format, self.type, self.image.buffer)
		if not app.inUpdateCallback then
			fb:unbind()
		end
		self.dirtyGPU = false
	end
glreport'here'

	return tex
end


-- This just holds a bunch of stuff that App will dump into itself
-- so its member functions' "self"s are just 'App'.
-- I'd call it 'App' but that might be confusing because it's not really App.
local AppDraw = {}

-- 'self' == app
function AppDraw:initDraw()
	self.fb = GLFBO{
		width = frameBufferSize.x,
		height = frameBufferSize.y,
	}:unbind()

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

	-- redirect the image buffer to our virtual system rom
	self.spriteTex = makeTexFromImage(self, {
		image = makeImageAtPtr(self.ram.spriteSheet, spriteSheetSize.x, spriteSheetSize.y, 1, 'unsigned char'):clear(),
		internalFormat = gl.GL_R8UI,
		format = gl.GL_RED_INTEGER,
		type = gl.GL_UNSIGNED_BYTE,
	})

	self.tileTex = makeTexFromImage(self, {
		image = makeImageAtPtr(self.ram.tileSheet, spriteSheetSize.x, spriteSheetSize.y, 1, 'unsigned char'):clear(),
		internalFormat = gl.GL_R8UI,
		format = gl.GL_RED_INTEGER,
		type = gl.GL_UNSIGNED_BYTE,
	})

	--[[
	16bpp ...
	- 10 bits of lookup into spriteTex
	- 4 bits high palette nibble
	- 1 bit hflip
	- 1 bit vflip
	- .... 2 bits rotate ... ? nah
	- .... 8 bits palette offset ... ? nah
	--]]
	self.mapTex = makeTexFromImage(self, {
		image = makeImageAtPtr(self.ram.tilemap, tilemapSize.x, tilemapSize.y, 1, 'unsigned short'):clear(),
		internalFormat = gl.GL_R16UI,
		format = gl.GL_RED_INTEGER,
		type = gl.GL_UNSIGNED_SHORT,
	})
	self.mapMem = self.mapTex.image.buffer

	-- palette is 256 x 1 x 16 bpp (5:5:5:1)
	self.palTex = makeTexFromImage(self, {
		image = makeImageAtPtr(self.ram.palette, paletteSize, 1, 1, 'unsigned short'),
		internalFormat = gl.GL_RGB5_A1,
		format = gl.GL_RGBA,
		type = gl.GL_UNSIGNED_SHORT_1_5_5_5_REV,	-- 'REV' means first channel first bit ... smh
	})
--print('palTex\n'..imageToHex(self.palTex.image))

	ffi.fill(self.ram.framebuffer, ffi.sizeof(self.ram.framebuffer), -1)
	-- [=[ framebuffer is 256 x 256 x 16bpp rgb565
	do
		local ctype = 'uint16_t'
		local fbRGB565Image = makeImageAtPtr(
			self.ram.framebuffer,
			frameBufferSize.x,
			frameBufferSize.y,
			1,
			ctype
		)
		self.fbRGB565Tex = makeTexFromImage(self, {
			image = fbRGB565Image,
			internalFormat = gl.GL_RGB565,
			format = gl.GL_RGB,
			type = gl.GL_UNSIGNED_SHORT_5_6_5,
		})
	end
	--]=]
	-- [=[ framebuffer is 256 x 256 x 8bpp indexed
	do
		local ctype = 'uint8_t'
		local fbIndexImage = makeImageAtPtr(
			self.ram.framebuffer,
			frameBufferSize.x,
			frameBufferSize.y,
			1,
			ctype
		)
		self.fbIndexTex = makeTexFromImage(self, {
			image = fbIndexImage,
			internalFormat = gl.GL_R8UI,
			format = gl.GL_RED_INTEGER,
			type = gl.GL_UNSIGNED_BYTE,
		})
	end
	--]=]
	--[=[ framebuffer is 256 x 256 x 8bpp rgb332
	self.fbTex = makeTexFromImage(self, {
		image = fbImage,
		internalFormat = gl.GL_R8UI,
		format = gl.GL_RED_INTEGER,
		type = gl.GL_UNSIGNED_BYTE,
	})
	--]=]

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

	local function readTexUint(code, scale)
		if not useTextureInt then
			code = 'uint('..code..' * '..clnumber(scale or
				-- why doesn't this make a difference?
				--bit.lshift(1,32)-1
				--256
				1
				--]]
				)..')'
		end
		return code
	end

	local function texCoordRectFromFloatVec(code, size)
		code = 'ivec2(('..code..') * vec2('..clnumber(size.x)..', '..clnumber(size.y)..'))'
		return code
	end

	local function texCoordRectFromIntVec(code, size)
		return code
	end

	-- code for converting 'uint colorIndex' to '(u)vec4 fragColor'
	local colorIndexToFrag = table{
		useTextureRect
		and [[
	ivec2 palTc = ivec2(colorIndex & ]]..('0x%Xu'):format(paletteSize-1)..[[, 0);
]]
		or [[
	vec2 palTc = vec2((float(colorIndex)+.5)/]]..clnumber(paletteSize)..[[, .5);
]],
		fragType == 'vec4'
		and [[
	fragColor = ]]..fragType..[[(texelFetch(palTex, palTc));	// / float((1u<<31)-1u);
]]
		or [[
	fragColor = ]]..fragType..[[(texelFetch(palTex, palTc));
]],
	}:concat'\n'..'\n'

	-- used for drawing our 16bpp framebuffer to the screen
	self.blitScreenRGBObj = GLSceneObject{
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

layout(location=0) out <?=fragType?> fragColor;

uniform <?=samplerType?> fbTex;

void main() {
<? if fragType == 'vec4' then ?>
#if 1	// how many bits does uvec4 get from texelFetch() ?
	fragColor = <?=fragType?>(texelFetch(fbTex, ]]..texCoordRectFromFloatVec('tcv', frameBufferSize)..[[) / float((1u<<31)-1u));
#else	// or does gl just magically know the conversion?
	fragColor = <?=fragType?>(texelFetch(fbTex, ]]..texCoordRectFromFloatVec('tcv', frameBufferSize)..[[));
#endif
<? else ?>
	fragColor = <?=fragType?>(texelFetch(fbTex, ]]..texCoordRectFromFloatVec('tcv', frameBufferSize)..[[));
<? end ?>
}
]],			{
				samplerType = samplerType,
				useTextureRect = useTextureRect,
				fragType = fragType,
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

	-- used for drawing our 8bpp indexed framebuffer to the screen
	self.blitScreenIndexObj = GLSceneObject{
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

layout(location=0) out <?=fragType?> fragColor;

uniform <?=samplerType?> fbTex;
uniform <?=samplerType?> palTex;

void main() {
	uint colorIndex = ]]..readTexUint('texelFetch(fbTex, '..texCoordRectFromFloatVec('tcv', frameBufferSize)..').r')..[[;
]]..colorIndexToFrag..[[
}
]],			{
				samplerType = samplerType,
				useTextureRect = useTextureRect,
				fragType = fragType,
				clnumber = clnumber,
				frameBufferSize = frameBufferSize,
			}),
			uniforms = {
				fbTex = 0,
				palTex = 1,
			},
		},
		texs = {self.fbTex, self.palTex},
		geometry = self.quadGeom,
		-- glUniform()'d every frame
		uniforms = {
			mvProjMat = self.blitScreenView.mvProjMat.ptr,
		},
	}

	-- used for drawing 8bpp fbIndexTex as rgb332 framebuffer to the screen
	self.blitScreenRGB332Obj = GLSceneObject{
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

layout(location=0) out vec4 fragColor;

uniform <?=samplerType?> fbTex;

void main() {
	uint rgb332 = ]]..readTexUint('texelFetch(fbTex, '..texCoordRectFromFloatVec('tcv', frameBufferSize)..').r')..[[;
	fragColor.r = float(rgb332 & 0x7u) / 7.;
	fragColor.g = float((rgb332 >> 3) & 0x7u) / 7.;
	fragColor.b = float((rgb332 >> 6) & 0x3u) / 3.;
	fragColor.a = 1.;
}
]],			{
				samplerType = samplerType,
				useTextureRect = useTextureRect,
				fragType = fragType,
				clnumber = clnumber,
				frameBufferSize = frameBufferSize,
			}),
			uniforms = {
				fbTex = 0,
				palTex = 1,
			},
		},
		texs = {self.fbTex, self.palTex},
		geometry = self.quadGeom,
		-- glUniform()'d every frame
		uniforms = {
			mvProjMat = self.blitScreenView.mvProjMat.ptr,
		},
	}


	-- make output shaders per-video-mode
	-- set them up as our app fields to use upon setVideoMode
	for _,info in ipairs{
		{name='RGB', colorOutput=colorIndexToFrag},
		{name='Index', colorOutput=colorIndexToFrag..[[
	fragColor.r = colorIndex;
	fragColor.g = 0;
	fragColor.b = 0;
]]},
		{name='RGB332', colorOutput=colorIndexToFrag..[[
	// TODO this won't work if we're using fragType == vec4 ...
	// what exactly is coming out of a usampler2D and into a uvec4?  is that documented anywhere?
//#error what is the range of the palTex?  internalFormat=GL_RGB5_A1, format=GL_RGBA, type=GL_UNSIGNED_SHORT_1_5_5_5_REV
	//fragColor >>= 16;	//[16,20] works ... WHY??!?!?!
	//fragColor &= 0xFFu;

	// OK SO THIS LOOKS GOOD ... WHY
	// WHY DID OPENGL DECIDE TO USE 26 BITS TO REPRESENT MY RGBA5551 TEXTURE'S COLOR CHANNELS?
	// and how come the palette gradiations seem to be exponential ... 0-3 is one shade, 4-7 is another, 8-15 is another, 16-31 is another .... wtf?
#if 1
	uint r = (fragColor.r >> 23) & 0x7u;
	uint g = (fragColor.g >> 23) & 0x7u;
	uint b = (fragColor.b >> 24) & 0x3u;
	fragColor.r = r | (g << 3) | (b << 6);
#else
	uint r = (fragColor.r >> 5) & 0x7u;
	uint g = (fragColor.g >> 5) & 0x7u;
	uint b = (fragColor.b >> 6) & 0x3u;
	fragColor.r = r | (g << 3) | (b << 6);
#endif

// verify that, from here to the blitScreenRGB332Obj shader, everything is fine:
	//fragColor.r = 0x3;		// mid red = WORKS
	//fragColor.r = 0x4;		// mid red = WORKS
	//fragColor.r = 0x7;	// full red = WORKS
	//fragColor.r = 0x8;	// no red, dark green = WORKS
	//fragColor.r = 0x18;		// mid green = WORKS
	//fragColor.r = 0x20;		// mid green = WORKS (looks sort of pale)
	//fragColor.r = 0x38;		// full green = WORKS (looks sort of pale though ...)
	//fragColor.r = 0x40;		// no green, dark blue = WORKS
	//fragColor.r = 0x80;			//mid blue .. WORKS
	//fragColor.r = 0xC0;		// full blue = WORKS
	//fragColor.r = 0xFF;		// white WORKS
//...and it is working fine.  The only problem now is that mysterious undocumented behavior of what happens when you assign to a uvec4 fragment
	fragColor.g = 0;
	fragColor.b = 0;
]]},
	} do
		self['lineSolid'..info.name..'Obj'] = GLSceneObject{
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
]],				{
					clnumber = clnumber,
					frameBufferSize = frameBufferSize,
				}),
				fragmentCode = template([[
layout(location=0) out <?=fragType?> fragColor;

uniform uint colorIndex;
uniform <?=samplerType?> palTex;

void main() {
]]..info.colorOutput..[[
}
]],				{
					fragType = fragType,
					samplerType = samplerType,
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
		assert(math.log(paletteSize, 2) % 1 == 0)	-- make sure our palette is a power-of-two

		self['quadSolid'..info.name..'Obj'] = GLSceneObject{
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
]],				{
					clnumber = clnumber,
					frameBufferSize = frameBufferSize,
				}),
				fragmentCode = template([[
// framebuffer pixel coordinates
in vec2 pcv;

uniform vec4 box;	//x,y,w,h

layout(location=0) out <?=fragType?> fragColor;

uniform bool borderOnly;
uniform bool round;

uniform uint colorIndex;

uniform <?=samplerType?> palTex;

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
]]..info.colorOutput..[[
}
]],				{
					fragType = fragType,
					samplerType = samplerType,
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

		self['quadSprite'..info.name..'Obj'] = GLSceneObject{
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
]],				{
					clnumber = clnumber,
					frameBufferSize = frameBufferSize,
				}),
				fragmentCode = template([[
in vec2 tcv;

layout(location=0) out <?=fragType?> fragColor;

//For now this is an integer added to the 0-15 4-bits of the sprite tex.
//You can set the top 4 bits and it'll work just like OR'ing the high color index nibble.
//Or you can set it to low numbers and use it to offset the palette.
//Should this be high bits? or just an offset to OR? or to add?
uniform uint paletteIndex;

// Reads 4 bits from wherever shift location you provide.
uniform <?=samplerType?> spriteTex;

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

uniform <?=samplerType?> palTex;

const float spriteSheetSizeX = <?=clnumber(spriteSheetSize.x)?>;
const float spriteSheetSizeY = <?=clnumber(spriteSheetSize.y)?>;

void main() {
	uint colorIndex = (]]
		..readTexUint('texelFetch(spriteTex, '..texCoordRectFromFloatVec('tcv', spriteSheetSize)..').r')
		..[[ >> spriteBit) & spriteMask;
	if (colorIndex == transparentIndex) discard;

	//colorIndex should hold
	colorIndex += paletteIndex;
	colorIndex &= 0XFFu;

]]..info.colorOutput..[[
	if (fragColor.a == 0.) discard;
}
]], 			{
					fragType = fragType,
					useTextureRect = useTextureRect,
					samplerType = samplerType,
					clnumber = clnumber,
					spriteSheetSize = spriteSheetSize,
				}),
				uniforms = {
					spriteTex = 0,
					palTex = 1,
					paletteIndex = 0,
					transparentIndex = -1,
					spriteBit = 0,
					spriteMask = 0xFF,
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

		self['quadMap'..info.name..'Obj'] = GLSceneObject{
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
]],				{
					clnumber = clnumber,
					frameBufferSize = frameBufferSize,
				}),
				fragmentCode = template([[
in vec2 tcv;
layout(location=0) out <?=fragType?> fragColor;

// tilemap texture
uniform uint mapIndexOffset;
uniform int draw16Sprites;	 	//0 = draw 8x8 sprites, 1 = draw 16x16 sprites
uniform <?=samplerType?> mapTex;
uniform <?=samplerType?> tileTex;
uniform <?=samplerType?> palTex;

const float spriteSheetSizeX = <?=clnumber(spriteSheetSize.x)?>;
const float spriteSheetSizeY = <?=clnumber(spriteSheetSize.y)?>;
const uint tilemapSizeX = <?=tilemapSize.x?>;
const uint tilemapSizeY = <?=tilemapSize.y?>;

void main() {
	// convert from input normalized coordinates to tilemap texel coordinates
	// [0, tilemapSize)^2
	ivec2 tci = ivec2(
		int(tcv.x * float(tilemapSizeX << draw16Sprites)),
		int(tcv.y * float(tilemapSizeY << draw16Sprites))
	);

	// convert to map texel coordinate
	// [0, tilemapSize)^2
	ivec2 tileTC = ivec2(
		(tci.x >> (3 + draw16Sprites)) & 0xFF,
		(tci.y >> (3 + draw16Sprites)) & 0xFF
	);

	//read the tileIndex in mapTex at tileTC
	//mapTex is R16, so red channel should be 16bpp (right?)
	// how come I don't trust that and think I'll need to switch this to RG8 ...
	int tileIndex = int(]]..readTexUint('texelFetch(mapTex, '..texCoordRectFromIntVec('tileTC', tilemapSize)..').r', 65536)..[[);

	//[0, 31)^2 = 5 bits for tile tex sprite x, 5 bits for tile tex sprite y
	ivec2 tileTexTC = ivec2(
		tileIndex & 0x1F,					// tilemap bits 0..4
		(tileIndex >> 5) & 0x1F			// tilemap bits 5..9
	);
	int palHi = (tileIndex >> 10) & 0xF;	// tilemap bits 10..13
	if ((tileIndex & (1<<14)) != 0) tci.x = ~tci.x;	// tilemap bit 14
	if ((tileIndex & (1<<15)) != 0) tci.y = ~tci.y;	// tilemap bit 15

	int mask = (1 << (3 + draw16Sprites)) - 1;
	// [0, spriteSize)^2
	tileTexTC = ivec2(
		(tci.x & mask) | (tileTexTC.x << 3),
		(tci.y & mask) | (tileTexTC.y << 3)
	);

	// tileTex is R8 indexing into our palette ...
	uint colorIndex = ]]
		..readTexUint('texelFetch(tileTex, '..texCoordRectFromIntVec('tileTexTC', spriteSheetSize)..').r')..[[;
	colorIndex += palHi << 4;
	colorIndex &= 0xFFu;

]]..info.colorOutput..[[
	if (fragColor.a == 0.) discard;
}
]],				{
					fragType = fragType,
					useTextureRect = useTextureRect,
					samplerType = samplerType,
					clnumber = clnumber,
					spriteSheetSize = spriteSheetSize,
					tilemapSize = tilemapSize,
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
	end

	self:setVideoMode(0)	-- 16bpp RGB565
	--self:setVideoMode(1)	-- 8bpp indexed
	--self:setVideoMode(2)	-- 8bpp RGB332

	-- for the editor

	-- a pattern for transparencies
	self.checkerTex = GLTex2D{
		type = gl.GL_UNSIGNED_BYTE,
		format = gl.GL_RGB,
		internalFormat = gl.GL_RGB,
		magFilter = gl.GL_NEAREST,
		--minFilter = gl.GL_NEAREST,
		minFilter = gl.GL_NEAREST_MIPMAP_NEAREST,
		--[[ checkerboard
		image = Image(2,2,3,'unsigned char', {0xf0,0xf0,0xf0,0xfc,0xfc,0xfc,0xfc,0xfc,0xfc,0xf0,0xf0,0xf0}),
		--]]
		-- [[ gradient
		image = Image(4,4,3,'unsigned char', {
			0xf0,0xf0,0xf0, 0xfd,0xfd,0xfd, 0xfe,0xfe,0xfe, 0xff,0xff,0xff,
			0xfd,0xfd,0xfd, 0xfe,0xfe,0xfe, 0xff,0xff,0xff, 0xf0,0xf0,0xf0,
			0xfe,0xfe,0xfe, 0xff,0xff,0xff, 0xf0,0xf0,0xf0, 0xfd,0xfd,0xfd,
			0xff,0xff,0xff, 0xf0,0xf0,0xf0, 0xfd,0xfd,0xfd, 0xfe,0xfe,0xfe,
		}),
		--]]
	}:unbind()
end

--[[
each video mode should uniquely ...
- pick the framebufferTex
- pick the blit SceneObj
- pick / setup flags for each other shader (since RGB modes need RGB output, indexed modes need indexed output ...)

TODO should I require this to runInEmu and expect fb to be bound?
--]]
function AppDraw:setVideoMode(mode)
	if mode == 0 then
		self.fbTex = self.fbRGB565Tex
		self.blitScreenObj = self.blitScreenRGBObj
		self.lineSolidObj = self.lineSolidRGBObj
		self.quadSolidObj = self.quadSolidRGBObj
		self.quadSpriteObj = self.quadSpriteRGBObj
		self.quadMapObj = self.quadMapRGBObj
	elseif mode == 1 then
		self.fbTex = self.fbIndexTex
		self.blitScreenObj = self.blitScreenIndexObj
		self.lineSolidObj = self.lineSolidIndexObj
		self.quadSolidObj = self.quadSolidIndexObj
		self.quadSpriteObj = self.quadSpriteIndexObj
		self.quadMapObj = self.quadMapIndexObj
		-- TODO and we need to change each shaders output from 565 RGB to Indexed also ...
		-- ... we have to defer the palette baking
	elseif mode == 2 then
		-- these convert from rendered content to the framebuffer ...
		self.lineSolidObj = self.lineSolidRGB332Obj
		self.quadSolidObj = self.quadSolidRGB332Obj
		self.quadSpriteObj = self.quadSpriteRGB332Obj
		self.quadMapObj = self.quadMapRGB332Obj
		-- this is the framebuffer
		self.fbTex = self.fbIndexTex
		-- this converts from the framebuffer to the screen
		self.blitScreenObj = self.blitScreenRGB332Obj
	else
		error("unknown video mode "..tostring(mode))
	end
	self.blitScreenObj.texs[1] = self.fbTex

	local fb = self.fb
	fb:bind()
	fb:setColorAttachmentTex2D(self.fbTex.id, 0, self.fbTex.target)
	local res,err = fb.check()
	if not res then
		print(err)
		print(debug.traceback())
	end
	fb:unbind()
end

return {
	argb8888revto5551 = argb8888revto5551,
	rgba5551_to_rgba8888_4ch = rgba5551_to_rgba8888_4ch,
	rgb565rev_to_rgba888_3ch = rgb565rev_to_rgba888_3ch,
	rgba8888_4ch_to_5551 = rgba8888_4ch_to_5551,
	resetFont = resetFont,
	resetFontOnSheet = resetFontOnSheet,
	resetPalette = resetPalette,
	AppDraw = AppDraw,
}
