local ffi = require 'ffi'
local op = require 'ext.op'
local template = require 'template'
local table = require 'ext.table'
local class = require 'ext.class'
local math = require 'ext.math'
local assert = require 'ext.assert'
local vector = require 'ffi.cpp.vector-lua'
local Image = require 'image'
local gl = require 'gl'
local glnumber = require 'gl.number'
local GLFBO = require 'gl.fbo'
local GLArrayBuffer = require 'gl.arraybuffer'
local GLTex2D = require 'gl.tex2d'
local GLGeometry = require 'gl.geometry'
local GLSceneObject = require 'gl.sceneobject'
local GLTypes = require 'gl.types'

local matrix_ffi = require 'matrix.ffi'
require 'vec-ffi.vec4ub'
require 'vec-ffi.create_vec3'{dim=4, ctype='unsigned short'}	-- vec4us_t

local RAMGPUTex = require 'numo9.ramgpu'

local numo9_rom = require 'numo9.rom'
local spriteSize = numo9_rom.spriteSize
local spriteSheetSize = numo9_rom.spriteSheetSize
local spriteSheetSizeInTiles = numo9_rom.spriteSheetSizeInTiles
local tilemapSize = numo9_rom.tilemapSize
local paletteSize = numo9_rom.paletteSize
local palettePtrType = numo9_rom.palettePtrType
local fontImageSize = numo9_rom.fontImageSize
local fontImageSizeInTiles = numo9_rom.fontImageSizeInTiles
local fontInBytes = numo9_rom.fontInBytes
local framebufferAddr = numo9_rom.framebufferAddr
local clipMax = numo9_rom.clipMax
local menuFontWidth = numo9_rom.menuFontWidth
local matType = numo9_rom.matType

assert.eq(matType, 'float', "TODO if this changes then update the modelMat, viewMat, projMat uniforms")


local vec2i = require 'vec-ffi.vec2i'
local dirLightMapSize = vec2i(256, 256)
local useDirectionalShadowmaps = true	-- can't turn off or it'll break stuff so *shrug*
local ident4x4 = matrix_ffi({4,4}, matType):eye()

-- either seems to work fine
local texelFunc = 'texture'
--local texelFunc = 'texelFetch'

local texInternalFormat_u8 = gl.GL_R8UI
local texInternalFormat_u16 = gl.GL_R16UI

-- 'REV' means first channel first bit ... smh
-- so even tho 5551 is on hardware since forever, it's not on ES3 or WebGL, only GL4...
-- in case it's missing, just use single-channel R16 and do the swizzles manually
local internalFormat5551 = texInternalFormat_u16
local format5551 = GLTex2D.formatInfoForInternalFormat[internalFormat5551].format
local type5551 = GLTex2D.formatInfoForInternalFormat[internalFormat5551].types[1]   -- gl.GL_UNSIGNED_SHORT

	-- convert it here to vec4 since default UNSIGNED_SHORT_1_5_5_5_REV uses vec4
local glslCode5551 = [[
// assumes the uint is [0,0xffff]
// returns rgba in [0,0x1f]
uvec4 u16to5551(uint x) {
	return uvec4(
		x & 0x1fu,
		(x & 0x3e0u) >> 5u,
		(x & 0x7c00u) >> 10u,
		((x & 0x8000u) >> 15u) * 0x1fu
	);
}
]]

local struct = require 'struct'
local Numo9Vertex = struct{
	name = 'Numo9Vertex',
	fields = {
		{name='vertex', type='vec3f_t'},
		{name='texcoord', type='vec2f_t'},
		{name='normal', type='vec3f_t'},
		{name='extra', type='vec4us_t'},
		{name='box', type='vec4f_t'},
	},
}

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
		if texelFunc == 'texelFetch' then
			tc = 'ivec2(('..tc..') * vec2(textureSize('..texvar..', 0)))'
		end
	elseif args.from == 'ivec2' then
		if texelFunc ~= 'texelFetch' then
			tc = '(vec2('..tc..') + .5) / vec2(textureSize('..texvar..', 0))'
		end
	end
	local dst
	if texelFunc == 'texelFetch' then
		dst = texelFunc..'('..texvar..', '..tc..', 0)'
	else
		dst = texelFunc..'('..texvar..', '..tc..')'
	end

	-- TODO this is for when args.tex is a 5551 GL_R16UI
	-- and to's type is vec4 ...
	--  however you can't always test for GL_R16UI because this is also BlobTilemap.ramgpu when reading tileIndex ...
	--  .. but that one's dest is uvec4 so meh
	-- but if I set that internalFormat then args.to will become uvec4, and then this will be indistinguishble from the BlobTilemap.ramgpu...
	-- so I would need an extra flag for "to vec4 5551"
	-- or should I already be setting them to vec4?
	if args.to == 'u16to5551' then
		dst = 'u16to5551(('..dst..').r)'
	elseif args.to == 'uvec4' then
		-- convert to uint, assume the source is a texture texel
		if args.tex:getGLSLFragType() == 'uvec4' then
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
local function rgb565rev_to_rgb888_3ch(rgb565)
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

local function rgb332_to_rgb888_3ch(rgb332)
	local r = bit.bor(rgb332, 7)
	local g = bit.band(bit.rshift(rgb332, 3), 7)
	local b = bit.band(bit.rshift(rgb332, 6), 3)
	return
		bit.bor(bit.lshift(r, 5), bit.lshift(r, 2), bit.rshift(r, 1)),
		bit.bor(bit.lshift(g, 5), bit.lshift(g, 2), bit.rshift(g, 1)),
		bit.bor(bit.lshift(b, 6), bit.lshift(b, 4), bit.lshift(b, 2), b)
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
	spriteSheetPtr = ffi.cast('uint8_t*', spriteSheetPtr)
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

assert(require 'ext.path''font.png':exists(), "failed to find the default font file!")
local function resetFont(fontPtr, fontFilename)
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

-- TODO every time App calls this, make sure its paletteRAM.dirtyCPU flag is set
-- it would be here but this is sometimes called by n9a as well
local function resetPalette(ptr)
	ptr = ffi.cast(palettePtrType, ptr)
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


-- This just holds a bunch of stuff that App will dump into itself
-- so its member functions' "self"s are just 'App'.
-- I'd call it 'App' but that might be confusing because it's not really App.
local AppVideo = {}

local VideoMode = class()

function VideoMode:init(args)
	for k,v in pairs(args) do self[k] = v end

	self.formatDesc = self.width..'x'..self.height..'x'..self.format
end

--[[
only on request, build the framebuffers, shaders, etc
--]]
function VideoMode:build()
	-- see if its already built
	if self.built then return end

	self:buildFramebuffers()
	self:buildColorOutputAndBlitScreenObj()
	self:buildUberShader()

	self.built = true
end

function VideoMode:buildFramebuffers()
	local app = self.app

	-- push and pop any currently-bound FBO
	-- this can happen if a runThread calls mode()
	if app.inUpdateCallback then
		app.fb:unbind()
	end

	local width, height = self.width, self.height
	local internalFormat, gltype, suffix
	if self.format == 'RGB565' then
		-- framebuffer is 16bpp rgb565 -- used for mode-0
		-- [[
		internalFormat = gl.GL_RGB565
		gltype = gl.GL_UNSIGNED_SHORT_5_6_5	-- for an internalFormat there are multiple gltype's so pick this one
		--]]
		--[[
		-- TODO do this but in doing so the framebuffer fragment vec4 turns into a uvec4
		-- and then the reads from u16to5551() which output vec4 no longer fit
		-- ... hmm ...
		-- ... but if I do this then the 565 hardware-blending no longer works, and I'd have to do that blending manually ...
		internalFormat = internalFormat5551
		--]]
		suffix = 'RGB565'
	elseif self.format == '8bppIndex'
	or self.format == 'RGB332'
	then
		-- framebuffer is 8bpp indexed -- used for mode-1, mode-2
		internalFormat = texInternalFormat_u8
		suffix = '8bpp'
		-- hmm TODO maybe
		-- if you want blending with RGB332 then you can use GL_R3_G3_B2 ...
		-- but it's not in GLES3/WebGL2
	elseif self.format == '4bppIndex' then
		-- here's where exceptions need to be made ...
		-- hmm, so when I draw sprites, I've got to shrink coords by half their size ... ?
		-- and then track whether we are in the lo vs hi nibble ... ?
		-- and somehow preserve the upper/lower nibbles on the sprite edges?
		-- maybe this is too tedious ...
		internalFormat = texInternalFormat_u8
		suffix = '8bpp'	-- suffix is for the framebuffer, and we are using R8UI format
		--width = bit.rshift(width, 1) + bit.band(width, 1)
	else
		error("unknown format "..tostring(self.format))
	end

	-- I'm making one FBO per size.
	-- Should I be making one FBO per internalFormat?
	local sizeKey = '_'..self.width..'x'..self.height
	local fb = not self.useNativeOutput and app.fbos[sizeKey]
	if not fb then
		fb = GLFBO{
			width = self.width,
			height = self.height,
		}

		fb:setDrawBuffers(
			gl.GL_COLOR_ATTACHMENT0,	-- fragColor
			gl.GL_COLOR_ATTACHMENT1,	-- fragNormal
			gl.GL_COLOR_ATTACHMENT2)	-- fragPos
		fb:unbind()

		if not self.useNativeOutput then
			app.fbos[sizeKey] = fb
		end
	end
	self.fb = fb

	-- make a depth tex per size
	local depthTex = not self.useNativeOutput and app.framebufferDepthTexs[sizeKey]
	if not depthTex then
		fb:bind()
		depthTex = GLTex2D{
			internalFormat = gl.GL_DEPTH_COMPONENT,
			width = self.width,
			height = self.height,
			format = gl.GL_DEPTH_COMPONENT,
			type = gl.GL_FLOAT,
			minFilter = gl.GL_NEAREST,
			magFilter = gl.GL_NEAREST,
			wrap = {
				s = gl.GL_CLAMP_TO_EDGE,
				t = gl.GL_CLAMP_TO_EDGE,
			},
		}
		gl.glFramebufferTexture2D(gl.GL_FRAMEBUFFER, gl.GL_DEPTH_ATTACHMENT, gl.GL_TEXTURE_2D, depthTex.id, 0)
		depthTex:unbind()
		fb:unbind()
	end
	self.framebufferDepthTex = depthTex

	-- while we're here, attach a normalmap as well, for "hardware"-based post-processing lighting effects?
	-- make a FBO normalmap per size.  Don't store it in fantasy-console "hardware" RAM just yet.  For now it's just going to be accessible by a single switch in RAM.
	local normalTex = not self.useNativeOutput and app.framebufferNormalTexs[sizeKey]
	if not normalTex then
		normalTex = GLTex2D{
			width = width,
			height = height,
			internalFormat = gl.GL_RGBA32F,
			format = gl.GL_RGBA,
			type = gl.GL_FLOAT,

			minFilter = gl.GL_NEAREST,
			--magFilter = gl.GL_NEAREST,
			magFilter = gl.GL_LINEAR,	-- maybe take off some sharp edges of the lighting?
			wrap = {
				s = gl.GL_CLAMP_TO_EDGE,
				t = gl.GL_CLAMP_TO_EDGE,
			},
		}:unbind()

-- [[ if normalTex and fb are init'd at the same time, i.e. their cache tables use matching keys, then this shouldn't happen any more often than necessary:
		fb:bind()
			:setColorAttachmentTex2D(normalTex.id, 1, normalTex.target)
			:unbind()
--]]

		if not self.useNativeOutput then
			app.framebufferNormalTexs[sizeKey] = normalTex
		end
	end
	self.framebufferNormalTex = assert(normalTex)

	local posTex = not self.useNativeOutput and app.framebufferPosTexs[sizeKey]
	if not posTex then
		posTex = GLTex2D{
			width = width,
			height = height,
			internalFormat = gl.GL_RGB32F,
			format = gl.GL_RGB,
			type = gl.GL_FLOAT,

			minFilter = gl.GL_NEAREST,
			--magFilter = gl.GL_NEAREST,
			magFilter = gl.GL_LINEAR,	-- maybe take off some sharp edges of the lighting?
			wrap = {
				s = gl.GL_CLAMP_TO_EDGE,
				t = gl.GL_CLAMP_TO_EDGE,
			},
		}:unbind()

		fb:bind()
			:setColorAttachmentTex2D(posTex.id, 2, posTex.target)
			:unbind()

		if not self.useNativeOutput then
			app.framebufferPosTexs[sizeKey] = posTex
		end
	end
	self.framebufferPosTex = assert(posTex)

	local sizeAndFormatKey = sizeKey..'x'..suffix
	local framebufferRAM = not self.useNativeOutput and app.framebufferRAMs[sizeAndFormatKey]
	-- this shares between 8bppIndexed (R8UI) and RGB322 (R8UI)
	if not framebufferRAM then
		-- is specified for GL_UNSIGNED_SHORT_5_6_5.
		-- otherwise falls back to default based on internalFormat
		-- set this here so we can determine .ctype for the ctor.
		-- TODO determine ctype = GLTypes.ctypeForGLType in RAMGPU ctor?)
		local formatInfo = assert.index(GLTex2D.formatInfoForInternalFormat, internalFormat)
		gltype = gltype or formatInfo.types[1]  -- there are multiple, so let the caller override

		if self.useNativeOutput then
			-- make a fake-wrapper that doesn't connect to the address space and does nothing for flushing to/from CPU
			framebufferRAM = setmetatable({}, RAMGPUTex)
			framebufferRAM.addr = 0
			framebufferRAM.addrEnd = 0

			local ctype = assert.index(GLTypes.ctypeForGLType, gltype)
			local image = Image(width, height, 1, ctype)
			framebufferRAM.image = image

			framebufferRAM.tex = GLTex2D{
				internalFormat = internalFormat,
				format = formatInfo.format,
				type = gltype,

				width = width,
				height = height,
				wrap = {
					s = gl.GL_CLAMP_TO_EDGE,
					t = gl.GL_CLAMP_TO_EDGE,
				},
				minFilter = gl.GL_NEAREST,
				magFilter = gl.GL_NEAREST,
				data = ffi.cast('uint8_t*', image.buffer),
			}

			function framebufferRAM:delete() return false end	-- :delete() is called on sheet/font/palette RAMGPU's between cart loading/unloading
			function framebufferRAM:overlaps() return false end
			function framebufferRAM:checkDirtyCPU() end
			function framebufferRAM:checkDirtyGPU() end
			function framebufferRAM:updateAddr(newaddr) end
		else
			framebufferRAM = RAMGPUTex{
				app = app,
				addr = framebufferAddr,
				width = width,
				height = height,
				channels = 1,
				internalFormat = internalFormat,
				glformat = formatInfo.format,
				gltype = gltype,
				ctype = assert.index(GLTypes.ctypeForGLType, gltype),
			}

			app.framebufferRAMs[sizeAndFormatKey] = framebufferRAM
		end
	end
	self.framebufferRAM = framebufferRAM

-- [[ do this here?
-- wait aren't the fb's shared between video modes?
	fb:bind()
		:setColorAttachmentTex2D(framebufferRAM.tex.id, 0, framebufferRAM.tex.target)
		:unbind()
--]]

	-- hmm this is becoming a mess ...
	-- link the fbRAM to its respective .fb so that , when we checkDirtyGPU and have to readPixels, it can use its own
	-- hmmmm
	-- can I just make one giant framebuffer and use it everywhere?
	-- or do I have to make one per screen mode's framebuffer?
	self.framebufferRAM.fb = self.fb
	-- don't bother do the same with framebufferNormalTex cuz it isn't a RAMGPU / doesn't have address space

	if app.inUpdateCallback then
		app.fb:bind()
	end
end

-- used with nativemode to recreate its resources every time the screen resizes
function VideoMode:delete()
	self.built = false
	if self.fb then
		self.fb:delete()
		self.fb = nil
	end
	if self.framebufferDepthTex then
		self.framebufferDepthTex:delete()
		self.framebufferDepthTex = nil
	end
	if self.framebufferNormalTex then
		self.framebufferNormalTex:delete()
		self.framebufferNormalTex = nil
	end
	if self.framebufferPosTex then
		self.framebufferPosTex:delete()
		self.framebufferPosTex = nil
	end
	if self.framebufferRAM then
		self.framebufferRAM:delete()
		self.framebufferRAM = nil
	end
end

-- code for converting 'uint colorIndex' to '(u)vec4 fragColor'
-- assert palleteSize is a power-of-two ...
local function colorIndexToFrag(app, destTex, decl)
	return decl..' = '..readTex{
		tex = app.blobs.palette[1].ramgpu.tex,
		texvar = 'paletteTex',
		tc = 'ivec2(int(colorIndex & '..('0x%Xu'):format(paletteSize-1)..'), 0)',
		from = 'ivec2',
		to = 'u16to5551',
	}..';\n'
end

-- and here's our blend solid-color option...
local function getBlendSolidColorCode(vec3, varname)
	return [[
	if (blendColorSolid.a > 0.) {
		]]..varname..[[.rgb = ]]..vec3..[[(blendColorSolid.rgb);
	}
]]
end

