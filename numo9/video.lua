--[[
TODO maybe move this into a numo9/rom.lua file
and put in that file the ROM and RAM struct defs
and all the spritesheet / tilemap specs
Or rename this to gfx.lua and put more GL stuff in it?
--]]
local ffi = require 'ffi'
local template = require 'template'
local table = require 'ext.table'
local math = require 'ext.math'
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
local frameBufferSize = require 'numo9.rom'.frameBufferSize
local spriteSheetSize = require 'numo9.rom'.spriteSheetSize
local spriteSheetSizeInTiles = require 'numo9.rom'.spriteSheetSizeInTiles
local tileSheetAddr = require 'numo9.rom'.tileSheetAddr
local tilemapSize = require 'numo9.rom'.tilemapSize
local tilemapSizeInSprites = require 'numo9.rom'.tilemapSizeInSprites
local fontWidth = require 'numo9.rom'.fontWidth
local mvMatScale = require 'numo9.rom'.mvMatScale
local spriteSheetAddr = require 'numo9.rom'.spriteSheetAddr
local spriteSheetInBytes = require 'numo9.rom'.spriteSheetInBytes
local paletteAddr = require 'numo9.rom'.paletteAddr
local paletteInBytes = require 'numo9.rom'.paletteInBytes
local packptr = require 'numo9.rom'.packptr
local unpackptr = require 'numo9.rom'.unpackptr

-- TODO use either settable or packptr ... ?
local function settableindex(t, i, ...)
	if select('#', ...) == 0 then return end
	t[i] = ...
	settableindex(t, i+1, select(2, ...))
end

local function settable(t, ...)
	settableindex(t, 1, ...)
end


-- I was hoping I could do this all in integer, but maybe not for the fragment output, esp with blending ...
-- glsl unsigned int fragment colors and samplers really doesn't do anything predictable...
local fragType = 'uvec4'
--local fragType = 'vec4'	-- not working

-- on = read usampler, off = read sampler
--local useTextureInt = false	-- not working
local useTextureInt = true

-- uses integer coordinates in shader.  you'd think that'd make it look more retro, but it seems shaders evolved for decades with float-only/predominant that int support is shoehorned in.
local useTextureRect = false
--local useTextureRect = true

--local texelType = (useTextureInt and 'u' or '')..'vec4'

local texelFunc = 'texture'
--local texelFunc = 'texelFetch'
-- I'm getting this error really: "No matching function for call to texelFetch(usampler2D, ivec2)"
-- so I guess I need to use usampler2DRect if I want to use texelFetch

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
local AppVideo = {}

