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
local GLFBO = require 'gl.fbo'
local GLGeometry = require 'gl.geometry'
local GLSceneObject = require 'gl.sceneobject'
local clnumber = require 'cl.obj.number'

local App = require 'numo9.app'
local paletteSize = App.paletteSize
local spriteSize = App.spriteSize
local frameBufferType = App.frameBufferType
local frameBufferSize = App.frameBufferSize
local frameBufferSizeInTiles = App.frameBufferSizeInTiles
local spriteSheetSize = App.spriteSheetSize
local spriteSheetSizeInTiles = App.spriteSheetSizeInTiles
local tilemapSize = App.tilemapSize
local tilemapSizeInSprites = App.tilemapSizeInSprites

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
	return
		bit.lshift(bit.band(rgba5551, 0x1F), 3),
		bit.lshift(bit.band(bit.rshift(rgba5551, 5), 0x1F), 3),
		bit.lshift(bit.band(bit.rshift(rgba5551, 10), 0x1F), 3),
		bit.band(1, bit.rshift(rgba5551, 15)) == 0 and 0 or 0xff
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
	local spriteSheetSize = require 'numo9.app'.spriteSheetSize

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

-- 'self' == app
local function initDraw(self)
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

<? if useTextureRect then ?>
uniform usampler2DRect fbTex;
<? else ?>
uniform usampler2D fbTex;
<? end ?>

const float frameBufferSizeX = <?=clnumber(frameBufferSize.x)?>;
const float frameBufferSizeY = <?=clnumber(frameBufferSize.y)?>;