-- this string can include template code that uses only vars that appear in all of makeVideoMode* template vars
local useLightingCode = [[

// TODO lighting variables in RAM:
const vec3 lightDir = vec3(0.19245008972988, 0.19245008972988, 0.96225044864938);
const vec3 lightAmbientColor = vec3(.3, .3, .3);
const vec3 lightDiffuseColor = vec3(1., 1., 1.);
const float lightSpecularShininess = 30.;
const vec3 lightSpecularColor = vec3(.5, .5, .5);

const float ssaoOffset = 18.0;
//const float ssaoStrength = 0.07;
//const float ssaoFalloff = 0.000002;
const float ssaoSampleRadius = .05;
const float ssaoInfluence = .8;	// 1 = 100% = you'll see black in fully-occluded points

// used for SSAO lighting, not used for projection
uniform mat4 drawProjMat;

// used for directional lighting
uniform mat4 lightMvProjMat;

// these are the random vectors inside a unit hemisphere facing z+
#define ssaoNumSamples 16
const vec3[ssaoNumSamples] ssaoRandomVectors = {
	vec3(0.58841258486248, 0.39770493127433, 0.18020748345621),
	vec3(-0.055272473410801, 0.35800974374131, 0.15028358974804),
	vec3(0.3199885122024, -0.57765628483213, 0.19344714028561),
	vec3(-0.71177536281716, 0.65982751624885, 0.16661179472317),
	vec3(0.6591556369125, 0.25301657986158, 0.65350042181301),
	vec3(0.37855701974814, 0.013090583813782, 0.71111037617741),
	vec3(0.53098955685005, 0.39114666484126, 0.29796836757796),
	vec3(-0.27445479803038, 0.28177659836742, 0.89415105823562),
	vec3(0.030042725676812, 0.3941820959086, 0.099681999794761),
	vec3(-0.60144625790746, 0.6112734005649, 0.3676468627808),
	vec3(0.72396342749209, 0.35994756762253, 0.30828171680103),
	vec3(-0.8082345863749, 0.13633528834184, 0.32199773139527),
	vec3(0.49667204075871, 0.12506306502285, 0.65431856367262),
	vec3(-0.086390931280017, 0.5832061191173, 0.29234165779378),
	vec3(-0.24610823044055, 0.77791376069684, 0.57363108026349),
	vec3(-0.194238481883, 0.01011984889981, 0.88466521192798),
};

void doLighting() {
	vec4 normalAndDepth = texture(framebufferNormalTex, tcv);
	vec3 normal = normalAndDepth.xyz;

#if 0 // debugging: show normalmap:
	fragColor.xyz = normalAndDepth.xyz * .5 + .5;
	return;
#endif

#if 1 // apply bumpmap lighting
	vec3 lightValue = max(
		lightAmbientColor,
		lightDiffuseColor * abs(dot(normal, lightDir))
		// maybe you just can't do specular lighting in [0,1]^3 space ...
		// maybe I should be doing inverse-frustum-projection stuff here
		// hmmmmmmmmmm
		// I really don't want to split projection and modelview matrices ...
		+ lightSpecularColor * pow(
			abs(reflect(lightDir, normal).z),
			lightSpecularShininess
		)
	);
	fragColor.xyz *= lightValue;
#endif

#if 1	// shadow map
	vec4 worldCoord = vec4(texture(framebufferPosTex, tcv).xyz, 1.);
	vec4 lightClipCoord = lightMvProjMat * worldCoord;
	bool inShadow = true;
	if (lightClipCoord.w > 0.
		&& all(lessThanEqual(vec3(-lightClipCoord.w, -lightClipCoord.w, -lightClipCoord.w), lightClipCoord.xyz)) 
		&& all(lessThanEqual(lightClipCoord.xyz, vec3(lightClipCoord.w, lightClipCoord.w, lightClipCoord.w)))
	) {
		vec3 lightNDCCoord = lightClipCoord.xyz / lightClipCoord.w;
		// in bounds
		float lightBufferDepth = texture(lightDepthTex, lightNDCCoord.xy * .5 + .5).x
			* 2. - 1.;	// convert from [0,1] to depthrange [-1,1]

		if (lightClipCoord.z < lightBufferDepth * lightClipCoord.w + 0.1) {
			// in light
			fragColor.xyz *= 1.2;
		} else {
			// in shadow
			fragColor.xyz *= .3;	//dir light ambient
		}
	} else {
		// in shadow
		fragColor.xyz *= .3;	//dir light ambient
	}
#endif

#if 1	// SSAO
	// currently this is the depth before homogeneous transform, so it'll all negative for frustum projections
	float depth = normalAndDepth.w;

	// current fragment in [-1,1]^2 screen coords x [0,1] depth coord
	vec3 origin = vec3(tcv.xy * 2. - 1., depth);

	// TODO just save float buffer? faster?
	// TODO should this random vec be in 3D or 2D?
	vec3 rvec = texture(noiseTex, tcv * ssaoOffset).xyz;
	rvec.z = 0.;
	rvec = normalize(rvec.xyz * 2. - 1.);

#if 0 // debugging: show rvec
	fragColor.xyz = rvec.xyz * .5 + .5;
	return;
#endif

	vec3 tangent = normalize(rvec - normal * dot(rvec, normal));
	vec3 bitangent = cross(tangent, normal);
	mat3 tangentMatrix = mat3(tangent, bitangent, normal);

	float numOccluded = 0.;
	for (int i = 0; i < ssaoNumSamples; ++i) {
		// rotate random hemisphere vector into our tangent space
		// but this is still in [-1,1]^2 screen coords x [0,1] depth coord, right?
		vec3 samplePt = tangentMatrix * ssaoRandomVectors[i]
			* ssaoSampleRadius
			+ origin;

		// TODO multiply by projection matrix?

		vec4 sampleNormalAndDepth = texture(
			framebufferNormalTex,
			samplePt.xy * .5 + .5
		);
		float sampleDepth = sampleNormalAndDepth.w;
		float depthDiff = samplePt.z - sampleDepth;
		if (depthDiff > ssaoSampleRadius) {
			numOccluded += step(sampleDepth, samplePt.z);
		}
//		numOccluded += step(ssaoFalloff, depthDiff)
//			* (1. - smoothstep(ssaoFalloff, ssaoStrength, depthDiff));
//			* (1. - dot(sampleNormalAndDepth.xyz, normal))
	}

// debugging to see ssao only ... all white ... hmm
//fragColor.xyz = vec3(1., 1., 1.);
	fragColor.xyz *= 1. - ssaoInfluence * numOccluded / float(ssaoNumSamples);
#endif
}
]]

-- blit screen is always to vec4 ... right?
local blitFragType = 'vec4'
local blitFragTypeVec3 = 'vec3'

function VideoMode:buildColorOutputAndBlitScreenObj()
	if self.format == 'RGB565' then
		self:buildColorOutputAndBlitScreenObj_RGB565(self)
	elseif self.format == '8bppIndex' then
		self:buildColorOutputAndBlitScreenObj_8bppIndex(self)
	elseif self.format == 'RGB332' then
		self:buildColorOutputAndBlitScreenObj_RGB332(self)
-- TODO?  it would need a 2nd pass ...
--	elseif self.format == '4bppIndex' then
--		return nil
	else
		error("unknown format "..tostring(self.format))
	end
end

function VideoMode:buildColorOutputAndBlitScreenObj_RGB565()
	local app = self.app
	-- [=[ internalFormat = gl.GL_RGB565
	self.colorIndexToFragColorCode = table{
'vec4 colorIndexToFragColor(uint colorIndex) {',
	colorIndexToFrag(app, self.framebufferRAM.tex, 'uvec4 ufragColor'),
'	vec4 resultFragColor = vec4(ufragColor) / 31.;',
	getBlendSolidColorCode(blitFragTypeVec3, 'resultFragColor'),
'	return resultFragColor;',
'}',
	}:concat'\n'
	--]=]
	--[=[ internalFormat = internalFormat5551
	self.colorIndexToFragColorCode = 'fragColor = '..readTex{
		tex = app.blobs.palette[1].ramgpu.tex,
		texvar = 'paletteTex',
		tc = 'ivec2(int(colorIndex & '..('0x%Xu'):format(paletteSize-1)..'), 0)',
		from = 'ivec2',
		to = 'uvec4',
	}..';\n'..[[

#if 0	// if anyone needs the rgb ...
		fragColor.a = (fragColor.r >> 15) * 0x1fu;
		fragColor.b = (fragColor.r >> 10) & 0x1fu;
		fragColor.g = (fragColor.r >> 5) & 0x1fu;
		fragColor.r &= 0x1fu;
		fragColor = (fragColor << 3) | (fragColor >> 2);
#else	// I think I'll just save the alpha for the immediate-after glsl code alpha discard test ...
		fragColor.a = (fragColor.r >> 15) * 0x1fu;
#endif
]]
		..getBlendSolidColorCode('uvec3', 'fragColor'),
	--]=]

	-- used for drawing our 16bpp framebuffer to the screen
--DEBUG:print'mode 0 blitScreenObj'
	self.blitScreenObj = GLSceneObject{
		program = {
			version = app.glslVersion,
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
precision highp sampler2D;
precision highp isampler2D;
precision highp usampler2D;	// needed by #version 300 es

in vec2 tcv;

layout(location=0) out <?=blitFragType?> fragColor;

uniform bool useLighting;

uniform <?=self.framebufferRAM.tex:getGLSLSamplerType()?> framebufferTex;
uniform <?=self.framebufferNormalTex:getGLSLSamplerType()?> framebufferNormalTex;
uniform <?=self.framebufferPosTex:getGLSLSamplerType()?> framebufferPosTex;
uniform <?=app.noiseTex:getGLSLSamplerType()?> noiseTex;	// for SSAO
uniform <?=app.lightDepthTex:getGLSLSamplerType()?> lightDepthTex;

]]..useLightingCode..[[

void main() {
#if 1	// internalFormat = gl.GL_RGB565
	fragColor = ]]..readTex{
	tex = self.framebufferRAM.tex,
	texvar = 'framebufferTex',
	tc = 'tcv',
	from = 'vec2',
	to = blitFragType,
}..[[;
#endif
#if 0	// internalFormat = internalFormat5551
	uint rgba5551 = ]]..readTex{
	tex = self.framebufferRAM.tex,
	texvar = 'framebufferTex',
	tc = 'tcv',
	from = 'vec2',
	to = blitFragType,
}..[[.r;

	fragColor.a = float(rgba5551 >> 15);
	fragColor.b = float((rgba5551 >> 10) & 0x1fu) / 31.;
	fragColor.g = float((rgba5551 >> 5) & 0x1fu) / 31.;
	fragColor.r = float(rgba5551 & 0x1fu) / 31.;
#endif

	if (useLighting) {
		doLighting();
	}
}
]],			{
				app = app,
				self = self,
				blitFragType = blitFragType,
			}),
			uniforms = {
				framebufferTex = 0,
				framebufferNormalTex = 1,
				framebufferPosTex = 2,
				noiseTex = 3,
				lightDepthTex = 4,
			},
		},
		texs = {
			self.framebufferRAM.tex,
			self.framebufferNormalTex,
			self.framebufferPosTex,
			app.noiseTex,
			app.lightDepthTex,
		},
		geometry = app.quadGeom,
		-- glUniform()'d every frame
		uniforms = {
			mvProjMat = app.blitScreenView.mvProjMat.ptr,
		},
	}

	return self
end

function VideoMode:buildColorOutputAndBlitScreenObj_8bppIndex()
	local app = self.app

	-- indexed mode can't blend so ... no draw-override
	-- this part is only needed for alpha
	self.colorIndexToFragColorCode = table{
'uvec4 colorIndexToFragColor(uint colorIndex) {',
	colorIndexToFrag(app, self.framebufferRAM.tex, 'uvec4 palColor'),
	[[
	uvec4 resultFragColor;
	resultFragColor.r = colorIndex;
	resultFragColor.g = 0u;
	resultFragColor.b = 0u;
	// only needed for quadSprite / quadMap:
	resultFragColor.a = (palColor.a << 3) | (palColor.a >> 2);
]],
-- hmm, idk what to do with blendColorSolid in 8bppIndex
-- but I don't want the GLSL compiler to optimize away the attr...
	getBlendSolidColorCode('uvec3', 'resultFragColor'),
[[
	return resultFragColor;
}
]]
	}:concat'\n'

	-- used for drawing our 8bpp indexed framebuffer to the screen
--DEBUG:print'mode 1 blitScreenObj'
	self.blitScreenObj = GLSceneObject{
		program = {
			version = app.glslVersion,
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
precision highp sampler2D;
precision highp isampler2D;
precision highp usampler2D;	// needed by #version 300 es

in vec2 tcv;

layout(location=0) out <?=blitFragType?> fragColor;

uniform bool useLighting;

uniform <?=self.framebufferRAM.tex:getGLSLSamplerType()?> framebufferTex;
uniform <?=self.framebufferNormalTex:getGLSLSamplerType()?> framebufferNormalTex;
uniform <?=self.framebufferPosTex:getGLSLSamplerType()?> framebufferPosTex;
uniform <?=app.noiseTex:getGLSLSamplerType()?> noiseTex;
uniform <?=app.lightDepthTex:getGLSLSamplerType()?> lightDepthTex;
uniform <?=app.blobs.palette[1].ramgpu.tex:getGLSLSamplerType()?> paletteTex;

<?=glslCode5551?>

]]..useLightingCode..[[

void main() {
	uint colorIndex = ]]..readTex{
	tex = self.framebufferRAM.tex,
	texvar = 'framebufferTex',
	tc = 'tcv',
	from = 'vec2',
	to = blitFragType,
}..[[.r;
]]..colorIndexToFrag(app, self.framebufferRAM.tex, 'uvec4 ufragColor')..[[
	fragColor = vec4(ufragColor) / 31.;

	if (useLighting) {
		doLighting();
	}
}
]],			{
				app = app,
				self = self,
				app = app,
				blitFragType = blitFragType,
				glslCode5551 = glslCode5551,
			}),
			uniforms = {
				framebufferTex = 0,
				framebufferNormalTex = 1,
				framebufferPosTex = 2,
				noiseTex = 3,
				lightDepthTex = 4,
				paletteTex = 5,
			},
		},
		texs = {
			self.framebufferRAM.tex,
			self.framebufferNormalTex,
			self.framebufferPosTex,
			app.noiseTex,
			app.lightDepthTex,
			app.blobs.palette[1].ramgpu.tex,	-- TODO ... what if we regen the resources?  we have to rebind this right?
		},
		geometry = app.quadGeom,
		-- glUniform()'d every frame
		uniforms = {
			mvProjMat = app.blitScreenView.mvProjMat.ptr,
		},
	}
end

function VideoMode:buildColorOutputAndBlitScreenObj_RGB332()
	local app = self.app
	self.colorIndexToFragColorCode = table{
'uvec4 colorIndexToFragColor(uint colorIndex) {',
	colorIndexToFrag(app, self.framebufferRAM.tex, 'uvec4 palColor')..'\n',
[[
	/*
	palColor is 5 5 5 5
	fragColor is 3 3 2
	so we lose   2 2 3 bits
	so we can dither those in ...
	*/
#if 1	// dithering
	uvec2 ufc = uvec2(gl_FragCoord);

	// 2x2 dither matrix, for the lower 2 bits that get discarded
	// hmm TODO should I do dither discard bitflags?
	uint threshold = (ufc.y & 1u) | (((ufc.x ^ ufc.y) & 1u) << 1u);	// 0-3

	if ((palColor.x & 3u) > threshold) palColor.x+=4u;
	if ((palColor.y & 3u) > threshold) palColor.y+=4u;
	if ((palColor.z & 3u) > threshold) palColor.z+=4u;
	palColor = clamp(palColor, 0u, 31u);
#endif
	uvec4 resultFragColor;
	resultFragColor.r = (palColor.r >> 2) |
				((palColor.g >> 2) << 3) |
				((palColor.b >> 3) << 6);
	resultFragColor.g = 0u;
	resultFragColor.b = 0u;
	// only needed for quadSprite / quadMap:
	resultFragColor.a = (palColor.a << 3) | (palColor.a >> 2);
]],
	-- hmm, idk what to do with blendColorSolid in 8bppIndex
	-- but I don't want the GLSL compiler to optimize away the attr...
	getBlendSolidColorCode('uvec3', 'resultFragColor'),
[[
	return resultFragColor;
}
]],
}:concat'\n'

	-- used for drawing 8bpp framebufferRAMs._256x256x8bpp as rgb332 framebuffer to the screen
--DEBUG:print'mode 2 blitScreenObj'
	self.blitScreenObj = GLSceneObject{
		program = {
			version = app.glslVersion,
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
precision highp sampler2D;
precision highp isampler2D;
precision highp usampler2D;	// needed by #version 300 es

in vec2 tcv;

layout(location=0) out <?=blitFragType?> fragColor;

uniform bool useLighting;

uniform <?=self.framebufferRAM.tex:getGLSLSamplerType()?> framebufferTex;
uniform <?=self.framebufferNormalTex:getGLSLSamplerType()?> framebufferNormalTex;
uniform <?=self.framebufferPosTex:getGLSLSamplerType()?> framebufferPosTex;
uniform <?=app.noiseTex:getGLSLSamplerType()?> noiseTex;
uniform <?=app.lightDepthTex:getGLSLSamplerType()?> lightDepthTex;

]]..useLightingCode..[[

void main() {
	uint rgb332 = ]]..readTex{
	tex = self.framebufferRAM.tex,
	texvar = 'framebufferTex',
	tc = 'tcv',
	from = 'vec2',
	to = blitFragType,
}..[[.r;
	fragColor.r = float(rgb332 & 0x7u) / 7.;
	fragColor.g = float((rgb332 >> 3) & 0x7u) / 7.;
	fragColor.b = float((rgb332 >> 6) & 0x3u) / 3.;
	fragColor.a = 1.;

	if (useLighting) {
		doLighting();
	}
}
]],			{
				app = app,
				self = self,
				blitFragType = blitFragType,
			}),
			uniforms = {
				framebufferTex = 0,
				framebufferNormalTex = 1,
				framebufferPosTex = 2,
				noiseTex = 3,
				lightDepthTex = 4,
			},
		},
		texs = {
			self.framebufferRAM.tex,
			self.framebufferNormalTex,
			self.framebufferPosTex,
			app.noiseTex,
			app.lightDepthTex,
		},
		geometry = app.quadGeom,
		-- glUniform()'d every frame
		uniforms = {
			mvProjMat = app.blitScreenView.mvProjMat.ptr,
		},
	}
end

function VideoMode:buildUberShader()
	local app = self.app

	-- now that we have our .colorIndexToFragColorCode defined,
	-- make our output shader
	-- TODO this also expects the following to be already defined:
	-- app.blobs.palette[1], app.blobs.sheet[1], app.blobs.tilemap[1]

	assert(math.log(paletteSize, 2) % 1 == 0)	-- make sure our palette is a power-of-two

	-- my one and only shader for drawing to FBO (at the moment)
	-- I picked an uber-shader over separate shaders/states, idk how perf will change, so far good by a small but noticeable % (10%-20% or so)
