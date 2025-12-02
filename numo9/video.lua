local ffi = require 'ffi'
local template = require 'template'
local table = require 'ext.table'
local math = require 'ext.math'
local assert = require 'ext.assert'
local matrix_ffi = require 'matrix.ffi'
local vec2i = require 'vec-ffi.vec2i'
local vec3f = require 'vec-ffi.vec3f'
local vector = require 'ffi.cpp.vector-lua'
local Image = require 'image'
local gl = require 'gl'
local glnumber = require 'gl.number'
local GLFBO = require 'gl.fbo'
local GLArrayBuffer = require 'gl.arraybuffer'
local GLTex2D = require 'gl.tex2d'
local GLGeometry = require 'gl.geometry'

local VideoMode = require 'numo9.videomode'.VideoMode
local Numo9Vertex = require 'numo9.videomode'.Numo9Vertex

local numo9_rom = require 'numo9.rom'
local spriteSize = numo9_rom.spriteSize
local spriteSheetSize = numo9_rom.spriteSheetSize
local spriteSheetSizeInTiles = numo9_rom.spriteSheetSizeInTiles
local tilemapSize = numo9_rom.tilemapSize
local tilemapSizeInBits = numo9_rom.tilemapSizeInBits
local paletteSize = numo9_rom.paletteSize
local palettePtrType = numo9_rom.palettePtrType
local fontImageSize = numo9_rom.fontImageSize
local fontImageSizeInTiles = numo9_rom.fontImageSizeInTiles
local fontInBytes = numo9_rom.fontInBytes
local framebufferAddr = numo9_rom.framebufferAddr
local clipMax = numo9_rom.clipMax
local menuFontWidth = numo9_rom.menuFontWidth
local matType = numo9_rom.matType
local matArrType = numo9_rom.matArrType
local Voxel = numo9_rom.Voxel
local animSheetPtrType = numo9_rom.animSheetPtrType
local animSheetSize = numo9_rom.animSheetSize
local maxLights = numo9_rom.maxLights

local uint8_t = ffi.typeof'uint8_t'
local uint8_t_p = ffi.typeof'uint8_t*'
local uint8_t_arr = ffi.typeof'uint8_t[?]'
local uint16_t_p = ffi.typeof'uint16_t*'
local uint16_t_arr = ffi.typeof'uint16_t[?]'
local float = ffi.typeof'float'
local float_4 = ffi.typeof'float[4]'
local GLuint_4 = ffi.typeof'GLuint[4]'
local matPtrType = ffi.typeof('$*', matType)


assert.eq(matType, float, "TODO if this changes then update the modelMat, viewMat, projMat uniforms")

--local dirLightMapSize = vec2i(256, 256)	-- for 16x16 tiles, 16 tiles wide, so 8 tile radius
--local dirLightMapSize = vec2i(512, 512)
--local dirLightMapSize = vec2i(1024, 1024)
local dirLightMapSize = vec2i(2048, 2048)	-- 16 texels/voxel * 64 voxels = 1024 texels across the whole scene
local useDirectionalShadowmaps = true	-- can't turn off or it'll break stuff so *shrug*

local ident4x4 = matrix_ffi({4,4}, matType):eye()

-- 'REV' means first channel first bit ... smh
-- so even tho 5551 is on hardware since forever, it's not on ES3 or WebGL, only GL4...
-- in case it's missing, just use single-channel R16 and do the swizzles manually
local internalFormat5551 = gl.GL_R16UI
local format5551 = GLTex2D.formatInfoForInternalFormat[internalFormat5551].format
local type5551 = GLTex2D.formatInfoForInternalFormat[internalFormat5551].types[1]   -- gl.GL_UNSIGNED_SHORT

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

local function rgba5551_to_rgb332(rgba5551)
	local r = bit.band(rgba5551, 0x1F)		-- bits 0-4
	local g = bit.band(rgba5551, 0x3E0)		-- bits 5-9
	local b = bit.band(rgba5551, 0x7C00)	-- bits 10-14
	return bit.bor(
		bit.rshift(r, 2),		-- shift bit 4 to bit 2
								-- use bits 0,1,2
		bit.band(
			bit.rshift(g, 4),	-- shift bit 9 to bit 5
			0x38				-- mask bits 3,4,5
		),
		bit.band(
			bit.rshift(b, 7),	-- shift bit 14 to bit 7
			0xc0				-- mask bits 6,7
		)
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
	spriteSheetPtr = ffi.cast(uint8_t_p, spriteSheetPtr)
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

--assert(require 'ext.path''font.png':exists(), "failed to find the default font file!")
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

local function resetAnimSheet(ptr)
	ptr = ffi.cast(animSheetPtrType, ptr)
	for i=0,animSheetSize-1 do
		ptr[0] = i
		ptr = ptr + 1
	end
end


-- This just holds a bunch of stuff that App will dump into itself
-- so its member functions' "self"s are just 'App'.
-- I'd call it 'App' but that might be confusing because it's not really App.
local AppVideo = {}

-- maybe this should be its own file?
-- maybe I'll merge RAMGPU with BlobImage ... and then make framebuffer a blob of its own (nahhhh ...) and then I won't need this to be its own file?
function AppVideo:initVideoModes()
--DEBUG:self.triBuf_flushCallsPerFrame = 0
--DEBUG:self.triBuf_flushSizes = {}
--DEBUG(flushtrace): self.triBuf_flushSizesPerTrace = {}
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
	- paletteMenuTex						256x1		2 bytes ... GL_R16UI
	- fontMenuTex							256x8		1 byte  ... GL_R8UI
	- checkerTex							4x4			3 bytes ... GL_RGB+GL_UNSIGNED_BYTE
	- videoMode._256x256xRGB565.framebufferRAM		256x256		2 bytes ... GL_RGB565+GL_UNSIGNED_SHORT_5_6_5
	- videoMode._256x256x8bppIndex.framebufferRAM	256x256		1 byte  ... GL_R8UI
	- videoMode._256x256xRGB332.framebufferRAM		256x256		1 byte  ... GL_R8UI
	- blobs:
	sheet:	 	BlobSheet 					256x256		1 byte  ... GL_R8UI
	tilemap:	BlobTilemap					256x256		2 bytes ... GL_R16UI
	palette:	BlobPalette					256x1		2 bytes ... GL_R16UI
	font:		BlobFont					256x8		1 byte  ... GL_R8UI
	animsheet:	BlobAnimSheet				1024x1		2 bytes ... GL_R16UI

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

	ffi.fill(self.ram.framebuffer, ffi.sizeof(self.ram.framebuffer), 0)

	-- TODO would be nice to have a 'useVec' sort of thing per shader for interleaved arrays like this ...
	-- this is here and in farmgame/app.lua
	self.vertexBufCPU = vector(Numo9Vertex)
	self.vertexBufGPU = GLArrayBuffer{
		size = ffi.sizeof(Numo9Vertex) * self.vertexBufCPU.capacity,
		data = self.vertexBufCPU.v,
		usage = gl.GL_DYNAMIC_DRAW,
	}:unbind()

	-- keep menu/editor gfx separate of the fantasy-console
	do
		-- palette is 256 x 1 x 16 bpp (5:5:5:1)
		local data = uint16_t_arr(256)
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
		local fontData = uint8_t_arr(fontInBytes)
		resetFont(fontData, 'font.png')
		local internalFormat = gl.GL_R8UI
		self.fontMenuTex = GLTex2D{
			internalFormat = internalFormat,
			format = GLTex2D.formatInfoForInternalFormat[internalFormat].format,
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

	-- TODO keep an animSheet separate too but bleh for now
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
		image = Image(2,2,3,uint8_t, {0xf0,0xf0,0xf0,0xfc,0xfc,0xfc,0xfc,0xfc,0xfc,0xf0,0xf0,0xf0}),
		--]]
		-- [[ gradient
		image = Image(4,4,3,uint8_t, {
			0xf0,0xf0,0xf0, 0xfd,0xfd,0xfd, 0xfe,0xfe,0xfe, 0xff,0xff,0xff,
			0xfd,0xfd,0xfd, 0xfe,0xfe,0xfe, 0xff,0xff,0xff, 0xf0,0xf0,0xf0,
			0xfe,0xfe,0xfe, 0xff,0xff,0xff, 0xf0,0xf0,0xf0, 0xfd,0xfd,0xfd,
			0xff,0xff,0xff, 0xf0,0xf0,0xf0, 0xfd,0xfd,0xfd, 0xfe,0xfe,0xfe,
		}),
		--]]
	}:unbind()

	-- a noise tex, using for SSAO
	-- TODO only two compoents are needed, and need pre-normalized would be nice, but storing in gl_rgb is nice too...
	do
		local image = Image(256, 256, 3, uint8_t)
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
		-- do this before setVideoMode because the video mode's light calc stuff needs this.
		self.lightDepthTex = GLTex2D{
			width = dirLightMapSize.x,
			height = dirLightMapSize.y,
			internalFormat = gl.GL_DEPTH_COMPONENT32F,
			format = gl.GL_DEPTH_COMPONENT,
			type = gl.GL_FLOAT,
			minFilter = gl.GL_NEAREST,
			magFilter = gl.GL_NEAREST,
			wrap = {
				s = gl.GL_CLAMP_TO_EDGE,
				t = gl.GL_CLAMP_TO_EDGE,
			},
		}:unbind()

		-- NOTICE the only reason this is here is to calc the mvProjMat and then in resetVideo it gets copied into ram.lightMat
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
		self.lightView.orthoSize = 32
		--]]
		-- 32 is half width, 24 is half length
		self.lightView.angle =
			quatd():fromAngleAxis(0, 0, 1, -45)
			* quatd():fromAngleAxis(1, 0, 0, 60)
		self.lightView.orbit:set(24, 24, 0)
		self.lightView.pos = self.lightView.orbit + 40 * self.lightView.angle:zAxis()
		self.lightView:setup(self.lightDepthTex.width / self.lightDepthTex.height)
		assert.eq(self.lightView.mvProjMat.ctype, ffi.typeof'float')
		-- end lightView that is only used on resetVideo to reset lightViewMat and lightProjMat

		self.lightmapFB = GLFBO{
			width = dirLightMapSize.x,
			height = dirLightMapSize.y,
		}
		self.lightmapFB:bind()
		self.lightDepthTex:bind()
		gl.glFramebufferTexture2D(gl.GL_FRAMEBUFFER, gl.GL_DEPTH_ATTACHMENT, gl.GL_TEXTURE_2D, self.lightDepthTex.id, 0)
		self.lightDepthTex:unbind()
		self.lightmapFB:unbind()

		-- lightview / lighting needs the light view pos and the draw view pos.
		-- for the light view pos, we can just copy it from lightView itself (until I start giving the cart author more control of the lighting)
		self.lightViewPos = vec3f()

		-- temp buf used for holding the combination of light view+proj
		self.lightViewMat = ident4x4:clone()	-- \_ have their pointers relocated to ram
		self.lightProjMat = ident4x4:clone()	-- /
		self.lightViewProjMat = ident4x4:clone()
		self.lightViewInvMat = ident4x4:clone()	-- \_ used especially for extracting position
		self.drawViewInvMat = ident4x4:clone()	-- /
	end

	-- set 255 mode first so that it has resources (cuz App:update() needs them for the menu)
	self:setVideoMode(255)