void main() {
<? if useTextureRect then ?>
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
<? else -- useTextureRect
?>
	fragColor = texture(fbTex, tcv);
<? end -- useTextureRect
?>
}
]],			{
				fragColorUseFloat = fragColorUseFloat,
				useTextureRect = useTextureRect,
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
<? if useTextureRect then ?>
uniform usampler2DRect palTex;
<? else ?>
uniform usampler2D palTex;
<? end ?>
<? assert(math.log(paletteSize, 2) % 1 == 0) ?>

float sqr(float x) { return x * x; }

void main() {
<? if useTextureRect then ?>
	ivec2 palTc = ivec2(
		colorIndex & <?=('0x%Xu'):format(paletteSize-1)?>,
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
<? else -- useTextureRect
?>
	fragColor = texture(palTex, vec2((float(colorIndex)+.5)/<?=clnumber(paletteSize)?>, .5));
<? end -- useTextureRect
?>
}
]],			{
				fragColorUseFloat = fragColorUseFloat,
				useTextureRect = useTextureRect,
				clnumber = clnumber,
				paletteSize = paletteSize,
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

uniform bool borderOnly;
uniform bool round;

uniform uint colorIndex;

<? if useTextureRect then ?>
uniform usampler2DRect palTex;
<? else ?>
uniform usampler2D palTex;
<? end ?>

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

<? if useTextureRect then ?>
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
<? else -- useTextureRect
?>
	fragColor = texture(palTex, vec2((float(colorIndex)+.5)/<?=clnumber(paletteSize)?>, .5));
<? end -- useTextureRect
?>
	// TODO THIS? or should we just rely on the transparentIndex==0 for that? or both?
	//for draw-solid it's not so useful because we can already specify the color and the transparency alpha here
	// so there's no point in having an alpha-by-color since it will be all-solid or all-transparent.
	//if (fragColor.a == 0) discard;
}
]],			{
				fragColorUseFloat = fragColorUseFloat,
				useTextureRect = useTextureRect,
				clnumber = clnumber,
				paletteSize = paletteSize,
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
<? if useTextureRect then ?>
uniform usampler2DRect spriteTex;
<? else ?>
uniform usampler2D spriteTex;
<? end ?>

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

<? if useTextureRect then ?>
uniform usampler2DRect palTex;
<? else ?>
uniform usampler2D palTex;
<? end ?>

const float spriteSheetSizeX = <?=clnumber(spriteSheetSize.x)?>;
const float spriteSheetSizeY = <?=clnumber(spriteSheetSize.y)?>;

void main() {
	// TODO provide a shift uniform for picking lo vs hi nibble
	// only use the lower 4 bits ...
<? if useTextureRect then ?>
	uint colorIndex = (texture(
		spriteTex,
		ivec2(
			tcv.x * spriteSheetSizeX,
			tcv.y * spriteSheetSizeY
		)
	).r >> spriteBit) & spriteMask;
<? else ?>
	uint colorIndex = (texture(spriteTex, tcv).r >> spriteBit) & spriteMask;
<? end ?>

	// TODO HERE MAYBE
	// lookup the colorIndex in the palette to determine the alpha channel
	// but really, why an extra tex read here?
	// how about instead I do the TIC-80 way and just specify which index per-sprite is transparent?
	// then I get to use all my colors
	if (colorIndex == transparentIndex) discard;

	//colorIndex should hold
	colorIndex += paletteIndex;
	colorIndex &= 0XFFu;

<? if useTextureRect then ?>
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
<? else -- useTextureRect
?>
	fragColor = texture(palTex, vec2((float(colorIndex)+.5)/<?=clnumber(paletteSize)?>, .5));
	if (fragColor.a == 0.) discard;
<? end -- useTextureRect
?>
}
]], 		{
				fragColorUseFloat = fragColorUseFloat,
				useTextureRect = useTextureRect,
				clnumber = clnumber,
				spriteSheetSize = spriteSheetSize,
				paletteSize = paletteSize,
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
uniform uint mapIndexOffset;
uniform int draw16Sprites;	 	//0 = draw 8x8 sprites, 1 = draw 16x16 sprites
<? if useTextureRect then ?>
uniform usampler2DRect mapTex;
uniform usampler2DRect tileTex;
uniform usampler2DRect palTex;
<? else ?>
uniform usampler2D mapTex;
uniform usampler2D tileTex;
uniform usampler2D palTex;
<? end ?>

const float spriteSheetSizeX = <?=clnumber(spriteSheetSize.x)?>;
const float spriteSheetSizeY = <?=clnumber(spriteSheetSize.y)?>;
const uint tilemapSizeX = <?=tilemapSize.x?>;
const uint tilemapSizeY = <?=tilemapSize.y?>;

void main() {
	// convert from input normalized coordinates to tilemap texel coordinates
	// [0, tilemapSize)^2
	uvec2 tci = uvec2(
		uint(tcv.x * float(tilemapSizeX << draw16Sprites)),
		uint(tcv.y * float(tilemapSizeY << draw16Sprites))
	);

	// convert to map texel coordinate
	// [0, tilemapSize)^2
	uvec2 tileTC = uvec2(
		(tci.x >> (3 + draw16Sprites)) & 0xFFu,
		(tci.y >> (3 + draw16Sprites)) & 0xFFu
	);

	//read the tileIndex in mapTex at tileTC
	//mapTex is R16, so red channel should be 16bpp (right?)
	// how come I don't trust that and think I'll need to switch this to RG8 ...
<? if useTextureRect then ?>
	uint tileIndex = texture(mapTex, tileTC).r;
<? else ?>
	uint tileIndex = texture(mapTex, vec2(
		float(tileTC.x) / float(tilemapSizeX),
		float(tileTC.y) / float(tilemapSizeY)
	)).r;
<? end ?>

	//[0, 31)^2 = 5 bits for tile tex sprite x, 5 bits for tile tex sprite y
	uvec2 tileTexTC = uvec2(
		tileIndex & 0x1Fu,					// tilemap bits 0..4
		(tileIndex >> 5) & 0x1Fu			// tilemap bits 5..9
	);
	uint palHi = (tileIndex >> 10) & 0xFu;	// tilemap bits 10..13
	if ((tileIndex & (1u<<14)) != 0u) tci.x = ~tci.x;	// tilemap bit 14
	if ((tileIndex & (1u<<15)) != 0u) tci.y = ~tci.y;	// tilemap bit 15

	uint mask = (1u << (3 + draw16Sprites)) - 1u;
	// [0, spriteSize)^2
	tileTexTC = uvec2(
		(tci.x & mask) | (tileTexTC.x << (3)),
		(tci.y & mask) | (tileTexTC.y << (3))
	);

	// tileTex is R8 indexing into our palette ...
<? if useTextureRect then ?>
	uint colorIndex = texture(tileTex, tileTexTC).r;
<? else ?>
	uint colorIndex = texture(tileTex, vec2(
		float(tileTexTC.x) / spriteSheetSizeX,
		float(tileTexTC.y) / spriteSheetSizeY
	)).r;
<? end ?>
	colorIndex |= palHi << 4;

//debug:
//colorIndex = tileIndex;

<? if useTextureRect then ?>
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
<? else -- useTextureRect
?>
	fragColor = texture(palTex, vec2((float(colorIndex)+.5)/<?=clnumber(paletteSize)?>, .5));
	if (fragColor.a == 0.) discard;
<? end -- useTextureRect
?>
}
]],			{
				fragColorUseFloat = fragColorUseFloat,
				useTextureRect = useTextureRect,
				clnumber = clnumber,
				spriteSheetSize = spriteSheetSize,
				tilemapSize = tilemapSize,
				paletteSize = paletteSize,
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

end

return {
	argb8888revto5551 = argb8888revto5551,
	rgba5551_to_rgba8888_4ch = rgba5551_to_rgba8888_4ch,
	rgba8888_4ch_to_5551 = rgba8888_4ch_to_5551,
	resetFont = resetFont,
	resetFontOnSheet = resetFontOnSheet,
	resetPalette = resetPalette,
	initDraw = initDraw,
}
