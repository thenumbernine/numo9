--[[
goes with numo9/video.lua and numo9/blob/image.lua
TODO honestly blob has a .image and blob.ramgpu has a .image
just merge this into .blob for BlobImage
and only use it separately for framebufferRAMs
idk that it even matters if framebufferRAMs and BlobImage.ramgpu's have the same interface
--]]
require 'ext.gc'	-- make sure luajit can __gc lua-tables
local ffi = require 'ffi'
local class = require 'ext.class'
local math = require 'ext.math'
local assert = require 'ext.assert'
local Image = require 'image'
local gl = require 'gl'
local GLTex2D = require 'gl.tex2d'
local glreport = require 'gl.report'

--[[
makes an image whose buffer is at a location in RAM
makes a GLTex2D that goes with that image
provides dirty/flushing functions
--]]
local RAMGPUTex = class()

--[[
args:
	app = app
	addr = where in RAM

	Image ctor:
	width
	height
	channels
	ctype
	src (optional)

	Tex ctor:
	target (optional)
	internalFormat
	gltype
	glformat
	wrap
	magFilter
	minFilter
--]]
function RAMGPUTex:init(args)
--DEBUG:print'RAMGPUTex:init begin'
glreport'before RAMGPUTex:init'
	local app = assert.index(args, 'app')
	self.app = app
	self.addr = assert.index(args, 'addr')
	assert.ge(self.addr, 0)
	local width = assert(tonumber(assert.index(args, 'width')))
	local height = assert(tonumber(assert.index(args, 'height')))
	local channels = assert.index(args, 'channels')
	if channels ~= 1 then print'DANGER - non-single-channel Image!' end
	local ctype = assert.index(args, 'ctype')
	local ctypeSize = ffi.sizeof(ctype)
	self.pixelSize = channels * ctypeSize

	self.size = width * height * channels * ctypeSize
	self.addrEnd = self.addr + self.size
	assert.le(self.addrEnd, app.memSize)
	local ptr = ffi.cast('uint8_t*', app.ram) + self.addr
	local src = args.src

--DEBUG:print(('RAMGPU 0x%x - 0x%x (size 0x%x)'):format(self.addr, self.addrEnd, self.size))

	local image = Image(width, height, channels, ctype, src)
	self.image = image
	if src then	-- if we specified a src to the Image then copy it into RAM before switching Image pointers to point at RAM
		ffi.copy(ptr, image.buffer, self.size)
	end
	-- TODO allow Image construction with ptr
	local formatp = ffi.typeof('$*', image.format)
	image.buffer = ffi.cast(formatp, ptr)

	local tex = GLTex2D{
		target = args.target,
		internalFormat = args.internalFormat or gl.GL_RGBA,
		format = args.glformat or gl.GL_RGBA,
		type = args.gltype or gl.GL_UNSIGNED_BYTE,

		width = width,
		height = height,
		wrap = args.wrap or { -- texture_rectangle doens't support repeat ...
			s = gl.GL_CLAMP_TO_EDGE,
			t = gl.GL_CLAMP_TO_EDGE,
		},
		minFilter = args.minFilter or gl.GL_NEAREST,
		--minFilter = args.minFilter or gl.GL_LINEAR_MIPMAP_LINEAR,
		--minFilter = gl.GL_LINEAR_MIPMAP_LINEAR,
		magFilter = args.magFilter or gl.GL_NEAREST,
		--magFilter = gl.GL_LINEAR,
		data = ptr,	-- ptr is stored
		--generateMipmap = true,
	}
-- this will fail when the menu font is being used
--assert.eq(tex.data, ffi.cast('uint8_t*', self.image.buffer))
	self.tex = tex
glreport'after RAMGPUTex:init'
--DEBUG:print'RAMGPUTex:init done'
end

-- manually free GPU resources
function RAMGPUTex:delete()
	if self.tex then
		self.tex:delete()
		self.tex = nil
	end
end

RAMGPUTex.__gc = RAMGPUTex.delete

function RAMGPUTex:overlaps(other)
	return self.addr < other.addrEnd and other.addr < self.addrEnd
end