assert(self.videoModes[255])


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
	self.lastAnimSheetTex:bind(3)
	self.lastTilemapTex:bind(2)
	self.lastSheetTex:bind(1)
	self.lastPaletteTex:bind(0)

	sceneObj.geometry.count = n

	local program = sceneObj.program
	program:use()

--[[ DEBUG - view the scene from the light's perspective
-- so I can tell why some unshadowed things arent being seen ...
	if self.ram.HD2DFlags == 0 then return end
	program:setUniform('viewMat', self.ram.lights[0].viewMat)
	program:setUniform('projMat', self.ram.lights[0].projMat)
--]]

--DEBUG:assert.index(sceneObj, 'vao')
	sceneObj.vao:bind()	-- sceneObj:enableAndSetAttrs()
	--self.vertexBufGPU:bind() ... already bound

	if self.vertexBufCPU.capacity ~= self.vertexBufCPULastCapacity then
		self.vertexBufGPU:setData{
			data = self.vertexBufCPU.v,
			count = self.vertexBufCPU.capacity,
			size = ffi.sizeof(Numo9Vertex) * self.vertexBufCPU.capacity,
		}
	else
--DEBUG:assert.eq(self.vertexBufGPU.data, self.vertexBufCPU.v)
		self.vertexBufGPU:updateData(0, self.vertexBufCPU:getNumBytes())
	end

	sceneObj.geometry:draw()

	if useDirectionalShadowmaps
	and bit.band(self.ram.HD2DFlags, ffi.C.HD2DFlags_lightingCastShadows) ~= 0
	then
		-- now - if we're using light - also draw the geom to the lightmap
		-- that means updating uniforms every render regardless ...
		if self.inUpdateCallback then
			-- should always be true
			self.currentVideoMode.fb:unbind()
		end
		self.lightmapFB:bind()

		for lightIndex=0,math.min(maxLights, self.ram.numLights)-1 do
			local light = self.ram.lights + lightIndex
--DEBUG:print('flush tri light', lightIndex, 'enabled', light.enabled)
			if 0 ~= bit.band(light.enabled, ffi.C.LIGHT_ENABLED_UPDATE_DEPTH_TEX) then
				gl.glViewport(
					light.region[0],
					light.region[1],
					light.region[2],
					light.region[3])

--DEBUG:print('light', lightIndex)
--DEBUG:print('viewMat\n'..require 'ext.range'(0,15):mapi(function(i) return light.viewMat[i] end):concat', ')
--DEBUG:print('projMat\n'..require 'ext.range'(0,15):mapi(function(i) return light.projMat[i] end):concat', ')
				-- don't change the model matrix, that way models are transformed to world properly
				program:setUniform('viewMat', light.viewMat)
				program:setUniform('projMat', light.projMat)
				gl.glUniform4f(program.uniforms.clipRect.loc, 0, 0, dirLightMapSize.x, dirLightMapSize.y)

				sceneObj.geometry:draw()
			end
		end

		-- restore
		program:setUniform('viewMat', self.ram.viewMat)
		program:setUniform('projMat', self.ram.projMat)
		gl.glUniform4f(program.uniforms.clipRect.loc, self:getClipRect())

		--gl.glViewport(0, 0, self.currentVideoMode.fb.width, self.currentVideoMode.fb.height)
		gl.glViewport(0, 0, self.ram.screenWidth, self.ram.screenHeight)

		self.lightmapFB:unbind()
		if self.inUpdateCallback then
			self.currentVideoMode.fb:bind()
		end
	end

	sceneObj.vao:unbind()	-- sceneObj:disableAttrs()

	-- reset the vectors and store the last capacity
	self.vertexBufCPULastCapacity = self.vertexBufCPU.capacity
	self.vertexBufCPU:resize(0)
end

-- setup texture state and uniforms
function AppVideo:triBuf_prepAddTri(
	paletteTex,
	sheetTex,
	tilemapTex,
	animSheetTex
)
assert(paletteTex)
assert(sheetTex)
assert(tilemapTex)
assert(animSheetTex)

	if self.lastPaletteTex ~= paletteTex
	or self.lastSheetTex ~= sheetTex
	or self.lastTilemapTex ~= tilemapTex
	or self.lastAnimSheetTex ~= animSheetTex
	then
		self:triBuf_flush()
		self.lastPaletteTex = paletteTex
		self.lastSheetTex = sheetTex
		self.lastTilemapTex = tilemapTex
		self.lastAnimSheetTex = animSheetTex
	end

	-- do this either first or last prepAddTri of the frame when HD2DFlags is set
	if useDirectionalShadowmaps
	and self.ram.HD2DFlags ~= 0
	then
--DEBUG(lighting):print'tri HD2DFlags viewMat'
--DEBUG(lighting):for i=0,15 do
--DEBUG(lighting):	io.write(' ', self.ram.viewMat[i])
--DEBUG(lighting):end
--DEBUG(lighting):print()

		if not self.haveCapturedDrawMatsForLightingThisFrame then
			self.haveCapturedDrawMatsForLightingThisFrame = true
			ffi.copy(self.drawViewMatForLighting.ptr, self.ram.viewMat, ffi.sizeof(matArrType))
			ffi.copy(self.drawProjMatForLighting.ptr, self.ram.projMat, ffi.sizeof(matArrType))
		end
	end

	-- upload uniforms to GPU before adding new tris ...
	local program = self.triBuf_sceneObj.program
	if self.modelMatDirty
	or self.viewMatDirty
	or self.projMatDirty
	or self.clipRectDirty
	or self.blendColorDirty
	or self.ditherDirty
	or self.cullFaceDirty
	or self.HD2DFlagsDirty
	or self.spriteNormalExhaggerationDirty
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
		if self.ditherDirty then
			gl.glUniform1ui(program.uniforms.dither.loc, self.ram.dither)
			self.ditherDirty = false
		end
		if self.cullFaceDirty then
			if self.ram.cullFace == 0 then
				gl.glDisable(gl.GL_CULL_FACE)
			else
				gl.glEnable(gl.GL_CULL_FACE)
				if self.ram.cullFace == 2 then
					gl.glCullFace(gl.GL_FRONT)
				else
					-- 1 or anyother nonzero:
					gl.glCullFace(gl.GL_BACK)
				-- lol yes there is a FRONT_AND_BACK accepted but no you cant use it
				end
			end
			self.cullFaceDirty = false
		end
		if self.HD2DFlagsDirty then
			self.HD2DFlagsDirty = false
			gl.glUniform1i(program.uniforms.HD2DFlags.loc, self.ram.HD2DFlags)
		end
		if self.spriteNormalExhaggerationDirty then
			self.spriteNormalExhaggerationDirty = false
			gl.glUniform1f(program.uniforms.spriteNormalExhaggeration.loc, self.ram.spriteNormalExhaggeration)
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
	animSheetTex,

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

	self:triBuf_prepAddTri(paletteTex, sheetTex, tilemapTex, animSheetTex)

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

function AppVideo:onHD2DFlagsChange()
	self:triBuf_flush()
	self.HD2DFlagsDirty = true
end

-- call this when ram.blendColor changes
-- or when self.blendColorA changes
-- or upon setVideoMode
function AppVideo:onBlendColorChange()
	self:triBuf_flush()
	self.blendColorDirty = true
end

function AppVideo:onDitherChange()
	self:triBuf_flush()
	self.ditherDirty = true
end

function AppVideo:onCullFaceChange()
	self:triBuf_flush()
	self.cullFaceDirty = true
end


function AppVideo:onSpriteNormalExhaggerationChange()
	self:triBuf_flush()
	self.spriteNormalExhaggerationDirty = true
end


function AppVideo:onFrameBufferSizeChange()
	self:triBuf_flush()
	self.frameBufferSizeUniformDirty = true
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
	for _,blob in ipairs(self.blobs.animsheet) do
		blob.ramgpu:checkDirtyGPU()
	end
end

function AppVideo:allRAMRegionsCheckDirtyGPU()
	-- TODO this current method updates *all* GPU/CPU framebuffer textures
	-- but if I provide more options, I'm only going to want to update the one we're using (or things would be slow)
	if self.currentVideoMode then
		self.currentVideoMode.framebufferRAM:checkDirtyGPU()
		assert(not self.currentVideoMode.framebufferRAM.dirtyGPU)
	end
	self:allRAMRegionsExceptFramebufferCheckDirtyGPU()
	if self.currentVideoMode then
		assert(not self.currentVideoMode.framebufferRAM.dirtyGPU)
	end
