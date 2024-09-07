local ffi = require 'ffi'
local string = require 'ext.string'
local table = require 'ext.table'
local Image = require 'image'
local sdl = require 'sdl'
local gl = require 'gl'
local glreport = require 'gl.report'
local GLApp = require 'glapp'
local GLTex2D = require 'gl.tex2d'
local GLFBO = require 'gl.fbo'
local GLProgram = require 'gl.program'
local GLSceneObject = require 'gl.sceneobject'
local vec2i = require 'vec-ffi.vec2i'

local App = require 'glapp.view'.apply(GLApp):subclass()

App.title = 'NuMo9'

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

	self.fb = GLFBO{
		width = 256,
		height = 256,
	}:unbind()

	self.spriteTex = self:makeTexFromImage{
		-- ok so this is rgba ...
		image = Image'font.png',
	}
	
	-- palette is 256 x 1 x 16 bpp (5:5:5:1)
	self.palTex = self:makeTexFromImage{
		image = Image(256, 1, 1, 'unsigned short',
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
		type = gl.GL_UNSIGNED_SHORT_5_5_5_1,
	}
--print('palTex\n'..imageToHex(self.palTex.image))

	-- screen is 256 x 256 x 8bpp
	self.screenTex = self:makeTexFromImage{
		image = Image(self.fb.width, self.fb.height, 1, 'unsigned char',
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

	self.drawShader = GLProgram{
		version = '410',
		precision = 'best',
		vertexCode = [[
in vec2 vertex;
out vec2 tcv;
uniform mat4 mvProjMat;
uniform vec4 tcbox;	//x,y,w,h
void main() {
	//tcv = vertex;
	tcv = tcbox.xy + vertex * tcbox.zw;
	gl_Position = mvProjMat * vec4(vertex, 0., 1.);
}
]],
		fragmentCode = [[
in vec2 tcv;
out vec4 fragColor;
uniform sampler2D indexTex;
uniform sampler2D palTex;
void main() {
	// TODO integer lookup ...
	float index = texture(indexTex, tcv).r;
	fragColor = texture(palTex, vec2((index * 255. + .5) / 256., .5));
//	fragColor = vec4(tcv, .5, 1.);
}
]],
		uniforms = {
			indexTex = 0,
			palTex = 1,
		},
	}:useNone()

	self.quadObj = GLSceneObject{
		program = self.drawShader,
		texs = {
			self.screenTex,
			self.palTex,
		},
		vertexes = {
			data = {
				0, 0,
				1, 0,
				0, 1,
				1, 1,
			},
			dim = 2,
		},
		geometry = {
			mode = gl.GL_TRIANGLE_STRIP,
		},
		-- reset every frame
		uniforms = {
			mvProjMat = self.view.mvProjMat.ptr,
		},
	}

	local view = self.view
	view.ortho = true
	view.orthoSize = 1

	-- virtual console stuff
	self.cursorPos = vec2i(0, 0)
	self.cursorSize = vec2i(8, 8)
	self.cmdbuf = ''

	self:print(self.title)
	self:write'> '
end

-- [[ also in sand-attack ... hmmmm ... 
-- consider putting somewhere common, maybe in gl.tex2d ?
-- maybe just save .image in gltex2d?
function App:makeTexFromImage(args)
glreport'here'	
	local image = assert(args.image)
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
	self.quadObj.uniforms.mvProjMat = view.mvProjMat.ptr
--]]
	
	gl.glViewport(0, 0, self.width, self.height)

	self.quadObj.texs[1] = self.screenTex
	self.quadObj.uniforms.tcbox = {0, 0, 1, 1}
	self.quadObj:draw()
end

function App:offsetCursor(dx, dy)
	local fb = self.fb
	self.cursorPos.x = self.cursorPos.x + dx
	self.cursorPos.y = self.cursorPos.y + dy
	
	while self.cursorPos.x < 0 do
		self.cursorPos.x = self.cursorPos.x + fb.width
		self.cursorPos.y = self.cursorPos.y - self.cursorSize.y
	end
	while self.cursorPos.x >= fb.width do
		self.cursorPos.x = self.cursorPos.x - fb.width
		self.cursorPos.y = self.cursorPos.y + self.cursorSize.y
	end

	while self.cursorPos.y < 0 do
		self.cursorPos.y = self.cursorPos.y + fb.height
	end
	while self.cursorPos.y >= fb.height do
		self.cursorPos.y = self.cursorPos.y - fb.height
	end
end

function App:drawChar(ch)
	local fb = self.fb
	fb:bind()
	fb:setColorAttachmentTex2D(self.screenTex.id)
	
	local res,err = fb.check()
	if not res then
		print(err)
		print(debug.traceback())
	end

	gl.glViewport(0, 0, fb.width, fb.height)

	local view = self.view
	view.projMat:setOrtho(0, fb.width, 0, fb.height, -1, 1)
	view.mvMat
		:setIdent()
		:applyTranslate(self.cursorPos.x, self.cursorPos.y)
		:applyScale(self.cursorSize.x, self.cursorSize.y)
	view.mvProjMat:mul4x4(view.projMat, view.mvMat)
	
	self.quadObj.texs[1] = self.spriteTex
	self.quadObj.texs[2] = self.palTex
	self.quadObj.uniforms.mvProjMat = view.mvProjMat.ptr

	-- vram / sprite sheet is 32 sprites wide ... 256 pixels wide, 8 pixels per sprite
	local tx = ch % 32
	local ty = (ch - tx) / 32
	self.quadObj.uniforms.tcbox = {
		tx / 32,
		ty / 32,
		1 / 32,
		1 / 32
	}
	self.quadObj:draw()
	fb:unbind()

	self:offsetCursor(self.cursorSize.x, 0)
end

function App:runCmd()
	local cmd = self.cmdbuf
	self.cmdbuf = ''
	self:write'\n'
	
	local env = {
		print = function(...) return self:print(...) end,
		io = {
			write = function(...) return self:write(...) end,
		},
	}
	local f, msg = load(cmd, nil, 't', env)
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
		self:offsetCursor(-self.cursorSize.x, 0)
		self:drawChar((' '):byte())
		self:offsetCursor(-self.cursorSize.x, 0)
	elseif ch == 10 or ch == 13 then
		self.cursorPos.x = 0
		self.cursorPos.y = self.cursorPos.y + self.cursorSize.y
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
		self:write(tostring(select(1, ...)))
	end
	self:write'\n'
end

function App:addCharToCmd(ch)
print(self.cmdbuf, ch)	
	if ch == 8
	and #self.cmdbuf > 0
	then
		self.cmdbuf = self.cmdbuf:sub(1,-2)
		self:addCharToScreen(ch)
	else
		self.cmdbuf = self.cmdbuf .. string.char(ch)
		self:addCharToScreen(ch)
	end
end

local _abyte = ('a'):byte()
function App:event(e)
	if e[0].type == sdl.SDL_KEYDOWN 
	or e[0].type == sdl.SDL_KEYUP
	then
		local press = e[0].type == sdl.SDL_KEYDOWN
		local keysym = e[0].key.keysym
		local sym = keysym.sym
		local mod = keysym.mod
		if press then
			if sym >= sdl.SDLK_a and sym <= sdl.SDLK_z 
			or sym >= sdl.SDLK_0 and sym <= sdl.SDLK_9
			or sym == sdl.SDLK_BACKQUOTE
			or sym == sdl.SDLK_MINUS
			or sym == sdl.SDLK_EQUALS
			or sym == sdl.SDLK_LEFTBRACKET
			or sym == sdl.SDLK_RIGHTBRACKET
			or sym == sdl.SDLK_BACKSLASH
			or sym == sdl.SDLK_QUOTE
			or sym == sdl.SDLK_SEMICOLON
			or sym == sdl.SDLK_COMMA
			or sym == sdl.SDLK_PERIOD
			or sym == sdl.SDLK_SLASH
			or sym == sdl.SDLK_SPACE
			then
				if bit.band(mod, sdl.SDLK_LSHIFT) ~= 0 then
					sym = sym - 32
				end
				self:addCharToCmd(sym)
			elseif sym == sdl.SDLK_BACKSPACE then
				self:addCharToCmd(sym)
			elseif sym == sdl.SDLK_RETURN then
				self:runCmd()
			end
		end
	end
end

return App
