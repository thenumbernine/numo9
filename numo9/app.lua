local ffi = require 'ffi'
local template = require 'template'
local string = require 'ext.string'
local table = require 'ext.table'
local getTime = require 'ext.timer'.getTime
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
local vec2i = require 'vec-ffi.vec2i'
local Editor = require 'numo9.editor'

local paletteSize = 256
local frameBufferSize = vec2i(256, 256)
local spriteSheetSize = vec2i(256, 256)
local spriteSize = vec2i(8, 8)
local spritesPerSheet = vec2i(spriteSheetSize.x / spriteSize.x, spriteSheetSize.y / spriteSize.y)

local App = require 'glapp.view'.apply(GLApp):subclass()

App.title = 'NuMo9'

App.paletteSize = paletteSize
App.frameBufferSize = frameBufferSize
App.spriteSheetSize = spriteSheetSize
App.spriteSize = spriteSize
App.spritesPerSheet = spritesPerSheet

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
	
	self.env = {
		pairs = pairs,
		ipairs = ipairs,
		error = error,
		select = select,
		pcall = pcall,
		xpcall = xpcall,
		load = load,
		clear = function(...) return self:clearScreen(...) end,
		print = function(...) return self:print(...) end,
		write = function(...) return self:write(...) end,
	}

	self.fb = GLFBO{
		width = frameBufferSize.x,
		height = frameBufferSize.y,
	}:unbind()

	self.spriteTex = self:makeTexFromImage{
		-- ok so this is rgba ...
		image = Image'font.png':split(),
		internalFormat = gl.GL_R8,
		format = gl.GL_RED,
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
		internalFormat = gl.GL_RGBA,
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
		internalFormat = gl.GL_R8,
		format = gl.GL_RED,
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
out vec4 fragColor;
uniform sampler2D indexTex;
uniform sampler2D palTex;
void main() {
	float index = texture(indexTex, tcv).r;
	fragColor = texture(palTex, vec2((index * <?=clnumber(paletteSize-1)?> + .5) / <?=clnumber(paletteSize)?>, .5));
}
]], 		{
				clnumber = clnumber,
				paletteSize = paletteSize,
			}),
			uniforms = {
				indexTex = 0,
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
out vec4 fragColor;
uniform sampler2D indexTex;
uniform sampler2D palTex;
void main() {
	// TODO integer lookup ...
	float index = texture(indexTex, tcv).r;
	// just write the 8bpp index to the screen, use tex to draw it
	fragColor = vec4(index, 0., 0., 1.);
}
]], 		{
				clnumber = clnumber,
				paletteSize = paletteSize,
			}),
			uniforms = {
				indexTex = 0,
				palTex = 1,
			},
		},
		texs = {
			self.spriteTex,
			self.palTex,
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

	-- virtual console stuff
	self.cursorPos = vec2i(0, 0)
	self.cmdbuf = ''

	-- TODO turn this into a console or rom or whatever
	self.editor = Editor{app=self}
end

-- [[ also in sand-attack ... hmmmm ... 
-- consider putting somewhere common, maybe in gl.tex2d ?
-- maybe just save .image in gltex2d?
function App:makeTexFromImage(args)
glreport'here'	
	local image = assert(args.image)
	if image.channels ~= 1 then print'DANGER - non-single-channel Image!' end
	local tex = GLTex2D{
		internalFormat = args.internalFormat or gl.GL_RGBA,
		format = args.format or gl.GL_RGBA,
		type = args.type or gl.GL_UNSIGNED_BYTE,
		
		width = tonumber(image.width),
		height = tonumber(image.height),
		wrap = args.wrap or {
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

	self.editor:update(getTime())

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

-- should cursor be a 'app' property or an 'editor' property?
-- should the low-level os be 'editor' or its own thing?
function App:offsetCursor(dx, dy)
	local fb = self.fb
	self.cursorPos.x = self.cursorPos.x + dx
	self.cursorPos.y = self.cursorPos.y + dy
	
	while self.cursorPos.x < 0 do
		self.cursorPos.x = self.cursorPos.x + frameBufferSize.x
		self.cursorPos.y = self.cursorPos.y - spriteSize.y
	end
	while self.cursorPos.x >= frameBufferSize.x do
		self.cursorPos.x = self.cursorPos.x - frameBufferSize.x
		self.cursorPos.y = self.cursorPos.y + spriteSize.y
	end

	while self.cursorPos.y < 0 do
		self.cursorPos.y = self.cursorPos.y + frameBufferSize.y
	end
	while self.cursorPos.y >= frameBufferSize.y do
		self.cursorPos.y = self.cursorPos.y - frameBufferSize.y
	end
end

function App:drawSolidRect(x,y,w,h,colorIndex)
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
palHiNibble = high 4 bits of the palette
--]]
function App:drawSprite(x,y,spriteIndex,palHiNibble)
	-- TODO move a lot of this outside into the update loop start/stop
	local fb = self.fb
	fb:bind()
	gl.glViewport(0, 0, frameBufferSize.x, frameBufferSize.y)

	local view = self.view
	view.projMat:setOrtho(0, frameBufferSize.x, 0, frameBufferSize.y, -1, 1)
	view.mvMat:setIdent()
	view.mvProjMat:mul4x4(view.projMat, view.mvMat)

	local sceneObj = self.quad4bppObj
	sceneObj.uniforms.mvProjMat = view.mvProjMat.ptr

	-- vram / sprite sheet is 32 sprites wide ... 256 pixels wide, 8 pixels per sprite
	local tx = spriteIndex % spritesPerSheet.x
	local ty = (spriteIndex - tx) / spritesPerSheet.x
	settable(sceneObj.uniforms.tcbox, 
		tx / tonumber(spritesPerSheet.x),
		ty / tonumber(spritesPerSheet.y),
		1 / tonumber(spritesPerSheet.x),
		1 / tonumber(spritesPerSheet.y)
	)
	settable(sceneObj.uniforms.box, 
		x,
		y,
		spriteSize.x,
		spriteSize.y
	)
	sceneObj:draw()
	fb:unbind()
end

function App:drawChar(ch)
	self:drawSprite(
		self.cursorPos.x,
		self.cursorPos.y,
		ch
	)
	self:offsetCursor(spriteSize.x, 0)
end

function App:runCmd()
	local cmd = self.cmdbuf
	self.cmdbuf = ''
	self:write'\n'
	
	local f, msg = load(cmd, nil, 't', self.env)
	if not f then
		self:print(tostring(msg))
	else
		local err
		if not xpcall(f, function(err_)
			err = err_..'\n'..debug.traceback()
		end) then
			self:print(err)
		end
	end
	self:write'> '
end

function App:addCharToScreen(ch)
	if ch == 8 then
		self:offsetCursor(-spriteSize.x, 0)
		self:drawChar((' '):byte())
		self:offsetCursor(-spriteSize.x, 0)
	elseif ch == 10 or ch == 13 then
		self:drawChar((' '):byte())	-- just in case the cursor is drawing white on the next char ...
		self.cursorPos.x = 0
		self.cursorPos.y = self.cursorPos.y + spriteSize.y
	else
		self:drawChar(ch)
	end
end

function App:write(...)
	for j=1,select('#', ...) do
		local s = tostring(select(j, ...))
		for i=1,#s do
			self:addCharToScreen(s:byte(i,i))
		end
	end
end

function App:print(...)
	for i=1,select('#', ...) do
		if i > 1 then self:write'\t' end
		self:write(tostring(select(i, ...)))
	end
	self:write'\n'
end

function App:addCharToCmd(ch)
	if ch == 8 then
		if #self.cmdbuf > 0 then
			self.cmdbuf = self.cmdbuf:sub(1,-2)
			self:addCharToScreen(ch)
		end
	else
		self.cmdbuf = self.cmdbuf .. string.char(ch)
		self:addCharToScreen(ch)
	end
end

function App:event(e)
	local editor = self.editor
	if editor.active then
		return editor:event(e)
	end
end

return App