end

-- flush anything from gpu to cpu
-- TODO this is duplciating the above
-- but it only flushes the *current* framebuffer
-- TODO when is each used???
function AppVideo:checkDirtyGPU()
	self:allRAMRegionsExceptFramebufferCheckDirtyGPU()
	self.currentVideoMode.framebufferRAM:checkDirtyGPU()
end


function AppVideo:allRAMRegionsCheckDirtyCPU()
	-- TODO this current method updates *all* GPU/CPU framebuffer textures
	-- but if I provide more options, I'm only going to want to update the one we're using (or things would be slow)
	self.currentVideoMode.framebufferRAM:checkDirtyCPU()
	self:allRAMRegionsExceptFramebufferCheckDirtyGPU()
end

-- TODO most the time I call this after I call :copyBlobsToRAM
-- so what should this do exactly vs what should that do?
-- also, this is called from reset() , i.e. it can be called during update.
-- that means framebuffers might be bound
-- and if we think of unbinding them here, this calls :setVideoMode
--  which also tests for update to determine framebuffer-bound status ...
function AppVideo:resetVideo()
--DEBUG:print'App:resetVideo'

	-- flush all before resetting RAM addrs in case any are pointed to the addrs' location
	-- do the framebuffers explicitly cuz typically 'checkDirtyGPU' just does the current one
	-- and also because the first time resetVideo() is called, the video mode hasn't been set yet, os the framebufferRAM hasn't been assigned yet
	self:allRAMRegionsCheckDirtyGPU()

	local spriteSheetBlob = self.blobs.sheet[1]
	local spriteSheet1Blob = self.blobs.sheet[2]
	local tilemapBlob = self.blobs.tilemap[1]
	local paletteBlob = self.blobs.palette[1]
	local fontBlob = self.blobs.font[1]
	-- TODO relocatable animSheet or nah is this relocatable thing all a dumb idea?

	-- TODO how should tehse work if I'm using flexible # blobs and that means not always enough?
	local spriteSheetAddr = spriteSheetBlob and spriteSheetBlob.addr or 0
	local spriteSheet1Addr = spriteSheet1Blob and spriteSheet1Blob.addr or 0
	local tilemapAddr = tilemapBlob and tilemapBlob.addr or 0
	local paletteAddr = paletteBlob and paletteBlob.addr or 0
	local fontAddr = fontBlob and fontBlob.addr or 0

	-- reset these
	self.ram.framebufferAddr = framebufferAddr
	self.ram.spriteSheetAddr = spriteSheetAddr
	self.ram.spriteSheet1Addr = spriteSheet1Addr
	self.ram.tilemapAddr = tilemapAddr
	self.ram.paletteAddr = paletteAddr
	self.ram.fontAddr = fontAddr
	-- and these, which are the ones that can be moved

	-- reset framebufferRAM objects' addresses:
	self.currentVideoMode.framebufferRAM:updateAddr(framebufferAddr)

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


	-- do this to set the framebufferRAM before doing checkDirtyCPU/GPU
	self.ram.videoMode = 0	-- 16bpp RGB565
	--self.ram.videoMode = 1	-- 8bpp indexed
	--self.ram.videoMode = 2	-- 8bpp RGB332

	-- then set to 0 for our default game env
	self:setVideoMode(self.ram.videoMode)

	self:copyBlobsToROM()

	-- [[ update now
	for _,blob in ipairs(self.blobs.sheet) do
		blob.ramgpu.dirtyCPU = true
		blob.ramgpu:checkDirtyCPU()
	end
	for _,blob in ipairs(self.blobs.tilemap) do
		blob.ramgpu.dirtyCPU = true
		blob.ramgpu:checkDirtyCPU()
	end
	for _,blob in ipairs(self.blobs.palette) do
		blob.ramgpu.dirtyCPU = true
		blob.ramgpu:checkDirtyCPU()
	end
	for _,blob in ipairs(self.blobs.font) do
		blob.ramgpu.dirtyCPU = true
		blob.ramgpu:checkDirtyCPU()
	end
	for _,blob in ipairs(self.blobs.animsheet) do
		blob.ramgpu.dirtyCPU = true
		blob.ramgpu:checkDirtyCPU()
	end
	--]]
	--[[ update later ... TODO except framebuffer or nah?
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

	self.ram.dither = 0
	self:onDitherChange()

	self.ram.cullFace = 0
	self:onCullFaceChange()

	self.ram.HD2DFlags = 0
	self:onHD2DFlagsChange()

	self.paletteBlobIndex = 0
	self.fontBlobIndex = 0
	self.animSheetBlobIndex = 0

	for i=0,255 do
		self.ram.fontWidth[i] = 5
	end

	self.ram.textFgColor = 0xfc
	self.ram.textBgColor = 0xf0


	-- init light vars
	self.ram.lightmapWidth = dirLightMapSize.x
	self.ram.lightmapHeight = dirLightMapSize.y

	self.ram.lightAmbientColor[0] = .4
	self.ram.lightAmbientColor[1] = .3
	self.ram.lightAmbientColor[2] = .2

	self.ram.numLights = 1
	for i=0,maxLights-1 do
		self.ram.lights[0].enabled = i==0 and 0xff or 0	-- enable light #1 by default (just like GL1.0 days...)

		self.ram.lights[0].region[0] = 0
		self.ram.lights[0].region[1] = 0
		self.ram.lights[0].region[2] = self.ram.lightmapWidth
		self.ram.lights[0].region[3] = self.ram.lightmapHeight

		self.ram.lights[0].ambientColor[0] = .4
		self.ram.lights[0].ambientColor[1] = .3
		self.ram.lights[0].ambientColor[2] = .2

		self.ram.lights[0].diffuseColor[0] = 1
		self.ram.lights[0].diffuseColor[1] = 1
		self.ram.lights[0].diffuseColor[2] = 1

		self.ram.lights[0].specularColor[0] = .6
		self.ram.lights[0].specularColor[1] = .5
		self.ram.lights[0].specularColor[2] = .4
		self.ram.lights[0].specularColor[3] = 30

		self.ram.lights[0].distAtten[0] = 1
		self.ram.lights[0].distAtten[1] = 0
		self.ram.lights[0].distAtten[2] = 0

		-- this is a global dir light so don't use angle range
		self.ram.lights[0].cosAngleRange[0] = -2
		self.ram.lights[0].cosAngleRange[1] = -1	-- set cos angle range to [-2,-1] so all values map to 1

		ffi.copy(self.ram.lights[0].viewMat, self.lightView.mvMat.ptr, ffi.sizeof(matArrType))
		ffi.copy(self.ram.lights[0].projMat, self.lightView.projMat.ptr, ffi.sizeof(matArrType))
	end

	self.ram.ssaoSampleRadius = 1
	self.ram.ssaoInfluence = 1

	self.ram.dofFocalDist = 0
	self.ram.dofAperature = .2
	self.ram.dofFocalRange = 1
	self.ram.dofBlurMax = 2

	self.ram.spriteNormalExhaggeration = 8
	self:onSpriteNormalExhaggerationChange()

	self.lastAnimSheetTex = self.blobs.animsheet[1].ramgpu.tex
	self.lastTilemapTex = self.blobs.tilemap[1].ramgpu.tex
	self.lastSheetTex = self.blobs.sheet[1].ramgpu.tex
	self.lastPaletteTex = self.blobs.palette[1].ramgpu.tex
	self.lastAnimSheetTex:bind(3)
	self.lastTilemapTex:bind(2)
	self.lastSheetTex:bind(1)
	self.lastPaletteTex:bind(0)

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
	for _,blob in ipairs(self.blobs.animsheet) do
		blob.ramgpu.dirtyCPU = true
	end
	-- only dirties the current framebuffer (is ok?)
	self.currentVideoMode.framebufferRAM.dirtyCPU = true
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

	local oldVideoMode = self.currentVideoMode

	-- first time we won't have a drawObj to flush
	self:triBuf_flush()	-- flush before we redefine what modeObj.drawObj is, which :triBuf_flush() depends on

	-- have the framebuffer to flush GPU to CPU
	-- only if dirtyGPU is set
	-- should we set dirtyGPU upon draw call or upon triBuf_flush?
	if oldVideoMode
	and oldVideoMode.framebufferRAM
	then
		oldVideoMode.framebufferRAM:checkDirtyGPU()
	end

	local newVideoMode = self.videoModes[modeIndex]
	if not newVideoMode then
		return false, "unknown video mode "..tostring(modeIndex)
	end
	newVideoMode:build()

	-- [[ unbind-if-necessary, switch, rebind-if-necessary
	if self.inUpdateCallback
	and oldVideoMode
	and oldVideoMode.fb
	then
		oldVideoMode.fb:unbind()
	end

	if self.inUpdateCallback then
		newVideoMode.fb:bind()
	end
	--]]
	-- [[ bind-if-necessary, update color attachment, unbind-if-necessary
	if not self.inUpdateCallback
	then
		newVideoMode.fb:bind()
	end
	newVideoMode.fb:setColorAttachmentTex2D(newVideoMode.framebufferRAM.tex.id, 0, newVideoMode.framebufferRAM.tex.target)

	local res,err = newVideoMode.fb.check()
	if not res then
		print(err)
		print(debug.traceback())
	end

	if not self.inUpdateCallback then
		newVideoMode.fb:unbind()
	end
	--]]

	self.ram.screenWidth = newVideoMode.width
	self.ram.screenHeight = newVideoMode.height

	self.modelMat:setIdent()
	self.viewMat:setIdent()
	-- for setting video mode should I initialize the projection matrix to its default ortho screen every time?
	-- sure.
	self.projMat:setOrtho(
		0, self.ram.screenWidth,
		self.ram.screenHeight, 0,
		-1000, 1000
	) -- and we will set onProjMatChange next...

	self.triBuf_sceneObj = newVideoMode.drawObj
	self:onModelMatChange()	-- the drawObj changed so make sure it refreshes its modelMat
	self:onViewMatChange()
	self:onProjMatChange()
	self:onClipRectChange()
	self:onBlendColorChange()
	self:onDitherChange()
	self:onCullFaceChange()
	self:onSpriteNormalExhaggerationChange()
	self:onFrameBufferSizeChange()

	self.currentVideoMode = newVideoMode
	self.currentVideoModeIndex = modeIndex

	-- if I don't clear screen then the depth has oob garbage that prevents all subsequent writes so ...
	-- ... I could just clear depth for visual effect
	-- ... tempting
	-- hmm but doing this here screws up the menu fro some reason,
	--  proly cuz its calling setVideoMode() to switch to 255 and back
	-- how about I just clearScreen in mode() calls, but not here?
	--self:clearScreen(nil, nil, true)

	if self.currentVideoMode then
		self.currentVideoMode.framebufferRAM:updateAddr(self.ram.framebufferAddr)
		self.currentVideoMode.framebufferRAM.dirtyCPU = true
		self.currentVideoMode.framebufferRAM:checkDirtyCPU()
	end

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

	local animSheetBlob = self.blobs.animsheet[1]
	resetAnimSheet(animSheetBlob.ramptr)
	animSheetBlob.ramgpu.dirtyCPU = true
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
		local paletteBlob = self.blobs.palette[1+self.ram.paletteBlobIndex]
		if not paletteBlob then
			paletteBlob = assert(self.blobs.palette[1], "can't render anything if you have no palettes (how did you delete the last one?)")
		end
		local paletteRAM = paletteBlob.ramgpu
		if paletteRAM.dirtyCPU then
			self:triBuf_flush()
			paletteRAM:checkDirtyCPU() -- before any GPU op that uses palette...
		end
		paletteTex = paletteRAM.tex
	end

	if self.currentVideoMode.framebufferRAM.dirtyCPU then
		self:triBuf_flush()
		self.currentVideoMode.framebufferRAM:checkDirtyCPU()
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
		self.lastTilemapTex or self.blobs.tilemap[1].ramgpu.tex,
		self.lastAnimSheetTex or self.blobs.animsheet[1].ramgpu.tex,
		x,  y,  0, x,  y,
		xR, y,  0, xR, y,
		x,  yR, 0, x,  yR,
		0, 0, 1,
		bit.bor(drawFlags, bit.lshift(colorIndex, 8)), 0, 0, 0,
		x, y, w, h
	)

	self:triBuf_addTri(
		paletteTex,
		self.lastSheetTex or self.blobs.sheet[1].ramgpu.tex,	-- to prevent extra flushes, just using whatever sheet/tilemap is already bound
		self.lastTilemapTex or self.blobs.tilemap[1].ramgpu.tex,
		self.lastAnimSheetTex or self.blobs.animsheet[1].ramgpu.tex,
		x,  yR, 0, x,  yR,
		xR, y,  0, xR, y,
		xR, yR, 0, xR, yR,
		0, 0, 1,
		bit.bor(drawFlags, bit.lshift(colorIndex, 8)), 0, 0, 0,
		x, y, w, h
	)

	-- TODO should 'dirtyGPU' go in the draw functions or in the triBuf_flush ?
	self.currentVideoMode.framebufferRAM.dirtyGPU = true
	self.currentVideoMode.framebufferRAM.changedSinceDraw = true
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
	local paletteBlob = self.blobs.palette[1+self.ram.paletteBlobIndex]
	if not paletteBlob then
		paletteBlob = assert(self.blobs.palette[1], "can't render anything if you have no palettes (how did you delete the last one?)")
	end
	local paletteRAM = paletteBlob.ramgpu
	if paletteRAM.dirtyCPU then
		self:triBuf_flush()
		paletteRAM:checkDirtyCPU() -- before any GPU op that uses palette...
	end
	local paletteTex = paletteRAM.tex	-- or maybe make it an argument like in drawSolidRect ...
	if self.currentVideoMode.framebufferRAM.dirtyCPU then
		self:triBuf_flush()
		self.currentVideoMode.framebufferRAM:checkDirtyCPU()
	end

	local normalX, normalY, normalZ = calcNormalForTri(
		x1, y1, z1,
		x2, y2, z2,
		x3, y3, z3
	)
	self:triBuf_addTri(
		paletteTex,
		self.lastSheetTex or self.blobs.sheet[1].ramgpu.tex,	-- to prevent extra flushes, just using whatever sheet/tilemap is already bound
		self.lastTilemapTex or self.blobs.tilemap[1].ramgpu.tex,
		self.lastAnimSheetTex or self.blobs.animsheet[1].ramgpu.tex,
		x1, y1, z1, 0, 0,
		x2, y2, z2, 1, 0,
		x3, y3, z3, 0, 1,
		normalX, normalY, normalZ,
		bit.lshift(math.floor(colorIndex or 0), 8), 0, 0, 0,
		0, 0, 1, 1		-- do box coords matter for tris if we're not using round or solid?
	)

	self.currentVideoMode.framebufferRAM.dirtyGPU = true
	self.currentVideoMode.framebufferRAM.changedSinceDraw = true
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
	modelInv:inv4x4(self.modelMat)
	viewInv:inv4x4(self.viewMat)
	projInv:inv4x4(self.projMat)
	x,y,z,w = mat4x4mul(projInv.ptr, x, y, z, w)
	x,y,z,w = mat4x4mul(viewInv.ptr, x,y,z,w)
	x,y,z,w = mat4x4mul(modelInv.ptr, x,y,z,w)
	return x,y,z,w
end

local modelMatPush = matArrType()
local viewMatPush = matArrType()
local projMatPush = matArrType()

function AppVideo:drawSolidLine3D(
	x1, y1, z1,
	x2, y2, z2,
	colorIndex,
	thickness,
	paletteTex
)
	if not paletteTex then
		local paletteBlob = self.blobs.palette[1+self.ram.paletteBlobIndex]
		if not paletteBlob then
			paletteBlob = assert(self.blobs.palette[1], "can't render anything if you have no palettes (how did you delete the last one?)")
		end
		local paletteRAM = paletteBlob.ramgpu
		if paletteRAM.dirtyCPU then
			self:triBuf_flush()
			paletteRAM:checkDirtyCPU() -- before any GPU op that uses palette...
		end
		paletteTex = paletteRAM.tex
	end

	if self.currentVideoMode.framebufferRAM.dirtyCPU then
		self:triBuf_flush()
		self.currentVideoMode.framebufferRAM:checkDirtyCPU()
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
		self.lastTilemapTex or self.blobs.tilemap[1].ramgpu.tex,
		self.lastAnimSheet or self.blobs.animsheet[1].ramgpu.tex,
		xLL, yLL, zLL, 0, 0,
		xRL, yRL, zRL, 1, 0,
		xLR, yLR, zLR, 0, 1,
		normalX, normalY, normalZ,
		bit.lshift(colorIndex, 8), 0, 0, 0,
		0, 0, 1, 1
	)

	self:triBuf_addTri(
		paletteTex,
		self.lastSheetTex or self.blobs.sheet[1].ramgpu.tex,	-- to prevent extra flushes, just using whatever sheet/tilemap is already bound
		self.lastTilemapTex or self.blobs.tilemap[1].ramgpu.tex,
		self.lastAnimSheet or self.blobs.animsheet[1].ramgpu.tex,
		xLR, yLR, zLR, 0, 1,
		xRL, yRL, zRL, 1, 0,
		xRR, yRR, zRR, 1, 1,
		normalX, normalY, normalZ,
		bit.lshift(colorIndex, 8), 0, 0, 0,
		0, 0, 1, 1
	)

	self.currentVideoMode.framebufferRAM.dirtyGPU = true
	self.currentVideoMode.framebufferRAM.changedSinceDraw = true

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

