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
local assert = require 'ext.assert'
local Image = require 'image'
local gl = require 'gl'
local glreport = require 'gl.report'
local GLFBO = require 'gl.fbo'
local GLTex2D = require 'gl.tex2d'
local GLGeometry = require 'gl.geometry'
local GLSceneObject = require 'gl.sceneobject'

local numo9_rom = require 'numo9.rom'
local paletteSize = numo9_rom.paletteSize
local spriteSize = numo9_rom.spriteSize
local frameBufferSize = numo9_rom.frameBufferSize
local spriteSheetSize = numo9_rom.spriteSheetSize
local spriteSheetSizeInTiles = numo9_rom.spriteSheetSizeInTiles
local tileSheetAddr = numo9_rom.tileSheetAddr
local tilemapSize = numo9_rom.tilemapSize
local tilemapSizeInSprites = numo9_rom.tilemapSizeInSprites
local fontImageSize = numo9_rom.fontImageSize
local fontImageSizeInTiles = numo9_rom.fontImageSizeInTiles
local mvMatScale = numo9_rom.mvMatScale
local spriteSheetAddr = numo9_rom.spriteSheetAddr
local spriteSheetInBytes = numo9_rom.spriteSheetInBytes
local paletteAddr = numo9_rom.paletteAddr
local paletteInBytes = numo9_rom.paletteInBytes
local fontInBytes = numo9_rom.fontInBytes
local packptr = numo9_rom.packptr
local unpackptr = numo9_rom.unpackptr

local function glslnumber(x)
	local s = tostring(tonumber(x))
	if s:find'e' then return s end
	if not s:find'%.' then s = s .. '.' end
	return s
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

-- uses integer coordinates in shader.  you'd think that'd make it look more retro, but it seems shaders evolved for decades with float-only/predominant that int support is shoehorned in.
local useTextureRect = false
--local useTextureRect = true

local texelFunc = 'texture'
--local texelFunc = 'texelFetch'
-- I'm getting this error really: "No matching function for call to texelFetch(usampler2D, ivec2)"
-- so I guess I need to use usampler2DRect if I want to use texelFetch

-- on = use GL_*UI for our texture internal format, off = use regular non-integer
--local useSamplerUInt = false
local useSamplerUInt = true

local texInternalFormat_u8 = useSamplerUInt
	and gl.GL_R8UI	-- use this with usampler2D(Rect) ... right?
	or gl.GL_R8	-- use this with sampler2D(Rect) ... right?
	--or gl.GL_R32F	-- needs CPU data to be in

local texInternalFormat_u16 = useSamplerUInt
	and gl.GL_R16UI
	or gl.GL_R16
	--or gl.GL_R32F

-- TODO move to gl?
local function infoForTex(tex)
	return assert.index(GLTex2D.formatInfoForInternalFormat, tex.internalFormat, "failed to find formatInfo for internalFormat")
end

local function glslPrefixForTex(tex)
	return GLTex2D.glslPrefixForInternalType[infoForTex(tex).internalType] or ''
end

local function samplerTypeForTex(tex)
	return glslPrefixForTex(tex)..'sampler2D'..(useTextureRect and 'Rect' or '')
end

local function fragTypeForTex(tex)
	return glslPrefixForTex(tex)..'vec4'
end

local function textureSize(tex)
	if useTextureRect then	-- textureSize(gsampler2DRect) doesn't have a LOD argument
		return 'textureSize('..tex..')'
	else
		return 'textureSize('..tex..', 0)'
	end
end

--[[
args:
	texvar = glsl var name
	tex = GLTex object
	tc
	from (optional) 'vec2' or 'ivec2'
	to (optional) 'vec4' or 'uvec4'
is this going to turn into a parser?
--]]
local function readTex(args)
	local texvar = args.texvar
	local tc = args.tc
	if args.from == 'vec2' then
		if useTextureRect or texelFunc == 'texelFetch' then
			tc = 'ivec2(('..tc..') * vec2('..textureSize(texvar)..'))'
		end
	elseif args.from == 'ivec2' then
		if not (useTextureRect or texelFunc == 'texelFetch') then
			tc = '(vec2('..tc..') + .5) / vec2('..textureSize(texvar)..')'
		end
	end
	local dst
	if texelFunc == 'texelFetch'
	and not useTextureRect 	-- texelFetch(gsampler2DRect) doesn't have a LOD argument
	then
		dst = texelFunc..'('..texvar..', '..tc..', 0)'
	else
		dst = texelFunc..'('..texvar..', '..tc..')'
	end
	if args.to == 'uvec4' then
		-- convert to uint, assume the source is a texture texel
		if fragTypeForTex(args.tex) == 'uvec4' then
			dst = 'uvec4('..dst..')'
		end
	end
	return dst
end

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

-- upon boot, upload the logo to the whole sheet
local function resetLogoOnSheet(spriteSheetPtr)
	local splashImg = Image'splash.png'
	assert.eq(splashImg.channels, 1)
	assert.eq(splashImg.width, spriteSheetSize.x)
	assert.eq(splashImg.height, spriteSheetSize.y)
	-- TODO don't do the whole spritesheet ...
	for y=0,spriteSheetSize.y-1 do
		for x=0,spriteSheetSize.x-1 do
			local index = x + spriteSheetSize.x * y
			spriteSheetPtr[index] = splashImg.buffer[index] == 0
				and 0xfc or 0xf0	-- subtract out the white
				--and 0xff or 0xf0	-- subtract light-gray (to fade? nah not working)
				--and 0xf0 or 0xfc	-- opposite, good for adding i guess?
		end
	end
end