--DEBUG:print('mode '..self.formatDesc..' drawObj')
	self.drawObj = GLSceneObject{
		program = {
			version = app.glslVersion,
			precision = 'best',
			vertexCode = template([[
precision highp sampler2D;
precision highp isampler2D;
precision highp usampler2D;	// needed by #version 300 es

layout(location=0) in vec3 vertex;

/*
This is the texcoord for sprite shaders.
This is the model-space coord (within box min/max) for solid/round shaders.
(TODO for round shader, should this be after transform? but then you'd have to transform the box by mvmat in the fragment shader too ...)
*/
layout(location=1) in vec2 texcoord;

layout(location=2) in vec3 normal;

/*
flat, flags for sprite vs solid etc:

extra.x:
	bit 0/1 =
		00 = use solid path
		01 = use sprite path
		10 = use tilemap path

for solid:
	.x = flags:
		bit 0/1 = render pathway = 00
		bit 2 = draw a solid round quad
		bit 4 = solid shader uses borderOnly
	.y = colorIndex

for sprites:
	.x:
		bit 0/1 = render pathway = 01
		bit 2 = don't use transparentIndex (on means don't test transparency at all ... set this when transparentIndex is OOB)
		bits 3-5 = spriteBit shift
			Specifies which bit to read from at the sprite.
			Only needs 3 bits.
			  (extra.x >> 3) == 0 = read sprite low nibble.
			  (extra.x >> 3) == 4 = read sprite high nibble.

	.y = spriteMask;
		Specifies the mask after shifting the sprite bit
		  0x01u = 1bpp
		  0x03u = 2bpp
		  0x07u = 3bpp
		  0x0Fu = 4bpp
		  0xFFu = 8bpp
		I'm giving this all 8 bits, but honestly I could just represent it as 3 bits and calculate the mask as ((1 << mask) - 1)

	.z = transparentIndex;
		Specifies which colorIndex to use as transparency.
		This is the value of the sprite texel post sprite bit shift & mask, but before applying the paletteIndex shift / high bits.
		If you want fully opaque then just choose an oob color index.

	.w = paletteIndex;
		For now this is an integer added to the 0-15 4-bits of the sprite tex.
		You can set the top 4 bits and it'll work just like OR'ing the high color index nibble.
		Or you can set it to low numbers and use it to offset the palette.
		Should this be high bits? or just an offset to OR? or to add?

for tilemap:
	.x
		bit 0/1 = render pathway = 10
		bit 2 = on = 16x16 tiles, off = 8x8 tiles

	.y = mapIndexOffset lo byte
	.z = mapIndexOffset hi byte (2 bits worth? how many bits should the tilemap index offset care about?)
*/
layout(location=3) in uvec4 extraAttr;

// flat, the bbox of the currently drawn quad, only used for round-rendering of solid-shader
// TODO just use texcoord?
layout(location=4) in vec4 boxAttr;

//GLES3 says we have at least 16 attributes to use ...

// the bbox world coordinates, used with 'boxAttr' for rounding
out vec2 tcv;

flat out vec3 normalv;
flat out uvec4 extra;
flat out vec4 box;

out vec3 clipCoordv;
out vec3 worldCoordv;

uniform mat4 modelMat, viewMat, projMat;

void main() {
	tcv = texcoord;
	normalv = normalize((projMat * (viewMat * (modelMat * vec4(normal, 0.)))).xyz);
	extra = extraAttr;
	box = boxAttr;

	vec4 worldCoord = modelMat * vec4(vertex, 1.);
	worldCoordv.xyz = worldCoord.xyz;

	vec4 viewCoord = viewMat * worldCoord;

	gl_Position = projMat * viewCoord;
	// TODO is this technically "clipCoord"?  because clipping is to [-1,1]^3 volume, which is post-homogeneous transform.
	//  so what's the name of the coordinate system post-projMat but pre-homogeneous-transform?  "projection/projected coordinates" ?
	clipCoordv = gl_Position.xyz;
}
]]),
			fragmentCode = template([[
precision highp sampler2D;
precision highp isampler2D;
precision highp usampler2D;	// needed by #version 300 es

in vec2 tcv;		// framebuffer pixel coordinates before transform , so they are sprite texels

flat in vec3 normalv;
flat in uvec4 extra;	// flags (round, borderOnly), colorIndex
flat in vec4 box;		// x, y, w, h in world coordinates, used for round / border calculations

in vec3 clipCoordv;
in vec3 worldCoordv;

layout(location=0) out <?=fragType?> fragColor;
layout(location=1) out vec4 fragNormal;	// normal xyz, clipCoord.z
layout(location=2) out vec3 fragPos;	// worldCoord.xyz

uniform <?=app.blobs.palette[1].ramgpu.tex:getGLSLSamplerType()?> paletteTex;
uniform <?=app.blobs.sheet[1].ramgpu.tex:getGLSLSamplerType()?> sheetTex;
uniform <?=app.blobs.tilemap[1].ramgpu.tex:getGLSLSamplerType()?> tilemapTex;

uniform vec4 blendColorSolid;
uniform vec4 clipRect;
//uniform vec2 frameBufferSize;

<?=glslCode5551?>

float sqr(float x) { return x * x; }
float lenSq(vec2 v) { return dot(v,v); }

//create an orthornomal basis from one vector that is normalized
mat3 onb1(vec3 n) {
	mat3 m;
	m[2] = n;
	vec3 x = vec3(0., n.z, -n.y); // cross(n, vec3(1., 0., 0.));
	vec3 y = vec3(-n.z, 0., n.x); // cross(n, vec3(0., 1., 0.));
	vec3 z = vec3(n.y, -n.x, 0.); // cross(n, vec3(0., 0., 1.));
	float x2 = dot(x,x);
	float y2 = dot(y,y);
	float z2 = dot(z,z);
	if (x2 > y2) {
		if (x2 > z2) {
			m[0] = x;
		} else {
			m[0] = z;
		}
	} else {
		if (y2 > z2) {
			m[0] = y;
		} else {
			m[0] = z;
		}
	}
	m[0] = normalize(m[0]);
	m[1] = cross(m[2], m[0]);	// should be unit enough
	return m;
}

//create an orthonormal basis from two vectors
// the second, normalized, is used as the 'y' column
// the third is the normalized cross of 'a' and 'b'.
// the first is the cross of the 2nd and 3rd
mat3 onb(vec3 a, vec3 b) {
	mat3 m;
	m[1] = normalize(b);
	m[2] = normalize(cross(a, m[1]));
	m[0] = normalize(cross(m[1], m[2]));
	return m;
}

// https://en.wikipedia.org/wiki/Grayscale#Luma_coding_in_video_systems
const vec3 greyscale = vec3(.2126, .7152, .0722);	// HDTV / sRGB / CIE-1931
//const vec3 greyscale = vec3(.299, .587, .114);	// Y'UV
//const vec3 greyscale = vec3(.2627, .678, .0593);	// HDR TV

<?=modeObj.colorIndexToFragColorCode?>

<?=fragType?> solidShading(vec2 tc) {
	bool round = (extra.x & 4u) != 0u;
	bool borderOnly = (extra.x & 8u) != 0u;
	uint colorIndex = (extra.x >> 8u) & 0xffu;
	<?=fragType?> resultColor = colorIndexToFragColor(colorIndex);

	// TODO think this through
	// calculate screen space epsilon at this point
	//float eps = abs(dFdy(tc.y));
	//float eps = abs(dFdy(tc.x));
	// more solid for 3D
	// TODO ... but adding borders at the 45 degrees...
	float eps = sqrt(lenSq(dFdx(tc)) + lenSq(dFdy(tc)));
	//float eps = length(vec2(dFdx(tc.x), dFdy(tc.y)));
	//float eps = max(abs(dFdx(tc.x)), abs(dFdy(tc.y)));

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
		vec2 delta = tc - center;
		vec2 frac = delta / radius;

		if (abs(delta.y) > abs(delta.x)) {
			// top/bottom quadrant
			float by = radius.y * sqrt(1. - frac.x * frac.x);
			if (delta.y > by || delta.y < -by) discard;
			if (borderOnly) {
				if (delta.y < by-eps && delta.y > -by+eps) discard;
			}
		} else {
			// left/right quadrant
			float bx = radius.x * sqrt(1. - frac.y * frac.y);
			if (delta.x > bx || delta.x < -bx) discard;
			if (borderOnly) {
				if (delta.x < bx-eps && delta.x > -bx+eps) discard;
			}
		}
	} else {
		if (borderOnly) {
			if (tc.x > box.x+eps
				&& tc.x < box.x+box.z-eps
				&& tc.y > box.y+eps
				&& tc.y < box.y+box.w-eps
			) discard;
		}
		// else default solid rect
	}

	return resultColor;
}

<?=fragType?> spriteShading(vec2 tc) {
	uint spriteBit = (extra.x >> 3) & 7u;
	uint spriteMask = (extra.x >> 8) & 0xffu;
	uint transparentIndex = extra.z;

	// shift the oob-transparency 2nd bit up to the 8th bit,
	// such that, setting this means `transparentIndex` will never match `colorIndex & spriteMask`;
	transparentIndex |= (extra.x & 4u) << 6;

	uint paletteIndex = extra.w;

	uint colorIndex = ]]
		..readTex{
			tex = app.blobs.sheet[1].ramgpu.tex,
			texvar = 'sheetTex',
			tc = 'tc',
			from = 'vec2',
			to = 'uvec4',
		}..[[.r;

	colorIndex >>= spriteBit;
	colorIndex &= spriteMask;

	// if you discard based on alpha here then the bilinear interpolation that samples this 4x will cause unnecessary discards
	bool forceTransparent = colorIndex == transparentIndex;

	colorIndex += paletteIndex;
	colorIndex &= 0xFFu;

	<?=fragType?> resultColor = colorIndexToFragColor(colorIndex);
	if (forceTransparent) {
<? if fragType == 'uvec4' then ?>
		resultColor.a = 0u;
<? else ?>
		resultColor.a = 0.;
<? end ?>
	}
	return resultColor;
}

<?=fragType?> tilemapShading(vec2 tc) {
	int mapIndexOffset = int(extra.z);

	//0 = draw 8x8 sprites, 1 = draw 16x16 sprites
	uint draw16Sprites = (extra.x >> 2) & 1u;

	const uint tilemapSizeX = <?=tilemapSize.x?>u;
	const uint tilemapSizeY = <?=tilemapSize.y?>u;

	// convert from input normalized coordinates to tilemap texel coordinates
	// [0, tilemapSize)^2
	ivec2 tci = ivec2(
		int(tc.x * float(tilemapSizeX << draw16Sprites)),
		int(tc.y * float(tilemapSizeY << draw16Sprites))
	);

	// convert to map texel coordinate
	// [0, tilemapSize)^2
	ivec2 tileTC = ivec2(
		(tci.x >> (3u + draw16Sprites)) & 0xFF,
		(tci.y >> (3u + draw16Sprites)) & 0xFF
	);

	//read the tileIndex in tilemapTex at tileTC
	//tilemapTex is R16, so red channel should be 16bpp (right?)
	// how come I don't trust that and think I'll need to switch this to RG8 ...
	int tileIndex = int(]]..readTex{
			tex = app.blobs.tilemap[1].ramgpu.tex,
			texvar = 'tilemapTex',
			tc = 'tileTC',
			from = 'ivec2',
			to = 'uvec4',
		}..[[.r);

	tileIndex += mapIndexOffset;

	//[0, 31)^2 = 5 bits for tile tex sprite x, 5 bits for tile tex sprite y
	ivec2 tileIndexTC = ivec2(
		tileIndex & 0x1F,				// tilemap bits 0..4
		(tileIndex >> 5) & 0x1F			// tilemap bits 5..9
	);
	int palHi = (tileIndex >> 10) & 7;	// tilemap bits 10..12
	int rot = (tileIndex >> 14) & 3;		// tilemap bits 14..15 = rotation
	if (rot == 1) {
		tci = ivec2(tci.y, ~tci.x);
	} else if (rot == 2) {
		tci = ivec2(~tci.x, ~tci.y);
	} else if (rot == 3) {
		tci = ivec2(~tci.y, tci.x);
	}
	if (((tileIndex >> 13) & 1) != 0) {
		tci.x = ~tci.x;	// tilemap bit 13 = hflip
	}

	int mask = (1 << (3u + draw16Sprites)) - 1;
	// [0, spriteSize)^2
	ivec2 tileTexTC = ivec2(
		(tci.x & mask) ^ (tileIndexTC.x << 3),
		(tci.y & mask) ^ (tileIndexTC.y << 3)
	);

	// sheetTex is R8 indexing into our palette ...
	uint colorIndex = ]]..readTex{
			tex = app.blobs.sheet[1].ramgpu.tex,
			texvar = 'sheetTex',
			tc = 'tileTexTC',
			from = 'ivec2',
			to = 'uvec4',
		}..[[.r;

	colorIndex += uint(palHi) << 5;

	return colorIndexToFragColor(colorIndex);
}

<?=fragType?> directShading(vec2 tc) {
	return <?=fragType?>(vec4(]]
			..readTex{
				tex = app.blobs.sheet[1].ramgpu.tex,
				texvar = 'sheetTex',
				tc = 'tc',
				from = 'vec2',
				to = fragType,
			}
..')'
..(
	--fragType == 'vec4' and
	'/ 255.'
	--or ''
)..[[);
}

void main() {
	if (gl_FragCoord.x < clipRect.x ||
		gl_FragCoord.y < clipRect.y ||
		gl_FragCoord.x >= clipRect.x + clipRect.z + 1. ||
		gl_FragCoord.y >= clipRect.y + clipRect.w + 1.
	) {
		discard;
	}

	uvec2 uFragCoord = uvec2(gl_FragCoord);
	uint threshold = (uFragCoord.y >> 1) & 1u
		| ((uFragCoord.x ^ uFragCoord.y) & 2u)
		| ((uFragCoord.y & 1u) << 2)
		| (((uFragCoord.x ^ uFragCoord.y) & 1u) << 3);
	uint dither = extra.y;
	if ((dither & (1u << threshold)) != 0u) discard;

	uint pathway = extra.x & 3u;

	float bumpHeight = -1.;

	// solid shading pathway
	if (pathway == 0u) {

		fragColor = solidShading(tcv);

		bumpHeight = dot(fragColor.xyz, greyscale);

	// sprite shading pathway
	} else if (pathway == 1u) {

#if 0	// color and bump height LINEAR ... gotta do it here, can't do it in mag filter texture because it's a u8 texture (TODO change to a GL_RED texture?  but then no promises on the value having 8 bits (but it's 2025, who am I kidding, it'll have 8 bits))

		vec2 size = textureSize(sheetTex, 0);
		vec2 stc = tcv.xy * size - .5;
		vec2 ftc = floor(stc);
		vec2 fp = fract(stc);

		// TODO make sure this doesn't go over the sprite edge ...
		// but how to tell how big the sprite is?
		// hmm I could use the 'box' to store the texcoord boundary ...
		<?=fragType?> fragColorLL = spriteShading((ftc + vec2(0.5, 0.5)) / size);
		<?=fragType?> fragColorRL = spriteShading((ftc + vec2(1.5, 0.5)) / size);
		<?=fragType?> fragColorLR = spriteShading((ftc + vec2(0.5, 1.5)) / size);
		<?=fragType?> fragColorRR = spriteShading((ftc + vec2(1.5, 1.5)) / size);

		fragColor = mix(
			mix(fragColorLL, fragColorRL, fp.x),
			mix(fragColorLR, fragColorRR, fp.x), fp.y
		);

		bumpHeight = dot(fragColor.xyz, greyscale);

#else
		fragColor = spriteShading(tcv);

#if 0	// bump height based on sprite sheet sampler which is NEAREST:
		bumpHeight = dot(fragColor.xyz, greyscale);
#else	// linear sampler in-shader for bump height / lighting only:
		vec2 size = textureSize(sheetTex, 0);
		vec2 stc = tcv.xy * size - .5;
		vec2 ftc = floor(stc);
		vec2 fp = fract(stc);

		<?=fragType?> fragColorLL = spriteShading((ftc + vec2(0.5, 0.5)) / size);
		<?=fragType?> fragColorRL = spriteShading((ftc + vec2(1.5, 0.5)) / size);
		<?=fragType?> fragColorLR = spriteShading((ftc + vec2(0.5, 1.5)) / size);
		<?=fragType?> fragColorRR = spriteShading((ftc + vec2(1.5, 1.5)) / size);

		float bumpHeightLL = dot(fragColorLL.xyz, greyscale);
		float bumpHeightRL = dot(fragColorRL.xyz, greyscale);
		float bumpHeightLR = dot(fragColorLR.xyz, greyscale);
		float bumpHeightRR = dot(fragColorRR.xyz, greyscale);

		bumpHeight = mix(
			mix(bumpHeightLL, bumpHeightRL, fp.x),
			mix(bumpHeightLR, bumpHeightRR, fp.x), fp.y
		);
#endif
#endif

	} else if (pathway == 2u) {

		fragColor = tilemapShading(tcv);

		bumpHeight = dot(fragColor.xyz, greyscale);

	// I had an extra pathway and I didn't know what to use it for
	// and I needed a RGB option for the cart browser (maybe I should just use this for all the menu system and just skip on the menu-palette?)
	} else if (pathway == 3u) {

		fragColor = directShading(tcv);

		bumpHeight = dot(fragColor.xyz, greyscale);

	}	// pathway


<? if fragType == 'uvec4' then ?>
	if (fragColor.a == 0u) disscard;
<? else ?>
	if (fragColor.a < .5) discard;
<? end ?>


// position

	fragPos.xyz = worldCoordv.xyz;


// lighting:

	// TODO lighting variables:
	const float spriteNormalExhaggeration = 8.;
	const float normalScreenExhaggeration = 1.;	// apply here or in the blitscreen shader?

#if 0	// normal from flat sided objs
	fragNormal.xyz = normalv;

#elif 0	// show sprite normals only
	bumpHeight *= spriteNormalExhaggeration;
	mat3 spriteBasis = onb(
		vec3(1., 0., dFdx(bumpHeight)),
		vec3(0., 1., dFdx(bumpHeight)));
	fragNormal.xyz = spriteBasis[2];

#else	// rotate sprite normals onto frag normal plane

	// calculate this before any discards ... or can we?
	// calculate this from magfilter=linear lookup for the texture (and do color magfilter=nearest) ... or can we?)
	// if we are going to discard then make sure the sprite bumpmap falls off ...
	bumpHeight *= spriteNormalExhaggeration;

	//glsl matrix index access is based on columns
	//so its index notation is reversed from math index notation.
	// spriteBasis[j][i] = spriteBasis_ij = d(bumpHeight)/d(fragCoord_j)
	mat3 spriteBasis = onb(
		vec3(1., 0., dFdx(bumpHeight)),
		vec3(0., 1., dFdx(bumpHeight)));

	// modelBasis[j][i] = modelBasis_ij = d(vertex_i)/d(fragCoord_j)
	mat3 modelBasis = onb1(normalv);

	//result should be d(bumpHeight)/d(vertex_j)
	// = d(bumpHeight)/d(fragCoord_k) * d(fragCoord_k)/d(vertex_j)
	// = d(bumpHeight)/d(fragCoord_k) * inv(d(vertex_j)/d(fragCoord_k))
	// = spriteBasis * transpose(modelBasis)
	//modelBasis = spriteBasis * transpose(modelBasis);
	//fragNormal.xyz = transpose(modelBasis)[2];
	fragNormal.xyz = (modelBasis * transpose(spriteBasis))[2];
#endif

	// TODO why ...
	fragNormal.xy = -fragNormal.xy;

	fragNormal.z *= normalScreenExhaggeration;
	fragNormal.xyz = normalize(fragNormal.xyz);

	// TODO just use the depth buffer as a texture instead of re-copying it here?
	//  if I did I'd get more bits of precision ...
	//  but this is easier/lazier.
	fragNormal.w = clipCoordv.z;
	//fragNormal.w = gl_FragDepth;
}
]],			{
				app = app,
				modeObj = self,
				fragType = self.framebufferRAM.tex:getGLSLFragType(),
				glslCode5551 = glslCode5551,
				tilemapSize = tilemapSize,
			}),
			uniforms = {
				paletteTex = 0,
				sheetTex = 1,
				tilemapTex = 2,
			},
		},
		geometry = {
			mode = gl.GL_TRIANGLES,
			count = 0,
		},
		attrs = {
			vertex = {
				type = gl.GL_FLOAT,
				size = 3,	-- 'dim' in buffer
				buffer = app.vertexBufGPU,
				stride = ffi.sizeof'Numo9Vertex',
				offset = ffi.offsetof('Numo9Vertex', 'vertex'),
			},
			texcoord = {
				type = gl.GL_FLOAT,
				size = 2,
				buffer = app.vertexBufGPU,
				stride = ffi.sizeof'Numo9Vertex',
				offset = ffi.offsetof('Numo9Vertex', 'texcoord'),
			},
			normal = {
				type = gl.GL_FLOAT,
				size = 3,
				buffer = app.vertexBufGPU,
				stride = ffi.sizeof'Numo9Vertex',
				offset = ffi.offsetof('Numo9Vertex', 'normal'),
			},
			-- 8 bytes = 32 bit so I can use memset?
			extraAttr = {
				type = gl.GL_UNSIGNED_SHORT,
				size = 4,
				--divisor = 3,
				buffer = app.vertexBufGPU,
				stride = ffi.sizeof'Numo9Vertex',
				offset = ffi.offsetof('Numo9Vertex', 'extra'),
			},
			-- 16 bytes =  128-bit ...
			boxAttr = {
				size = 4,
				type = gl.GL_FLOAT,
				--divisor = 3,	-- 6 honestly ...
				buffer = app.vertexBufGPU,
				stride = ffi.sizeof'Numo9Vertex',
				offset = ffi.offsetof('Numo9Vertex', 'box'),
			},
		},
	}
end