local clearFloat = float_4()
local clearUInt = GLuint_4()
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
		local paletteBlob = self.blobs.palette[1+self.ram.paletteBlobIndex]
		if not paletteBlob then
			paletteBlob = assert(self.blobs.palette[1], "can't render anything if you have no palettes (how did you delete the last one?)")
		end
		local paletteRAM = paletteBlob.ramgpu
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
		self.currentVideoMode.framebufferRAM.dirtyCPU = false
	end

	if not self.inUpdateCallback then
		self.currentVideoMode.fb:bind()
	end

	if not depthOnly then
		local modeObj = self.currentVideoMode
		if not modeObj then
			print'clearScreen() failed -- no video mode present!!!'
		else
			modeObj:build()
			if modeObj.format == 'RGB565' then	-- internalFormat == GL_RGB565
				local selColorValue = ffi.cast(uint16_t_p, paletteTex.data)[colorIndex]
				clearFloat[0] = bit.band(selColorValue, 0x1f) / 0x1f
				clearFloat[1] = bit.band(bit.rshift(selColorValue, 5), 0x1f) / 0x1f
				clearFloat[2] = bit.band(bit.rshift(selColorValue, 10), 0x1f) / 0x1f
				clearFloat[3] = 1
				gl.glClearBufferfv(gl.GL_COLOR, 0, clearFloat)
			elseif modeObj.format == '8bppIndex' then
				clearUInt[0] = colorIndex
				clearUInt[1] = 0
				clearUInt[2] = 0
				clearUInt[3] = 0xff
				gl.glClearBufferuiv(gl.GL_COLOR, 0, clearUInt)
			elseif modeObj.format == 'RGB332' then
				local selColorValue = ffi.cast(uint16_t_p, paletteTex.data)[colorIndex]
				clearUInt[0] = rgba5551_to_rgb332(selColorValue)
				clearUInt[1] = 0
				clearUInt[2] = 0
				clearUInt[3] = 0xff
				gl.glClearBufferuiv(gl.GL_COLOR, 0, clearUInt)
			elseif modeObj.format == '4bppIndex' then
				error'TODO'
			end
		end
	end

	-- clear depth
	gl.glClear(gl.GL_DEPTH_BUFFER_BIT)

	if useDirectionalShadowmaps
	and self.ram.HD2DFlags ~= 0
	then
		-- while we're here, clear normal buffer's alpha component to disable lighting on the background
		-- only if HD2DFlags are set?
		-- TODO should I have a separate flag for this?
		-- should cls() have a flags variable instead of just depth bool?
		clearFloat[0] = 0
		clearFloat[1] = 0
		clearFloat[2] = 1
		clearFloat[3] = 0	-- framebufferNormalTex.a == 0 <=> disable lighting on background by default
		gl.glClearBufferfv(gl.GL_COLOR, 1, clearFloat)

		-- ok now switch framebuffers to the shadow framebuffer
		-- depth-only or depth-and-color doesn't matter, both ways the lightmap gets cleared
		-- TODO only do this N-many frames to save on perf
		self.currentVideoMode.fb:unbind()

		self.lightmapFB:bind()
		gl.glViewport(0, 0, self.lightmapFB.width, self.lightmapFB.height)
		gl.glClear(gl.GL_DEPTH_BUFFER_BIT)
		self.lightmapFB:unbind()
		gl.glViewport(0, 0, self.ram.screenWidth, self.ram.screenHeight)

		-- done - rebind the framebuffer if necessary
		if self.inUpdateCallback then
			self.currentVideoMode.fb:bind()
		end
	else
		-- alternatively if we're not also drawing to our lightmap then we don't always need to unbind the fb
		if not self.inUpdateCallback then
			self.currentVideoMode.fb:bind()
		end
	end

	if not depthOnly then
		self.currentVideoMode.framebufferRAM.dirtyGPU = true
		self.currentVideoMode.framebufferRAM.changedSinceDraw = true
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
		blendMode = 0xff
	end

	if self.currentBlendMode == blendMode then return end

	self:triBuf_flush()

	if blendMode == 0xff then
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
uses pathway 1, i.e. draws sprites
--]]
function AppVideo:drawQuadTex(
	paletteTex,
	sheetTex,
	x, y, w, h,	-- quad box
	tx, ty, tw, th,	-- texcoord bbox in [0,1]
	orientation2D,
	paletteOffset,
	transparentIndex,
	spriteBit,
	spriteMask
)
	orientation2D = orientation2D or 0
	paletteOffset = paletteOffset or 0
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

	-- I could do orientation2D in the shader like I do for tilemap
	-- or I could just do it here ... like I'm doing for drawbrush ...
	local uL = tx
	local vL = ty
	local uR = tx + tw
	local vR = ty + th

	--[[
	uL uR
vL	 1-2
	 |\|
vR   3-4
	--]]
	local u1, v1 = uL, vL
	local u2, v2 = uR, vL
	local u3, v3 = uL, vR
	local u4, v4 = uR, vR

	-- transform orientation here
	local hflip = bit.band(1, orientation2D)
	local rot = bit.band(3, bit.rshift(orientation2D, 1))
	if hflip ~= 0 then
		  u1, u2, u3, u4
		= u2, u1, u4, u3
	end
	if rot == 1 then
		  u1, v1, u2, v2, u3, v3, u4, v4
		= u3, v3, u1, v1, u4, v4, u2, v2
	elseif rot == 2 then
		  u1, v1, u2, v2, u3, v3, u4, v4
		= u4, v4, u3, v3, u2, v2, u1, v1
	elseif rot == 3 then
		  u1, v1, u2, v2, u3, v3, u4, v4
		= u2, v2, u4, v4, u1, v1, u3, v3
	end

	self:triBuf_addTri(
		paletteTex,
		sheetTex,
		self.lastTilemapTex or self.blobs.tilemap[1].ramgpu.tex, 	-- to prevent extra flushes, just using whatever sheet/tilemap is already bound
		self.lastAnimSheetTex or self.blobs.animsheet[1].ramgpu.tex,
		x,  y,  0, u1, v1,
		xR, y,  0, u2, v2,
		x,  yR, 0, u3, v3,
		0, 0, 1,
		bit.bor(drawFlags, bit.lshift(spriteMask, 8)), 0, transparentIndex, paletteOffset,
		0, 0, 1, 1
	)

	self:triBuf_addTri(
		paletteTex,
		sheetTex,
		self.lastTilemapTex or self.blobs.tilemap[1].ramgpu.tex, 	-- to prevent extra flushes, just using whatever sheet/tilemap is already bound
		self.lastAnimSheetTex or self.blobs.animsheet[1].ramgpu.tex,
		x,  yR, 0, u3, v3,
		xR, y,  0, u2, v2,
		xR, yR, 0, u4, v4,
		0, 0, 1,
		bit.bor(drawFlags, bit.lshift(spriteMask, 8)), 0, transparentIndex, paletteOffset,
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
		self.lastAnimSheetTex or self.blobs.animsheet[1].ramgpu.tex,
		x,  y,  0, uL, vL,
		xR, y,  0, uR, vL,
		x,  yR, 0, uL, vR,
		0, 0, 1,
		3, 0, 0, 0,
		0, 0, 1, 1
	)

	self:triBuf_addTri(
		paletteTex,
		sheetTex,
		self.lastTilemapTex or self.blobs.tilemap[1].ramgpu.tex, 	-- to prevent extra flushes, just using whatever sheet/tilemap is already bound
		self.lastAnimSheetTex or self.blobs.animsheet[1].ramgpu.tex,
		x,  yR, 0, uL, vR,
		xR, y,  0, uR, vL,
		xR, yR, 0, uR, vR,
		0, 0, 1,
		3, 0, 0, 0,
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
	paletteOffset = offset into the 256-color palette
	transparentIndex,
	spriteBit,
	spriteMask

sheetIndex is 0 or 1 depending on spriteSheet or spriteSheet1 ...
should I just have an addr here?  and cache by ptr texs?
I was thinking of having some ROM metadata that flagged blobs as dif types, and then for the VRAM blobs generate GPU texs ...
--]]
function AppVideo:drawQuad(
	x, y, w, h,	-- quad box
	tx, ty, tw, th,	-- texcoord bbox
	orientation2D,
	sheetIndex,
	paletteOffset,
	transparentIndex,
	spriteBit,
	spriteMask,
	paletteTex	-- override for gui
)
	local sheetBlob = self.blobs.sheet[sheetIndex+1]
	if not sheetBlob then return end
	local sheetRAM = sheetBlob.ramgpu
	if not sheetRAM then return end
	if sheetRAM.dirtyCPU then
		self:triBuf_flush()
		sheetRAM:checkDirtyCPU()			-- before we read from the sprite tex, make sure we have most updated copy
	end

	if not paletteTex then
		local paletteBlob = self.blobs.palette[1+self.ram.paletteBlobIndex]
		if not paletteBlob then
			paletteBlob = assert(self.blobs.palette[1], "can't render anything if you have no palettes (how did you delete the last one?)")
		end
		local paletteRAM = paletteBlob.ramgpu
		if paletteRAM.dirtyCPU then
			self:triBuf_flush()
			paletteRAM:checkDirtyCPU() 		-- before any GPU op that uses palette...
		end
		paletteTex = paletteRAM.tex
	end

	-- TODO only this before we actually do the :draw()
	if self.currentVideoMode.framebufferRAM.dirtyCPU then
		self:triBuf_flush()
		self.currentVideoMode.framebufferRAM:checkDirtyCPU()		-- before we write to framebuffer, make sure we have most updated copy
	end

	self:drawQuadTex(
		paletteTex,
		sheetRAM.tex,
		x, y, w, h,
		tx / 256, ty / 256, tw / 256, th / 256,
		orientation2D,
		paletteOffset,
		transparentIndex,
		spriteBit,
		spriteMask)

	-- TODO only this after we actually do the :draw()
	self.currentVideoMode.framebufferRAM.dirtyGPU = true
	self.currentVideoMode.framebufferRAM.changedSinceDraw = true