local function resetROMFont(fontPtr, fontFilename)
	-- paste our font letters one bitplane at a time ...
	-- TODO just hardcode this resource in the code?
	local fontImg = assert(Image(fontFilename or 'font.png'), "failed to find file "..tostring(fontFilename))
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
		assert.lt(srcx, fontImg.width)
		assert.lt(srcy, fontImg.height)
		assert.lt(dstx, fontImageSize.x)
		assert.lt(dsty, fontImageSize.y)
		for by=0,7 do
			for bx=0,7 do
				local srcp = fontImg.buffer
					+ srcx + bx
					+ fontImg.width * (
						srcy + by
					)
				local dstp = fontPtr
					+ dstx + bx
					+ fontImageSize.x * (
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
			dstx, dsty = inc2d(dstx, dsty, fontImageSize.x, fontImageSize.y)
			if not dstx then break end
		end
	end
end

-- TODO every time App calls this, make sure its palTex.dirtyCPU flag is set
-- it would be here but this is sometimes called by n9a as well
local function resetPalette(ptr)	-- uint16_t*
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

local function resetROMPalette(rom)
	resetPalette(rom.palette)
end

-- [[ also in sand-attack ... hmmmm ...
-- consider putting somewhere common, maybe in gl.tex2d ?
-- maybe just save .image in gltex2d?
function makeTexFromImage(app, args)
glreport'before makeTexFromImage'
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
glreport'after makeTexFromImage'

	return tex
end


-- This just holds a bunch of stuff that App will dump into itself
-- so its member functions' "self"s are just 'App'.
-- I'd call it 'App' but that might be confusing because it's not really App.
local AppVideo = {}

-- called upon app init
-- 'self' == app
function AppVideo:initDraw()
	self.fb = GLFBO{
		width = frameBufferSize.x,
		height = frameBufferSize.y,
	}:unbind()

	local function makeImageAtPtr(ptr, x, y, ch, type, ...)
		assert.ne(ptr, nil)
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
		image = makeImageAtPtr(self.ram.spriteSheet, spriteSheetSize.x, spriteSheetSize.y, 1, 'uint8_t'):clear(),
		internalFormat = texInternalFormat_u8,
		format = GLTex2D.formatInfoForInternalFormat[texInternalFormat_u8].format,
		type = gl.GL_UNSIGNED_BYTE,
	})

	self.tileTex = makeTexFromImage(self, {
		image = makeImageAtPtr(self.ram.tileSheet, spriteSheetSize.x, spriteSheetSize.y, 1, 'uint8_t'):clear(),
		internalFormat = texInternalFormat_u8,
		format = GLTex2D.formatInfoForInternalFormat[texInternalFormat_u8].format,
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
		image = makeImageAtPtr(self.ram.tilemap, tilemapSize.x, tilemapSize.y, 1, 'uint16_t'):clear(),
		internalFormat = texInternalFormat_u16,
		format = GLTex2D.formatInfoForInternalFormat[texInternalFormat_u16].format,
		type = gl.GL_UNSIGNED_SHORT,
	})
	self.mapMem = self.mapTex.image.buffer

	-- palette is 256 x 1 x 16 bpp (5:5:5:1)
	self.palTex = makeTexFromImage(self, {
		image = makeImageAtPtr(self.ram.palette, paletteSize, 1, 1, 'uint16_t'),
		internalFormat = gl.GL_RGB5_A1,
		format = gl.GL_RGBA,
		type = gl.GL_UNSIGNED_SHORT_1_5_5_5_REV,	-- 'REV' means first channel first bit ... smh
	})

	-- font is gonna be stored planar, 8bpp, 8 chars per 8x8 sprite per-bitplane
	-- so a 256 char font will be 2048 bytes
	self.fontTex = makeTexFromImage(self, {
		image = makeImageAtPtr(self.ram.font, fontImageSize.x, fontImageSize.y, 1, 'uint8_t'),
		internalFormat = texInternalFormat_u8,
		format = GLTex2D.formatInfoForInternalFormat[texInternalFormat_u8].format,
		type = gl.GL_UNSIGNED_BYTE,
	})

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
			internalFormat = texInternalFormat_u8,
			format = GLTex2D.formatInfoForInternalFormat[texInternalFormat_u8].format,
			type = gl.GL_UNSIGNED_BYTE,
		})
	end
	--]=]

	-- keep menu/editor gfx separate of the fantasy-console
	do
		-- palette is 256 x 1 x 16 bpp (5:5:5:1)
		local data = ffi.new('uint16_t[?]', 256)
		resetPalette(data)
		self.palMenuTex = GLTex2D{
			internalFormat = gl.GL_RGB5_A1,
			format = gl.GL_RGBA,
			width = paletteSize,
			height = 1,
			type = gl.GL_UNSIGNED_SHORT_1_5_5_5_REV,	-- 'REV' means first channel first bit ... smh
			wrap = {
				s = gl.GL_CLAMP_TO_EDGE,
				t = gl.GL_CLAMP_TO_EDGE,
			},
			minFilter = gl.GL_NEAREST,
			magFilter = gl.GL_NEAREST,
			data = data,
		}:unbind()

		-- framebuffer for the editor ... doesn't have a mirror in RAM, so it doesn't cause the net state to go out of sync
		local size = frameBufferSize.x * frameBufferSize.y * 3
		local data = ffi.new('uint8_t[?]', size)
		ffi.fill(data, size)
		self.fbMenuTex = GLTex2D{
			internalFormat = gl.GL_RGB,
			format = gl.GL_RGB,
			type = gl.GL_UNSIGNED_BYTE,
			width = frameBufferSize.x,
			height = frameBufferSize.y,
			wrap = {
				s = gl.GL_CLAMP_TO_EDGE,
				t = gl.GL_CLAMP_TO_EDGE,
			},
			minFilter = gl.GL_NEAREST,
			magFilter = gl.GL_NEAREST,
			data = data,
		}:unbind()
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

	-- code for converting 'uint colorIndex' to '(u)vec4 fragColor'
	-- assert palleteSize is a power-of-two ...
	local function colorIndexToFrag(tex, decl)
		return (decl or 'fragColor')..' = '..readTex{
			tex = self.palTex,
			texvar = 'palTex',
			tc = 'ivec2(int(colorIndex & '..('0x%Xu'):format(paletteSize-1)..'), 0)',
			from = 'ivec2',
			to = fragTypeForTex(tex),
		}..';\n'
	end

	-- and here's our blend solid-color option...
	local function getDrawOverrideCode(fbTex, vec3)
		return [[
	if (drawOverrideSolid.a > 0) {
		fragColor.rgb = ]]..vec3..[[(drawOverrideSolid.rgb);
	}
]]
	end

	self.videoModeInfo = {
		-- 16bpp rgb565
		[0]={
			fbTex = self.fbRGB565Tex,

			-- generator properties
			name = 'RGB',
			colorOutput = colorIndexToFrag(self.fbRGB565Tex)..'\n'
				..getDrawOverrideCode(self.fbRGB565Tex, 'vec3'),
		},
		-- 8bpp indexed
		{
			fbTex = self.fbIndexTex,

			-- generator properties
			-- indexed mode can't blend so ... no draw-override
			name = 'Index',
			colorOutput =
-- this part is only needed for alpha
colorIndexToFrag(self.fbIndexTex, 'vec4 palColor')..'\n'..
[[
	fragColor.r = colorIndex;
	fragColor.g = 0;
	fragColor.b = 0;
	// only needed for quadSprite / quadMap:
	fragColor.a = uint(palColor.a * 255.);
]],
		},
		-- 8bpp rgb332
		{
			fbTex = self.fbIndexTex,

			-- generator properties
			name = 'RGB332',
			colorOutput = colorIndexToFrag(self.fbIndexTex, 'vec4 palColor')..'\n'
..getDrawOverrideCode(self.fbIndexTex, 'uvec3')..'\n'
..template([[
	/*
	palColor is  5 5 5
	fragColor is 3 3 2
	so we lose   2 2 3 bits
	so we can dither those in ...
	*/
	uint r5 = uint(palColor.r * 31.);
	uint g5 = uint(palColor.g * 31.);
	uint b5 = uint(palColor.b * 31.);
	ivec2 ipixelPos = ivec2(pixelPos);
	fragColor.r = (r5 >> 2) |
				((g5 >> 2) << 3) |
				((b5 >> 3) << 6);
	fragColor.g = 0;
	fragColor.b = 0;
	// only needed for quadSprite / quadMap:
	fragColor.a = uint(palColor.a * 255.);
]],		{
			self = self,
			fragTypeForTex = fragTypeForTex,
		})},
	}

