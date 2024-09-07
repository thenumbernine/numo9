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
local string = require 'ext.string'
local table = require 'ext.table'
local getTime = require 'ext.timer'.getTime
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

local Console = require 'numo9.console'
local EditCode = require 'numo9.editcode'


local paletteSize = 256
local frameBufferSize = vec2i(256, 256)
local spriteSheetSize = vec2i(256, 256)
local spriteSize = vec2i(8, 8)
local spritesPerSheet = vec2i(spriteSheetSize.x / spriteSize.x, spriteSheetSize.y / spriteSize.y)
local spritesPerFrameBuffer = vec2i(frameBufferSize.x / spriteSize.x, frameBufferSize.y / spriteSize.y)

local App = require 'glapp.view'.apply(GLApp):subclass()

App.title = 'NuMo9'
App.width = 720
App.height = 512

App.paletteSize = paletteSize
App.frameBufferSize = frameBufferSize
App.spriteSheetSize = spriteSheetSize
App.spriteSize = spriteSize
App.spritesPerSheet = spritesPerSheet
App.spritesPerFrameBuffer = spritesPerFrameBuffer 

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

function rgb888revto5551(rgba)
	local r = bit.band(bit.rshift(rgba, 16), 0xff)
	local g = bit.band(bit.rshift(rgba, 8), 0xff)
	local b = bit.band(rgba, 0xff)
	local abgr = bit.bor(
		bit.rshift(r, 3),
		bit.lshift(bit.rshift(g, 3), 5),
		bit.lshift(bit.rshift(b, 3), 10),
		bit.lshift(1, 15)
	)
	assert(abgr >= 0 and abgr <= 0xffff, ('%x'):format(abgr))
	return abgr
end

function App:initGL()

	self.env = setmetatable({
		pairs = pairs,
		ipairs = ipairs,
		error = error,
		select = select,
		pcall = pcall,
		xpcall = xpcall,
		load = load,
		clear = function(...) return self:clearScreen(...) end,
		print = function(...) return self.con:print(...) end,
		write = function(...) return self.con:write(...) end,
		run = function(...) self:runCmd(self.editCode.text) end,
		-- TODO don't do this either
		app = self,
	}, {
		-- TODO don't __index=_G and sandbox it instead
		__index = _G,
	})

	self.fb = GLFBO{
		width = frameBufferSize.x,
		height = frameBufferSize.y,
	}:unbind()

	self.spriteTex = self:makeTexFromImage{
		-- this file is rgba, so split off just one channel from it:
		image = Image'font.png':split(),
		internalFormat = gl.GL_R8UI,
		format = gl.GL_RED_INTEGER,
		type = gl.GL_UNSIGNED_BYTE,
	}
	
	-- palette is 256 x 1 x 16 bpp (5:5:5:1)
	self.palTex = self:makeTexFromImage{
		image = Image(paletteSize, 1, 1, 'unsigned short',
		--[[ garbage colors
		function(i)
			return math.floor(math.random() * 0xffff)
		end
		--]]
		-- [[ builtin palette
		-- https://en.wikipedia.org/wiki/List_of_software_palettes
		table{
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
		}:mapi(rgb888revto5551):rep(16)
		--]]
		),
		internalFormat = gl.GL_RGB5_A1,
		format = gl.GL_RGBA,
		type = gl.GL_UNSIGNED_SHORT_1_5_5_5_REV,	-- 'REV' means first channel first bit ... smh
	}
--print('palTex\n'..imageToHex(self.palTex.image))

	-- screen is 256 x 256 x 8bpp
	self.screenTex = self:makeTexFromImage{
		image = Image(frameBufferSize.x, frameBufferSize.y, 1, 'unsigned char',
			-- [[ init to garbage pixels
			function(i,j)
				return math.floor(math.random() * 0xff)
			end
			--]]
		),
		internalFormat = gl.GL_R8UI,
		format = gl.GL_RED_INTEGER,
		type = gl.GL_UNSIGNED_BYTE,
	}