end

function AppVideo:drawTexTri3D(
	x1,y1,z1,u1,v1,
	x2,y2,z2,u2,v2,
	x3,y3,z3,u3,v3,
	sheetIndex,
	paletteOffset,
	transparentIndex,
	spriteBit,
	spriteMask
)
	sheetIndex = sheetIndex or 0
	local sheetBlob = self.blobs.sheet[sheetIndex+1]
	if not sheetBlob then return end
	local sheetRAM = sheetBlob.ramgpu
	if not sheetRAM then return end
	if sheetRAM.dirtyCPU then
		self:triBuf_flush()
		sheetRAM:checkDirtyCPU()				-- before we read from the sprite tex, make sure we have most updated copy
	end

	local paletteBlob = self.blobs.palette[1+self.ram.paletteBlobIndex]
	if not paletteBlob then
		paletteBlob = assert(self.blobs.palette[1], "can't render anything if you have no palettes (how did you delete the last one?)")
	end
	local paletteRAM = paletteBlob.ramgpu
	if paletteRAM.dirtyCPU then
		self:triBuf_flush()
		paletteRAM:checkDirtyCPU() 		-- before any GPU op that uses palette...
	end
	local paletteTex = paletteRAM.tex	-- or maybe make it an argument like in drawSolidRect ...

	if self.currentVideoMode.framebufferRAM.dirtyCPU then
		self:triBuf_flush()
		self.currentVideoMode.framebufferRAM:checkDirtyCPU()		-- before we write to framebuffer, make sure we have most updated copy
	end

	spriteBit = spriteBit or 0
	spriteMask = spriteMask or 0xFF
	transparentIndex = transparentIndex or -1
	paletteOffset = paletteOffset or 0

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
		self.lastAnimSheetTex or self.blobs.animsheet[1].ramgpu.tex,
		x1, y1, z1, u1 / tonumber(spriteSheetSize.x), v1 / tonumber(spriteSheetSize.y),
		x2, y2, z2, u2 / tonumber(spriteSheetSize.x), v2 / tonumber(spriteSheetSize.y),
		x3, y3, z3, u3 / tonumber(spriteSheetSize.x), v3 / tonumber(spriteSheetSize.y),
		normalX, normalY, normalZ,
		bit.bor(drawFlags, bit.lshift(spriteMask, 8)), 0, transparentIndex, paletteOffset,
		0, 0, 1, 1
	)

	self.currentVideoMode.framebufferRAM.dirtyGPU = true
	self.currentVideoMode.framebufferRAM.changedSinceDraw = true
