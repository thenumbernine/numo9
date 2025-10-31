local ffi = require 'ffi'
local assert = require 'ext.assert'
local class = require 'ext.class'
local Image = require 'image'
local gl = require 'gl'
local GLFBO = require 'gl.fbo'
local GLTex2D = require 'gl.tex2d'
local GLTypes = require 'gl.types'

local RAMGPUTex = require 'numo9.ramgpu'


local numo9_rom = require 'numo9.rom'
local framebufferAddr = numo9_rom.framebufferAddr


local uint8_t_p = ffi.typeof'uint8_t*'


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
		internalFormat = gl.GL_R8UI
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
		internalFormat = gl.GL_R8UI
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
			-- 4th component holds 'HD2DFlags' for this geom at this fragment
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
			-- 4th component holds clip-coord z, since SSAO needs to sample that a lot
			internalFormat = gl.GL_RGBA32F,
			format = gl.GL_RGBA,
			type = gl.GL_FLOAT,

			minFilter = gl.GL_NEAREST,
			magFilter = gl.GL_NEAREST,
			--magFilter = gl.GL_LINEAR,	-- maybe take off some sharp edges of the lighting?
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
				magFilter = gl.GL_NEAREST,
				minFilter = gl.GL_NEAREST,
				data = ffi.cast(uint8_t_p, image.buffer),
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
				magFilter = gl.GL_NEAREST,
				minFilter = gl.GL_NEAREST,
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

return VideoMode