--[[ a wrapper to output the code
	local origGLSceneObject = GLSceneObject
	local function GLSceneObject(args)
		print'vertex'
		print(require 'template.showcode'(args.program.vertexCode))
		print'fragment'
		print(require 'template.showcode'(args.program.fragmentCode))
		print()
		return origGLSceneObject(args)
	end
--]]

	local blitFragType = 'vec4'	-- blit screen is always to vec4 ... right?

	-- used for drawing our 16bpp framebuffer to the screen
--DEBUG:print'mode 0 blitScreenObj'
	self.videoModeInfo[0].blitScreenObj = GLSceneObject{
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

layout(location=0) out <?=blitFragType?> fragColor;
uniform <?=samplerTypeForTex(fbTex)?> fbTex;

void main() {
	fragColor = ]]..readTex{
		tex = self.videoModeInfo[0].fbTex,
		texvar = 'fbTex',
		tc = 'tcv',
		from = 'vec2',
		to = blitFragType,
	}..[[;
}
]],			{
				fbTex = self.videoModeInfo[0].fbTex,
				samplerTypeForTex = samplerTypeForTex,
				blitFragType = blitFragType,
			}),
			uniforms = {
				fbTex = 0,
			},
		},
		texs = {self.videoModeInfo[0].fbTex},
		geometry = self.quadGeom,
		-- glUniform()'d every frame
		uniforms = {
			mvProjMat = self.blitScreenView.mvProjMat.ptr,
		},
	}

	-- used for drawing our 8bpp indexed framebuffer to the screen
--DEBUG:print'mode 1 blitScreenObj'
	self.videoModeInfo[1].blitScreenObj = GLSceneObject{
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

layout(location=0) out <?=blitFragType?> fragColor;

uniform <?=samplerTypeForTex(fbTex)?> fbTex;
uniform <?=samplerTypeForTex(palTex)?> palTex;

void main() {
	uint colorIndex = ]]..readTex{
		tex = self.videoModeInfo[1].fbTex,
		texvar = 'fbTex',
		tc = 'tcv',
		from = 'vec2',
		to = blitFragType,
	}..[[.r;
]]..colorIndexToFrag(self.videoModeInfo[1].fbTex)..[[
}
]],			{
				samplerTypeForTex = samplerTypeForTex,
				fbTex = self.videoModeInfo[1].fbTex,
				palTex = self.palTex,
				blitFragType = blitFragType,
			}),
			uniforms = {
				fbTex = 0,
				palTex = 1,
			},
		},
		texs = {self.videoModeInfo[1].fbTex, self.palTex},
		geometry = self.quadGeom,
		-- glUniform()'d every frame
		uniforms = {
			mvProjMat = self.blitScreenView.mvProjMat.ptr,
		},
	}

	-- used for drawing 8bpp fbIndexTex as rgb332 framebuffer to the screen
--DEBUG:print'mode 2 blitScreenObj'
	self.videoModeInfo[2].blitScreenObj = GLSceneObject{
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

layout(location=0) out <?=blitFragType?> fragColor;

uniform <?=samplerTypeForTex(fbTex)?> fbTex;

void main() {
	uint rgb332 = ]]..readTex{
		tex = self.videoModeInfo[1].fbTex,
		texvar = 'fbTex',
		tc = 'tcv',
		from = 'vec2',
		to = blitFragType,
	}..[[.r;
	fragColor.r = float(rgb332 & 0x7u) / 7.;
	fragColor.g = float((rgb332 >> 3) & 0x7u) / 7.;
	fragColor.b = float((rgb332 >> 6) & 0x3u) / 3.;
	fragColor.a = 1.;
}
]],			{
				fbTex = self.videoModeInfo[2].fbTex,
				samplerTypeForTex = samplerTypeForTex,
				blitFragType = blitFragType,
			}),
			uniforms = {
				fbTex = 0,
				palTex = 1,
			},
		},
		texs = {self.videoModeInfo[2].fbTex, self.palTex},
		geometry = self.quadGeom,
		-- glUniform()'d every frame
		uniforms = {
			mvProjMat = self.blitScreenView.mvProjMat.ptr,
		},
	}

	-- make output shaders per-video-mode
	-- set them up as our app fields to use upon setVideoMode
	for infoIndex,info in pairs(self.videoModeInfo) do