end


--[[
spriteIndex =
	bits 0..4 = x coordinate in sprite sheet
	bits 5..9 = y coordinate in sprite sheet
	bit 10 = sprite sheet vs tile sheet
	bits 11.. = blob to use for sprite/tile sheet
tilesWide = width in tiles
tilesHigh = height in tiles
paletteOffset =
	byte value that holds which palette to use, added to the sprite color index
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
	orientation2D,
	scaleX,
	scaleY,
	paletteOffset,
	transparentIndex,
	spriteBit,
	spriteMask,
	paletteTex
)
	screenX = screenX or 0
	screenY = screenY or 0
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
		orientation2D,
		sheetIndex,
		paletteOffset,
		transparentIndex,
		spriteBit,
		spriteMask,
		paletteTex
	)
end

-- TODO go back to tileIndex instead of tileX tileY.  That's what tset() issues after all.
-- TODO which is faster, using a single quad draw here, or chopping it up into individual quads and rendering each separately?
-- especially considering if we make them all quads and use the same shader as the sprite shader then we can batch draw all sprites + maps together.
function AppVideo:drawTileMap(
	tileX,			-- \_ upper-left position in the tilemap
	tileY,			-- /
	tilesWide,		-- \_ how many tiles wide & high to draw
	tilesHigh,		-- /
	screenX,		-- \_ where in the screen to draw
	screenY,		-- /
	tilemapIndexOffset,	-- general shift to apply to all read map indexes in the tilemap
	draw16Sprites,	-- set to true to draw 16x16 sprites instead of 8x8 sprites.  You still index tileX/Y with the 8x8 position. tilesWide/High are in terms of 16x16 sprites.
	sheetIndex,		-- which sheet to use, 0 to 2*n-1 for n blobs.  even are sprite-sheets, odd are tile-sheets.
	tilemapIndex	-- which tilemap blob to use, 0 to n-1 for n blobs
)
	sheetIndex = sheetIndex or 0
	local sheetBlob = self.blobs.sheet[sheetIndex+1]
	if not sheetBlob then return end
	local sheetRAM = sheetBlob.ramgpu
	if not sheetRAM then return end
	if sheetRAM.dirtyCPU then
		self:triBuf_flush()
		sheetRAM:checkDirtyCPU()
	end

	local paletteBlob = self.blobs.palette[1+self.ram.paletteBlobIndex]
	if not paletteBlob then
		paletteBlob = assert(self.blobs.palette[1], "can't render anything if you have no palettes (how did you delete the last one?)")
	end
	local paletteRAM = paletteBlob.ramgpu
	if paletteRAM.dirtyCPU then
		self:triBuf_flush()
		paletteRAM:checkDirtyCPU() 	-- before any GPU op that uses palette...
	end

	tilemapIndex = tilemapIndex or 0
	local tilemapBlob = self.blobs.tilemap[tilemapIndex+1]
	if not tilemapBlob then return end
	local tilemapRAM = tilemapBlob.ramgpu
	if tilemapRAM.dirtyCPU then
		self:triBuf_flush()
		tilemapRAM:checkDirtyCPU()
	end

	local animSheetBlob = self.blobs.animsheet[1+self.ram.animSheetBlobIndex]
	if not animSheetBlob then
		animSheetBlob = assert(self.blobs.animsheet[1], "can't render anything if you have no animsheets (how did you delete the last one?)")
	end
	local animSheetRAM = animSheetBlob.ramgpu
	if animSheetRAM.dirtyCPU then
		self:triBuf_flush()
		animSheetRAM:checkDirtyCPU()
	end

	if self.currentVideoMode.framebufferRAM.dirtyCPU then
		self:triBuf_flush()
		self.currentVideoMode.framebufferRAM:checkDirtyCPU()
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
	tilemapIndexOffset = tilemapIndexOffset or 0
	local extraX = bit.bor(
		2,	-- tilemap pathway
		draw16Sprites and 4 or 0
	)
	local extraZ = tilemapIndexOffset

	self:triBuf_addTri(
		paletteRAM.tex,
		sheetRAM.tex,
		tilemapRAM.tex,
		animSheetRAM.tex,
		xL, yL, 0, uL, vL,
		xR, yL, 0, uR, vL,
		xL, yR, 0, uL, vR,
		0, 0, 1,
		extraX, 0, extraZ, 0,
		0, 0, 1, 1
	)

	self:triBuf_addTri(
		paletteRAM.tex,
		sheetRAM.tex,
		tilemapRAM.tex,
		animSheetRAM.tex,
		xL, yR, 0, uL, vR,
		xR, yL, 0, uR, vL,
		xR, yR, 0, uR, vR,
		0, 0, 1,
		extraX, 0, extraZ, 0,
		0, 0, 1, 1
	)

	self.currentVideoMode.framebufferRAM.dirtyGPU = true
	self.currentVideoMode.framebufferRAM.changedSinceDraw = true
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
	fgColorIndex = tonumber(ffi.cast(uint8_t, fgColorIndex or self.ram.textFgColor))
	bgColorIndex = tonumber(ffi.cast(uint8_t, bgColorIndex or self.ram.textBgColor))
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
	local paletteOffset = fgColorIndex - 1

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
			self.lastAnimSheetTex or self.blobs.animsheet[1].ramgpu.tex,
			x,  y,  0, uL, 0,
			xR, y,  0, uR, 0,
			x,  yR, 0, uL, th,
			0, 0, 1,
			bit.bor(drawFlags, 0x100), 0, 0, paletteOffset,
			0, 0, 1, 1
		)

		self:triBuf_addTri(
			paletteTex,
			fontTex,
			self.lastTilemapTex or self.blobs.tilemap[1].ramgpu.tex,		-- to prevent extra flushes, just using whatever sheet/tilemap is already bound
			self.lastAnimSheetTex or self.blobs.animsheet[1].ramgpu.tex,
			xR, y,  0, uR, 0,
			xR, yR, 0, uR, th,
			x,  yR, 0, uL, th,
			0, 0, 1,
			bit.bor(drawFlags, 0x100), 0, 0, paletteOffset,
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
	local fontBlob = self.blobs.font[1+self.ram.fontBlobIndex]
	if not fontBlob then
		fontBlob = assert(self.blobs.font[1], "can't render anything if you have no fonts (how did you delete the last one?)")
	end
	local fontRAM = fontBlob.ramgpu
	if fontRAM.dirtyCPU then
		self:triBuf_flush()
		fontRAM:checkDirtyCPU()			-- before we read from the sprite tex, make sure we have most updated copy
	end
	local fontTex = fontRAM.tex

	local paletteBlob = self.blobs.palette[1+self.ram.paletteBlobIndex]
	if not paletteBlob then
		paletteBlob = assert(self.blobs.palette[1], "can't render anything if you have no palettes (how did you delete the last one?)")
	end
	local paletteRAM = paletteBlob.ramgpu
	if paletteRAM.dirtyCPU then
		self:triBuf_flush()
		paletteRAM:checkDirtyCPU() 		-- before any GPU op that uses palette...
	end
	local paletteTex = paletteRAM.tex

	if self.currentVideoMode.framebufferRAM.dirtyCPU then
		self:triBuf_flush()
		self.currentVideoMode.framebufferRAM:checkDirtyCPU()		-- before we write to framebuffer, make sure we have most updated copy
	end
--]]

	local result = self:drawTextCommon(fontTex, paletteTex, ...)