--print('screenTex\n'..imageToHex(self.screenTex.image))

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

	local glslVersion = '410'

	-- used for drawing our 8bpp framebuffer to the screen
	self.quad8bppToRGBObj = GLSceneObject{
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
uniform usampler2D screenTex;
uniform usampler2D palTex;
void main() {
	uint index = texture(screenTex, tcv).r;
	float indexf = float(index) / 255.;
	fragColor = texture(palTex, vec2((indexf * <?=clnumber(paletteSize-1)?> + .5) / <?=clnumber(paletteSize)?>, .5));
}
]], 		{
				clnumber = clnumber,
				paletteSize = paletteSize,
			}),
			uniforms = {
				screenTex = 0,
				palTex = 1,
			},
		},
		texs = {
			self.screenTex,
			self.palTex,
		},
		geometry = self.quadGeom,
		-- reset every frame
		uniforms = {
			mvProjMat = self.view.mvProjMat.ptr,
		},
	}

	self.quad4bppObj = GLSceneObject{
		program = {
			version = glslVersion,
			precision = 'best',
			vertexCode = [[
in vec2 vertex;
out vec2 tcv;
uniform vec4 box;	//x,y,w,h
uniform vec4 tcbox;	//x,y,w,h
uniform mat4 mvProjMat;
void main() {
	tcv = tcbox.xy + vertex * tcbox.zw;
	vec2 rvtx = box.xy + vertex * box.zw;
	gl_Position = mvProjMat * vec4(rvtx, 0., 1.);
}
]],
			fragmentCode = template([[
in vec2 tcv;
out uvec4 fragColor;

//For now this is an integer added to the 0-15 4-bits of the sprite tex.
//You can set the top 4 bits and it'll work just like OR'ing the high color index nibble.
//Or you can set it to low numbers and use it to offset the palette.
//Should this be high bits? or just an offset to OR? or to add?
uniform uint paletteIndex;	

// Reads 4 bits from wherever shift location you provide.
uniform usampler2D spriteTex;

// Specifies which bit to read from at the sprite.
//  0 = read sprite low nibble.
//  4 = read sprite high nibble.
//  other = ???
uniform uint spriteBit;

void main() {
	// TODO provide a shift uniform for picking lo vs hi nibble
	// only use the lower 4 bits ...
	uint colorIndex = (texture(spriteTex, tcv).r >> spriteBit) & 0xFu;
	//colorIndex should hold 
	colorIndex += paletteIndex;
	colorIndex &= 0XFFu;
	// write the 8bpp colorIndex to the screen, use tex to draw it
	fragColor = uvec4(
		colorIndex,
		0,
		0,
		0xFFu
	);

}
]], 		{
				clnumber = clnumber,
				paletteSize = paletteSize,
			}),
			uniforms = {
				spriteTex = 0,
				paletteIndex = 0,
				spriteBit = 0,
			},
		},
		texs = {
			self.spriteTex,
		},
		geometry = self.quadGeom,
		-- reset every frame
		uniforms = {
			mvProjMat = self.view.mvProjMat.ptr,
			box = {0, 0, 8, 8},
			tcbox = {0, 0, 1, 1},
		},
	}

	self.quadSolidObj = GLSceneObject{
		program = {
			version = glslVersion,
			precision = 'best',
			vertexCode = [[
in vec2 vertex;
uniform vec4 box;	//x,y,w,h
uniform mat4 mvProjMat;
void main() {
	vec2 rvtx = box.xy + vertex * box.zw;
	gl_Position = mvProjMat * vec4(rvtx, 0., 1.);
}
]],
			fragmentCode = [[
out vec4 fragColor;
uniform float colorIndex;
void main() {
	fragColor = vec4(colorIndex, 0., 0., 1.);
}
]],
		},
		geometry = self.quadGeom,
		-- reset every frame
		uniforms = {
			mvProjMat = self.view.mvProjMat.ptr,
			colorIndex = 0,
			box = {0, 0, 8, 8},
		},
	}

	local fb = self.fb
	fb:bind()
	fb:setColorAttachmentTex2D(self.screenTex.id)
	local res,err = fb.check()
	if not res then
		print(err)
		print(debug.traceback())
	end
	fb:unbind()

	local view = self.view
	view.ortho = true
	view.orthoSize = 1

	self.editCode = EditCode{app=self}
	self.con = Console{app=self}
	--self.runFocus = self.con
	self.runFocus = self.editCode