--DEBUG:print('mode '..infoIndex..' lineSolidObj')
		info.lineSolidObj = GLSceneObject{
			program = {
				version = glslVersion,
				precision = 'best',
				vertexCode = template([[
layout(location=0) in vec2 vertex;
out vec2 pixelPos;
uniform vec3 pos0;
uniform vec3 pos1;
uniform mat4 mvMat;

//instead of a projection matrix, here I'm going to convert from framebuffer pixel coordinates to GL homogeneous coordinates.
const float frameBufferSizeX = <?=glslnumber(frameBufferSize.x)?>;
const float frameBufferSizeY = <?=glslnumber(frameBufferSize.y)?>;

const float lineThickness = 1.;

void main() {
	vec4 xformPos0 = mvMat * vec4(pos0, 1.);
	vec4 xformPos1 = mvMat * vec4(pos1, 1.);
	vec4 delta = xformPos1 - xformPos0;
	gl_Position = xformPos0
		+ delta * vertex.x
		+ normalize(vec4(-delta.y, delta.x, 0., 0.)) * (vertex.y - .5) * 2. * lineThickness;
	pixelPos = gl_Position.xy;
	gl_Position.xy *= vec2(2. / frameBufferSizeX, 2. / frameBufferSizeY);
	gl_Position.xy -= 1.;
}
]],				{
					glslnumber = glslnumber,
					frameBufferSize = frameBufferSize,
				}),
				fragmentCode = template([[
in vec2 pixelPos;
layout(location=0) out <?=fragType?> fragColor;

uniform uint colorIndex;
uniform <?=samplerTypeForTex(self.palTex)?> palTex;
uniform vec4 drawOverrideSolid;

void main() {
]]..info.colorOutput..[[
}
]],				{
					info = info,
					fragType = fragTypeForTex(info.fbTex),
					self = self,
					samplerTypeForTex = samplerTypeForTex,
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
				pos0 = {0, 0, 0},
				pos1 = {8, 8, 8},
				drawOverrideSolid = {0, 0, 0, 0},
			},
		}
		assert(math.log(paletteSize, 2) % 1 == 0)	-- make sure our palette is a power-of-two

		-- TODO maybe ditch quadSolid* and dont' use uniforms to draw quads ... and just do this with prims ... idk
		-- but quadSolid has my ellipse/border shader so ....
--DEBUG:print('mode '..infoIndex..' triSolidObj')
		info.triSolidObj = GLSceneObject{
			program = {
				version = glslVersion,
				precision = 'best',
				vertexCode = template([[
layout(location=0) in vec3 vertex;
out vec2 pixelPos;
uniform mat4 mvMat;

//instead of a projection matrix, here I'm going to convert from framebuffer pixel coordinates to GL homogeneous coordinates.
const float frameBufferSizeX = <?=glslnumber(frameBufferSize.x)?>;
const float frameBufferSizeY = <?=glslnumber(frameBufferSize.y)?>;

void main() {
	gl_Position = mvMat * vec4(vertex, 1.);
	pixelPos = gl_Position.xy;
	gl_Position.xy *= vec2(2. / frameBufferSizeX, 2. / frameBufferSizeY);
	gl_Position.xy -= 1.;
}
]],				{
					glslnumber = glslnumber,
					frameBufferSize = frameBufferSize,
				}),
				fragmentCode = template([[
in vec2 pixelPos;
layout(location=0) out <?=fragType?> fragColor;

uniform uint colorIndex;

uniform <?=samplerTypeForTex(self.palTex)?> palTex;
uniform vec4 drawOverrideSolid;

float sqr(float x) { return x * x; }

void main() {
]]..info.colorOutput..[[
}
]],				{
					fragType = fragTypeForTex(info.fbTex),
					self = self,
					samplerTypeForTex = samplerTypeForTex,
				}),
				uniforms = {
					palTex = 0,
					--mvMat = self.mvMat.ptr,
				},
			},
			texs = {self.palTex},
			-- glUniform()'d every frame
			uniforms = {
				mvMat = self.mvMat.ptr,
				colorIndex = 0,
				drawOverrideSolid = {0, 0, 0, 0},
			},
			vertexes = {
				dim = 3,
				useVec = true,
				count = 3,
			},
			geometry = {
				mode = gl.GL_TRIANGLES,
				count = 3,
			},
		}

--DEBUG:print('mode '..infoIndex..' quadSolidObj')
		info.quadSolidObj = GLSceneObject{
			program = {
				version = glslVersion,
				precision = 'best',
				vertexCode = template([[
layout(location=0) in vec2 vertex;
out vec2 pixelPos;
out vec2 pcv;	// unnecessary except for the sake of 'round' ...
uniform vec4 box;	//x,y,w,h
uniform mat4 mvMat;

//instead of a projection matrix, here I'm going to convert from framebuffer pixel coordinates to GL homogeneous coordinates.
const float frameBufferSizeX = <?=glslnumber(frameBufferSize.x)?>;
const float frameBufferSizeY = <?=glslnumber(frameBufferSize.y)?>;

void main() {
	pcv = box.xy + vertex * box.zw;	// TODO should this be after transform? but then you'd have to transform the box by mvmat in the fragment shader too ...
	gl_Position = mvMat * vec4(pcv, 0., 1.);
	pixelPos = gl_Position.xy;
	gl_Position.xy *= vec2(2. / frameBufferSizeX, 2. / frameBufferSizeY);
	gl_Position.xy -= 1.;
}
]],				{
					glslnumber = glslnumber,
					frameBufferSize = frameBufferSize,
				}),
				fragmentCode = template([[
in vec2 pcv;		// framebuffer pixel coordinates before transform , so they are sprite texels
in vec2 pixelPos;	// framebuffer pixel coordaintes after transform, so they really are framebuffer coordinates

uniform vec4 box;	//x,y,w,h

layout(location=0) out <?=fragType?> fragColor;

uniform bool borderOnly;
uniform bool round;

uniform uint colorIndex;

uniform <?=samplerTypeForTex(self.palTex)?> palTex;
uniform vec4 drawOverrideSolid;

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
					fragType = fragTypeForTex(info.fbTex),
					self = self,
					samplerTypeForTex = samplerTypeForTex,
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

--DEBUG:print('mode '..infoIndex..' quadSpriteObj')
		info.quadSpriteObj = GLSceneObject{
			program = {
				version = glslVersion,
				precision = 'best',
				vertexCode = template([[
in vec2 vertex;
out vec2 tcv;
out vec2 pixelPos;
uniform vec4 box;	//x,y,w,h
uniform vec4 tcbox;	//x,y,w,h

uniform mat4 mvMat;

const float frameBufferSizeX = <?=glslnumber(frameBufferSize.x)?>;
const float frameBufferSizeY = <?=glslnumber(frameBufferSize.y)?>;

void main() {
	tcv = tcbox.xy + vertex * tcbox.zw;
	vec2 pc = box.xy + vertex * box.zw;
	gl_Position = mvMat * vec4(pc, 0., 1.);
	pixelPos = gl_Position.xy;
	gl_Position.xy *= vec2(2. / frameBufferSizeX, 2. / frameBufferSizeY);
	gl_Position.xy -= 1.;
}
]],				{
					glslnumber = glslnumber,
					frameBufferSize = frameBufferSize,
				}),
				fragmentCode = template([[
in vec2 tcv;
in vec2 pixelPos;

layout(location=0) out <?=fragType?> fragColor;

//For now this is an integer added to the 0-15 4-bits of the sprite tex.
//You can set the top 4 bits and it'll work just like OR'ing the high color index nibble.
//Or you can set it to low numbers and use it to offset the palette.
//Should this be high bits? or just an offset to OR? or to add?
uniform uint paletteIndex;

// Reads 4 bits from wherever shift location you provide.
uniform <?=samplerTypeForTex(self.spriteTex)?> spriteTex;

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

uniform <?=samplerTypeForTex(self.palTex)?> palTex;

uniform vec4 drawOverrideSolid;

void main() {
<? if useSamplerUInt then ?>
	uint colorIndex = ]]
		..readTex{
			tex = self.spriteTex,
			texvar = 'spriteTex',
			tc = 'tcv',
			from = 'vec2',
			to = 'uvec4',
		}
		..[[.r;

	colorIndex >>= spriteBit;
	colorIndex &= spriteMask;

	if (colorIndex == transparentIndex) discard;
	colorIndex += paletteIndex;

<?=info.colorOutput?>

<? if fragType == 'uvec4' then ?>
	if (fragColor.a == 0) discard;
<? else ?>
	if (fragColor.a < .5) discard;
<? end ?>

<? else ?>

	float colorIndexNorm = ]]
		..readTex{
			tex = self.spriteTex,
			texvar = 'spriteTex',
			tc = 'tcv / vec2(textureSize(spriteTex))',
			from = 'vec2',
			to = 'vec4',
		}
..[[.r;
	uint colorIndex = uint(colorIndexNorm * 255. + .5);
	colorIndex >>= spriteBit;
	colorIndex &= spriteMask;
	if (colorIndex == transparentIndex) discard;
	colorIndex += paletteIndex;
<?=info.colorOutput?>
<? end ?>
}
]], 			{
					glslnumber = glslnumber,
					fragType = fragTypeForTex(info.fbTex),
					useSamplerUInt = useSamplerUInt,
					self = self,
					samplerTypeForTex = samplerTypeForTex,
					info = info,
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

--DEBUG:print('mode '..infoIndex..' quadMapObj')
		info.quadMapObj = GLSceneObject{
			program = {
				version = glslVersion,
				precision = 'best',
				vertexCode = template([[
in vec2 vertex;
out vec2 tcv;
out vec2 pixelPos;
uniform vec4 box;		//x y w h
uniform vec4 tcbox;		//tx ty tw th
uniform mat4 mvMat;

const float frameBufferSizeX = <?=glslnumber(frameBufferSize.x)?>;
const float frameBufferSizeY = <?=glslnumber(frameBufferSize.y)?>;

void main() {
	tcv = tcbox.xy + vertex * tcbox.zw;
	vec2 pc = box.xy + vertex * box.zw;
	gl_Position = mvMat * vec4(pc, 0., 1.);
	pixelPos = gl_Position.xy;
	gl_Position.xy *= vec2(2. / frameBufferSizeX, 2. / frameBufferSizeY);
	gl_Position.xy -= 1.;
}
]],				{
					glslnumber = glslnumber,
					frameBufferSize = frameBufferSize,
				}),
				fragmentCode = template([[
in vec2 tcv;
in vec2 pixelPos;
layout(location=0) out <?=fragType?> fragColor;

// tilemap texture
uniform uint mapIndexOffset;
uniform int draw16Sprites;	 	//0 = draw 8x8 sprites, 1 = draw 16x16 sprites
uniform <?=samplerTypeForTex(self.mapTex)?> mapTex;
uniform <?=samplerTypeForTex(self.tileTex)?> tileTex;
uniform <?=samplerTypeForTex(self.palTex)?> palTex;

const uint tilemapSizeX = <?=tilemapSize.x?>;
const uint tilemapSizeY = <?=tilemapSize.y?>;

uniform vec4 drawOverrideSolid;

void main() {
#if 0	// do it in float
	int tileSize = 1 << (3 + draw16Sprites);
	float tileSizef = float(tileSize);
	int mask = tileSize - 1;

	// convert from input normalized coordinates to tilemap texel coordinates
	// [0, tilemapSize)^2
	vec2 tcf = vec2(
		.5 + tcv.x * float(tilemapSizeX << draw16Sprites),
		.5 + tcv.y * float(tilemapSizeY << draw16Sprites)
	);
	tcf /= tileSizef;

	// convert to map texel coordinate
	// [0, tilemapSize)^2
	// mod 256 ? maybe?
	// integer part of tcf

	//read the tileIndex in mapTex at tcf
	//mapTex is R16, so red channel should be 16bpp (right?)
	// how come I don't trust that and think I'll need to switch this to RG8 ...
	int tileIndex = int(]]..readTex{
		tex = self.mapTex,
		texvar = 'mapTex',
		tc = '(floor(tcf) + .5) / vec2('..textureSize'mapTex'..')',
		from = 'vec2',
		to = 'uvec4',
	}..[[.r);

	//[0, 31)^2 = 5 bits for tile tex sprite x, 5 bits for tile tex sprite y
	ivec2 tileIndexTC = ivec2(
		tileIndex & 0x1F,				// tilemap bits 0..4
		(tileIndex >> 5) & 0x1F			// tilemap bits 5..9
	);
	int palHi = (tileIndex >> 10) & 0xF;	// tilemap bits 10..13

	vec2 tcfp = tcf - floor(tcf);
	if ((tileIndex & (1<<14)) != 0) tcfp.x = 1. - tcfp.x;	// tilemap bit 14
	if ((tileIndex & (1<<15)) != 0) tcfp.y = 1. - tcfp.y;	// tilemap bit 15

	// [0, spriteSize)^2
	ivec2 tileTexTC = ivec2(
		int(tcfp.x * tileSizef) ^ (tileIndexTC.x << 3),
		int(tcfp.y * tileSizef) ^ (tileIndexTC.y << 3)
	);

	// tileTex is R8 indexing into our palette ...
	uint colorIndex = ]]..readTex{
		tex = self.tileTex,
		texvar = 'tileTex',
		tc = 'tileTexTC',
		from = 'ivec2',
		to = 'uvec4',
	}..[[.r;

#else	//do it in int

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
	int tileIndex = int(]]..readTex{
		tex = self.mapTex,
		texvar = 'mapTex',
		tc = 'tileTC',
		from = 'ivec2',
		to = 'uvec4',
	}..[[.r);

	//[0, 31)^2 = 5 bits for tile tex sprite x, 5 bits for tile tex sprite y
	ivec2 tileIndexTC = ivec2(
		tileIndex & 0x1F,				// tilemap bits 0..4
		(tileIndex >> 5) & 0x1F			// tilemap bits 5..9
	);
	int palHi = (tileIndex >> 10) & 0xF;	// tilemap bits 10..13
	if ((tileIndex & (1<<14)) != 0) tci.x = ~tci.x;	// tilemap bit 14
	if ((tileIndex & (1<<15)) != 0) tci.y = ~tci.y;	// tilemap bit 15

	int mask = (1 << (3 + draw16Sprites)) - 1;
	// [0, spriteSize)^2
	ivec2 tileTexTC = ivec2(
		(tci.x & mask) ^ (tileIndexTC.x << 3),
		(tci.y & mask) ^ (tileIndexTC.y << 3)
	);

	// tileTex is R8 indexing into our palette ...
	uint colorIndex = ]]..readTex{
		tex = self.tileTex,
		texvar = 'tileTex',
		tc = 'tileTexTC',
		from = 'ivec2',
		to = 'uvec4',
	}..[[.r;

#endif


	colorIndex += palHi << 4;
]]..info.colorOutput..[[
	if (fragColor.a == 0.) discard;
}
]],				{
					fragType = fragTypeForTex(info.fbTex),
					self = self,
					samplerTypeForTex = samplerTypeForTex,
					glslnumber = glslnumber,
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
		image = Image(2,2,3,'uint8_t', {0xf0,0xf0,0xf0,0xfc,0xfc,0xfc,0xfc,0xfc,0xfc,0xf0,0xf0,0xf0}),
		--]]
		-- [[ gradient
		image = Image(4,4,3,'uint8_t', {
			0xf0,0xf0,0xf0, 0xfd,0xfd,0xfd, 0xfe,0xfe,0xfe, 0xff,0xff,0xff,
			0xfd,0xfd,0xfd, 0xfe,0xfe,0xfe, 0xff,0xff,0xff, 0xf0,0xf0,0xf0,
			0xfe,0xfe,0xfe, 0xff,0xff,0xff, 0xf0,0xf0,0xf0, 0xfd,0xfd,0xfd,
			0xff,0xff,0xff, 0xf0,0xf0,0xf0, 0xfd,0xfd,0xfd, 0xfe,0xfe,0xfe,
		}),
		--]]
	}:unbind()

	self:resetVideo()
end

-- flush anything from gpu to cpu
function AppVideo:checkDirtyGPU()
	self.spriteTex:checkDirtyGPU()
	self.tileTex:checkDirtyGPU()
	self.mapTex:checkDirtyGPU()
	self.palTex:checkDirtyGPU()
	self.fontTex:checkDirtyGPU()
	self.fbTex:checkDirtyGPU()
end

function AppVideo:setDirtyCPU()
	self.spriteTex.dirtyCPU = true
	self.tileTex.dirtyCPU = true
	self.mapTex.dirtyCPU = true
	self.palTex.dirtyCPU = true
	self.fontTex.dirtyCPU = true
	self.fbTex.dirtyCPU = true
end

function AppVideo:resetVideo()
	--[[ update later ...
	self:checkDirtyGPU()
	--]]
	ffi.copy(self.ram.v, self.banks.v[0].v, ffi.sizeof'ROM')
	-- [[ update now ...
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
	self.fontTex:bind()
		:subimage()
		:unbind()
	self.fontTex.dirtyCPU = false
	--]]
	--[[ update later ...
	self:setDirtyCPU()
	--]]

	self.ram.videoMode = 0	-- 16bpp RGB565
	--self.ram.videoMode = 1	-- 8bpp indexed
	--self.ram.videoMode = 2	-- 8bpp RGB332
	self:setVideoMode(self.ram.videoMode)

	self.ram.blendMode = 0xff	-- = none
	self.ram.blendColor = rgba8888_4ch_to_5551(255,0,0,255)	-- solid red

	for i=0,255 do
		self.ram.fontWidth[i] = 5
	end

	-- 4 uint8 bytes: x, y, w, h ... width and height are inclusive so i can do 0 0 ff ff and get the whole screen
	self:setClipRect(0, 0, 0xff, 0xff)

	self:matident()
end

--[[
each video mode should uniquely ...
- pick the framebufferTex
- pick the blit SceneObj
- pick / setup flags for each other shader (since RGB modes need RGB output, indexed modes need indexed output ...)
--]]
function AppVideo:setVideoMode(mode)
	local info = self.videoModeInfo[mode]
	if info then
		-- fbTex is the VRAM tex ... soo rename it?  fbVRAMTex or something?
		self.fbTex = info.fbTex
		self.blitScreenObj = info.blitScreenObj
		self.lineSolidObj = info.lineSolidObj
		self.triSolidObj = info.triSolidObj
		self.quadSolidObj = info.quadSolidObj
		self.quadSpriteObj = info.quadSpriteObj
		self.quadMapObj = info.quadMapObj
	else
		error("unknown video mode "..tostring(mode))
	end
	self.blitScreenObj.texs[1] = self.fbTex

	self:setFBTex(self.fbTex)
	self.currentVideoMode = mode
end

-- this is set between the VRAM tex .fbTex (for draw commands that need to be reflected to the CPU)
--  and the menu tex .fbMenuTex (for those that don't)
function AppVideo:setFBTex(tex)
	local fb = self.fb
	if not self.inUpdateCallback then
		fb:bind()
	end
	fb:setColorAttachmentTex2D(tex.id, 0, tex.target)
	local res,err = fb.check()
	if not res then
		print(err)
		print(debug.traceback())
	end
	if not self.inUpdateCallback then
		fb:unbind()
	end
end

-- exchnage two colors in the palettes, and in all spritesheets,
-- subject to some texture subregion (to avoid swapping bitplanes of things like the font)
function AppVideo:colorSwap(from, to, x, y, w, h)
	-- TODO SORT THIS OUT
	ffi.copy(self.ram.v, self.banks.v[0].v, ffi.sizeof'ROM')
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
	-- TODO option for only swap in a specific sheet/addr
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
	ffi.copy(self.banks.v[0].v, self.ram.v, ffi.sizeof'ROM')
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

function AppVideo:resetFont()
	self.fontTex:checkDirtyGPU()
	resetROMFont(self.ram.font)
	ffi.copy(self.banks.v[0].font, self.ram.font, fontInBytes)
	self.fontTex.dirtyCPU = true
end

-- externally used ...
-- this re-inserts the font and default palette
-- and copies those changes back into the cartridge too (stupid idea of keeping two copies of the cartridge in RAM and ROM ...)
function AppVideo:resetGFX()
	self:resetFont()

	self.palTex:checkDirtyGPU()
	resetROMPalette(self.ram)
	ffi.copy(self.banks.v[0].palette, self.ram.palette, paletteInBytes)
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
	uniforms.colorIndex = math.floor(colorIndex or 0)
	uniforms.borderOnly = borderOnly or false
	uniforms.round = round or false
	if w < 0 then x,w = x+w,-w end
	if h < 0 then y,h = y+h,-h end
	settable(uniforms.box, x, y, w, h)

	local blendSolidR, blendSolidG, blendSolidB = rgba5551_to_rgba8888_4ch(self.ram.blendColor)
	settable(uniforms.drawOverrideSolid, blendSolidR/255, blendSolidG/255, blendSolidB/255, self.drawOverrideSolidA)

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

function AppVideo:drawSolidTri3D(x1, y1, z1, x2, y2, z2, x3, y3, z3, colorIndex)
	self.palTex:checkDirtyCPU() -- before any GPU op that uses palette...
	self.fbTex:checkDirtyCPU()

	local sceneObj = self.triSolidObj
	local uniforms = sceneObj.uniforms

	uniforms.mvMat = self.mvMat.ptr
	uniforms.colorIndex = math.floor(colorIndex)

	local vtxGPU = sceneObj.attrs.vertex.buffer
	local vtxCPU = vtxGPU:beginUpdate()
	vtxCPU:emplace_back():set(x1, y1, z1)
	vtxCPU:emplace_back():set(x2, y2, z2)
	vtxCPU:emplace_back():set(x3, y3, z3)
	vtxGPU:endUpdate()

	local blendSolidR, blendSolidG, blendSolidB = rgba5551_to_rgba8888_4ch(self.ram.blendColor)
	settable(uniforms.drawOverrideSolid, blendSolidR/255, blendSolidG/255, blendSolidB/255, self.drawOverrideSolidA)

	sceneObj:draw()
	self.fbTex.dirtyGPU = true
	self.fbTex.changedSinceDraw = true
end

function AppVideo:drawSolidTri(x1, y1, x2, y2, x3, y3, colorIndex)
	return self:drawSolidTri3D(x1, y1, 0, x2, y2, 0, x3, y3, 0, colorIndex)
end

function AppVideo:drawSolidLine3D(x1,y1,z1,x2,y2,z2,colorIndex)
	self.palTex:checkDirtyCPU() -- before any GPU op that uses palette...
	self.fbTex:checkDirtyCPU()

	local sceneObj = self.lineSolidObj
	local uniforms = sceneObj.uniforms

	uniforms.mvMat = self.mvMat.ptr
	uniforms.colorIndex = colorIndex
	settable(uniforms.pos0, x1,y1,z1)
	settable(uniforms.pos1, x2,y2,z2)

	local blendSolidR, blendSolidG, blendSolidB = rgba5551_to_rgba8888_4ch(self.ram.blendColor)
	settable(uniforms.drawOverrideSolid, blendSolidR/255, blendSolidG/255, blendSolidB/255, self.drawOverrideSolidA)

	sceneObj:draw()
	self.fbTex.dirtyGPU = true
	self.fbTex.changedSinceDraw = true
end

function AppVideo:drawSolidLine(x1,y1,x2,y2,colorIndex)
	return self:drawSolidLine3D(x1,y1,0,x2,y2,0,colorIndex)
end

local mvMatCopy = ffi.new('float[16]')
function AppVideo:clearScreen(colorIndex)
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

-- [[ TODO this here or this in the draw commands?
	self.drawOverrideSolidA = bit.band(blendMode, 4) == 0 and 0 or 0xff	-- > 0 means we're using draw-override
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
	palTex,
	paletteIndex,
	transparentIndex,
	spriteBit,
	spriteMask
)
	if tex.checkDirtyCPU then	-- some editor textures are separate of the 'hardware' and don't possess this
		tex:checkDirtyCPU()				-- before we read from the sprite tex, make sure we have most updated copy
	end
	if palTex.checkDirtyCPU then
		palTex:checkDirtyCPU() 	-- before any GPU op that uses palette...
	end
	self.fbTex:checkDirtyCPU()		-- before we write to framebuffer, make sure we have most updated copy

	paletteIndex = paletteIndex or 0
	transparentIndex = transparentIndex or -1
	spriteBit = spriteBit or 0
	spriteMask = spriteMask or 0xFF

	local sceneObj = self.quadSpriteObj
	local uniforms = sceneObj.uniforms
	sceneObj.texs[1] = tex
	sceneObj.texs[2] = palTex

	uniforms.mvMat = self.mvMat.ptr
	uniforms.paletteIndex = paletteIndex	-- user has to specify high-bits
	uniforms.transparentIndex = transparentIndex
	uniforms.spriteBit = spriteBit
	uniforms.spriteMask = spriteMask
	settable(uniforms.tcbox, tx, ty, tw, th)
	settable(uniforms.box, x, y, w, h)

	local blendSolidR, blendSolidG, blendSolidB = rgba5551_to_rgba8888_4ch(self.ram.blendColor)
	settable(uniforms.drawOverrideSolid, blendSolidR/255, blendSolidG/255, blendSolidB/255, self.drawOverrideSolidA)

	sceneObj:draw()

	-- restore in case it wasn't the original
	sceneObj.texs[1] = self.spriteTex
	sceneObj.texs[2] = self.palTex

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
		self.palTex,	-- palTex
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
	self.palTex:checkDirtyCPU() 	-- before any GPU op that uses palette...
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

	local blendSolidR, blendSolidG, blendSolidB = rgba5551_to_rgba8888_4ch(self.ram.blendColor)
	settable(uniforms.drawOverrideSolid, blendSolidR/255, blendSolidG/255, blendSolidB/255, self.drawOverrideSolidA)

	sceneObj:draw()
	self.fbTex.dirtyGPU = true
	self.fbTex.changedSinceDraw = true
end

-- draw transparent-background text
function AppVideo:drawText1bpp(text, x, y, color, scaleX, scaleY)
	scaleX = scaleX or 1
	scaleY = scaleY or 1
	--local texSizeInTiles = spriteSheetSizeInTiles	-- using sprite sheet last row
	local texSizeInTiles = fontImageSizeInTiles		-- using separate font tex
	for i=1,#text do
		local ch = text:byte(i)
		local bi = bit.band(ch, 7)		-- get the bit offset
		local by = bit.rshift(ch, 3)	-- get the byte offset
		--local tx,ty = by,texSizeInTiles.y-1				-- using sprite sheet last row
		local tx,ty = by,0							-- using separate font tex
		self:drawQuad(
			x,									-- x
			y,									-- y
			spriteSize.x * scaleX,				-- spritesWide
			spriteSize.y * scaleY,				-- spritesHigh
			tx / tonumber(texSizeInTiles.x),	-- tx
			ty / tonumber(texSizeInTiles.y),	-- ty
			1 / tonumber(texSizeInTiles.x),		-- tw
			1 / tonumber(texSizeInTiles.y),		-- th
			--self.spriteTex,						-- tex
			self.fontTex,						-- tex
			self.palTex,						-- palTex
			-- font color is 0 = background, 1 = foreground
			-- so shift this by 1 so the font tex contents shift it back
			-- TODO if compression is a thing then store 8 letters per 8x8 sprite
			-- heck why not store 2 letters per left and right half as well?
			-- 	that's half the alphaet in a single 8x8 sprite black.
			color-1,							-- paletteIndex ... 'color index offset' / 'palette high bits'
			0,									-- transparentIndex
			bi,									-- spriteBit
			1									-- spriteMask
		)
		x = x + self.ram.fontWidth[ch] * scaleX
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
			local ch = text:byte(i)
			-- TODO the ... between drawSolidRect and drawSprite is not the same...
			self:drawSolidRect(
				x,
				y,
				scaleX * self.ram.fontWidth[ch],
				scaleY * spriteSize.y,
				bgColorIndex
			)
			x = x + self.ram.fontWidth[ch]
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

-- matrix commands, so I don't duplicate these here in the env and in net ...
-- should I set defaults here as well?
-- I'm already setting them in env so ... nah ...

function AppVideo:matident()
	self.mvMat:setIdent()
	self:mvMatToRAM()
end

function AppVideo:mattrans(x,y,z)
	self:mvMatFromRAM()
	self.mvMat:applyTranslate(x, y, z)
	self:mvMatToRAM()
end

function AppVideo:matrot(theta, x, y, z)
	self:mvMatFromRAM()
	self.mvMat:applyRotate(theta, x, y, z)
	self:mvMatToRAM()
end

function AppVideo:matscale(x, y, z)
	self:mvMatFromRAM()
	self.mvMat:applyScale(x, y, z)
	self:mvMatToRAM()
end

function AppVideo:matortho(l, r, t, b, n, f)
	self:mvMatFromRAM()
	-- adjust from [-1,1] to [0,256]
	-- opengl ortho matrix, which expects input space to be [-1,1]
	self.mvMat:applyTranslate(128, 128)
	self.mvMat:applyScale(128, 128)
	self.mvMat:applyOrtho(l, r, t, b, n, f)
	self:mvMatToRAM()
end

function AppVideo:matfrustum(l, r, t, b, n, f)
	self:mvMatFromRAM()
	self.mvMat:applyFrustum(l, r, t, b, n, f)
	-- TODO Why is matortho a lhs transform to screen space but matfrustum a rhs transform to screen space? what did I do wrong?
	self.mvMat:applyTranslate(128, 128)
	self.mvMat:applyScale(128, 128)
	self:mvMatToRAM()
end

function AppVideo:matlookat(ex, ey, ez, cx, cy, cz, upx, upy, upz)
	self:mvMatFromRAM()
	self.mvMat:applyLookAt(ex, ey, ez, cx, cy, cz, upx, upy, upz)
	self:mvMatToRAM()
end

return {
	argb8888revto5551 = argb8888revto5551,
	rgba5551_to_rgba8888_4ch = rgba5551_to_rgba8888_4ch,
	rgb565rev_to_rgba888_3ch = rgb565rev_to_rgba888_3ch,
	rgba8888_4ch_to_5551 = rgba8888_4ch_to_5551,
	resetROMFont = resetROMFont,
	resetLogoOnSheet = resetLogoOnSheet,
	resetROMPalette = resetROMPalette,
	AppVideo = AppVideo,
}