-- [[ drawQuad shutdown
	self.currentVideoMode.framebufferRAM.dirtyGPU = true
	self.currentVideoMode.framebufferRAM.changedSinceDraw = true
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
	elseif matrixIndex == 2 then
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
	local fbRAM = self.currentVideoMode.framebufferRAM
	fbRAM:checkDirtyGPU()
	local fbTex = fbRAM.tex
	local modeObj = self.currentVideoMode
	modeObj:build()
	if modeObj.format == 'RGB565' then
		-- convert to RGB8 first
		local image = Image(fbTex.width, fbTex.height, 3, uint8_t)
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
		local image = Image(fbTex.width, fbTex.height, 1, uint8_t)
		ffi.copy(image.buffer, fbRAM.image.buffer, fbTex.width * fbTex.height)
		image.palette = range(0,255):mapi(function(i)
			local r,g,b,a = rgba5551_to_rgba8888_4ch(palImg.buffer[i])
			--return {r,g,b,a}	-- can PNG palette handle RGB or also RGBA?
			return {r,g,b}
		end)
		image:save(fn)
	elseif modeObj.format == 'RGB332' then
		local image = Image(fbTex.width, fbTex.height, 3, uint8_t)
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

			local tileIndex = brush(bx, by, bw, bh, stampTileX, stampTileY, stampOrientation) or 0
			local palHi = bit.band(7, bit.rshift(tileIndex, 10))
			local tileOrientation = bit.band(7, bit.rshift(tileIndex, 13))

			tileOrientation = orientationCombine(stampOrientation, tileOrientation)

			local spriteIndex = bit.band(0x3FF, tileIndex)	-- 10 bits

			self:drawSprite(
				spriteIndex + bit.lshift(sheetBlobIndex, 10), -- spriteIndex
				screenX,				-- screenX
				screenY,				-- screenY
				tileSizeInTiles,		-- tilesWide
				tileSizeInTiles,		-- tilesHigh
				tileOrientation,		-- orientation2D
				nil,					-- scaleX
				nil,					-- scaleY
				bit.lshift(palHi, 5),	-- paletteOffset
				nil,					-- transparentIndex
				nil,					-- spriteBit
				nil,					-- spriteMask
				nil						-- paletteTex
			)
		end
	end
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
					tilemapAddr + bit.lshift(bit.bor(dstx, bit.lshift(dsty, tilemapSizeInBits.x)), 1),
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
	paletteOffset,
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
				paletteOffset,
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
				paletteOffset,
				transparentIndex,
				spriteBit,
				spriteMask
			)
		end
	end
end

-- this just draws one single voxel.
local modelMatPush = matArrType()
local vox = Voxel()	-- better ffi.cast/ffi.new inside here or store outside?
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
		local v0, v1, v2  = v.ptr[0], v.ptr[1], v.ptr[ 2]
		local v4, v5, v6  = v.ptr[4], v.ptr[5], v.ptr[ 6]
		local v8, v9, v10 = v.ptr[8], v.ptr[9], v.ptr[10]

		-- normalize rows
		local ilvx = 1 / math.sqrt(v0 * v0 + v4 * v4 + v8  * v8 )
		local ilvy = 1 / math.sqrt(v1 * v1 + v5 * v5 + v9  * v9 )
		local ilvz = 1 / math.sqrt(v2 * v2 + v6 * v6 + v10 * v10)

		-- multiply
		local m = self.modelMat
		local m0, m1, m2  = m.ptr[0], m.ptr[1], m.ptr[ 2]
		local m4, m5, m6  = m.ptr[4], m.ptr[5], m.ptr[ 6]
		local m8, m9, m10 = m.ptr[8], m.ptr[9], m.ptr[10]

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
	-- TODO we also have 28 29 30 31 52 53 54 55 60 61 62 63
	else
		if vox.scaleX == 1 then
			self:matscale(-1, 1, 1)
		end

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

local modelMatPush = matArrType()
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
	local sheetBlob = self.blobs.sheet[sheetIndex+1]
	if not sheetBlob then return end
	local sheetRAM = sheetBlob.ramgpu
	if not sheetRAM then return end
	if sheetRAM.dirtyCPU then
		self:triBuf_flush()
		sheetRAM:checkDirtyCPU()				-- before we read from the sprite tex, make sure we have most updated copy
	end
	local sheetTex = sheetRAM.tex

	local paletteBlob = self.blobs.palette[1+self.ram.paletteBlobIndex]
	if not paletteBlob then
		paletteBlob = assert(self.blobs.palette[1], "can't render anything if you have no palettes (how did you delete the last one?)")
	end
	local paletteRAM = paletteBlob.ramgpu
	if paletteRAM.dirtyCPU then
		self:triBuf_flush()
		paletteRAM:checkDirtyCPU() 		-- before any GPU op that uses palette...
	end
	local paletteTex = paletteRAM.tex	-- or maybe make it an argument like in drawSolidRect ...

	local tilemapTex = self.lastTilemapTex or self.blobs.tilemap[1].ramgpu.tex	-- to prevent extra flushes, just using whatever sheet/tilemap is already bound
	local animSheetTex = self.lastAnimSheetTex or self.blobs.animsheet[1].ramgpu.tex	-- same

	if self.currentVideoMode.framebufferRAM.dirtyCPU then
		self:triBuf_flush()
		self.currentVideoMode.framebufferRAM:checkDirtyCPU()		-- before we write to framebuffer, make sure we have most updated copy
	end

	voxelmap:rebuildMesh(self)

	-- setup textures and uniforms

	-- [[ draw by copying into buffers in AppVideo here
	do
		-- flushes only if necessary.  assigns new texs.  uploads uniforms only if necessary.
		self:triBuf_prepAddTri(paletteTex, sheetTex, tilemapTex, animSheetTex)

		--[=[ copy each chunk into the draw buffer
		for i=0,voxelmap.chunkVolume-1 do
			local chunk = voxelmap.chunks[i]
			local srcVtxs = chunk.vertexBufCPU
			local srcLen = #srcVtxs

			local dstVtxs = self.vertexBufCPU
			local dstLen = #dstVtxs
			local writeOfs = dstLen

			dstVtxs:resize(dstLen + srcLen)
			local dstVtxPtr = dstVtxs.v + writeOfs
			ffi.copy(dstVtxPtr, srcVtxs.v, ffi.sizeof(Numo9Vertex) * srcLen)
		end
		--]=]
		-- [=[ copy the master list into the draw buffer
		local srcVtxs = voxelmap.vertexBufCPU
		local srcLen = #srcVtxs

		local dstVtxs = self.vertexBufCPU
		local dstLen = #dstVtxs
		local writeOfs = dstLen

		dstVtxs:resize(dstLen + srcLen)
		local dstVtxPtr = dstVtxs.v + writeOfs
		ffi.copy(dstVtxPtr, srcVtxs.v, ffi.sizeof(Numo9Vertex) * srcLen)
		--]=]
	end
	--]]
	--[[ draw using blob/voxelmap's own GPU buffer
	-- ... never seems to go that fast
	self:triBuf_flush()
	self:triBuf_prepAddTri(paletteTex, sheetTex, tilemapTex, animSheetTex)	-- make sure textures are set
	voxelmap:drawMesh(self)
	--]]

	self.currentVideoMode.framebufferRAM.dirtyGPU = true
	self.currentVideoMode.framebufferRAM.changedSinceDraw = true

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

function AppVideo:updateHD2DPass()
	assert(not self.inUpdateCallback)

--[=[ trying to read the depth buffer
-- seems harder to read the depth buffer than to debug shadowmap lighting calculations.
tempLightCPU = tempLightCPU or ffi.new('float[?]', dirLightMapSize.x * dirLightMapSize.y)
-- [[
self.lightmapFB:bind()
--gl.glReadBuffers(gl.GL_NONE)	-- glReadBuffers, when is this needed?
gl.glReadPixels(0, 0, dirLightMapSize.x, dirLightMapSize.y, gl.GL_DEPTH_COMPONENT, gl.GL_FLOAT, tempLightCPU)
self.lightmapFB:unbind()
--]]
--[[
self.lightDepthTex:toCPU(tempLightCPU)
--]]
print()
for y=0,self.lightDepthTex.height-1 do
	for x=0,self.lightDepthTex.width-1 do
		io.write(' ', tempLightCPU[x + self.lightDepthTex.width * y])
	end
	print()
end
print()
--]=]

	local videoMode =
		self.activeMenu
		and self.videoModes[255]
		or self.currentVideoMode

	local calcLightTex = videoMode.calcLightTex
	local calcLightFB = calcLightTex.fbo
	-- only for native res video mode ...shouldn't this happen in the :resize() callback?
	if videoMode.width ~= calcLightFB.width
	or videoMode.height ~= calcLightFB.height
	then
		-- delete the old tex
		calcLightTex.hist[1]:delete()

		-- realloc a new tex
		calcLightTex.hist[1] = GLTex2D{
			width = videoMode.width,
			height = videoMode.height,
			internalFormat = gl.GL_RGBA32F,
			format = gl.GL_RGBA,
			type = gl.GL_FLOAT,
			minFilter = gl.GL_NEAREST,
			magFilter = gl.GL_LINEAR,
			wrap = {
				s = gl.GL_CLAMP_TO_EDGE,
				t = gl.GL_CLAMP_TO_EDGE,
			},
		}:unbind()

		-- update refs
		videoMode.blitScreenObj.texs[3] = calcLightTex:cur()

		-- and resize the fbo stored size
		calcLightFB.width = videoMode.width
		calcLightFB.height = videoMode.height
		calcLightTex.width = videoMode.width
		calcLightTex.height = videoMode.height
	end


	calcLightTex:swap()
	calcLightFB
		:bind()
		:setColorAttachmentTex2D(calcLightTex:cur().id)

	gl.glViewport(0, 0, calcLightTex.width, calcLightTex.height)
	-- but there's no need to clear it so long as all geometry gets rendered with the 'HD2DFlags' set to zero
	-- then in the light combine pass it wont combine

	-- this currently gets blitted per-display
	-- so if menu is open we dont want it
	-- that means I just broke menu lighting *again*...
	--if not self.activeMenu then
	-- how to get around lighting
	-- I can always just not apply the calcLightTex if we're in light mode
	-- or I can make sure that the menu render calcs always set the to false

	local sceneObj = videoMode.calcLightBlitObj
	sceneObj.texs[1] = videoMode.framebufferNormalTex
	sceneObj.texs[2] = videoMode.framebufferPosTex
	-- these dont change:
	--sceneObj.texs[3] = self.noiseTex
	--sceneObj.texs[4] = self.lightDepthTex

--DEBUG(lighting):print('drawing lighting')
--DEBUG(lighting):print('lighting drawView\n'..self.drawViewMatForLighting)
--DEBUG(lighting):print('lighting drawProj\n'..self.drawProjMatForLighting)
--DEBUG(lighting):print()

--[[ if we dont break out of the sandbox...
	sceneObj:draw()
--]]
-- [[ doing custom stuff
	local texs = sceneObj.texs
	for i,tex in ipairs(texs) do
		tex:bind(i-1)
	end

	local program = sceneObj.program
	program:use()

	-- TODO use UBOs but I'm lazy

	-- all the 'if program.uniforms.* are only for when I do debugging and the uniforms dont compile
	if program.uniforms.ssaoSampleRadius then
		gl.glUniform1f(
			program.uniforms.ssaoSampleRadius.loc,
			self.ram.ssaoSampleRadius)
	end

	if program.uniforms.ssaoInfluence then
		gl.glUniform1f(
			program.uniforms.ssaoInfluence.loc,
			self.ram.ssaoInfluence)
	end

	local drawViewInvMatCalcd
	if program.uniforms.drawViewPos then
		drawViewInvMatCalcd = true
		self.drawViewInvMat:inv4x4(self.drawViewMatForLighting)
		gl.glUniform3fv(
			program.uniforms.drawViewPos.loc,
			1,	-- count
			self.drawViewInvMat.ptr + 12	-- access the translation part of the inverse = the view pos
		)
	end

	if program.uniforms.drawViewMat then
		gl.glUniformMatrix4fv(
			program.uniforms.drawViewMat.loc,
			1,	-- count
			false,	-- transpose
			self.drawViewMatForLighting.ptr
		)
	end

	if program.uniforms.drawProjMat then
		gl.glUniformMatrix4fv(
			program.uniforms.drawProjMat.loc,
			1,	--count
			false,	--transpose
			self.drawProjMatForLighting.ptr
		)
	end

	if program.uniforms.numLights then
		gl.glUniform1i(
			program.uniforms.numLights.loc,
			self.ram.numLights)
	end

	if program.uniforms.lightAmbientColor then
		gl.glUniform3fv(
			program.uniforms.lightAmbientColor.loc,
			1,	-- count
			self.ram.lightAmbientColor
		)
	end

	for i=0,math.min(maxLights, self.ram.numLights)-1 do
		local light = self.ram.lights + i
--DEBUG:print('updating uniforms for light', i, 'enabled', light.enabled)
		gl.glUniform1i(
			gl.glGetUniformLocation(
				program.id,
				'lights_enabled['..i..']'
			),
			0 ~= bit.band(light.enabled, ffi.C.LIGHT_ENABLED_UPDATE_CALCS))

		gl.glUniform4f(
			gl.glGetUniformLocation(
				program.id,
				'lights_region['..i..']'
			),
			tonumber(light.region[0]) / tonumber(self.ram.lightmapWidth),
			tonumber(light.region[1]) / tonumber(self.ram.lightmapHeight),
			tonumber(light.region[2]) / tonumber(self.ram.lightmapWidth),
			tonumber(light.region[3]) / tonumber(self.ram.lightmapHeight)
		)

		gl.glUniform3fv(
			gl.glGetUniformLocation(
				program.id,
				'lights_ambientColor['..i..']'
			),
			1,	-- count
			light.ambientColor
		)

		gl.glUniform3fv(
			gl.glGetUniformLocation(
				program.id,
				'lights_diffuseColor['..i..']'
			),
			1,	-- count
			light.diffuseColor
		)

		gl.glUniform4fv(
			gl.glGetUniformLocation(
				program.id,
				'lights_specularColor['..i..']'
			),
			1,	-- count
			light.specularColor
		)

		gl.glUniform3fv(
			gl.glGetUniformLocation(
				program.id,
				'lights_distAtten['..i..']'
			),
			1,	-- count ... as in arrays right?
			light.distAtten
		)

		gl.glUniform2f(
			gl.glGetUniformLocation(
				program.id,
				'lights_cosAngleRange['..i..']'
			),
			light.cosAngleRange[0],
			1 / (light.cosAngleRange[1] - light.cosAngleRange[0])
		)

		self.lightViewMat.ptr = ffi.cast(matPtrType, light.viewMat)
		self.lightProjMat.ptr = ffi.cast(matPtrType, light.projMat)
		self.lightViewProjMat:mul4x4(self.lightProjMat, self.lightViewMat)
		self.lightViewInvMat:inv4x4(self.lightViewMat)

--DEBUG(lighting):print('lighting lightView\n'..self.lightViewMat)
--DEBUG(lighting):print('lighting lightProj\n'..self.lightProjMat)

		gl.glUniformMatrix4fv(
			gl.glGetUniformLocation(
				program.id,
				'lights_viewProjMat['..i..']'
			),
			1,	-- count
			false,	-- transpose
			self.lightViewProjMat.ptr)

		gl.glUniform3fv(
			gl.glGetUniformLocation(
				program.id,
				'lights_viewPos['..i..']'
			),
			1,	-- count
			self.lightViewInvMat.ptr + 12
		)

		gl.glUniform3fv(
			gl.glGetUniformLocation(
				program.id,
				'lights_negViewDir['..i..']'
			),
			1,	-- count
			self.lightViewInvMat.ptr + 8
		)
	end

	sceneObj.vao:bind()	-- sceneObj:enableAndSetAttrs()
	sceneObj.geometry:draw()
	program:useNone()
	for i=#texs,1,-1 do
		texs[i]:unbind(i-1)
	end
--]]

	calcLightFB:unbind()

--[[ nahhh
	calcLightTex:cur():bind()
		:generateMipmap()
--]]

	-- now combine them here too
	if bit.band(self.ram.HD2DFlags, bit.bor(
		ffi.C.HD2DFlags_useHDR,
		ffi.C.HD2DFlags_useDoF
	)) ~= 0 then
		-- HDR and DOF both need mipmaps,
		-- so they can't accept our indexed color,
		-- so I have to combine and mipmap here.

		-- update the palette bound when drawing the 8bppIndex screen
		-- which palette to use? first?  extra RAM var to specify?
		-- how about whatevers selected as the active palette at end of frame?
		-- for mode-1 8bpp-indexed video mode - we will need to flush the palette as well, before every blit too
		local sceneObj = videoMode.blitScreenObj
		if videoMode.format == '8bppIndex' then
			local paletteBlob =
				self.blobs.palette[1+self.ram.paletteBlobIndex]
				or self.blobs.palette[1]
			paletteBlob.ramgpu:checkDirtyCPU()
			sceneObj.texs[4] = paletteBlob.ramgpu.tex
		end

		local view = self.blitScreenView
		view.mvProjMat:setOrtho(0,1,0,1,-1,1)
		sceneObj.uniforms.mvProjMat = view.mvProjMat.ptr

		local prevTex
		videoMode.lightAndFBTex.fbo:bind()
		sceneObj:draw()
		videoMode.lightAndFBTex.fbo:unbind()
		prevTex = videoMode.lightAndFBTex:cur()

		-- TODO
		if bit.band(self.ram.HD2DFlags, ffi.C.HD2DFlags_useHDR) ~= 0 then
			prevTex
				:bind()
				--:setParameter(gl.GL_TEXTURE_MIN_FILTER, gl.GL_NEAREST_MIPMAP_LINEAR)
				:generateMipmap()
				:unbind()

			videoMode.hdrTex.fbo:bind()
			videoMode.hdrBlitObj.texs[1] = prevTex
			videoMode.hdrBlitObj:draw()
			videoMode.hdrTex.fbo:unbind()
			prevTex = videoMode.hdrTex:cur()
		--[[
		else
			prevTex
				:bind()
				:setParameter(gl.GL_TEXTURE_MIN_FILTER, gl.GL_NEAREST)
				:unbind()
		--]]
		end

		if bit.band(self.ram.HD2DFlags, ffi.C.HD2DFlags_useDoF) ~= 0 then
			-- [[ dont use mipmaps with DoF, use a blur kernel instead
			prevTex
				:bind()
				--:setParameter(gl.GL_TEXTURE_MIN_FILTER, gl.GL_NEAREST_MIPMAP_LINEAR)
				:generateMipmap()
				:unbind()
			--]]
			local fbo = videoMode.dofTex.fbo
			fbo:bind()
			local sceneObj = videoMode.dofBlitObj
			local texs = sceneObj.texs
			texs[1] = prevTex
			texs[2] = videoMode.framebufferPosTex
			for i,tex in ipairs(texs) do
				tex:bind(i-1)
			end
			local program = sceneObj.program
			program:use()
			if program.uniforms.dofFocalDist then
				gl.glUniform1f(
					program.uniforms.dofFocalDist.loc,
					self.ram.dofFocalDist
				)
			end
			if program.uniforms.dofFocalRange then
				gl.glUniform1f(
					program.uniforms.dofFocalRange.loc,
					self.ram.dofFocalRange
				)
			end
			if program.uniforms.dofAperature then
				gl.glUniform1f(
					program.uniforms.dofAperature.loc,
					self.ram.dofAperature
				)
			end
			if program.uniforms.dofBlurMax then
				gl.glUniform1f(
					program.uniforms.dofBlurMax.loc,
					self.ram.dofBlurMax
				)
			end
			if program.uniforms.drawViewDir then
				gl.glUniform4f(
					program.uniforms.drawViewDir.loc,
					self.drawViewMatForLighting.ptr[2],
					self.drawViewMatForLighting.ptr[6],
					self.drawViewMatForLighting.ptr[10],
					self.drawViewMatForLighting.ptr[14]
				)
			end
			sceneObj.vao:bind()	-- sceneObj:enableAndSetAttrs()
			sceneObj.geometry:draw()
			program:useNone()
			for i=#texs,1,-1 do
				texs[i]:unbind(i-1)
			end
			fbo:unbind()
		end
	end
end

-- get the last tex in the pipeline for rendering to screen
function AppVideo:getPipelineRenderTex()
	if bit.band(self.ram.HD2DFlags, ffi.C.HD2DFlags_useDoF) ~= 0 then
		return self.currentVideoMode.dofTex:cur()
	end
	if bit.band(self.ram.HD2DFlags, ffi.C.HD2DFlags_useHDR) ~= 0 then
		return self.currentVideoMode.hdrTex:cur()
	end
	return self.currentVideoMode.framebufferRAM.tex
end

return {
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
	resetAnimSheet = resetAnimSheet,
	calcNormalForTri = calcNormalForTri,
	Numo9Vertex = Numo9Vertex,
	AppVideo = AppVideo,
}