end

-- [[ also in sand-attack ... hmmmm ... 
-- consider putting somewhere common, maybe in gl.tex2d ?
-- maybe just save .image in gltex2d?
function App:makeTexFromImage(args)
glreport'here'	
	local image = assert(args.image)
	if image.channels ~= 1 then print'DANGER - non-single-channel Image!' end
	local tex = GLTex2D{
		-- rect would be nice
		-- but how come wrap doesn't work with texture_rect? 
		-- how hard is it to implement a modulo operator?
		-- or another question, which is slower, integer modulo or float conversion in glsl?
		--target = gl.GL_TEXTURE_RECTANGLE,
		internalFormat = args.internalFormat or gl.GL_RGBA,
		format = args.format or gl.GL_RGBA,
		type = args.type or gl.GL_UNSIGNED_BYTE,
		
		width = tonumber(image.width),
		height = tonumber(image.height),
		wrap = args.wrap or {
			s = gl.GL_REPEAT,
			t = gl.GL_REPEAT,
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

-- static method
function App:makeTexWithBlankImage(size)
	local img = Image(size.x, size.y, 4, 'unsigned char')
	ffi.fill(img.buffer, 4 * size.x * size.y)
	return self:makeTexFromImage(img)
end
--]]

function App:update()
	App.super.update(self)

	gl.glViewport(0, 0, self.width, self.height)
	gl.glClearColor(.1, .2, .3, 1.)
	gl.glClear(bit.bor(gl.GL_COLOR_BUFFER_BIT, gl.GL_DEPTH_BUFFER_BIT))

	if self.runFocus.update then
		self.runFocus:update(getTime())
	end

-- [[ redo ortho projection matrix
-- every frame ... not necessary if the screen is static
-- but mebbe I want mode7 or something idk
	local view = self.view
--	view:setup(self.width / self.height)
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
	local sceneObj = self.quad8bppToRGBObj
	sceneObj.uniforms.mvProjMat = view.mvProjMat.ptr
--]]
	
	gl.glViewport(0, 0, self.width, self.height)

	sceneObj:draw()
end

function App:drawSolidRect(x, y, w, h, colorIndex)
	-- TODO move a lot of this outside into the update loop start/stop
	local fb = self.fb
	fb:bind()
	gl.glViewport(0, 0, frameBufferSize.x, frameBufferSize.y)

	local view = self.view
	view.projMat:setOrtho(0, frameBufferSize.x, 0, frameBufferSize.y, -1, 1)
	view.mvMat:setIdent()
	view.mvProjMat:mul4x4(view.projMat, view.mvMat)

	local sceneObj = self.quadSolidObj
	sceneObj.uniforms.mvProjMat = view.mvProjMat.ptr
	sceneObj.uniforms.colorIndex = colorIndex
	settable(sceneObj.uniforms.box, x, y, w, h)
	sceneObj:draw()
	fb:unbind()
end

function App:clearScreen(colorIndex)
	colorIndex = colorIndex or 0
	local fb = self.fb
	self:drawSolidRect(0, 0, frameBufferSize.x, frameBufferSize.y, colorIndex)
end

--[[
index = 5 bits x , 5 bits y
paletteIndex = byte value ... high 4 bits holds the palette index ... add this to the color (or should I or- it?)
--]]
function App:drawSprite(x, y, spriteIndex, paletteIndex)
	paletteIndex = paletteIndex or 0
	-- TODO move a lot of this outside into the update loop start/stop
	local fb = self.fb
	fb:bind()
	gl.glViewport(0, 0, frameBufferSize.x, frameBufferSize.y)

	local view = self.view
	view.projMat:setOrtho(0, frameBufferSize.x, 0, frameBufferSize.y, -1, 1)
	view.mvMat:setIdent()
	view.mvProjMat:mul4x4(view.projMat, view.mvMat)

	local sceneObj = self.quad4bppObj
	local uniforms = sceneObj.uniforms
	
	uniforms.mvProjMat = view.mvProjMat.ptr
	uniforms.paletteIndex = paletteIndex	-- user has to specify high-bits

	-- vram / sprite sheet is 32 sprites wide ... 256 pixels wide, 8 pixels per sprite
	local tx = spriteIndex % spritesPerSheet.x
	local ty = (spriteIndex - tx) / spritesPerSheet.x
	settable(uniforms.tcbox, 
		tx / tonumber(spritesPerSheet.x),
		ty / tonumber(spritesPerSheet.y),
		1 / tonumber(spritesPerSheet.x),
		1 / tonumber(spritesPerSheet.y)
	)
	settable(uniforms.box, x, y, spriteSize.x, spriteSize.y)
	sceneObj:draw()
	fb:unbind()
end

function App:drawChar(...)
	-- always the same? TODO think out sprite tables builtin vs customizable
	return self:drawSprite(...)
end

function App:drawText(x, y, text, colorIndex)
	for i=1,#text do
		self:drawChar(x, y, text:byte(i), colorIndex)
		x = x + spriteSize.x
	end
end

-- system() function
function App:runCmd(cmd)
	local f, msg = load(cmd, nil, 't', self.env)
	if not f then
		return f, msg
	else
		return xpcall(f, function(err)
			return err..'\n'..debug.traceback()
		end) 
	end
end

function App:event(e)
	if self.runFocus.event then
		self.runFocus:event(e)
	end
end

-- used by event-handling
local shiftFor = {
	-- letters handled separate
	[('`'):byte()] = ('~'):byte(),
	[('1'):byte()] = ('!'):byte(),
	[('2'):byte()] = ('@'):byte(),
	[('3'):byte()] = ('#'):byte(),
	[('4'):byte()] = ('$'):byte(),
	[('5'):byte()] = ('%'):byte(),
	[('6'):byte()] = ('^'):byte(),
	[('7'):byte()] = ('&'):byte(),
	[('8'):byte()] = ('*'):byte(),
	[('9'):byte()] = ('('):byte(),
	[('0'):byte()] = (')'):byte(),
	[('-'):byte()] = ('_'):byte(),
	[('='):byte()] = ('+'):byte(),
	[('['):byte()] = ('{'):byte(),
	[(']'):byte()] = ('}'):byte(),
	[('\\'):byte()] = ('|'):byte(),
	[(';'):byte()] = (':'):byte(),
	[("'"):byte()] = ('"'):byte(),
	[(','):byte()] = (','):byte(),
	[('<'):byte()] = ('>'):byte(),
	[('/'):byte()] = ('?'):byte(),
}
function App:getKeySymForShift(sym, shift)
	if sym >= sdl.SDLK_a and sym <= sdl.SDLK_z then
		if shift then
			sym = sym - 32
		end
		return sym
	-- add with non-standard shift capitalizing
	elseif sym == sdl.SDLK_SPACE
	or sym == sdl.SDLK_BACKSPACE 	-- ???
	then
		return sym
	else
		local shiftSym = shiftFor[sym]
		if shiftSym then
			return shift and shiftSym or sym
		end
	end
	-- return nil = not a char-producing key
end

return App