-- maybe this should be its own file?
-- maybe I'll merge RAMGPU with BlobImage ... and then make framebuffer a blob of its own (nahhhh ...) and then I won't need this to be its own file?
function AppVideo:initVideoModes()
	-- I chose a few fixed-size common aspect-ratio modes based on what fits in 128k and is tile-aligned
	self.videoModes = table()

	local function addVideoModeFormat(args)
		args.app = self
		local modeObj = VideoMode(args)
		-- zero-based insert
		if #self.videoModes == 0
		and not self.videoModes[0]
		then
			self.videoModes[0] = modeObj
		else
			self.videoModes[#self.videoModes+1] = modeObj
		end
	end

	-- 16bpp upper bound resolution:
	for _,wh in ipairs{
		{256, 256},	-- 1:1
		{272, 217},	-- 5:4
		{288, 216},	-- 4:3
		{304, 202},	-- 3:2
		{320, 200},	-- 8:5
		{320, 192},	-- 5:3
		{336, 189},	-- 16:9
		{336, 177},	-- 17:9
		{352, 176},	-- 2:1
		{384, 164},	-- 21:9
	} do
		for _,format in ipairs{'RGB565', '8bppIndex', 'RGB332'} do
			-- the 1:1 is added above ...
			addVideoModeFormat{
				width = wh[1],
				height = wh[2],
				format = format,
			}
		end
	end
	-- 8bpp upper bound resolutions:
	for _,wh in ipairs{
		{352, 352},	-- 1:1
		{400, 320},	-- 5:4
		{416, 312},	-- 4:3
		{432, 288},	-- 3:2
		{448, 280},	-- 8:5
		{464, 278},	-- 5:3
		{480, 270},	-- 16:9
		{496, 262},	-- 17:9
		{512, 256},	-- 2:1
		{544, 233},	-- 21:9
	} do
		for _,format in ipairs{'8bppIndex', 'RGB332'} do
			addVideoModeFormat{
				width = wh[1],
				height = wh[2],
				format = format,
			}
		end
	end
	--[[ TODO 4bpp
	-- but there's no GL formats for 4bpp ...
	-- and I'd do separate 4bpp at a time to an 8bpp buffer
	-- but it looks like GL got rid of its bitmasking features (did it?)
	for _,wh in ipairs{
		{512, 512},
		{560, 448},
		{576, 432},
		{624, 416},
		{640, 400},
		{656, 393},
		{672, 378},
		{688, 364},
		{720, 360},
		{768, 329},
	} do
		addVideoModeFormat{
			width = wh[1],
			height = wh[2],
			format = '4bppIndex',
		}
	end
	-- ... but that means GL output writing to multiple bytes per single pixel ...
	-- I could do it with a 2nd pass to combine bit output ...
	--]]
	-- TODO 2bpp 1bpp


	-- [[ hmmmmm native-resolution?  but requires lots of work-arounds for address-space , framebuffer, etc
	local videoModeNative = VideoMode{
		app = self,
		width = self.width,
		height = self.height,
		format = 'RGB565',

		-- i.e. don't cache or use cached fbo's, cleanup, allow resize, etc.
		-- ... hmm, how long before I just let the user pick any mode they want ...
		useNativeOutput = true,
	}
	videoModeNative.formatDesc = 'Native_'..videoModeNative.format
	self.videoModes[255] = videoModeNative
	local app = self
	function videoModeNative:build()
		self.width = app.width
		self.height = app.height

		VideoMode.build(self)

		app.ram.screenWidth = self.width
		app.ram.screenHeight = self.height
		app:onFrameBufferSizeChange()
	end
	--]]

	-- The following are caches used by the videomodes and get populated per calls to VideoMode:build()

	-- hmm, is there any reason why like-format buffers can't use the same gl texture?
	-- also, is there any reason I'm building all modes up front?  why not wait until they are requested?

	-- self.fbos['_'..width..'x'..height] = FBO with depth attachment.
	-- for FBO's size is all that matters, right? not format right?
	self.fbos = {}

	-- ex: framebuffer is 256 x 144 x 16bpp rgb565
	--self.framebufferRAMs._256x144xRGB565
	self.framebufferRAMs = {}
	self.framebufferNormalTexs = {}
	self.framebufferPosTexs = {}
	self.framebufferDepthTexs = {}
	self.framebufferLightDepthTexs = {}
end

-- called upon app init
-- 'self' == app
function AppVideo:initVideo()
	self.glslVersion = cmdline.glsl or 'latest'

	--[[
	create these upon resetVideo() or at least upon loading a new ROM, and make a sprite/tile sheet per blob
	but I am still using the texture specs for my shader creation
	and my shader creation is done once
	so until then, just resize them here

	hmm, how to reduce texture #s as much as possible
	Can I get by binding everything everywhere overall?
	GLES3 GL_MAX_TEXTURE_SIZE must be at least 2048, so 2048x2048,
	so if our textures are restricted to 256x256 then I can save 8x8 of the 256x256 texs in just one = 64 sprite/tile sheets in just one tex ...
	... but uploading would require some row interleaving ...
	... but it wouldn't if I just stored a single 256 x 2048 texture with just 8 nested textures ...
	... or it wouldn't if I just did the texture memory unraveling in-shader (and stored it as garbage in memory)
	... oh yeah I can get even more space from using a bigger format ... like 16/32-bit RGB/A textures ...
	... and that's just a single texture for GLES3, if we want to deal with multiple bound textures we have
		GL_MAX_TEXTURE_IMAGE_UNITS is guaranteed to be at least 16

	What are allll our textures?
	- paletteMenuTex					256x1		2 bytes ... GL_R16UI
	- fontMenuTex						256x8		1 byte  ... GL_R8UI
	- checkerTex						4x4			3 bytes ... GL_RGB+GL_UNSIGNED_BYTE
	- framebufferRAMs._256x256xRGB565	256x256		2 bytes ... GL_RGB565+GL_UNSIGNED_SHORT_5_6_5
	- framebufferRAMs._256x256x8bpp		256x256		1 byte  ... GL_R8UI
	- blobs:
	sheet:	 	BlobSheet 				256x256		1 byte  ... GL_R8UI
	tilemap:	BlobTilemap				256x256		2 bytes ... GL_R16UI
	palette:	BlobPalette				256x1		2 bytes ... GL_R16UI
	font:		BlobFont				256x8		1 byte  ... GL_R8UI

	I could put sheetRAM on one tex, tilemapRAM on another, paletteRAM on another, fontRAM on another ...
	... and make each be 256 cols wide ... and as high as there are blobs ...
	... but if 2048 is the min size, then 256x2048 = 8 sheets worth, and if we use sprite & tilemap then that's 4 ...
	... or I could use a 512 x 2048 tex ... and just delegate what region on the tex each sheet gets ...
	... or why not, use all 2048 x 2048 = 64 different 256x256 sheets, and sprite/tile means 32 blob max ...
	I could make a single GL tex, and share regions on it between different BlobSheet's...
	This would break with the tex.ptr == image.ptr model ... no more calling :subimage() without specifying regions ...

	Should I just put the whole cartridge on the GPU and keep it sync'd at all times?
	How often do I modify the cartridge anyways?
	--]]
	self:resizeRAMGPUs()

	-- off by default
	self.ram.useHardwareLighting = 0

	ffi.fill(self.ram.framebuffer, ffi.sizeof(self.ram.framebuffer), 0)

	-- TODO would be nice to have a 'useVec' sort of thing per shader for interleaved arrays like this ...
	-- this is here and in farmgame/app.lua
	self.vertexBufCPU = vector'Numo9Vertex'
	self.vertexBufGPU = GLArrayBuffer{
		size = ffi.sizeof'Numo9Vertex' * self.vertexBufCPU.capacity,
		data = self.vertexBufCPU.v,
		usage = gl.GL_DYNAMIC_DRAW,
	}:unbind()

	-- keep menu/editor gfx separate of the fantasy-console
	do
		-- palette is 256 x 1 x 16 bpp (5:5:5:1)
		local data = ffi.new('uint16_t[?]', 256)
		resetPalette(data)
		self.paletteMenuTex = GLTex2D{
			width = paletteSize,
			height = 1,
			internalFormat = internalFormat5551,
			format = format5551,
			type = type5551,
			wrap = {
				s = gl.GL_CLAMP_TO_EDGE,
				t = gl.GL_CLAMP_TO_EDGE,
			},
			minFilter = gl.GL_NEAREST,
			magFilter = gl.GL_NEAREST,
			data = data,
		}:unbind()

		-- font is 256 x 8 x 8 bpp, each 8x8 in each bitplane is a unique letter
		local fontData = ffi.new('uint8_t[?]', fontInBytes)
		resetFont(fontData, 'font.png')
		self.fontMenuTex = GLTex2D{
			internalFormat = texInternalFormat_u8,
			format = GLTex2D.formatInfoForInternalFormat[texInternalFormat_u8].format,
			type = gl.GL_UNSIGNED_BYTE,
			width = fontImageSize.x,
			height = fontImageSize.y,
			wrap = {
				s = gl.GL_CLAMP_TO_EDGE,
				t = gl.GL_CLAMP_TO_EDGE,
			},
			minFilter = gl.GL_NEAREST,
			magFilter = gl.GL_NEAREST,
			data = fontData,
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

	-- building modes needs quadGeom to be created
	self:initVideoModes()

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

	-- a noise tex, maybe using for SSAO
	do
		local image = Image(256, 256, 3, 'uint8_t')
		for i=0,image:getBufferSize()-1 do
			image.buffer[i] = math.random(0,255)
		end
		self.noiseTex = GLTex2D{
			type = gl.GL_UNSIGNED_BYTE,
			format = gl.GL_RGB,
			internalFormat = gl.GL_RGB,
			magFilter = gl.GL_NEAREST,
			minFilter = gl.GL_NEAREST,
			wrap = {
				s = gl.GL_REPEAT,
				t = gl.GL_REPEAT,
			},
			image = image,
		}:unbind()
	end

	if useDirectionalShadowmaps then
		-- now allocate a GL_TEXTURE_CUBE_ARRAY for our point lights
		-- and a GL_TEXTURE_2D_ARRAY for our directional lights
		-- size is lightmap resolution x max # of lights
		-- lets just do a single directional light for starters
		self.lightDepthTex = GLTex2D{
			width = dirLightMapSize.x,
			height = dirLightMapSize.y,
			internalFormat = gl.GL_DEPTH_COMPONENT,
			format = gl.GL_DEPTH_COMPONENT,
			type = gl.GL_FLOAT,
			minFilter = gl.GL_NEAREST,
			magFilter = gl.GL_NEAREST,
			wrap = {
				s = gl.GL_CLAMP_TO_EDGE,
				t = gl.GL_CLAMP_TO_EDGE,
			},
		}:unbind()

		local quatd = require 'vec-ffi.quatd'
		local View = require 'glapp.view'
		self.lightView = View()
		-- lightmap has to encompass the visible scene so *shrug* how big to make it
		-- too big = blobbing up lightmap texels
		-- too small = a directional spotlight
		-- aha hence "CSM" technique ... which is basically, multiple ortho dir lights of different ortho volume sizes.
		-- this has gotta be game dependent ...
		--[[ frustum light / spotlight
		self.lightView.znear = 1
		self.lightView.zfar = 200
		--]]
		-- [[ ortho light / directional light
		self.lightView.ortho = true
		self.lightView.znear = -4
		self.lightView.zfar = 64
		self.lightView.orthoSize = 40
		--]]
		-- 32 is half width, 24 is half length
		self.lightView.angle = 
			--quatd():fromAngleAxis(0, 0, 1, 45)
			quatd():fromAngleAxis(1, 0, 0, 60)
		self.lightView.orbit:set(32, 24, 0)
		self.lightView.pos = self.lightView.orbit + 32 * self.lightView.angle:zAxis()
		self.lightView:setup(self.lightDepthTex.width / self.lightDepthTex.height)

		self.lightmapFB = GLFBO{
			width = dirLightMapSize.x,
			height = dirLightMapSize.y,
		}
		self.lightmapFB:bind()
		self.lightDepthTex:bind()
		gl.glFramebufferTexture2D(gl.GL_FRAMEBUFFER, gl.GL_DEPTH_ATTACHMENT, gl.GL_TEXTURE_2D, self.lightDepthTex.id, 0)
		self.lightDepthTex:unbind()
		self.lightmapFB:unbind()
	end

--DEBUG:self.triBuf_flushCallsPerFrame = 0
--DEBUG:self.triBuf_flushSizes = {}
--DEBUG(flushtrace): self.triBuf_flushSizesPerTrace = {}

	self:resetVideo()
end

function AppVideo:triBuf_flush()
--DEBUG: self.triBuf_flushCallsPerFrame = self.triBuf_flushCallsPerFrame + 1
	local sceneObj = self.triBuf_sceneObj
	if not sceneObj then return end	-- for some calls called before this is even created ...

	-- flush the old
	local n = #self.vertexBufCPU
	if n == 0 then return end

--DEBUG: self.triBuf_flushSizes[n] = (self.triBuf_flushSizes[n] or 0) + 1
--DEBUG(flushtrace): local tb = debug.traceback()
--DEBUG(flushtrace): self.triBuf_flushSizesPerTrace[tb] = (self.triBuf_flushSizesPerTrace[tb] or 0) + 1

	--[[ resize if capacity changed, upload
	for name,attr in pairs(sceneObj.attrs) do
		attr.buffer:endUpdate()
	end
	--]]

	-- bind textures
	-- TODO bind here or elsewhere to prevent re-binding of the same texture ...
	self.lastTilemapTex:bind(2)
	self.lastSheetTex:bind(1)
	self.lastPaletteTex:bind(0)

	sceneObj.geometry.count = n

	local program = sceneObj.program
	program:use()

	self.vertexBufGPU:bind()
	if self.vertexBufCPU.capacity ~= self.vertexBufCPULastCapacity then
		self.vertexBufGPU:setData{
			data = self.vertexBufCPU.v,
			count = self.vertexBufCPU.capacity,
			size = ffi.sizeof'Numo9Vertex' * self.vertexBufCPU.capacity,
		}
	else
--DEBUG:assert.eq(self.vertexBufGPU.data, self.vertexBufCPU.v)
		self.vertexBufGPU:updateData(0, self.vertexBufCPU:getNumBytes())
	end

	sceneObj:enableAndSetAttrs()
	sceneObj.geometry:draw()

	if useDirectionalShadowmaps
	and self.ram.useHardwareLighting ~= 0
	then
		-- now - if we're using light - also draw the geom to the lightmap
		-- that means updating uniforms every render regardless ...
		if self.inUpdateCallback then
			-- should always be true
			self.fb:unbind()
		end
		self.lightmapFB:bind()

		gl.glViewport(0, 0, self.lightmapFB.width, self.lightmapFB.height)

		program:setUniform('modelMat', ident4x4.ptr)
		program:setUniform('viewMat', self.lightView.mvMat.ptr)
		program:setUniform('projMat', self.lightView.projMat.ptr)
		gl.glUniform4f(program.uniforms.clipRect.loc, 0, 0, dirLightMapSize.x, dirLightMapSize.y)

		sceneObj.geometry:draw()

		program:setUniform('modelMat', self.ram.modelMat)
		program:setUniform('viewMat', self.ram.viewMat)
		program:setUniform('projMat', self.ram.projMat)
		gl.glUniform4f(program.uniforms.clipRect.loc, self:getClipRect())

		--gl.glViewport(0, 0, self.fb.width, self.fb.height)
		gl.glViewport(0, 0, self.ram.screenWidth, self.ram.screenHeight)

		self.lightmapFB:unbind()
		if self.inUpdateCallback then
			self.fb:bind()
		end
	end

	sceneObj:disableAttrs()

	-- reset the vectors and store the last capacity
	self.vertexBufCPULastCapacity = self.vertexBufCPU.capacity
	self.vertexBufCPU:resize(0)

-- ??? TODO not this because it's forcing more flushes?
	self.lastPaletteTex = nil
	self.lastSheetTex = nil
end

-- setup texture state and uniforms
function AppVideo:triBuf_prepAddTri(
	paletteTex,
	sheetTex,
	tilemapTex
)
	if self.lastPaletteTex ~= paletteTex
	or self.lastSheetTex ~= sheetTex
	or self.lastTilemapTex ~= tilemapTex
	then
		self:triBuf_flush()
		self.lastPaletteTex = paletteTex
		self.lastSheetTex = sheetTex
		self.lastTilemapTex = tilemapTex
	end

	-- upload uniforms to GPU before adding new tris ...
	local program = self.triBuf_sceneObj.program
	if self.modelMatDirty
	or self.viewMatDirty
	or self.projMatDirty
	or self.clipRectDirty
	or self.blendColorDirty
	or self.frameBufferSizeUniformDirty
	then
		program:use()
		if self.modelMatDirty then
			program:setUniform('modelMat', self.ram.modelMat)
			self.modelMatDirty = false
		end
		if self.viewMatDirty then
			program:setUniform('viewMat', self.ram.viewMat)
			self.viewMatDirty = false
		end
		if self.projMatDirty then
			program:setUniform('projMat', self.ram.projMat)
			self.projMatDirty = false
		end
		if self.clipRectDirty then
			gl.glUniform4f(
				program.uniforms.clipRect.loc,
				self:getClipRect())
			self.clipRectDirty = false
		end
		if self.blendColorDirty then
			local blendSolidR, blendSolidG, blendSolidB = rgba5551_to_rgba8888_4ch(self.ram.blendColor)
			local blendSolidA = self.blendColorA * 255
			gl.glUniform4f(
				program.uniforms.blendColorSolid.loc,
				blendSolidR/255,
				blendSolidG/255,
				blendSolidB/255,
				blendSolidA/255)
			self.blendColorDirty = false
		end
		--[[ TODO not sure just yet
		if self.frameBufferSizeUniformDirty then
			gl.glUniform2f(
				program.uniforms.frameBufferSize.loc,
				self.ram.screenWidth,
				self.ram.screenHeight)
			self.frameBufferSizeUniformDirty = false
		end
		--]]
		program:useNone()
	end
end

local function calcNormalForTri(
	x1, y1, z1,
	x2, y2, z2,
	x3, y3, z3
)
	local dax, day, daz = x2 - x1, y2 - y1, z2 - z1
	local dbx, dby, dbz = x3 - x2, y3 - y2, z3 - z2
	-- don't bother normalize it, the shader will
	return
		day * dbz - daz * dby,
		daz * dbx - dax * dbz,
		dax * dby - day * dbx
end

function AppVideo:triBuf_addTri(
	paletteTex,
	sheetTex,
	tilemapTex,

	-- per vtx
	x1, y1, z1, u1, v1,
	x2, y2, z2, u2, v2,
	x3, y3, z3, u3, v3,

	-- divisor
	normalX, normalY, normalZ,
	extraX, extraY, extraZ, extraW,
	boxX, boxY, boxW, boxH
)
	local sceneObj = self.triBuf_sceneObj

	local vertex = sceneObj.attrs.vertex.buffer.vec
	local texcoord = sceneObj.attrs.texcoord.buffer.vec
	local normal = sceneObj.attrs.normal.buffer.vec
	local extraAttr = sceneObj.attrs.extraAttr.buffer.vec
	local boxAttr = sceneObj.attrs.boxAttr.buffer.vec

	self:triBuf_prepAddTri(paletteTex, sheetTex, tilemapTex)

	-- push
	local v
	v = self.vertexBufCPU:emplace_back()
	v.vertex.x, v.vertex.y, v.vertex.z = x1, y1, z1
	v.texcoord.x, v.texcoord.y = u1, v1
	v.normal.x, v.normal.y, v.normal.z = normalX, normalY, normalZ
	v.extra.x, v.extra.y, v.extra.z, v.extra.w = extraX, extraY, extraZ, extraW
	v.box.x, v.box.y, v.box.z, v.box.w = boxX, boxY, boxW, boxH

	v = self.vertexBufCPU:emplace_back()
	v.vertex.x, v.vertex.y, v.vertex.z = x2, y2, z2
	v.texcoord.x, v.texcoord.y = u2, v2
	v.normal.x, v.normal.y, v.normal.z = normalX, normalY, normalZ
	v.extra.x, v.extra.y, v.extra.z, v.extra.w = extraX, extraY, extraZ, extraW
	v.box.x, v.box.y, v.box.z, v.box.w = boxX, boxY, boxW, boxH

	v = self.vertexBufCPU:emplace_back()
	v.vertex.x, v.vertex.y, v.vertex.z = x3, y3, z3
	v.texcoord.x, v.texcoord.y = u3, v3
	v.normal.x, v.normal.y, v.normal.z = normalX, normalY, normalZ
	v.extra.x, v.extra.y, v.extra.z, v.extra.w = extraX, extraY, extraZ, extraW
	v.box.x, v.box.y, v.box.z, v.box.w = boxX, boxY, boxW, boxH
end

function AppVideo:onModelMatChange()
	self:triBuf_flush()	-- make sure the current tri buf is drawn with the current modelMat
	self.modelMatDirty = true
end

function AppVideo:onViewMatChange()
	self:triBuf_flush()	-- make sure the current tri buf is drawn with the current viewMat
	self.viewMatDirty = true
end

function AppVideo:onProjMatChange()
	self:triBuf_flush()	-- make sure the current tri buf is drawn with the current projMat
	self.projMatDirty = true
end

function AppVideo:onClipRectChange()
	self:triBuf_flush()
	self.clipRectDirty = true
end

-- call this when ram.blendColor changes
-- or when self.blendColorA changes
-- or upon setVideoMode
function AppVideo:onBlendColorChange()
	self:triBuf_flush()
	self.blendColorDirty = true
end

function AppVideo:onFrameBufferSizeChange()
	self:triBuf_flush()
	self.frameBufferSizeUniformDirty = true
end

-- build RAMGPU's of BlobImage's if they aren't already there
-- update their address if they are there
function AppVideo:resizeRAMGPUs()
--DEBUG:print'AppVideo:resizeRAMGPUs'
	for _,blob in ipairs(self.blobs.sheet) do
		blob:buildRAMGPU(self)
	end
	for _,blob in ipairs(self.blobs.tilemap) do
		blob:buildRAMGPU(self)
	end
	for _,blob in ipairs(self.blobs.palette) do
		blob:buildRAMGPU(self)
	end
	for _,blob in ipairs(self.blobs.font) do
		blob:buildRAMGPU(self)
	end
--DEBUG:print'AppVideo:resizeRAMGPUs done'
end

function AppVideo:allRAMRegionsExceptFramebufferCheckDirtyGPU()
	for _,blob in ipairs(self.blobs.sheet) do
		blob.ramgpu:checkDirtyGPU()
	end
	for _,blob in ipairs(self.blobs.tilemap) do
		blob.ramgpu:checkDirtyGPU()
	end
	for _,blob in ipairs(self.blobs.palette) do
		blob.ramgpu:checkDirtyGPU()
	end
	for _,blob in ipairs(self.blobs.font) do
		blob.ramgpu:checkDirtyGPU()
	end
end

function AppVideo:allRAMRegionsCheckDirtyGPU()
	-- TODO this current method updates *all* GPU/CPU framebuffer textures
	-- but if I provide more options, I'm only going to want to update the one we're using (or things would be slow)
	for k,v in pairs(self.framebufferRAMs) do
		v:checkDirtyGPU()
	end
	self:allRAMRegionsExceptFramebufferCheckDirtyGPU()
end

-- flush anything from gpu to cpu
-- TODO this is duplciating the above
-- but it only flushes the *current* framebuffer
-- TODO when is each used???
function AppVideo:checkDirtyGPU()
	self:allRAMRegionsExceptFramebufferCheckDirtyGPU()
	self.framebufferRAM:checkDirtyGPU()
end


function AppVideo:allRAMRegionsCheckDirtyCPU()
	-- TODO this current method updates *all* GPU/CPU framebuffer textures
	-- but if I provide more options, I'm only going to want to update the one we're using (or things would be slow)
	for _,v in pairs(self.framebufferRAMs) do
		v:checkDirtyCPU()
	end
	self:allRAMRegionsExceptFramebufferCheckDirtyGPU()
end

-- TODO most the time I call this after I call :copyBlobsToRAM
-- so what should this do exactly vs what should that do?
function AppVideo:resetVideo()
--DEBUG:print'App:resetVideo'
	-- remake the textures every time the # blobs changes thanks to loadRAM()
	self:resizeRAMGPUs()

	-- flush all before resetting RAM addrs in case any are pointed to the addrs' location
	-- do the framebuffers explicitly cuz typically 'checkDirtyGPU' just does the current one
	-- and also because the first time resetVideo() is called, the video mode hasn't been set yet, os the framebufferRAM hasn't been assigned yet
	self:allRAMRegionsCheckDirtyGPU()

	-- TODO how should tehse work if I'm using flexible # blobs and that means not always enough?
	local spriteSheetAddr = self.blobs.sheet[1] and self.blobs.sheet[1].addr or 0
	local tileSheetAddr = self.blobs.sheet[2] and self.blobs.sheet[2].addr or 0
	local tilemapAddr = self.blobs.tilemap[1] and self.blobs.tilemap[1].addr or 0
	local paletteAddr = self.blobs.palette[1] and self.blobs.palette[1].addr or 0
	local fontAddr = self.blobs.font[1] and self.blobs.font[1].addr or 0

	-- reset these
	self.ram.framebufferAddr = framebufferAddr
	self.ram.spriteSheetAddr = spriteSheetAddr
	self.ram.tileSheetAddr = tileSheetAddr
	self.ram.tilemapAddr = tilemapAddr
	self.ram.paletteAddr = paletteAddr
	self.ram.fontAddr = fontAddr
	-- and these, which are the ones that can be moved

	-- reset all framebufferRAM objects' addresses:
	for _,v in pairs(self.framebufferRAMs) do
		v:updateAddr(framebufferAddr)
	end

	local sheetRAM = self.blobs.sheet[1].ramgpu
	if sheetRAM then sheetRAM:updateAddr(spriteSheetAddr) end
	local tileSheetRAM = self.blobs.sheet[2].ramgpu
	if tileSheetRAM then tileSheetRAM:updateAddr(tileSheetAddr) end
	local tilemapRAM = self.blobs.tilemap[1].ramgpu
	if tilemapRAM then tilemapRAM:updateAddr(tilemapAddr) end
	local paletteRAM = self.blobs.palette[1].ramgpu
	if paletteRAM then paletteRAM:updateAddr(paletteAddr) end
	local fontRAM = self.blobs.font[1].ramgpu
	if fontRAM then fontRAM:updateAddr(fontAddr) end


	-- do this to set the framebufferRAM before doing checkDirtyCPU/GPU
	self.ram.videoMode = 0	-- 16bpp RGB565
	--self.ram.videoMode = 1	-- 8bpp indexed
	--self.ram.videoMode = 2	-- 8bpp RGB332

	-- set 255 mode first so that it has resources (cuz App:update() needs them for the menu)
	self:setVideoMode(255)

assert(self.videoModes[255])

	-- then set to 0 for our default game env
	self:setVideoMode(self.ram.videoMode)

	self:copyBlobsToROM()

	-- [[ update now ...
	for _,blob in ipairs(self.blobs.sheet) do
		blob.ramgpu.tex:bind()
			:subimage()
		blob.ramgpu.dirtyCPU = false
	end
	for _,blob in ipairs(self.blobs.tilemap) do
		blob.ramgpu.tex:bind()
			:subimage()
		blob.ramgpu.dirtyCPU = false
	end
	for _,blob in ipairs(self.blobs.palette) do
		blob.ramgpu.tex:bind()
			:subimage()
		blob.ramgpu.dirtyCPU = false
	end
	for _,blob in ipairs(self.blobs.font) do
		blob.ramgpu.tex:bind()
			:subimage()
		blob.ramgpu.dirtyCPU = false
	end
	--]]
	--[[ update later ...
	self:setDirtyCPU()
	--]]

	-- 4 uint8 bytes: x, y, w, h ... width and height are inclusive so i can do 0 0 ff ff and get the whole screen
	self:setClipRect(0, 0, clipMax, clipMax)

	self:matident()
	self:matident(1)
	self:matident(2)
	-- default ortho
	self:matortho(0, self.ram.screenWidth, self.ram.screenHeight, 0, -1000, 1000)

	self.ram.blendMode = 0xff	-- = none
	self.ram.blendColor = rgba8888_4ch_to_5551(255,0,0,255)	-- solid red
	self:onBlendColorChange()

	self.paletteBlobIndex = 0
	self.fontBlobIndex = 0

	for i=0,255 do
		self.ram.fontWidth[i] = 5
	end

	self.ram.textFgColor = 0xfc
	self.ram.textBgColor = 0xf0

--DEBUG:print'App:resetVideo done'
end

function AppVideo:setDirtyCPU()
	for _,blob in ipairs(self.blobs.sheet) do
		blob.ramgpu.dirtyCPU = true
	end
	for _,blob in ipairs(self.blobs.tilemap) do
		blob.ramgpu.dirtyCPU = true
	end
	for _,blob in ipairs(self.blobs.palette) do
		blob.ramgpu.dirtyCPU = true
	end
	for _,blob in ipairs(self.blobs.font) do
		blob.ramgpu.dirtyCPU = true
	end
	-- only dirties the current framebuffer (is ok?)
	self.framebufferRAM.dirtyCPU = true
end

--[[
each video mode should uniquely ...
- pick the framebufferTex
- pick the blit SceneObj
- pick / setup flags for each other shader (since RGB modes need RGB output, indexed modes need indexed output ...)
--]]
function AppVideo:setVideoMode(modeIndex)
	assert.type(modeIndex, 'number')
	if self.currentVideoModeIndex == modeIndex then return true end

	-- first time we won't have a drawObj to flush
	self:triBuf_flush()	-- flush before we redefine what modeObj.drawObj is, which :triBuf_flush() depends on

	local modeObj = self.videoModes[modeIndex]
	if not modeObj then
		error("unknown video mode "..tostring(modeIndex))
	end
	modeObj:build()

	self.framebufferRAM = modeObj.framebufferRAM
	self.framebufferNormalTex = modeObj.framebufferNormalTex
	self.framebufferPosTex = modeObj.framebufferPosTex
	self.blitScreenObj = modeObj.blitScreenObj
	self.drawObj = modeObj.drawObj

	-- [[ unbind-if-necessary, switch, rebind-if-necessary
	if self.inUpdateCallback then
		self.fb:unbind()
	end

	self.fb = modeObj.fb

	if self.inUpdateCallback then
		self.fb:bind()
	end
	--]]
	-- [[ bind-if-necessary, update color attachment, unbind-if-necessary
	if not self.inUpdateCallback then
		self.fb:bind()
	end
	self.fb:setColorAttachmentTex2D(self.framebufferRAM.tex.id, 0, self.framebufferRAM.tex.target)

	local res,err = self.fb.check()
	if not res then
		print(err)
		print(debug.traceback())
	end
	if not self.inUpdateCallback then
		self.fb:unbind()
	end
	--]]

	self.ram.screenWidth = modeObj.width
	self.ram.screenHeight = modeObj.height

	self.modelMat:setIdent()
	self.viewMat:setIdent()
	-- for setting video mode should I initialize the projection matrix to its default ortho screen every time?
	-- sure.
	self.projMat:setOrtho(
		0, self.ram.screenWidth,
		self.ram.screenHeight, 0,
		-1000, 1000
	) -- and we will set onProjMatChange next...

	self.triBuf_sceneObj = self.drawObj
	self:onModelMatChange()	-- the drawObj changed so make sure it refreshes its modelMat
	self:onViewMatChange()
	self:onProjMatChange()
	self:onClipRectChange()
	self:onBlendColorChange()
	self:onFrameBufferSizeChange()

	self.blitScreenObj.texs[1] = self.framebufferRAM.tex
	self.blitScreenObj.texs[2] = self.framebufferNormalTex
	self.blitScreenObj.texs[3] = self.framebufferPosTex

	self.currentVideoMode = modeObj
	self.currentVideoModeIndex = modeIndex

	return true
end

-- exchange two colors in the palettes, and in all spritesheets,
-- subject to some texture subregion (to avoid swapping bitplanes of things like the font)
-- net-friendly
function AppVideo:colorSwap(from, to, x, y, w, h, paletteBlobIndex)
	-- TODO SORT THIS OUT
	self:copyBlobsToROM()
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
	for _,blob in ipairs(self.blobs.sheet) do
		local base = blob.ramgpu.addr
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
	local fromAddr = self.blobs.palette[1+paletteBlobIndex].addr + bit.lshift(from, 1)
	local toAddr = self.blobs.palette[1+paletteBlobIndex].addr + bit.lshift(to, 1)
	local oldFromValue = self:peekw(fromAddr)
	self:net_pokew(fromAddr, self:peekw(toAddr))
	self:net_pokew(toAddr, oldFromValue)
	self:copyRAMToBlobs()
	return fromFound, toFound
end


function AppVideo:resetFont()
	self:triBuf_flush()
	local fontBlob = self.blobs.font[1]
	-- TODO ensure there's at least one?
	if not fontBlob then return end
	fontBlob.ramgpu:checkDirtyGPU()
	resetFont(fontBlob.ramptr)
	fontBlob:copyToROM()
	fontBlob.ramgpu.dirtyCPU = true
end

-- externally used ...
-- this re-inserts the font and default palette
-- and copies those changes back into the cartridge too
function AppVideo:resetGFX()
	self:resetFont()

	-- reset palette
	local paletteBlob = self.blobs.palette[1]
-- TODO ensure there's at least one?
	if not paletteBlob then return end
	paletteBlob.ramgpu.dirtyGPU = false
	resetPalette(paletteBlob.ramptr)
	paletteBlob:copyToROM()
	paletteBlob.ramgpu.dirtyCPU = true
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
	round,
	paletteTex	-- override for gui - hack for menus to impose their palettes
)
	x = tonumber(x) or 0
	y = tonumber(y) or 0
	w = tonumber(w) or 0
	h = tonumber(h) or 0
	if not paletteTex then
		local paletteRAM = self.blobs.palette[1+self.ram.paletteBlobIndex].ramgpu
		if not paletteRAM then
			paletteRAM = assert(self.blobs.palette[1].ramgpu, "can't render anything if you have no palettes (how did you delete the last one?)")
		end
		if paletteRAM.dirtyCPU then
			self:triBuf_flush()
			paletteRAM:checkDirtyCPU() -- before any GPU op that uses palette...
		end
		paletteTex = paletteRAM.tex
	end

	if self.framebufferRAM.dirtyCPU then
		self:triBuf_flush()
		self.framebufferRAM:checkDirtyCPU()
	end

	if w < 0 then x,w = x+w,-w end
	if h < 0 then y,h = y+h,-h end

	local xR = x + w
	local yR = y + h

	local drawFlags = bit.bor(
		round and 4 or 0,
		borderOnly and 8 or 0
	)

	colorIndex = math.floor(colorIndex or 0)

	self:triBuf_addTri(
		paletteTex,
		self.lastSheetTex or self.blobs.sheet[1].ramgpu.tex,	-- to prevent extra flushes, just using whatever sheet/tilemap is already bound
		self.lastTilemapTex or self.blobs.tilemap[1].ramgpu.tex,		-- to prevent extra flushes, just using whatever sheet/tilemap is already bound
		x,  y,  0, x,  y,
		xR, y,  0, xR, y,
		x,  yR, 0, x,  yR,
		0, 0, 1,
		bit.bor(drawFlags, bit.lshift(colorIndex, 8)), self.ram.dither, 0, 0,
		x, y, w, h
	)

	self:triBuf_addTri(
		paletteTex,
		self.lastSheetTex or self.blobs.sheet[1].ramgpu.tex,	-- to prevent extra flushes, just using whatever sheet/tilemap is already bound
		self.lastTilemapTex or self.blobs.tilemap[1].ramgpu.tex,		-- to prevent extra flushes, just using whatever sheet/tilemap is already bound
		x,  yR, 0, x,  yR,
		xR, y,  0, xR, y,
		xR, yR, 0, xR, yR,
		0, 0, 1,
		bit.bor(drawFlags, bit.lshift(colorIndex, 8)), self.ram.dither, 0, 0,
		x, y, w, h
	)

	self.framebufferRAM.dirtyGPU = true
	self.framebufferRAM.changedSinceDraw = true
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

function AppVideo:drawSolidTri3D(
	x1, y1, z1,
	x2, y2, z2,
	x3, y3, z3,
	colorIndex
)
	local paletteRAM = self.blobs.palette[1+self.ram.paletteBlobIndex].ramgpu
	if not paletteRAM then
		paletteRAM = assert(self.blobs.palette[1].ramgpu, "can't render anything if you have no palettes (how did you delete the last one?)")
	end
	if paletteRAM.dirtyCPU then
		self:triBuf_flush()
		paletteRAM:checkDirtyCPU() -- before any GPU op that uses palette...
	end
	local paletteTex = paletteRAM.tex	-- or maybe make it an argument like in drawSolidRect ...
	if self.framebufferRAM.dirtyCPU then
		self:triBuf_flush()
		self.framebufferRAM:checkDirtyCPU()
	end

	local normalX, normalY, normalZ = calcNormalForTri(
		x1, y1, z1,
		x2, y2, z2,
		x3, y3, z3
	)
	self:triBuf_addTri(
		paletteTex,
		self.lastSheetTex or self.blobs.sheet[1].ramgpu.tex,	-- to prevent extra flushes, just using whatever sheet/tilemap is already bound
		self.lastTilemapTex or self.blobs.tilemap[1].ramgpu.tex,		-- to prevent extra flushes, just using whatever sheet/tilemap is already bound
		x1, y1, z1, 0, 0,
		x2, y2, z2, 1, 0,
		x3, y3, z3, 0, 1,
		normalX, normalY, normalZ,
		bit.lshift(math.floor(colorIndex or 0), 8), self.ram.dither, 0, 0,
		0, 0, 1, 1		-- do box coords matter for tris if we're not using round or solid?
	)

	self.framebufferRAM.dirtyGPU = true
	self.framebufferRAM.changedSinceDraw = true
end

function AppVideo:drawSolidTri(x1, y1, x2, y2, x3, y3, colorIndex)
	return self:drawSolidTri3D(x1, y1, 0, x2, y2, 0, x3, y3, 0, colorIndex)
end

local function mat4x4mul(m, x, y, z, w)
	x = tonumber(x)
	y = tonumber(y)
	z = tonumber(z) or 0
	w = tonumber(w) or 1
	return
		m[0] * x + m[4] * y + m[ 8] * z + m[12] * w,
		m[1] * x + m[5] * y + m[ 9] * z + m[13] * w,
		m[2] * x + m[6] * y + m[10] * z + m[14] * w,
		m[3] * x + m[7] * y + m[11] * z + m[15] * w
end

-- this function is only used with drawing lines at the moment...
local function homogeneous(x,y,z,w)
	if w > 0 then
		x = x / w
		y = y / w
		z = z / w
	end
	return x,y,z,1
end

-- transform from world coords to screen coords (including projection, including homogeneous transform, including screen-space coordinates)
function AppVideo:transform(x,y,z,w, projMat, modelMat, viewMat)
	modelMat = modelMat or self.ram.modelMat
	viewMat = viewMat or self.ram.viewMat
	projMat = projMat or self.ram.projMat
	x,y,z,w = mat4x4mul(modelMat, x,y,z,w)
	x,y,z,w = mat4x4mul(viewMat, x,y,z,w)
	x,y,z,w = mat4x4mul(projMat, x,y,z,w)
	x,y,z,w = homogeneous(x,y,z,w)
	-- normalized coords to screen-space coords (and y-flip?)
	x = (x + 1) * .5 * self.ram.screenWidth
	y = (-y + 1) * .5 * self.ram.screenHeight
	return x,y,z,w
end

-- inverse-transform from framebuffer/screen coords to menu coords
local modelInv = matrix_ffi({4,4}, matType):zeros()
local viewInv = matrix_ffi({4,4}, matType):zeros()
local projInv = matrix_ffi({4,4}, matType):zeros()
function AppVideo:invTransform(x,y,z)
	x = tonumber(x)
	y = tonumber(y)
	z = tonumber(z) or 0
	local w = 1
	-- screen-space coords to normalized-device coords (and y-flip?)
	x = -1 + 2 * x / tonumber(self.ram.screenWidth)
	y = 1 - 2 * y / tonumber(self.ram.screenHeight)
	-- normalized-device coords to homogeneous inv transform? or nah?
	-- TODO transform accepts 'm' mvType[16] override, but this operates on 4x4 matrix.ffi types...
	-- TODO make this operation in-place
	modelInv:copy(self.modelMat):applyInv4x4()
	viewInv:copy(self.viewMat):applyInv4x4()
	projInv:copy(self.projMat):applyInv4x4()
	x,y,z,w = mat4x4mul(projInv.ptr, x, y, z, w)
	x,y,z,w = mat4x4mul(viewInv.ptr, x,y,z,w)
	x,y,z,w = mat4x4mul(modelInv.ptr, x,y,z,w)
	return x,y,z,w
end

local modelMatPush = ffi.new(matType..'[16]')
local viewMatPush = ffi.new(matType..'[16]')
local projMatPush = ffi.new(matType..'[16]')

function AppVideo:drawSolidLine3D(
	x1, y1, z1,
	x2, y2, z2,
	colorIndex,
	thickness,
	paletteTex
)
	if not paletteTex then
		local paletteRAM = self.blobs.palette[1+self.ram.paletteBlobIndex].ramgpu
		if not paletteRAM then
			paletteRAM = assert(self.blobs.palette[1].ramgpu, "can't render anything if you have no palettes (how did you delete the last one?)")
		end
		if paletteRAM.dirtyCPU then
			self:triBuf_flush()
			paletteRAM:checkDirtyCPU() -- before any GPU op that uses palette...
		end
		paletteTex = paletteRAM.tex
	end

	if self.framebufferRAM.dirtyCPU then
		self:triBuf_flush()
		self.framebufferRAM:checkDirtyCPU()
	end

	-- fwd-transform into screen coords and just offset by this many pixels
	local v1x, v1y, v1z = self:transform(x1, y1, z1)
	local v2x, v2y, v2z = self:transform(x2, y2, z2)
	local dx = v2x - v1x
	local dy = v2y - v1y
	local il = 1 / math.sqrt(dx^2 + dy^2)
	local nx = -dy * il
	local ny = dx * il

	local halfThickness = (thickness or 1) * .5

	local xLL, yLL, zLL =
		v1x - nx * halfThickness,
		v1y - ny * halfThickness,
		v1z
	local xRL, yRL, zRL =
		v2x - nx * halfThickness,
		v2y - ny * halfThickness,
		v2z
	local xLR, yLR, zLR =
		v1x + nx * halfThickness,
		v1y + ny * halfThickness,
		v1z
	local xRR, yRR, zRR =
		v2x + nx * halfThickness,
		v2y + ny * halfThickness,
		v2z

	colorIndex = math.floor(colorIndex or 0)

	-- ok how to perturb input vertex going through a frustum projection such that the output is only +1 in the x or y direction?
	-- meh, forget it, just do the transform on CPU and use an identity matrix
	ffi.copy(modelMatPush, self.ram.modelMat, ffi.sizeof(modelMatPush))
	self:matident()
	ffi.copy(viewMatPush, self.ram.viewMat, ffi.sizeof(viewMatPush))
	self:matident(1)
	ffi.copy(projMatPush, self.ram.projMat, ffi.sizeof(projMatPush))
	self:matident(2)
	self:matortho(0, self.ram.screenWidth, self.ram.screenHeight, 0, 1, -1)	-- 1, -1 maps to ident depth range

	local normalX, normalY, normalZ = calcNormalForTri(
		xLL, yLL, zLL,
		xRL, yRL, zRL,
		xLR, yLR, zLR
	)

	self:triBuf_addTri(
		paletteTex,
		self.lastSheetTex or self.blobs.sheet[1].ramgpu.tex,	-- to prevent extra flushes, just using whatever sheet/tilemap is already bound
		self.lastTilemapTex or self.blobs.tilemap[1].ramgpu.tex,		-- to prevent extra flushes, just using whatever sheet/tilemap is already bound
		xLL, yLL, zLL, 0, 0,
		xRL, yRL, zRL, 1, 0,
		xLR, yLR, zLR, 0, 1,
		normalX, normalY, normalZ,
		bit.lshift(colorIndex, 8), self.ram.dither, 0, 0,
		0, 0, 1, 1
	)

	self:triBuf_addTri(
		paletteTex,
		self.lastSheetTex or self.blobs.sheet[1].ramgpu.tex,	-- to prevent extra flushes, just using whatever sheet/tilemap is already bound
		self.lastTilemapTex or self.blobs.tilemap[1].ramgpu.tex,		-- to prevent extra flushes, just using whatever sheet/tilemap is already bound
		xLR, yLR, zLR, 0, 1,
		xRL, yRL, zRL, 1, 0,
		xRR, yRR, zRR, 1, 1,
		normalX, normalY, normalZ,
		bit.lshift(colorIndex, 8), self.ram.dither, 0, 0,
		0, 0, 1, 1
	)

	self.framebufferRAM.dirtyGPU = true
	self.framebufferRAM.changedSinceDraw = true

	ffi.copy(self.ram.modelMat, modelMatPush, ffi.sizeof(modelMatPush))
	self:onModelMatChange()
	ffi.copy(self.ram.viewMat, viewMatPush, ffi.sizeof(viewMatPush))
	self:onViewMatChange()
	ffi.copy(self.ram.projMat, projMatPush, ffi.sizeof(projMatPush))
	self:onProjMatChange()
end

function AppVideo:drawSolidLine(x1, y1, x2, y2, colorIndex, thickness, paletteTex)
	return self:drawSolidLine3D(x1, y1, 0, x2, y2, 0, colorIndex, thickness, paletteTex)
end

local clearFloat = ffi.new('float[4]')
local clearUInt = ffi.new('GLuint[4]')
function AppVideo:clearScreen(
	colorIndex,
	paletteTex,	-- override for menu ... starting to think this should be a global somewhere...
	depthOnly
)
	colorIndex = colorIndex or 0
-- using clear for depth ... isn't guaranteeing sorting though ... hmm ...
-- if we do clear color here then it'll go out of order between clearScreen() and triBuf_flush() calls
-- so better to clear depth only?  then there's a tiny out of sync problem but probably no one will notice I hope...
	self:triBuf_flush()

	if colorIndex < 0 or colorIndex > 255 then
		-- TODO default color ? transparent? what to do?
		colorIndex = 0
	end

	if not paletteTex then
		local paletteRAM = self.blobs.palette[1+self.ram.paletteBlobIndex].ramgpu
		if not paletteRAM then
			paletteRAM = assert(self.blobs.palette[1].ramgpu, "can't render anything if you have no palettes (how did you delete the last one?)")
		end
		if paletteRAM.dirtyCPU then
			self:triBuf_flush()
			paletteRAM:checkDirtyCPU() -- before any GPU op that uses palette...
		end
		paletteTex = paletteRAM.tex
	end

	assert(paletteTex.data)

	if not depthOnly then
		-- instead of flushing back the CPU->GPU
		-- since I'm just going to overwrite the GPU content
		-- just clear the dirtyCPU flag here (and set dirtyGPU later)
		self.framebufferRAM.dirtyCPU = false
	end

	local fb = self.fb
	if not self.inUpdateCallback then
		fb:bind()
	end

	if not depthOnly then
		local modeObj = self.currentVideoMode
		if not modeObj then
			print'clearScreen() failed -- no video mode present!!!'
		else
			modeObj:build()
			if modeObj.format == 'RGB565' then	-- internalFormat == GL_RGB565
				local selColorValue = ffi.cast('uint16_t*', paletteTex.data)[colorIndex]
				clearFloat[0] = bit.band(selColorValue, 0x1f) / 0x1f
				clearFloat[1] = bit.band(bit.rshift(selColorValue, 5), 0x1f) / 0x1f
				clearFloat[2] = bit.band(bit.rshift(selColorValue, 10), 0x1f) / 0x1f
				clearFloat[3] = 1
				gl.glClearBufferfv(gl.GL_COLOR, 0, clearFloat)
			elseif modeObj.format == '8bppIndex'
			or modeObj.format == 'RGB332'	-- TODO RGB332 should be converted from index to RGB, right?  but with dithering too ... so far that's only done in shader for 332 ...
			then	-- internalFormat == texInternalFormat_u8 ... which is now et to G_R8UI
				clearUInt[0] = colorIndex
				clearUInt[1] = 0
				clearUInt[2] = 0
				clearUInt[3] = 0xff
				gl.glClearBufferuiv(gl.GL_COLOR, 0, clearUInt)
			elseif modeObj.format == '4bppIndex' then
				error'TODO'
			end
		end
	end
	gl.glClear(gl.GL_DEPTH_BUFFER_BIT)

	if useDirectionalShadowmaps 
	and self.ram.useHardwareLighting ~= 0
	then
		-- ok now switch framebuffers to the shadow framebuffer
		-- depth-only or depth-and-color doesn't matter, both ways the lightmap gets cleared
		-- TODO only do this N-many frames to save on perf
		fb:unbind()

		self.lightmapFB:bind()
		gl.glClear(gl.GL_DEPTH_BUFFER_BIT)
		self.lightmapFB:unbind()

		-- done - rebind the framebuffer if necessary
		if self.inUpdateCallback then
			fb:bind()
		end
	else
		-- alternatively if we're not also drawing to our lightmap then we don't always need to unbind the fb
		if not self.inUpdateCallback then
			fb:bind()
		end
	end

	if not depthOnly then
		self.framebufferRAM.dirtyGPU = true
		self.framebufferRAM.changedSinceDraw = true
	end
end

-- w, h is inclusive, right?  meaning for [0,256)^2 you should call (0,0,255,255)
-- NOTICE I chose [incl,excl) at first so that I could represent it with bytes for 256x256 screen, but now that I've got bigger screens, meh no point.
function AppVideo:setClipRect(...)
	self.ram.clipRect[0], self.ram.clipRect[1], self.ram.clipRect[2], self.ram.clipRect[3] = ...
	self:onClipRectChange()
end

function AppVideo:getClipRect()
	return self.ram.clipRect[0], self.ram.clipRect[1], self.ram.clipRect[2], self.ram.clipRect[3]
end

-- for when we blend against solid colors, these go to the shaders to output it
AppVideo.blendColorA = 0
function AppVideo:setBlendMode(blendMode)
	if blendMode < 0 or blendMode >= 8 then
		blendMode = -1
	end

	if self.currentBlendMode == blendMode then return end

	self:triBuf_flush()

	if blendMode == -1 then
		self.blendColorA = 0
		self:onBlendColorChange()
		gl.glDisable(gl.GL_BLEND)
	else

		gl.glEnable(gl.GL_BLEND)

		local subtract = bit.band(blendMode, 2) ~= 0
		if subtract then
			--gl.glBlendEquation(gl.GL_FUNC_SUBTRACT)		-- sprite minus framebuffer
			gl.glBlendEquation(gl.GL_FUNC_REVERSE_SUBTRACT)	-- framebuffer minus sprite
		else
			gl.glBlendEquation(gl.GL_FUNC_ADD)
		end

	-- [[ TODO this here or this in the draw commands?
		self.blendColorA = bit.band(blendMode, 4) == 0 and 0 or 0xff	-- > 0 means we're using draw-override
		self:onBlendColorChange()
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

	self.currentBlendMode = blendMode
end

--[[
'lower level' than 'drawQuad'
accepts a texture as arguments, so the UI/Editor can draw with textures outside of the RAM
doesn't care about tex dirty (cuz its probably a tex outside RAM)
doesn't care about framebuffer dirty (cuz its probably the editor framebuffer)
uses pathway 1
--]]
function AppVideo:drawQuadTex(
	paletteTex,
	sheetTex,
	x, y, w, h,	-- quad box
	tx, ty, tw, th,	-- texcoord bbox in [0,1]
	paletteIndex,
	transparentIndex,
	spriteBit,
	spriteMask
)
	paletteIndex = paletteIndex or 0
	transparentIndex = transparentIndex or -1
	spriteBit = spriteBit or 0
	spriteMask = spriteMask or 0xFF

	local drawFlags = bit.bor(
		-- bits 0/1 == 01b <=> use sprite pathway
		1,

		-- if transparency is oob then flag the "don't use transparentIndex" bit
		(transparentIndex < 0 or transparentIndex >= 256) and 4 or 0,

		-- store sprite bit shift in the next 3 bits
		bit.lshift(spriteBit, 3)
	)

	local xR = x + w
	local yR = y + h

	local uL = tx
	local vL = ty
	local uR = tx + tw
	local vR = ty + th

	self:triBuf_addTri(
		paletteTex,
		sheetTex,
		self.lastTilemapTex or self.blobs.tilemap[1].ramgpu.tex, 	-- to prevent extra flushes, just using whatever sheet/tilemap is already bound
		x,  y,  0, uL, vL,
		xR, y,  0, uR, vL,
		x,  yR, 0, uL, vR,
		0, 0, 1,
		bit.bor(drawFlags, bit.lshift(spriteMask, 8)), self.ram.dither, transparentIndex, paletteIndex,
		0, 0, 1, 1
	)

	self:triBuf_addTri(
		paletteTex,
		sheetTex,
		self.lastTilemapTex or self.blobs.tilemap[1].ramgpu.tex, 	-- to prevent extra flushes, just using whatever sheet/tilemap is already bound
		x,  yR, 0, uL, vR,
		xR, y,  0, uR, vL,
		xR, yR, 0, uR, vR,
		0, 0, 1,
		bit.bor(drawFlags, bit.lshift(spriteMask, 8)), self.ram.dither, transparentIndex, paletteIndex,
		0, 0, 1, 1
	)
end

--[[
uses pathway 3 to draw quads
--]]
function AppVideo:drawQuadTexRGB(
	paletteTex,
	sheetTex,
	x, y, w, h,	-- quad box
	tx, ty, tw, th	-- texcoord bbox
)
	local xR = x + w
	local yR = y + h

	local uL = tx
	local vL = ty
	local uR = tx + tw
	local vR = ty + th

	self:triBuf_addTri(
		paletteTex,
		sheetTex,
		self.lastTilemapTex or self.blobs.tilemap[1].ramgpu.tex, 	-- to prevent extra flushes, just using whatever sheet/tilemap is already bound
		x,  y,  0, uL, vL,
		xR, y,  0, uR, vL,
		x,  yR, 0, uL, vR,
		0, 0, 1,
		3, self.ram.dither, 0, 0,
		0, 0, 1, 1
	)

	self:triBuf_addTri(
		paletteTex,
		sheetTex,
		self.lastTilemapTex or self.blobs.tilemap[1].ramgpu.tex, 	-- to prevent extra flushes, just using whatever sheet/tilemap is already bound
		x,  yR, 0, uL, vR,
		xR, y,  0, uR, vL,
		xR, yR, 0, uR, vR,
		0, 0, 1,
		3, self.ram.dither, 0, 0,
		0, 0, 1, 1
	)
end


--[[
'lower level' functionality than 'drawSprite'
but now that i'm using it for `sspr()` glue, it's in the cartridge api ...
args:
	x y w h = quad rectangle on screen
	tx ty tw th = texcoord rectangle in [0,255] pixel coordinates
	sheetIndex = 0 for sprite sheet, 1 for tile sheet
	paletteIndex = offset into the 256-color palette
	transparentIndex,
	spriteBit,
	spriteMask

sheetIndex is 0 or 1 depending on spriteSheet or tileSheet ...
should I just have an addr here?  and cache by ptr texs?
I was thinking of having some ROM metadata that flagged blobs as dif types, and then for the VRAM blobs generate GPU texs ...
--]]
function AppVideo:drawQuad(
	x, y, w, h,	-- quad box
	tx, ty, tw, th,	-- texcoord bbox
	sheetIndex,
	paletteIndex,
	transparentIndex,
	spriteBit,
	spriteMask,
	paletteTex	-- override for gui
)
	local sheetRAM = self.blobs.sheet[sheetIndex+1].ramgpu
	if not sheetRAM then return end
	if sheetRAM.dirtyCPU then
		self:triBuf_flush()
		sheetRAM:checkDirtyCPU()			-- before we read from the sprite tex, make sure we have most updated copy
	end

	if not paletteTex then
		local paletteRAM = self.blobs.palette[1+self.ram.paletteBlobIndex].ramgpu
		if not paletteRAM then
			paletteRAM = assert(self.blobs.palette[1].ramgpu, "can't render anything if you have no palettes (how did you delete the last one?)")
		end
		if paletteRAM.dirtyCPU then
			self:triBuf_flush()
			paletteRAM:checkDirtyCPU() 		-- before any GPU op that uses palette...
		end
		paletteTex = paletteRAM.tex
	end

	-- TODO only this before we actually do the :draw()
	if self.framebufferRAM.dirtyCPU then
		self:triBuf_flush()
		self.framebufferRAM:checkDirtyCPU()		-- before we write to framebuffer, make sure we have most updated copy
	end

	self:drawQuadTex(
		paletteTex,
		sheetRAM.tex,
		x, y, w, h,
		tx / 256, ty / 256, tw / 256, th / 256,
		paletteIndex,
		transparentIndex,
		spriteBit,
		spriteMask)

	-- TODO only this after we actually do the :draw()
	self.framebufferRAM.dirtyGPU = true
	self.framebufferRAM.changedSinceDraw = true
end

function AppVideo:drawTexTri3D(
	x1,y1,z1,u1,v1,
	x2,y2,z2,u2,v2,
	x3,y3,z3,u3,v3,
	sheetIndex,
	paletteIndex,
	transparentIndex,
	spriteBit,
	spriteMask
)
	sheetIndex = sheetIndex or 0
	local sheetRAM = self.blobs.sheet[sheetIndex+1].ramgpu
	if not sheetRAM then return end
	if sheetRAM.dirtyCPU then
		self:triBuf_flush()
		sheetRAM:checkDirtyCPU()				-- before we read from the sprite tex, make sure we have most updated copy
	end

	local paletteRAM = self.blobs.palette[1+self.ram.paletteBlobIndex].ramgpu
	if not paletteRAM then
		paletteRAM = assert(self.blobs.palette[1].ramgpu, "can't render anything if you have no palettes (how did you delete the last one?)")
	end
	if paletteRAM.dirtyCPU then
		self:triBuf_flush()
		paletteRAM:checkDirtyCPU() 		-- before any GPU op that uses palette...
	end
	local paletteTex = paletteRAM.tex	-- or maybe make it an argument like in drawSolidRect ...

	if self.framebufferRAM.dirtyCPU then
		self:triBuf_flush()
		self.framebufferRAM:checkDirtyCPU()		-- before we write to framebuffer, make sure we have most updated copy
	end

	spriteBit = spriteBit or 0
	spriteMask = spriteMask or 0xFF
	transparentIndex = transparentIndex or -1
	paletteIndex = paletteIndex or 0

	local drawFlags = bit.bor(
		-- bits 0/1 == 01b <=> use sprite pathway
		1,

		-- if transparency is oob then flag the "don't use transparentIndex" bit
		(transparentIndex < 0 or transparentIndex >= 256) and 4 or 0,

		-- store sprite bit shift in the next 3 bits
		bit.lshift(spriteBit, 3)
	)

	local normalX, normalY, normalZ = calcNormalForTri(
		x1, y1, z1,
		x2, y2, z2,
		x3, y3, z3
	)
	self:triBuf_addTri(
		paletteTex,
		sheetRAM.tex,
		self.lastTilemapTex or self.blobs.tilemap[1].ramgpu.tex, 	-- to prevent extra flushes, just using whatever sheet/tilemap is already bound
		x1, y1, z1, u1 / tonumber(spriteSheetSize.x), v1 / tonumber(spriteSheetSize.y),
		x2, y2, z2, u2 / tonumber(spriteSheetSize.x), v2 / tonumber(spriteSheetSize.y),
		x3, y3, z3, u3 / tonumber(spriteSheetSize.x), v3 / tonumber(spriteSheetSize.y),
		normalX, normalY, normalZ,
		bit.bor(drawFlags, bit.lshift(spriteMask, 8)), self.ram.dither, transparentIndex, paletteIndex,
		0, 0, 1, 1
	)

	self.framebufferRAM.dirtyGPU = true
	self.framebufferRAM.changedSinceDraw = true
end


--[[
spriteIndex =
	bits 0..4 = x coordinate in sprite sheet
	bits 5..9 = y coordinate in sprite sheet
	bit 10 = sprite sheet vs tile sheet
	bits 11.. = blob to use for sprite/tile sheet
tilesWide = width in tiles
tilesHigh = height in tiles
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
	tilesWide,
	tilesHigh,
	paletteIndex,
	transparentIndex,
	spriteBit,
	spriteMask,
	scaleX,
	scaleY
)
	tilesWide = tilesWide or 1
	tilesHigh = tilesHigh or 1
	scaleX = scaleX or 1
	scaleY = scaleY or 1
	-- vram / sprite sheet is 32 sprites wide ... 256 pixels wide, 8 pixels per sprite
	spriteIndex = math.floor(spriteIndex or 0)
	local tx = bit.band(spriteIndex, 0x1f)
	local ty = bit.band(bit.rshift(spriteIndex, 5), 0x1f)
	local sheetIndex = bit.rshift(spriteIndex, 10)
	self:drawQuad(
		-- x y w h
		screenX,
		screenY,
		tilesWide * spriteSize.x * scaleX,
		tilesHigh * spriteSize.y * scaleY,
		-- tx ty tw th in [0,255] pixels
		bit.lshift(tx, 3),
		bit.lshift(ty, 3),
		bit.lshift(tilesWide, 3),
		bit.lshift(tilesHigh, 3),
		sheetIndex,
		paletteIndex,
		transparentIndex,
		spriteBit,
		spriteMask,
		nil	-- paletteTex ... TODO palette from 8+'th bits of paletteIndex?
	)
end

-- TODO go back to tileIndex instead of tileX tileY.  That's what mset() issues after all.
-- TODO which is faster, using a single quad draw here, or chopping it up into individual quads and rendering each separately?
-- especially considering if we make them all quads and use the same shader as the sprite shader then we can batch draw all sprites + maps together.
function AppVideo:drawMap(
	tileX,			-- \_ upper-left position in the tilemap
	tileY,			-- /
	tilesWide,		-- \_ how many tiles wide & high to draw
	tilesHigh,		-- /
	screenX,		-- \_ where in the screen to draw
	screenY,		-- /
	mapIndexOffset,	-- general shift to apply to all read map indexes in the tilemap
	draw16Sprites,	-- set to true to draw 16x16 sprites instead of 8x8 sprites.  You still index tileX/Y with the 8x8 position. tilesWide/High are in terms of 16x16 sprites.
	sheetIndex,		-- which sheet to use, 0 to 2*n-1 for n blobs.  even are sprite-sheets, odd are tile-sheets.
	tilemapIndex	-- which tilemap blob to use, 0 to n-1 for n blobs
)
	sheetIndex = sheetIndex or 1
	local sheetRAM = self.blobs.sheet[sheetIndex+1].ramgpu
	if not sheetRAM then return end
	if sheetRAM.dirtyCPU then
		self:triBuf_flush()
		sheetRAM:checkDirtyCPU()	-- TODO just use multiple sprite sheets and let the map() function pick which one
	end

	local paletteRAM = self.blobs.palette[1+self.ram.paletteBlobIndex].ramgpu
	if not paletteRAM then
		paletteRAM = assert(self.blobs.palette[1].ramgpu, "can't render anything if you have no palettes (how did you delete the last one?)")
	end
	if paletteRAM.dirtyCPU then
		self:triBuf_flush()
		paletteRAM:checkDirtyCPU() 	-- before any GPU op that uses palette...
	end
	local paletteTex = paletteRAM.tex	-- or maybe make it an argument like in drawSolidRect ...

	tilemapIndex = tilemapIndex or 0
	local tilemapRAM = self.blobs.tilemap[tilemapIndex+1].ramgpu
	if tilemapRAM.dirtyCPU then
		self:triBuf_flush()
		tilemapRAM:checkDirtyCPU()
	end
	if self.framebufferRAM.dirtyCPU then
		self:triBuf_flush()
		self.framebufferRAM:checkDirtyCPU()
	end

	tilesWide = tilesWide or 1
	tilesHigh = tilesHigh or 1

	local draw16As0or1 = draw16Sprites and 1 or 0

	local xL = screenX or 0
	local yL = screenY or 0
	local xR = xL + tilesWide * bit.lshift(spriteSize.x, draw16As0or1)
	local yR = yL + tilesHigh * bit.lshift(spriteSize.y, draw16As0or1)

	local uL = tileX / tonumber(spriteSheetSizeInTiles.x)
	local vL = tileY / tonumber(spriteSheetSizeInTiles.y)
	local uR = uL + tilesWide / tonumber(spriteSheetSizeInTiles.x)
	local vR = vL + tilesHigh / tonumber(spriteSheetSizeInTiles.y)

	-- user has to specify high-bits
	mapIndexOffset = mapIndexOffset or 0
	local extraX = bit.bor(
		2,	-- tilemap pathway
		draw16Sprites and 4 or 0
	)
	local extraZ = mapIndexOffset

	self:triBuf_addTri(
		paletteTex,
		sheetRAM.tex,
		tilemapRAM.tex,
		xL, yL, 0, uL, vL,
		xR, yL, 0, uR, vL,
		xL, yR, 0, uL, vR,
		0, 0, 1,
		extraX, self.ram.dither, extraZ, 0,
		0, 0, 1, 1
	)

	self:triBuf_addTri(
		paletteTex,
		sheetRAM.tex,
		tilemapRAM.tex,
		xL, yR, 0, uL, vR,
		xR, yL, 0, uR, vL,
		xR, yR, 0, uR, vR,
		0, 0, 1,
		extraX, self.ram.dither, extraZ, 0,
		0, 0, 1, 1
	)

	self.framebufferRAM.dirtyGPU = true
	self.framebufferRAM.changedSinceDraw = true
end

function AppVideo:drawTextCommon(
	fontTex,
	paletteTex,
	text,
	x, y,
	fgColorIndex, bgColorIndex,
	scaleX, scaleY
)
	x = x or 0
	y = y or 0
	fgColorIndex = tonumber(ffi.cast('uint8_t', fgColorIndex or self.ram.textFgColor))
	bgColorIndex = tonumber(ffi.cast('uint8_t', bgColorIndex or self.ram.textBgColor))
	scaleX = scaleX or 1
	scaleY = scaleY or 1
	local x0 = x

	-- should font bg respect transparency/alpha?
	-- or why even draw a background to it? let the user?
	-- or how about use it as a separate flag?
	-- TODO this always uses the cart colors even for the menu draw routine ...
	local r,g,b,a = rgba5551_to_rgba8888_4ch(ffi.cast(palettePtrType, paletteTex.data)[bgColorIndex])
	if a > 0 then
		local bgw = 0
		for i=1,#text do
			local ch = text:byte(i)
			local w = scaleX * (self.inMenuUpdate and menuFontWidth or self.ram.fontWidth[ch])
			bgw = bgw + w
		end

		-- TODO the ... between drawSolidRect and drawSprite is not the same ...
		self:drawSolidRect(
			x0,
			y,
			bgw,
			scaleY * spriteSize.y,
			bgColorIndex,
			nil,	-- borderOnly
			nil,	-- round
			paletteTex
		)
	end

-- draw transparent-background text
	local x = x0 + 1
	y = y + 1

	local w = spriteSize.x * scaleX
	local h = spriteSize.y * scaleY
	local texSizeInTiles = fontImageSizeInTiles		-- using separate font tex
	local tw = 1 / tonumber(texSizeInTiles.x)
	local th = 1 / tonumber(texSizeInTiles.y)
	local paletteIndex = fgColorIndex - 1

	for i=1,#text do
		local ch = text:byte(i)
		local spriteBit = bit.band(ch, 7)		-- get the bit offset
		local by = bit.rshift(ch, 3)	-- get the byte offset

		local drawFlags = bit.bor(
			-- bits 0/1 == 01b <=> use sprite pathway
			1,

			-- transparentIndex == 0, which is in-bounds, so don't set the transparentIndex oob flag
			0,

			-- store sprite bit shift in the next 3 bits
			bit.lshift(spriteBit, 3)
		)

		local xR = x + w
		local yR = y + h

		local uL = by / tonumber(texSizeInTiles.x)
		local uR = uL + tw

		self:triBuf_addTri(
			paletteTex,
			fontTex,
			self.lastTilemapTex or self.blobs.tilemap[1].ramgpu.tex,		-- to prevent extra flushes, just using whatever sheet/tilemap is already bound
			x,  y,  0, uL, 0,
			xR, y,  0, uR, 0,
			x,  yR, 0, uL, th,
			0, 0, 1,
			bit.bor(drawFlags, 0x100), self.ram.dither, 0, paletteIndex,
			0, 0, 1, 1
		)

		self:triBuf_addTri(
			paletteTex,
			fontTex,
			self.lastTilemapTex or self.blobs.tilemap[1].ramgpu.tex,		-- to prevent extra flushes, just using whatever sheet/tilemap is already bound
			xR, y,  0, uR, 0,
			xR, yR, 0, uR, th,
			x,  yR, 0, uL, th,
			0, 0, 1,
			bit.bor(drawFlags, 0x100), self.ram.dither, 0, paletteIndex,
			0, 0, 1, 1
		)

		x = x + scaleX * (self.inMenuUpdate and menuFontWidth or self.ram.fontWidth[ch])
	end

	return x - x0
end

-- TODO same inlining as I just did to :drawMenuText ...
-- draw a solid background color, then draw the text transparent
-- specify an oob bgColorIndex to draw with transparent background
-- and default x, y to the last cursor position
function AppVideo:drawText(...)
-- [[ drawQuad startup
	local fontRAM = self.blobs.font[1+self.ram.fontBlobIndex].ramgpu
	if not fontRAM then
		fontRAM = assert(self.blobs.font[1].ramgpu, "can't render anything if you have no fonts (how did you delete the last one?)")
	end
	if fontRAM.dirtyCPU then
		self:triBuf_flush()
		fontRAM:checkDirtyCPU()			-- before we read from the sprite tex, make sure we have most updated copy
	end
	local fontTex = fontRAM.tex

	local paletteRAM = self.blobs.palette[1+self.ram.paletteBlobIndex].ramgpu
	if not paletteRAM then
		paletteRAM = assert(self.blobs.palette[1].ramgpu, "can't render anything if you have no palettes (how did you delete the last one?)")
	end
	if paletteRAM.dirtyCPU then
		self:triBuf_flush()
		paletteRAM:checkDirtyCPU() 		-- before any GPU op that uses palette...
	end
	local paletteTex = paletteRAM.tex

	if self.framebufferRAM.dirtyCPU then
		self:triBuf_flush()
		self.framebufferRAM:checkDirtyCPU()		-- before we write to framebuffer, make sure we have most updated copy
	end
--]]

	local result = self:drawTextCommon(fontTex, paletteTex, ...)

-- [[ drawQuad shutdown
	self.framebufferRAM.dirtyGPU = true
	self.framebufferRAM.changedSinceDraw = true
--]]

	return result
end

-- same as drawText but using the menu font and palette
function AppVideo:drawMenuText(...)
	return self:drawTextCommon(self.fontMenuTex, self.paletteMenuTex, ...)
end


-- matrix commands, so I don't duplicate these here in the env and in net ...
-- should I set defaults here as well?
-- I'm already setting them in env so ... nah ...

function AppVideo:matident(matrixIndex)
	matrixIndex = tonumber(matrixIndex) or 0
	if matrixIndex == 0 then
		self.modelMat:setIdent()
		self:onModelMatChange()
	elseif matrixIndex == 1 then
		self.viewMat:setIdent()
		self:onViewMatChange()
	else
		self.projMat:setIdent()
		self:onProjMatChange()
	end
end

function AppVideo:mattrans(x, y, z, matrixIndex)
	matrixIndex = tonumber(matrixIndex) or 0
	if matrixIndex == 0 then
		self.modelMat:applyTranslate(x, y, z)
		self:onModelMatChange()
	elseif matrixIndex == 1 then
		self.viewMat:applyTranslate(x, y, z)
		self:onViewMatChange()
	else
		self.projMat:applyTranslate(x, y, z)
		self:onProjMatChange()
	end
end

function AppVideo:matrot(theta, x, y, z, matrixIndex)
	matrixIndex = tonumber(matrixIndex) or 0
	if matrixIndex == 0 then
		self.modelMat:applyRotate(theta, x, y, z)
		self:onModelMatChange()
	elseif matrixIndex == 1 then
		self.viewMat:applyRotate(theta, x, y, z)
		self:onViewMatChange()
	else
		self.projMat:applyRotate(theta, x, y, z)
		self:onProjMatChange()
	end
end

function AppVideo:matrotcs(c, s, x, y, z, matrixIndex)
	matrixIndex = tonumber(matrixIndex) or 0
	if matrixIndex == 0 then
		self.modelMat:applyRotateCosSinUnit(c, s, x, y, z)
		self:onModelMatChange()
	elseif matrixIndex == 1 then
		self.viewMat:applyRotateCosSinUnit(c, s, x, y, z)
		self:onViewMatChange()
	else
		self.projMat:applyRotateCosSinUnit(c, s, x, y, z)
		self:onProjMatChange()
	end
end

function AppVideo:matscale(x, y, z, matrixIndex)
	matrixIndex = tonumber(matrixIndex) or 0
	if matrixIndex == 0 then
		self.modelMat:applyScale(x, y, z)
		self:onModelMatChange()
	elseif matrixIndex == 1 then
		self.viewMat:applyScale(x, y, z)
		self:onViewMatChange()
	else
		self.projMat:applyScale(x, y, z)
		self:onProjMatChange()
	end
end

function AppVideo:matlookat(ex, ey, ez, cx, cy, cz, upx, upy, upz, matrixIndex)
	matrixIndex = tonumber(matrixIndex) or 1
	if matrixIndex == 0 then
		self.modelMat:applyLookAt(ex, ey, ez, cx, cy, cz, upx, upy, upz)
		self:onModelMatChange()
	elseif matrixIndex == 1 then
		self.viewMat:applyLookAt(ex, ey, ez, cx, cy, cz, upx, upy, upz)
		self:onViewMatChange()
	else
		self.projMat:applyLookAt(ex, ey, ez, cx, cy, cz, upx, upy, upz)
		self:onProjMatChange()
	end
end

function AppVideo:matortho(l, r, t, b, n, f, matrixIndex)
	matrixIndex = tonumber(matrixIndex) or 2	-- default projection
	if matrixIndex == 0 then
		self.modelMat:applyOrtho(l, r, t, b, n, f)
		self:onModelMatChange()
	elseif matrixIndex == 1 then
		self.viewMat:applyOrtho(l, r, t, b, n, f)
		self:onViewMatChange()
	else
		self.projMat:applyOrtho(l, r, t, b, n, f)
		self:onProjMatChange()
	end
end

function AppVideo:matfrustum(l, r, b, t, n, f, matrixIndex)
	matrixIndex = tonumber(matrixIndex) or 2	-- default projection
	if matrixIndex == 0 then
		self.modelMat:applyFrustum(l, r, b, t, n, f)
		self:onModelMatChange()
	elseif matrixIndex == 1 then
		self.viewMat:applyFrustum(l, r, b, t, n, f)
		self:onViewMatChange()
	else
		self.projMat:applyFrustum(l, r, b, t, n, f)
		self:onProjMatChange()
	end
end


local path = require 'ext.path'
local screenshotPath = path'screenshots'
function AppVideo:getScreenShotFilename()
	-- TODO only once upon init?
	if not screenshotPath:exists() then
		-- don't assert -- if it already exists the cmd will fail
		screenshotPath:mkdir()
	end

	-- make a new subdir for each application instance ... ?
	if not self.sessionScreenshotDir then
		self.sessionScreenshotDir = screenshotPath/os.date'%Y.%m.%d-%H.%M.%S'
		assert(not self.sessionScreenshotDir:exists(), "found a duplicate screenshot timestamp subdir")
		assert(self.sessionScreenshotDir:mkdir())
		self.screenshotIndex = 0
	end

	local fn = self.sessionScreenshotDir / ('%05d.png'):format(self.screenshotIndex)
	self.screenshotIndex = self.screenshotIndex + 1
	return fn
end

-- overriding whats in GLApp
function AppVideo:screenshotToFile(fn)
	fn = path(fn).path	-- path or string -> string
	local fbRAM = self.framebufferRAM
	fbRAM:checkDirtyGPU()
	local fbTex = fbRAM.tex
	local modeObj = self.currentVideoMode
	modeObj:build()
	if modeObj.format == 'RGB565' then
		-- convert to RGB8 first
		local image = Image(fbTex.width, fbTex.height, 3, 'uint8_t')
		local srcp = fbRAM.image.buffer + 0
		local dstp = image.buffer + 0
		for i=0,fbTex.width*fbTex.height-1 do
			dstp[0], dstp[1], dstp[2] = rgb565rev_to_rgb888_3ch(srcp[0])
			srcp = srcp + 1
			dstp = dstp + 3
		end
		image:save(fn)
	elseif modeObj.format == '8bppIndex' then
		local range = require 'ext.range'
		local palImg = self.blobs.palette[1].image
		local image = Image(fbTex.width, fbTex.height, 1, 'uint8_t')
		ffi.copy(image.buffer, fbRAM.image.buffer, fbTex.width * fbTex.height)
		image.palette = range(0,255):mapi(function(i)
			local r,g,b,a = rgba5551_to_rgba8888_4ch(palImg.buffer[i])
			--return {r,g,b,a}	-- can PNG palette handle RGB or also RGBA?
			return {r,g,b}
		end)
		image:save(fn)
	elseif modeObj.format == 'RGB332' then
		local image = Image(fbTex.width, fbTex.height, 3, 'uint8_t')
		local srcp = fbRAM.image.buffer + 0
		local dstp = image.buffer + 0
		for i=0,fbTex.width*fbTex.height-1 do
			dstp[0], dstp[1], dstp[2] = rgb332_to_rgb888_3ch(srcp[0])
			srcp = srcp + 1
			dstp = dstp + 3
		end
		image:save(fn)
	else
		error'here'
	end
	print('wrote '..fn)
end

function AppVideo:screenshot()
	self:screenshotToFile(self:getScreenShotFilename())
end

function AppVideo:saveLabel()
	local base, ext = path(self.currentLoadedFilename):getext()
	self:screenshotToFile(base..'/label.png')
end

local function orientationCombine(a, b)
	-- ok I made a function for input => orientation, output => 2D matrix
	-- then I applied it twice, and found a bitwise function that reproduces that
	-- and here it is
	return bit.band(7, bit.bxor(
		a,
		b,
		bit.lshift(bit.band(
			bit.bxor(
				bit.lshift(a, 1),
				a
			),
			b,
			2
		), 1)
	))
end


local modelMatPush = ffi.new(matType..'[16]')
-- this is a sprite-based preview of tilemap rendering
-- it's made to simulate blitting the brush onto the tilemap (without me writing the tiles to a GPU texture and using the shader pathway)
function AppVideo:drawBrush(
	brushIndex,
	stampScreenX, stampScreenY,
	stampW, stampH,
	stampOrientation,
	draw16Sprites,
	sheetBlobIndex
)
	brushIndex = brushIndex or 0
	stampScreenX = stampScreenX or 0
	stampScreenY = stampScreenY or 0
	stampW = stampW or 0
	stampH = stampH or 0
	stampOrientation = stampOrientation or 0
	sheetBlobIndex = sheetBlobIndex or 0

	local gameEnv = self.gameEnv
	if not gameEnv then
--DEBUG:print('drawBrush - no gameEnv - bailing')
		return
	end
	local brushes = gameEnv.numo9_brushes
	if not brushes then
--DEBUG:print('drawBrush - no numo9_brushes - bailing')
		return
	end
	local brush = brushes[brushIndex]
	if not brush then
--DEBUG:print('drawBrush - numo9_brushes key '..tostring(brushIndex)..' not found - bailing')
		return
	end

	ffi.copy(modelMatPush, self.ram.modelMat, ffi.sizeof(modelMatPush))

	local stampTileX, stampTileY = 0, 0	-- TODO how to show select brushes? as alays in UL, or as their location in the pick screen? meh?
	-- or TODO stampScreenX = stampTileX * tileSizeInPixels
	-- but for the select's sake, keep the two separate

	local draw16As0or1 = draw16Sprites and 1 or 0
	local tileSizeInTiles = bit.lshift(1, draw16As0or1)
	local tileBits = draw16Sprites and 4 or 3
	local tileSizeInPixels = bit.lshift(1, tileBits)

	local stampHFlip = bit.band(1, stampOrientation)
	local stampRot = bit.band(3, bit.rshift(stampOrientation, 1))

	for ofsx=0,stampW-1 do
		for ofsy=0,stampH-1 do
			local screenX = stampScreenX + ofsx * tileSizeInPixels
			local screenY = stampScreenY + ofsy * tileSizeInPixels

			local bx, by, bw, bh = ofsx, ofsy, stampW, stampH
			if stampRot == 1 then
				bx, by, bw, bh = by, bw-1-bx, bh, bw
			elseif stampRot == 2 then
				bx, by, bw, bh = by, bw-1-bx, bh, bw
				bx, by, bw, bh = by, bw-1-bx, bh, bw
			elseif stampRot == 3 then
				bx, by, bw, bh = by, bw-1-bx, bh, bw
				bx, by, bw, bh = by, bw-1-bx, bh, bw
				bx, by, bw, bh = by, bw-1-bx, bh, bw
			end
			if stampHFlip ~= 0 then bx = bw-1-bx end

			-- TODO what if 'brush' is not there, i.e. a bad brushIndex in a stamp?
			local tileIndex = brush and brush(bx, by, bw, bh, stampTileX, stampTileY) or 0
			local palHi = bit.band(7, bit.rshift(tileIndex, 10))
			local tileOrientation = bit.band(7, bit.rshift(tileIndex, 13))

			tileOrientation = orientationCombine(stampOrientation, tileOrientation)

			local tileHFlip = bit.band(1, tileOrientation)
			local tileRot = bit.rshift(tileOrientation, 1)

			local spriteIndex = bit.band(0x3FF, tileIndex)	-- 10 bits

			-- TODO build rotations into the sprite pathway?
			-- it's in the tilemap pathway already ...
			-- either way, this is just a preview for the tilemap pathway
			-- since brushes don't render themselves, but just blit to the tilemap
			ffi.copy(self.ram.modelMat, modelMatPush, ffi.sizeof(modelMatPush))
			--self:onModelMatChange() ... but it gets set in mattrans also ...
			self:mattrans(
				screenX + tileSizeInPixels / 2,
				screenY + tileSizeInPixels / 2
			)
			self:matrot(tileRot * math.pi * .5)
			if tileHFlip ~= 0 then
				self:matscale(-1, 1)
			end
			self:drawSprite(
				spriteIndex + bit.lshift(sheetBlobIndex, 10), -- spriteIndex
				-tileSizeInPixels / 2,	-- screenX
				-tileSizeInPixels / 2,	-- screenY
				tileSizeInTiles,		-- tilesWide
				tileSizeInTiles,		-- tilesHigh
				bit.lshift(palHi, 5),	-- paletteIndex
				nil,					-- transparentIndex
				nil,					-- spriteBit
				nil,					-- spriteMask
				nil,					-- scaleX
				nil						-- scaleY
			)
		end
	end

	ffi.copy(self.ram.modelMat, modelMatPush, ffi.sizeof(modelMatPush))
	self:onModelMatChange()
end

-- these are net friendly since they are called from the game API
function AppVideo:blitBrush(
	brushIndex, tilemapIndex,
	stampX, stampY, stampW, stampH,
	stampOrientation,
	cx, cy, cw, ch
)
--DEBUG:print('blitBrush', brushIndex, tilemapIndex, stampX, stampY, stampW, stampH, cx, cy, cw, ch)
	brushIndex = brushIndex or 0
	tilemapIndex = tilemapIndex or 0
	stampOrientation = stampOrientation or 0
	-- tilemap clip region
	cx = cx or 0
	cy = cy or 0
	cw = cw or math.huge
	ch = ch or math.huge

	local gameEnv = self.gameEnv
	if not gameEnv then
--DEBUG:print('blitBrush - no gameEnv - bailing')
		return
	end
	local brushes = gameEnv.numo9_brushes
	if not brushes then
--DEBUG:print('blitBrush - no numo9_brushes - bailing')
		return
	end
	local brush = brushes[brushIndex]
	if not brush then
--DEBUG:print('blitBrush - no brushBlob '..tostring(brushIndex)..' - bailing')
		return
	end

	local tilemapBlob = self.blobs.tilemap[tilemapIndex+1]
	if not tilemapBlob then
--DEBUG:print('blitBrush - no tilemapBlob '..tostring(tilemapBlob)..' - bailing')
		return
	end
	local tilemapAddr = tilemapBlob.addr

	local stampHFlip = bit.band(1, stampOrientation)
	local stampRot = bit.band(3, bit.rshift(stampOrientation, 1))

	-- TODO early bailout of intersection test
	for ofsy=0,stampH-1 do
		for ofsx=0,stampW-1 do
			local dstx = ofsx + stampX
			local dsty = ofsy + stampY
			-- in blit bounds
			if dstx >= cx and dstx < cx + cw
			and dsty >= cy and dsty < cy + ch
			-- in tilemap bounds
			and dstx >= 0 and dstx < tilemapSize.x
			and dsty >= 0 and dsty < tilemapSize.y
			then
				-- TODO if we're rotating the stamp then no more promises of ofsx ofsy vs stampx stampy ...
				-- ... should I pass stampOrientation also to let brush definers try to fix this or nah?
				local bx, by, bw, bh = ofsx, ofsy, stampW, stampH
				if stampRot == 1 then
					bx, by, bw, bh = by, bw-1-bx, bh, bw
				elseif stampRot == 2 then
					bx, by, bw, bh = by, bw-1-bx, bh, bw
					bx, by, bw, bh = by, bw-1-bx, bh, bw
				elseif stampRot == 3 then
					bx, by, bw, bh = by, bw-1-bx, bh, bw
					bx, by, bw, bh = by, bw-1-bx, bh, bw
					bx, by, bw, bh = by, bw-1-bx, bh, bw
				end
				if stampHFlip ~= 0 then bx = bw-1-bx end

				local tileIndex = brush(bx, by, bw, bh, stampX, stampY, stampOrientation) or 0
				local tileOrientation = bit.band(7, bit.rshift(tileIndex, 13))

				tileOrientation = orientationCombine(stampOrientation, tileOrientation)

				-- reconstruct
				tileIndex = bit.bor(
					bit.band(0x1fff, tileIndex),
					bit.lshift(tileOrientation, 13)
				)
				self:net_pokew(
					tilemapAddr + 2 * (dstx + dsty * tilemapSize.x),
					tileIndex
				)
			end
		end
	end
end

function AppVideo:blitBrushMap(
	brushmapIndex, tilemapIndex,
	x, y,
	-- TODO orientation here too?
	cx, cy, cw, ch
)
--DEBUG:print('blitBrushMap', brushmapIndex, tilemapIndex, x, y, w, h)
	brushmapIndex = brushmapIndex or 0
	-- brushmap offset into the tilemap
	x = x or 0
	y = y or 0
	-- optional brushmap clip region
	cx = cx or 0
	cy = cy or 0
	cw = cw or math.huge
	ch = ch or math.huge

	local brushmapBlob = self.blobs.brushmap[brushmapIndex+1]
	if not brushmapBlob then
--DEBUG:print('blitBrushMap - no brushmapBlob '..tostring(brushmapIndex)..' - bailing')
		return
	end

	for _,stamp in ipairs(brushmapBlob.vec) do
--DEBUG:print('stamp', _, require 'ext.tolua'(stamp))
		local sx = stamp.x + x
		local sy = stamp.y + y
		if sx >= cx
		and sx + stamp.w < cx + cw
		and sy >= cy
		and sy + stamp.h < cy + ch
		then
			self:blitBrush(
				tonumber(stamp.brush),
				tilemapIndex,
				sx,
				sy,
				stamp.w,
				stamp.h,
				stamp.orientation,
				-- [[ TODO properly convert from cx cy cw ch in brushmap space
				-- to cx cy cw ch in tilemap space
				math.max(cx + x, sx),
				math.max(cy + y, sy),
				math.min(cw, stamp.w),
				math.min(ch, stamp.h)
				--]]
			)
		end
	end
end

function AppVideo:drawMesh3D(
	mesh3DIndex,
	uofs,
	vofs,
	sheetIndex,
	-- TODO terminology problem ...
	-- this is passed on to be used as paletteIndexOffset
	-- but it is passed in as paletteBlobIndex
	paletteIndex,
	transparentIndex,
	spriteBit,
	spriteMask
)
	mesh3DIndex = mesh3DIndex or 0
	uofs = uofs or 0
	vofs = vofs or 0

	local mesh = self.blobs.mesh3d[mesh3DIndex+1]
	if not mesh then
--DEBUG:print('failed to find mesh', mesh3DIndex)
		return
	end

	local vtxs = mesh:getVertexPtr()
	local inds = mesh:getIndexPtr()
	local numIndexes = mesh:getNumIndexes()
	if numIndexes == 0 then	-- no indexes? just draw all vtxs
--DEBUG:print('drawing vertexes only')
		local numVtxs = mesh:getNumVertexes()
		for i=0,numVtxs-3,3 do
			local a = vtxs + i
			local b = vtxs + i+1
			local c = vtxs + i+2
--DEBUG:print('drawMesh3D drawing', i, a, b, c)
			self:drawTexTri3D(
				a.x, a.y, a.z, a.u + uofs, a.v + vofs,
				b.x, b.y, b.z, b.u + uofs, b.v + vofs,
				c.x, c.y, c.z, c.u + uofs, c.v + vofs,
				sheetIndex,
				paletteIndex,
				transparentIndex,
				spriteBit,
				spriteMask
			)
		end
	else	-- draw indexed vertexes
--DEBUG:print('drawing mesh with indexes', numIndexes)
		for i=0,numIndexes-3,3 do
			local a = vtxs + inds[i]
			local b = vtxs + inds[i+1]
			local c = vtxs + inds[i+2]
			self:drawTexTri3D(
				a.x, a.y, a.z, a.u + uofs, a.v + vofs,
				b.x, b.y, b.z, b.u + uofs, b.v + vofs,
				c.x, c.y, c.z, c.u + uofs, c.v + vofs,
				sheetIndex,
				paletteIndex,
				transparentIndex,
				spriteBit,
				spriteMask
			)
		end
	end
end

-- this just draws one single voxel.
local modelMatPush = ffi.new(matType..'[16]')
local vox = ffi.new'Voxel'	-- better ffi.cast/ffi.new inside here or store outside?
function AppVideo:drawVoxel(voxelValue, ...)
	vox.intval = voxelValue or 0

	ffi.copy(modelMatPush, self.ram.modelMat, ffi.sizeof(modelMatPush))
	self:mattrans(.5, .5, .5)
	self:matscale(1/32768, 1/32768, 1/32768)

	-- orientation
	-- there are 24 right-handed cube isometric transformations
	-- there are 5bpp = 32 representations as bitwise Euler angles,
	-- there are 8 redundant Euler angle orientation representations.
	-- these are: 20, 21, 22, 23, 28, 29, 30, 31
	if vox.orientation == 20 then
		-- special-case, xyz-aligned, anchored to voxel center
		-- so now we undo the rotation, i.e. use the rotation transpose
		-- multiply our current modelMat with the viewMat's upper 3x3 transposed and normalized:
		local v = self.viewMat
		local v0, v1, v2,  v3  = v.ptr[0], v.ptr[1], v.ptr[ 2], v.ptr[ 3]
		local v4, v5, v6,  v7  = v.ptr[4], v.ptr[5], v.ptr[ 6], v.ptr[ 7]
		local v8, v9, v10, v11 = v.ptr[8], v.ptr[9], v.ptr[10], v.ptr[11]

		-- normalize cols
		local ilvx = 1 / math.sqrt(v0 * v0 + v4 * v4 + v8  * v8 )
		local ilvy = 1 / math.sqrt(v1 * v1 + v5 * v5 + v9  * v9 )
		local ilvz = 1 / math.sqrt(v2 * v2 + v6 * v6 + v10 * v10)

		-- multiply
		local m = self.modelMat
		local m0, m1, m2,  m3  = m.ptr[0], m.ptr[1], m.ptr[ 2], m.ptr[ 3]
		local m4, m5, m6,  m7  = m.ptr[4], m.ptr[5], m.ptr[ 6], m.ptr[ 7]
		local m8, m9, m10, m11 = m.ptr[8], m.ptr[9], m.ptr[10], m.ptr[11]

		-- x axis
		m.ptr[0] = (v0 * m0 + v4 * m4 + v8  * m8) * ilvx
		m.ptr[4] = (v1 * m0 + v5 * m4 + v9  * m8) * ilvy
		m.ptr[8] = (v2 * m0 + v6 * m4 + v10 * m8) * ilvz

		-- y axis
		m.ptr[1] = (v0 * m1 + v4 * m5 + v8  * m9) * ilvx
		m.ptr[5] = (v1 * m1 + v5 * m5 + v9  * m9) * ilvy
		m.ptr[9] = (v2 * m1 + v6 * m5 + v10 * m9) * ilvz

		-- z axis
		m.ptr[ 2] = (v0 * m2 + v4 * m6 + v8  * m10) * ilvx
		m.ptr[ 6] = (v1 * m2 + v5 * m6 + v9  * m10) * ilvy
		m.ptr[10] = (v2 * m2 + v6 * m6 + v10 * m10) * ilvz

		-- set translation:
		m.ptr[ 3] = (v0 * m3 + v4 * m7 + v8  * m11) * ilvx
		m.ptr[ 7] = (v1 * m3 + v5 * m7 + v9  * m11) * ilvy
		m.ptr[11] = (v2 * m3 + v6 * m7 + v10 * m11) * ilvz

	elseif vox.orientation == 21 then
		-- TODO special case, xy-aligned, z axis still maintained, anchored to voxel center
		local v = self.viewMat
		local x, y = v.ptr[6], v.ptr[2]
		local l = 1/math.sqrt(x^2 + y^2)

		self:matrotcs(0, -1, -1, 0, 0)
		-- now rotate the z-axis to point at the view z

		-- find the angle/axis to the view and rotate by that
		self:matrotcs(l * x, -l * y, 0, 1, 0)

--[[ TODO just apply it:
[[c, 0, s, 0],
[-s, 0, c, 0],
[0, -1, 0, 0],
[0, 0, 0, 1]]
--]]

	elseif vox.orientation == 22 then
		-- TODO special case, xyz-aligned, anchored to z- center
	elseif vox.orientation == 23 then
		-- TODO special case, xy-aligned, anchored to z- center
	else
		-- euler-angles
		-- TODO for speed you can cache these.  all matrix elements are -1,0,1, so no need to cos/sin
		-- TODO which is fastest?  cis calc vs for-loop vs if-else vs table
		local c, s

		c, s = 1, 0
		for i=0,vox.rotZ-1 do c, s = -s, c end
		self:matrotcs(c, s, 0, 0, 1)

		c, s = 1, 0
		for i=0,vox.rotY-1 do c, s = -s, c end
		self:matrotcs(c, s, 0, 1, 0)

		c, s = 1, 0
		for i=0,vox.rotX-1 do c, s = -s, c end
		self:matrotcs(c, s, 1, 0, 0)
	end

	self:drawMesh3D(
		vox.mesh3DIndex,
		bit.lshift(vox.tileXOffset, 3),
		bit.lshift(vox.tileYOffset, 3),
		...
	)

	ffi.copy(self.ram.modelMat, modelMatPush, ffi.sizeof(modelMatPush))
	self:onModelMatChange()
end

local modelMatPush = ffi.new(matType..'[16]')
function AppVideo:drawVoxelMap(
	voxelmapIndex,
	sheetIndex
)
	voxelmapIndex = voxelmapIndex or 0
	local voxelmap = self.blobs.voxelmap[voxelmapIndex+1]
	if not voxelmap then
--DEBUG:print('failed to find voxelmap', voxelmapIndex)
		return
	end

	sheetIndex = sheetIndex or 0
	local sheetRAM = self.blobs.sheet[sheetIndex+1].ramgpu
	if not sheetRAM then return end
	if sheetRAM.dirtyCPU then
		self:triBuf_flush()
		sheetRAM:checkDirtyCPU()				-- before we read from the sprite tex, make sure we have most updated copy
	end
	local sheetTex = sheetRAM.tex

	local paletteRAM = self.blobs.palette[1+self.ram.paletteBlobIndex].ramgpu
	if not paletteRAM then
		paletteRAM = assert(self.blobs.palette[1].ramgpu, "can't render anything if you have no palettes (how did you delete the last one?)")
	end
	if paletteRAM.dirtyCPU then
		self:triBuf_flush()
		paletteRAM:checkDirtyCPU() 		-- before any GPU op that uses palette...
	end
	local paletteTex = paletteRAM.tex	-- or maybe make it an argument like in drawSolidRect ...

	local tilemapTex = self.lastTilemapTex or self.blobs.tilemap[1].ramgpu.tex	-- to prevent extra flushes, just using whatever sheet/tilemap is already bound

	if self.framebufferRAM.dirtyCPU then
		self:triBuf_flush()
		self.framebufferRAM:checkDirtyCPU()		-- before we write to framebuffer, make sure we have most updated copy
	end

	-- TODO invalidate upon dirty flag set
	voxelmap:rebuildMesh(self)

	-- setup textures and uniforms

	-- [[ draw by copying into buffers in AppVideo here
	do
		-- flushes only if necessary.  assigns new texs.  uploads uniforms only if necessary.
		self:triBuf_prepAddTri(paletteTex, sheetTex, tilemapTex)

		local srcVtxs = voxelmap.vertexBufCPU
		local srcLen = #srcVtxs

		local dstVtxs = self.vertexBufCPU
		local dstLen = #dstVtxs
		local writeOfs = dstLen

		dstVtxs:resize(dstLen + srcLen)
		local dstVtxPtr = dstVtxs.v + writeOfs
		ffi.copy(dstVtxPtr, srcVtxs.v, ffi.sizeof'Numo9Vertex' * srcLen)
	end
	--]]
	--[[ draw using blob/voxelmap's own GPU buffer
	-- ... never seems to go that fast
	self:triBuf_flush()
	self:triBuf_prepAddTri(paletteTex, sheetTex, tilemapTex)	-- make sure textures are set
	voxelmap:drawMesh(self)
	--]]

	self.framebufferRAM.dirtyGPU = true
	self.framebufferRAM.changedSinceDraw = true

	-- for now just pass the billboard voxels on to drawVoxel
	-- TODO optimize maybe? idk?
	ffi.copy(modelMatPush, self.ram.modelMat, ffi.sizeof(modelMatPush))
	local vptr = voxelmap:getVoxelDataRAMPtr()
	local width, height, depth = voxelmap:getWidth(), voxelmap:getHeight(), voxelmap:getDepth()
	for j=0,#voxelmap.billboardXYZVoxels-1 do
		local i = voxelmap.billboardXYZVoxels.v[j]
		self:mattrans(i.x, i.y, i.z)
		self:drawVoxel(vptr[i.x + width * (i.y + height * i.z)].intval, sheetIndex)
		ffi.copy(self.ram.modelMat, modelMatPush, ffi.sizeof(modelMatPush))
		self:onModelMatChange()
	end
	for j=0,#voxelmap.billboardXYVoxels-1 do
		local i = voxelmap.billboardXYVoxels.v[j]
		self:mattrans(i.x, i.y, i.z)
		self:drawVoxel(vptr[i.x + width * (i.y + height * i.z)].intval, sheetIndex)
		ffi.copy(self.ram.modelMat, modelMatPush, ffi.sizeof(modelMatPush))
		self:onModelMatChange()
	end
end

return {
	texInternalFormat_u8 = texInternalFormat_u8,
	texInternalFormat_u16 = texInternalFormat_u16,
	internalFormat5551 = internalFormat5551,
	format5551 = format5551,
	type5551 = type5551,
	argb8888revto5551 = argb8888revto5551,
	rgba5551_to_rgba8888_4ch = rgba5551_to_rgba8888_4ch,
	rgb565rev_to_rgb888_3ch = rgb565rev_to_rgb888_3ch,
	rgba8888_4ch_to_5551 = rgba8888_4ch_to_5551,
	resetLogoOnSheet = resetLogoOnSheet,
	resetFont = resetFont,
	resetPalette = resetPalette,
	calcNormalForTri = calcNormalForTri,
	AppVideo = AppVideo,
}