-- TODO gonna subclass this soon ...
-- assumes it is being called from within the render loop
function RAMGPUTex:checkDirtyCPU()
	if not self.dirtyCPU then return end
	-- we should never get in a state where both CPU and GPU are dirty
	-- if someone is about to write to one then it shoudl test the other and flush it if it's dirty, then set the one
	assert(not self.dirtyGPU, "someone dirtied both cpu and gpu without flushing either")
	local app = self.app
	local tex = self.tex
	local fb = app.fb
	if app.inUpdateCallback then
		fb:unbind()
	end
-- this will fail when the menu font is being used
--assert.eq(tex.data, ffi.cast('uint8_t*', self.image.buffer))
	tex:bind()
		:subimage()
		--:generateMipmap()
	if app.inUpdateCallback then
		fb:bind()
	end
	self.dirtyCPU = false
	self.changedSinceDraw = true	-- only used by framebufferRAM, if its GPU state ever changes, to let the app know to draw it again
end

-- TODO is this only applicable for framebufferRAM?
-- if anything else has a dirty GPU ... it'd have to be because the framebuffer was rendering to it
-- and right now, the fb is only outputting to framebufferRAM ...
-- NOTICE any time you call checkDirtyGPU on a framebufferRAM that is,
-- you will need to do it from outside the inUpdateCallback
function RAMGPUTex:checkDirtyGPU()
glreport'checkDirtyGPU begin'
	if not self.dirtyGPU then return end
	assert(not self.dirtyCPU, "someone dirtied both cpu and gpu without flushing either")
	-- assert that fb is bound to framebufferRAM ...
	local app = self.app
	local tex = self.tex
	local image = self.image
	local fb =
		-- only for framebufferRAMs,
		-- they have dif size from sprite sheets etc and might want their own fraembuffeers ...
		-- ... honestly same for palettes right?
		-- well esp fbRAMs theres will be bigger than the default fb size of 256x256
		self.fb or
		-- ... nope that didn't fix it
		app.fb
	if not app.inUpdateCallback then
		fb:bind()
glreport'checkDirtyGPU after fb:bind'
	else
		if app.fb ~= fb then
			app.fb:unbind()
glreport'checkDirtyGPU after app.fb:unbind'
			fb:bind()
glreport'checkDirtyGPU after fb:bind'
		end
	end
--DEBUG:assert(tex.data)
--DEBUG:assert.eq(tex.data, ffi.cast('uint8_t*', self.image.buffer))
--DEBUG:assert.le(0, tex.data - app.ram.v, 'tex.data')
--DEBUG:assert.lt(tex.data - app.ram.v, app.memSize, 'tex.data')
	gl.glReadPixels(0, 0, tex.width, tex.height, tex.format, tex.type, image.buffer)
--DEBUG:print('fb size', fb.width, fb.height)
--DEBUG:print('glReadPixels', 0, 0, tex.width, tex.height, tex.format, tex.type, image.buffer)
glreport'checkDirtyGPU after glReadPixels'
	if not app.inUpdateCallback then
		fb:unbind()
glreport'checkDirtyGPU after fb:unbind'
	else
		if app.fb ~= fb then
			fb:unbind()
glreport'checkDirtyGPU after fb:unbind'
			app.fb:bind()
glreport'checkDirtyGPU after app.fb:bind'
		end
	end
	self.dirtyGPU = false
glreport'checkDirtyGPU end'
end

--[[
sync CPU and GPU mem then move and flag cpu-dirty so the next cycle will update
--]]
function RAMGPUTex:updateAddr(newaddr)
--DEBUG:print'checkDirtyGPU'
	self:checkDirtyGPU()	-- only the framebuffer has this
--DEBUG:print'checkDirtyCPU'
	self:checkDirtyCPU()
-- clamp or allow OOB? or error?  or what?
	newaddr = math.clamp(bit.bor(0, newaddr), 0, self.app.memSize - self.size)
--DEBUG:print(('new addr: $%x'):format(newaddr))
	self.addr = newaddr
--DEBUG:print('self.addr', self.addr)
--DEBUG:print('self.size', self.size)
	self.addrEnd = newaddr + self.size
--DEBUG:print('self.addrEnd', self.addrEnd)
	self.tex.data = ffi.cast('uint8_t*', self.app.ram.v) + self.addr
--DEBUG:print('self.tex.data', self.tex.data)
	local formatp = ffi.typeof('$*', self.image.format)
	self.image.buffer = ffi.cast(formatp, self.tex.data)
--DEBUG:print('self.image.buffer', self.image.buffer)
	self.dirtyCPU = true
end

return RAMGPUTex 