-- 'self' == app
function AppVideo:initDraw()
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
		if useTextureRect or texelFunc == 'texelFetch' then
			code = 'ivec2(('..code..') * vec2('..clnumber(size.x)..', '..clnumber(size.y)..'))'
		end
		return code
	end

	local function texCoordRectFromIntVec(code, size)
		if not (useTextureRect or texelFunc == 'texelFetch') then
			code = 'vec2(('..code..') + .5) / vec2('..clnumber(size.x)..', '..clnumber(size.y)..')'
		end
		return code
	end

	-- code for converting 'uint colorIndex' to '(u)vec4 fragColor'
	local colorIndexToFrag = table{
		(useTextureRect or texelFunc == 'texelFetch')
		and [[
	ivec2 palTc = ivec2(colorIndex & ]]..('0x%Xu'):format(paletteSize-1)..[[, 0);
]]
		or [[
	vec2 palTc = vec2((float(colorIndex)+.5)/]]..clnumber(paletteSize)..[[, .5);
]],
		[[
	fragColor = ]]..texelFunc..[[(palTex, palTc);
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

//It should require a vec4 since our fb target will be RGB5_A1/GL_RGBA which is a float type
// according to this post https://stackoverflow.com/a/9185740
//layout(location=0) out vec4 fragColor;
// so how come it doesn't work unless I use uvec4 as the fragment type?
// and how come the gl docs just say it gets normalized ...
layout(location=0) out uvec4 fragColor;
// and how come texelFetch has no problem handing off to a vec4 and a uvec4 ... WHAT KIND OF CONVERSION IS GOING ON THERE?

uniform <?=samplerType?> fbTex;

void main() {
	fragColor = ]]..texelFunc..[[(fbTex, ]]..texCoordRectFromFloatVec('tcv', frameBufferSize)..[[);
// with vec4 fragColor, none of these give a meaningful result:
//fragColor *= 1. / 255.;
//fragColor *= 1. / 65535.;
//fragColor *= 1. / 16777215.;
//fragColor *= 1. / 4294967295.;
}
]],			{
				samplerType = samplerType,
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

layout(location=0) out uvec4 fragColor;

uniform <?=samplerType?> fbTex;
uniform <?=samplerType?> palTex;

void main() {
	uint colorIndex = ]]..readTexUint(texelFunc..'(fbTex, '..texCoordRectFromFloatVec('tcv', frameBufferSize)..').r')..[[;
]]..colorIndexToFrag..[[
}
]],			{
				samplerType = samplerType,
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
	uint rgb332 = ]]..readTexUint(texelFunc..'(fbTex, '..texCoordRectFromFloatVec('tcv', frameBufferSize)..').r')..[[;
	fragColor.r = float(rgb332 & 0x7u) / 7.;
	fragColor.g = float((rgb332 >> 3) & 0x7u) / 7.;
	fragColor.b = float((rgb332 >> 6) & 0x3u) / 3.;
	fragColor.a = 1.;
}
]],			{
				samplerType = samplerType,
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

		-- and here's our blend solid-color option...
	local drawOverrideCode = [[
	if (drawOverrideSolid.a > 0) {
		// use max int since we're writing out to RGB5_A1 which is a RGB i.e. float tex in GL
		// ... does uint not use all 32 bits?  do i have to query the bit resolution outside glsl and shift that many bits inside glsl?  what is going on here?
		//fragColor.rgb = drawOverrideSolid.rgb << 24;	// green/blue looks blue
		//fragColor.rgb = drawOverrideSolid.rgb << 23;	// green/blue looks green, loses blue channel
		//fragColor.rgb = drawOverrideSolid.rgb << 22;	// same
		//fragColor.rgb = drawOverrideSolid.rgb << 21;	// black
		//fragColor.rgb = drawOverrideSolid.rgb * 16843009;	// this is ((1<<32)-1)/((1<<8)-1) ... green turns blue ...
		//fragColor.rgb = drawOverrideSolid.rgb * 8421504;	// this is ((1<<31)-1)/((1<<8)-1) ... green turns black ...
	}
]]

	-- make output shaders per-video-mode
	-- set them up as our app fields to use upon setVideoMode
	for _,info in ipairs{
		{name='RGB', colorOutput=colorIndexToFrag..'\n'..drawOverrideCode},

		-- indexed mode can't blend so ... no draw-override
		{name='Index', colorOutput=colorIndexToFrag..[[
	fragColor.r = colorIndex;
	fragColor.g = 0;
	fragColor.b = 0;
]]},
		{name='RGB332', colorOutput=colorIndexToFrag..'\n'
..drawOverrideCode..'\n'
..[[
	// TODO this won't work if we're using fragType == vec4 ...
	// what exactly is coming out of a usampler2D and into a uvec4?  is that documented anywhere?
//#error what is the range of the palTex?  internalFormat=GL_RGB5_A1, format=GL_RGBA, type=GL_UNSIGNED_SHORT_1_5_5_5_REV
	//fragColor >>= 16;	//[16,20] works ... WHY??!?!?!
	//fragColor &= 0xFFu;
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
uniform <?=fragType?> drawOverrideSolid;

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
				drawOverrideSolid = {0, 0, 0, 0},
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
uniform <?=fragType?> drawOverrideSolid;

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
				drawOverrideSolid = {0, 0, 0, 0},
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

uniform <?=fragType?> drawOverrideSolid;

void main() {
	uint colorIndex = (]]
		..readTexUint(texelFunc..'(spriteTex, '..texCoordRectFromFloatVec('tcv', spriteSheetSize)..').r')
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
				drawOverrideSolid = {0, 0, 0, 0},
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

uniform <?=fragType?> drawOverrideSolid;

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
	int tileIndex = int(]]..readTexUint(texelFunc..'(mapTex, '..texCoordRectFromIntVec('tileTC', tilemapSize)..').r', 65536)..[[);

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
		..readTexUint(texelFunc..'(tileTex, '..texCoordRectFromIntVec('tileTexTC', spriteSheetSize)..').r')..[[;
	colorIndex += palHi << 4;
	colorIndex &= 0xFFu;

]]..info.colorOutput..[[
	if (fragColor.a == 0.) discard;
}
]],				{
					fragType = fragType,
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
				drawOverrideSolid = {0, 0, 0, 0},
			},
		}
	end

	self.ram.videoMode[0] = 0	-- 16bpp RGB565
	--self.ram.videoMode[0] = 1	-- 8bpp indexed
	--self.ram.videoMode[0] = 2	-- 8bpp RGB332
	self:setVideoMode(self.ram.videoMode[0])

	self.ram.blendMode[0] = 0xff	-- = none

	-- for debugging ...
	-- still getting erratic results ...
	-- how does GL do conversions between texture()/texelFetch(), and vec4-vs-uvec4 and fragments vs their targets and their respective formats?
	self.ram.blendColor[0] = rgba8888_4ch_to_5551(255,255,127,255)
	self.ram.blendColor[0] = rgba8888_4ch_to_5551(255,255,0,255)
	self.ram.blendColor[0] = rgba8888_4ch_to_5551(255,255,255,255)
	self.ram.blendColor[0] = rgba8888_4ch_to_5551(255,0,0,255)
	self.ram.blendColor[0] = rgba8888_4ch_to_5551(255,0,255,255)
	self.ram.blendColor[0] = rgba8888_4ch_to_5551(0,255,0,255)		-- black
	self.ram.blendColor[0] = rgba8888_4ch_to_5551(0,255,255,255)	-- black
	self.ram.blendColor[0] = rgba8888_4ch_to_5551(0,255,127,255)	-- works sort of

	-- 4 uint8 bytes: x, y, w, h ... width and height are inclusive so i can do 0 0 ff ff and get the whole screen
	self:setClipRect(0, 0, 0xff, 0xff)

	-- for the editor

	-- a pattern for transparencies
	self.checkerTex = GLTex2D{
		type = gl.GL_UNSIGNED_BYTE,
		format = gl.GL_RGB,
		internalFormat = gl.GL_RGB,
		magFilter = gl.GL_NEAREST,
		minFilter = gl.GL_NEAREST,
		--minFilter = gl.GL_NEAREST_MIPMAP_NEAREST,		-- doesn't work so well with alpha channesl
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
--]]
function AppVideo:setVideoMode(mode)
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
	if not self.inUpdateCallback then
		fb:bind()
	end
	fb:setColorAttachmentTex2D(self.fbTex.id, 0, self.fbTex.target)
	local res,err = fb.check()
	if not res then
		print(err)
		print(debug.traceback())
	end
	if not self.inUpdateCallback then
		fb:unbind()
	end

	self.currentVideoMode = mode
end

-- exchnage two colors in the palettes, and in all spritesheets,
-- subject to some texture subregion (to avoid swapping bitplanes of things like the font)
function AppVideo:colorSwap(from, to, x, y, w, h)
	-- TODO SORT THIS OUT
	ffi.copy(self.ram.v, self.cartridge.v, ffi.sizeof'ROM')
	from = math.floor(from)
	to = math.floor(to)
	x = math.floor(x)
	y = math.floor(y)
	w = math.floor(w)
	h = math.floor(h)
	if from < 0 or from >= 256 or to < 0 or to >= 256 then return false end
	x = math.clamp(x, 0, spriteSheetSize.x-1)
	y = math.clamp(y, 0, spriteSheetSize.y-1)
	w = math.clamp(w, 0, spriteSheetSize.x)
	h = math.clamp(h, 0, spriteSheetSize.y)
	local fromFound = 0
	local toFound = 0
	for _,base in ipairs{spriteSheetAddr, tileSheetAddr} do
		for j=y,y+h-1 do
			for i=x,x+w-1 do
				local addr = base + i + spriteSheetSize.x * j
				local c = self:peek(addr)
				if c == from then
					fromFound = fromFound + 1
					self:net_poke(addr, to)
				elseif c == to then
					toFound = toFound + 1
					self:net_poke(addr, from)
				end
			end
		end
	end
	-- now swap palette entries
	local fromAddr =  paletteAddr + bit.lshift(from, 1)
	local toAddr =  paletteAddr + bit.lshift(to, 1)
	local oldFromValue = self:peekw(fromAddr)
	self:net_pokew(fromAddr, self:peekw(toAddr))
	self:net_pokew(toAddr, oldFromValue)
	ffi.copy(self.cartridge.v, self.ram.v, ffi.sizeof'ROM')
	return fromFound, toFound
end


-- convert to/from our fixed-point storage in RAM and the float matrix that the matrix library uses
function AppVideo:mvMatToRAM()
	for i=0,15 do
		self.ram.mvMat[i] = self.mvMat.ptr[i] * mvMatScale
	end
end
function AppVideo:mvMatFromRAM()
	for i=0,15 do
		self.mvMat.ptr[i] = self.ram.mvMat[i] / mvMatScale
	end
end

-- this re-inserts the font and default palette
-- and copies those changes back into the cartridge too (stupid idea of keeping two copies of the cartridge in RAM and ROM ...)
function AppVideo:resetGFX()
	self.spriteTex:checkDirtyGPU()
	self.palTex:checkDirtyGPU()

	--self.spriteTex:prepForCPU()
	resetFont(self.ram)
	ffi.copy(self.cartridge.spriteSheet, self.ram.spriteSheet, spriteSheetInBytes)

	--self.palTex:prepForCPU()
	resetPalette(self.ram)
	ffi.copy(self.cartridge.palette, self.ram.palette, paletteInBytes)

	self.spriteTex.dirtyCPU = true
	self.palTex.dirtyCPU = true
end

function AppVideo:resize()
	needDrawCounter = drawCounterNeededToRedraw
end


function AppVideo:drawSolidRect(
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

	uniforms.mvMat = self.mvMat.ptr
	uniforms.colorIndex = math.floor(colorIndex)
	uniforms.borderOnly = borderOnly or false
	uniforms.round = round or false
	if w < 0 then x,w = x+w,-w end
	if h < 0 then y,h = y+h,-h end
	settable(uniforms.box, x, y, w, h)

	-- redundant, but i guess this is a way to draw with a color outside the palette, so *shrug*
	settable(uniforms.drawOverrideSolid, self.drawOverrideSolidR, self.drawOverrideSolidG, self.drawOverrideSolidB, self.drawOverrideSolidA)

	sceneObj:draw()
	self.fbTex.dirtyGPU = true
	self.fbTex.changedSinceDraw = true
end
-- TODO get rid of this function
function AppVideo:drawBorderRect(
	x,
	y,
	w,
	h,
	colorIndex,
	...	-- round
)
	return self:drawSolidRect(x,y,w,h,colorIndex,true,...)
end

function AppVideo:drawSolidLine(x1,y1,x2,y2,colorIndex)
	self.palTex:checkDirtyCPU() -- before any GPU op that uses palette...
	self.fbTex:checkDirtyCPU()

	local sceneObj = self.lineSolidObj
	local uniforms = sceneObj.uniforms

	uniforms.mvMat = self.mvMat.ptr
	uniforms.colorIndex = colorIndex
	settable(uniforms.line, x1,y1,x2,y2)
	settable(uniforms.drawOverrideSolid, self.drawOverrideSolidR, self.drawOverrideSolidG, self.drawOverrideSolidB, self.drawOverrideSolidA)

	sceneObj:draw()
	self.fbTex.dirtyGPU = true
	self.fbTex.changedSinceDraw = true
end

local mvMatCopy = ffi.new('float[16]')
function AppVideo:clearScreen(colorIndex)
--	self.quadSolidObj.uniforms.mvMat = ident4x4.ptr
	gl.glDisable(gl.GL_SCISSOR_TEST)
	ffi.copy(mvMatCopy, self.mvMat.ptr, ffi.sizeof(mvMatCopy))
	self.mvMat:setIdent()
	self:drawSolidRect(
		0,
		0,
		frameBufferSize.x,
		frameBufferSize.y,
		colorIndex or 0)
	gl.glEnable(gl.GL_SCISSOR_TEST)
	ffi.copy(self.mvMat.ptr, mvMatCopy, ffi.sizeof(mvMatCopy))
--	self.quadSolidObj.uniforms.mvMat = self.mvMat.ptr
end

function AppVideo:setClipRect(x, y, w, h)
	-- NOTICE the ram is only useful for reading, not writing, as it won't invoke a glScissor call
	-- ... should I change that?
	packptr(4, self.ram.clipRect, x, y, w, h)
	gl.glScissor(
		self.ram.clipRect[0],
		self.ram.clipRect[1],
		self.ram.clipRect[2]+1,
		self.ram.clipRect[3]+1)
end

-- for when we blend against solid colors, these go to the shaders to output it
AppVideo.drawOverrideSolidR = 0
AppVideo.drawOverrideSolidG = 0
AppVideo.drawOverrideSolidB = 0
AppVideo.drawOverrideSolidA = 0
function AppVideo:setBlendMode(blendMode)
	if blendMode >= 8 then
		self.drawOverrideSolidA = 0
		gl.glDisable(gl.GL_BLEND)
		return
	end

	gl.glEnable(gl.GL_BLEND)

	local subtract = bit.band(blendMode, 2) ~= 0
	if subtract then
		--gl.glBlendEquation(gl.GL_FUNC_SUBTRACT)		-- sprite minus framebuffer
		gl.glBlendEquation(gl.GL_FUNC_REVERSE_SUBTRACT)	-- framebuffer minus sprite
	else
		gl.glBlendEquation(gl.GL_FUNC_ADD)
	end

--[[
-- TODO how to get blend to replace the incoming color with a constant-color?
-- or is there not?
-- do I have to code the color-replacement into the shaders?
	local cr, cg, cb
	if bit.band(blendMode, 4) ~= 0 then
		cr, cg, cb = rgba5551_to_rgba8888_4ch(self.ram.blendColor[0])
	else
		cr, cg, cb = 1, 1, 1
	end
--]]
-- [[ ... if not then it's gotta be done as a shader ... all shaders need a toggle to override their output when necessary for blend ...
	self.drawOverrideSolidA = bit.band(blendMode, 4) == 0 and 0 or 0xff	-- > 0 means we're using draw-override
	local dr, dg, db = rgba5551_to_rgba8888_4ch(self.ram.blendColor[0])
	self.drawOverrideSolidR = dr
	self.drawOverrideSolidG = dg
	self.drawOverrideSolidB = db
--]]
	local ca = 1
	local half = bit.band(blendMode, 1) ~= 0
	-- technically half didnt work when blending with constant-color on the SNES ...
	if half then
		ca = .5
	end
	gl.glBlendColor(1, 1, 1, ca)

	if half then
		gl.glBlendFunc(gl.GL_CONSTANT_ALPHA, gl.GL_CONSTANT_ALPHA)
	else
		gl.glBlendFunc(gl.GL_ONE, gl.GL_ONE)
	end
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
function AppVideo:drawQuad(
	x, y, w, h,	-- quad box
	tx, ty, tw, th,	-- texcoord bbox
	tex,
	paletteIndex,
	transparentIndex,
	spriteBit,
	spriteMask
)
	if tex.checkDirtyCPU then	-- some editor textures are separate of the 'hardware' and don't possess this
		tex:checkDirtyCPU()				-- before we read from the sprite tex, make sure we have most updated copy
	end
	self.palTex:checkDirtyCPU() 	-- before any GPU op that uses palette...
	self.fbTex:checkDirtyCPU()		-- before we write to framebuffer, make sure we have most updated copy

	paletteIndex = paletteIndex or 0
	transparentIndex = transparentIndex or -1
	spriteBit = spriteBit or 0
	spriteMask = spriteMask or 0xFF

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
	settable(uniforms.drawOverrideSolid, self.drawOverrideSolidR, self.drawOverrideSolidG, self.drawOverrideSolidB, self.drawOverrideSolidA)

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
function AppVideo:drawSprite(
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
	spritesWide = spritesWide or 1
	spritesHigh = spritesHigh or 1
	scaleX = scaleX or 1
	scaleY = scaleY or 1
	-- vram / sprite sheet is 32 sprites wide ... 256 pixels wide, 8 pixels per sprite
	spriteIndex = math.floor(spriteIndex)
	local tx = spriteIndex % spriteSheetSizeInTiles.x
	local ty = (spriteIndex - tx) / spriteSheetSizeInTiles.x
	self:drawQuad(
		-- x y w h
		screenX,
		screenY,
		spritesWide * spriteSize.x * scaleX,
		spritesHigh * spriteSize.y * scaleY,
		-- tx ty tw th
		tx / tonumber(spriteSheetSizeInTiles.x),
		ty / tonumber(spriteSheetSizeInTiles.y),
		spritesWide / tonumber(spriteSheetSizeInTiles.x),
		spritesHigh / tonumber(spriteSheetSizeInTiles.y),
		self.spriteTex,	-- tex
		paletteIndex,
		transparentIndex,
		spriteBit,
		spriteMask
	)
end

-- TODO go back to tileIndex instead of tileX tileY.  That's what mset() issues after all.
function AppVideo:drawMap(
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

	uniforms.mvMat = self.mvMat.ptr
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
	settable(uniforms.drawOverrideSolid, self.drawOverrideSolidR, self.drawOverrideSolidG, self.drawOverrideSolidB, self.drawOverrideSolidA)

	sceneObj:draw()
	self.fbTex.dirtyGPU = true
	self.fbTex.changedSinceDraw = true
end

-- draw transparent-background text
function AppVideo:drawText1bpp(text, x, y, color, scaleX, scaleY)
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
function AppVideo:drawText(text, x, y, fgColorIndex, bgColorIndex, scaleX, scaleY)
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

return {
	argb8888revto5551 = argb8888revto5551,
	rgba5551_to_rgba8888_4ch = rgba5551_to_rgba8888_4ch,
	rgb565rev_to_rgba888_3ch = rgb565rev_to_rgba888_3ch,
	rgba8888_4ch_to_5551 = rgba8888_4ch_to_5551,
	resetFont = resetFont,
	resetFontOnSheet = resetFontOnSheet,
	resetPalette = resetPalette,
	AppVideo = AppVideo,
}