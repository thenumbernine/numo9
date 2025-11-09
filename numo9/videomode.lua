--[[
ok flowchart on how our rendering is supposed to work ...

each mode
has a fbo
renders geometry
and outputs to:
- framebufferRAM.tex ("framebufferTex" in GLSL) attached to 0 for underlying color ...
	- RGB565 => GL_RGB565
	- 8bppIndex => GL_R8UI
	- RGB332 => GL_R8UI
- framebufferDepthTex as GL_DEPTH_COMPONENT attached to depth ... hmm its not read from, is it?  nah.
- framebufferNormalTex GL_RGBA32F attached to color 1
- framebufferPosTex GL_RGBA32F attached to color 2

separately, there's the uberlightmap
- lightDepthTex GL_DEPTH_COMPONENT32F attached to depth
- nothing attached to color ...
	- ... TODO I can save some calcs by copying the whole ubershader and just cut out all the color stuff, and just only do depth read/writes here.
	- but there is a lot of alpha-based discard so it might not be that much less calcs ...

then lighting resizes as it goes
TODO but should be in mode as well
it takes in:
- framebufferNormalTex as 0
- framebufferPosTex as 1
- noiseTex as 2 for SSAO (TODO somehow noise this / blur this / but dont get tearing on edges when camera moves somehow)
- lightDepthTex as 3
it outputs:
- calcLightTex GL_RGBA32F attached to color 0 for light scale

then final screen blit (happening every render, not just 60fps ...)
takes in:
- framebufferRAM.tex for color
- calcLightTex for light scale
it outputs directly to the screen
- TODO maybe output to a *new* post-lighting buffer then just blit that to screen ???
	- but honestly, I've already got the renderer set up to only draw when needed ... its just always redrawing every frame ...
	- I should just not redraw the menu if we're not in a net game or something ... hmm ...
--]]
local ffi = require 'ffi'
local template = require 'template'
local assert = require 'ext.assert'
local table = require 'ext.table'
local class = require 'ext.class'
local Image = require 'image'
local gl = require 'gl'
local glreport = require 'gl.report'
local glnumber = require 'gl.number'
local GLFBO = require 'gl.fbo'
local GLTex2D = require 'gl.tex2d'
local GLTypes = require 'gl.types'
local GLSceneObject = require 'gl.sceneobject'
local GLPingPong = require 'gl.pingpong'

local RAMGPUTex = require 'numo9.ramgpu'


local numo9_rom = require 'numo9.rom'
local tilemapSize = numo9_rom.tilemapSize
local paletteSize = numo9_rom.paletteSize
local framebufferAddr = numo9_rom.framebufferAddr
local maxLights = numo9_rom.maxLights


local uint8_t_p = ffi.typeof'uint8_t*'


local vec2f = require 'vec-ffi.vec2f'
local vec3f = require 'vec-ffi.vec3f'
local vec4f = require 'vec-ffi.vec4f'
local vec4us = require 'vec-ffi.vec4us'

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
		app.currentVideoMode.fb:unbind()
	end

	local width, height = self.width, self.height
	local internalFormat, gltype
	if self.format == 'RGB565' then
		-- framebuffer is 16bpp rgb565 -- used for mode-0
		-- [[
		internalFormat = gl.GL_RGB565
		gltype = gl.GL_UNSIGNED_SHORT_5_6_5	-- for an internalFormat there are multiple gltype's so pick this one
		--]]
		--[[
		-- TODO do this but in doing so the framebuffer fragment vec4 turns into a uvec4
		-- and then the reads from u16_to_5551_uvec4() which output vec4 no longer fit
		-- ... hmm ...
		-- ... but if I do this then the 565 hardware-blending no longer works, and I'd have to do that blending manually ...
		internalFormat = internalFormat5551
		--]]
	elseif self.format == '8bppIndex'
	or self.format == 'RGB332'
	then
		-- framebuffer is 8bpp indexed -- used for mode-1, mode-2
		internalFormat = gl.GL_R8UI
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
		--width = bit.rshift(width, 1) + bit.band(width, 1)
	else
		error("unknown format "..tostring(self.format))
	end

	-- framebuffer for rendering geometry to 'framebufferRAM.tex' + framebufferDepthTex + framebufferNormalTex + framebufferPosTex
	self.fb = GLFBO{
		width = self.width,
		height = self.height,
	}

	self.fb:setDrawBuffers(
		gl.GL_COLOR_ATTACHMENT0,	-- fragColor
		gl.GL_COLOR_ATTACHMENT1,	-- fragNormal
		gl.GL_COLOR_ATTACHMENT2)	-- fragPos
	self.fb:unbind()

	-- make a depth tex per size
	self.fb:bind()
	self.framebufferDepthTex = GLTex2D{
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
	gl.glFramebufferTexture2D(gl.GL_FRAMEBUFFER, gl.GL_DEPTH_ATTACHMENT, gl.GL_TEXTURE_2D, self.framebufferDepthTex.id, 0)
	self.framebufferDepthTex:unbind()
	self.fb:unbind()

	-- while we're here, attach a normalmap as well, for "hardware"-based post-processing lighting effects?
	-- make a FBO normalmap per size.
	-- Don't store it in fantasy-console "hardware" RAM just yet.
	-- For now it's just going to be accessible by a single switch in RAM.
	self.framebufferNormalTex = GLTex2D{
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
	self.fb:bind()
		:setColorAttachmentTex2D(self.framebufferNormalTex.id, 1, self.framebufferNormalTex.target)
		:unbind()

	self.framebufferPosTex = GLTex2D{
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
	self.fb:bind()
		:setColorAttachmentTex2D(self.framebufferPosTex.id, 2, self.framebufferPosTex.target)
		:unbind()

	-- this shares between 8bppIndexed (R8UI) and RGB322 (R8UI)
	do
		-- is specified for GL_UNSIGNED_SHORT_5_6_5.
		-- otherwise falls back to default based on internalFormat
		-- set this here so we can determine .ctype for the ctor.
		-- TODO determine ctype = GLTypes.ctypeForGLType in RAMGPU ctor?)
		local formatInfo = assert.index(GLTex2D.formatInfoForInternalFormat, internalFormat)
		gltype = gltype or formatInfo.types[1]  -- there are multiple, so let the caller override

		if self.useNativeOutput then
			-- make a fake-wrapper that doesn't connect to the address space and does nothing for flushing to/from CPU
			self.framebufferRAM = setmetatable({}, RAMGPUTex)
			self.framebufferRAM.addr = 0
			self.framebufferRAM.addrEnd = 0

			local ctype = assert.index(GLTypes.ctypeForGLType, gltype)
			local image = Image(width, height, 1, ctype)
			self.framebufferRAM.image = image

			self.framebufferRAM.tex = GLTex2D{
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

			function self.framebufferRAM:delete() return false end	-- :delete() is called on sheet/font/palette RAMGPU's between cart loading/unloading
			function self.framebufferRAM:overlaps() return false end
			function self.framebufferRAM:checkDirtyCPU()
				self.dirtyCPU = false
			end
			function self.framebufferRAM:checkDirtyGPU()
				self.dirtyGPU = false
			end
			function self.framebufferRAM:updateAddr(newaddr) end
		else
			self.framebufferRAM = RAMGPUTex{
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
		end
	end

-- [[ do this here?
-- wait aren't the fb's shared between video modes?
	self.fb:bind()
		:setColorAttachmentTex2D(self.framebufferRAM.tex.id, 0, self.framebufferRAM.tex.target)
		:unbind()
--]]

	-- hmm this is becoming a mess ...
	-- link the fbRAM to its respective .fb so that , when we checkDirtyGPU and have to readPixels, it can use its own
	-- hmmmm
	-- can I just make one giant framebuffer and use it everywhere?
	-- or do I have to make one per screen mode's framebuffer?
	self.framebufferRAM.fb = self.fb
	-- don't bother do the same with framebufferNormalTex cuz it isn't a RAMGPU / doesn't have address space


	-- deferred lighting framebuffer,
	-- save the light-calc stuff here too
	--
	-- TODO
	-- Google AI is retarded.
	-- No Google, it is not a good idea to downsample the SSAO buffer.  It makes tearing appear at edges' lighting.
	-- No it is not a good idea to blend it with past SSAO buffers, that makes ghosting and TV-static effects.
	-- The best I found was just 1 texture, rendered with only its info, no blurring, no past iterations, no miplevels, no other resolutions.
	-- and use it in the final pass.
	-- so TODO you can replace calcLightTex with just a tex and a fbo.
	-- but meh it does package the two into one class well.
	--
	-- downsample gbuffer into here for ssao calcs and use that tex to render to the final scene
	-- TODO blending multiple buffers together doesn't seem to make that much of a difference
	-- 	but it does cause ghosting and tearing at edges.  so..
	self.calcLightTex = GLPingPong{
		numBuffers = 1,	-- just for the fbo + tex
		width = self.width,
		height = self.height,
		internalFormat = gl.GL_RGBA32F,
		minFilter = gl.GL_NEAREST,
		magFilter = gl.GL_LINEAR,
		wrap = {
			s = gl.GL_CLAMP_TO_EDGE,
			t = gl.GL_CLAMP_TO_EDGE,
		},
	}
	-- TODO put setDrawBuffers init in gl.pingpong ... when you dont provide a fbo?
	--  or is it even needed for single-color-attachment fbos?
	self.calcLightTex.fbo
		:bind()
		:setDrawBuffers(gl.GL_COLOR_ATTACHMENT0)
		:setColorAttachmentTex2D(self.calcLightTex:cur().id)
	-- but there's no need to clear it so long as all geometry gets rendered with the 'HD2DFlags' set to zero
	-- then in the light combine pass it wont combine
	gl.glClearColor(1,1,1,1)
	gl.glClear(bit.bor(gl.GL_DEPTH_BUFFER_BIT, gl.GL_COLOR_BUFFER_BIT))
	self.calcLightTex.fbo
		:unbind()
--]]

-- [[ more deferred lighting
	-- do this after resetting video so that we have a videoMode object
	self.calcLightBlitObj = GLSceneObject{
		program = {
			version = app.glslVersion,
			precision = 'best',
			vertexCode = [[
layout(location=0) in vec2 vertex;
out vec2 tcv;
void main() {
	tcv = vertex;
	gl_Position = vec4(vertex.xy * 2. - 1., 0., 1.);
}
]],
			fragmentCode = template([[
precision highp sampler2D;
precision highp isampler2D;
precision highp usampler2D;	// needed by #version 300 es

in vec2 tcv;

layout(location=0) out vec4 fragColor;

uniform <?=videoMode.framebufferNormalTex:getGLSLSamplerType()?> framebufferNormalTex;
uniform <?=videoMode.framebufferPosTex:getGLSLSamplerType()?> framebufferPosTex;
uniform <?=app.noiseTex:getGLSLSamplerType()?> noiseTex;	// used by SSAO
uniform <?=app.lightDepthTex:getGLSLSamplerType()?> lightDepthTex;

#define maxLights ]]..maxLights..[[

// lighting variables in RAM:
uniform int numLights;
uniform vec3 lightAmbientColor;	// overall ambient level
// lights[] array TODO use UBO:
uniform bool lights_enabled[maxLights];
uniform vec4 lights_region[maxLights];	// uint16_t[4] x y w h / (lightmapWidth, lightmapHeight)
uniform vec3 lights_ambientColor[maxLights];// per light ambient (is attenuated, so its diffuse without dot product dependency).
uniform vec3 lights_diffuseColor[maxLights];// = vec3(1., 1., 1.);
uniform vec4 lights_specularColor[maxLights];// = vec3(.6, .5, .4, 30.);	// w = shininess
uniform vec3 lights_distAtten[maxLights];	// vec3(const, linear, quadratic) attenuation
uniform vec2 lights_cosAngleRange[maxLights];	// cosine(outer angle), 1 / (cosine(inner angle) - cosine(outer angle)) = {0,1}
uniform mat4 lights_viewProjMat[maxLights];	// used for light depth coord transform, and for determining the light pos
uniform vec3 lights_viewPos[maxLights];	// translation components of inverse-view-matrix of the light
uniform vec3 lights_negViewDir[maxLights];	// negative-z-axis of inverse-view-matrix of the light

uniform float ssaoSampleRadius;// = 1.;	// this is in world coordinates, so it's gonna change per-game
uniform float ssaoInfluence;// = 1.;	// 1 = 100% = you'll see black in fully-occluded points

const float ssaoSampleTCScale = 18.;	// ? meh

uniform mat4 drawViewMat;	// used by SSAO
uniform mat4 drawProjMat;	// used by ...
uniform vec3 drawViewPos;

// these are the random vectors inside a unit hemisphere facing z+
#define ssaoNumSamples 8
const vec3[ssaoNumSamples] ssaoRandomVectors = vec3[ssaoNumSamples](
	vec3(0.58841258486248, 0.39770493127433, 0.18020748345621),
	vec3(-0.055272473410801, 0.35800974374131, 0.15028358974804),
	vec3(0.3199885122024, -0.57765628483213, 0.19344714028561),
	vec3(-0.71177536281716, 0.65982751624885, 0.16661179472317),
	vec3(0.6591556369125, 0.25301657986158, 0.65350042181301),
	vec3(0.37855701974814, 0.013090583813782, 0.71111037617741),
	vec3(0.53098955685005, 0.39114666484126, 0.29796836757796),
	vec3(-0.27445479803038, 0.28177659836742, 0.89415105823562)
#if 0
	vec3(0.030042725676812, 0.3941820959086, 0.099681999794761),
	vec3(-0.60144625790746, 0.6112734005649, 0.3676468627808),
	vec3(0.72396342749209, 0.35994756762253, 0.30828171680103),
	vec3(-0.8082345863749, 0.13633528834184, 0.32199773139527),
	vec3(0.49667204075871, 0.12506306502285, 0.65431856367262),
	vec3(-0.086390931280017, 0.5832061191173, 0.29234165779378),
	vec3(-0.24610823044055, 0.77791376069684, 0.57363108026349),
	vec3(-0.194238481883, 0.01011984889981, 0.88466521192798)
#endif
);

void main() {
#if 0	// debug - show the lightmap
float l = texture(lightDepthTex, tcv).x;
fragColor = vec4(l, l * 10., 1. - l * 100., .0);	// tell debug compositer to use this color here.
return;
#endif

	vec4 worldNormal = texture(framebufferNormalTex, tcv);
	int HD2DFlags = int(worldNormal.w);
	// no lighting on this fragment
	if ((HD2DFlags & <?=ffi.C.HD2DFlags_lightingApplyToSurface?>) == 0) {
		fragColor = vec4(1., 1., 1., 1.);
		return;
	}

	vec3 normalizedWorldNormal = normalize(worldNormal.xyz);
#if 0 // debugging: show normalmap:
fragColor = vec4(normalizedWorldNormal * .5 + .5, 0.);	// w=0 is debugging and means 'show the lightmap at this point'
return;
#endif

	vec4 worldCoordAndClipDepth = texture(framebufferPosTex, tcv);
	vec4 worldCoord = vec4(worldCoordAndClipDepth.xyz, 1.);
	float clipDepth = worldCoordAndClipDepth.w;

	if ((HD2DFlags & <?=bit.bor(ffi.C.HD2DFlags_calcFromLightMap, ffi.C.HD2DFlags_calcFromLights)?>) == 0) {
		// no light calcs = full light
		fragColor = vec4(1., 1., 1., 1.);
	} else {
		bool calcFromLightMap = 0 != (HD2DFlags & <?=ffi.C.HD2DFlags_calcFromLightMap?>);
		bool calcFromLights = 0 != (HD2DFlags & <?=ffi.C.HD2DFlags_calcFromLights?>);

		// start off with scene ambient
		fragColor = vec4(lightAmbientColor.xyz, 1.);

		for (int lightIndex = 0; lightIndex < numLights; ++lightIndex) {
			if (!lights_enabled[lightIndex]) continue;

			if (calcFromLightMap) {
				vec4 lightClipCoord = lights_viewProjMat[lightIndex] * worldCoord;
				// frustum test before homogeneous transform
				if (!(lightClipCoord.w > 0.
					&& all(lessThanEqual(vec3(-lightClipCoord.w, -lightClipCoord.w, -lightClipCoord.w), lightClipCoord.xyz))
					&& all(lessThanEqual(lightClipCoord.xyz, vec3(lightClipCoord.w, lightClipCoord.w, lightClipCoord.w)))
				)) continue;

				vec3 lightNDCoord = lightClipCoord.xyz / lightClipCoord.w;
				vec3 lightND01Coord = lightNDCoord * .5 + .5;

				vec2 lightTC = lightND01Coord.xy * lights_region[lightIndex].zw + lights_region[lightIndex].xy;

				// in bounds
				float lightBufferDepth = texture(lightDepthTex, lightTC).x;

				// zero gets depth alias stripes
				// nonzero is dependent on the scene
				// the proper way to do this is to save the depth range per-fragment and use that here as the epsilon
				//const float lightDepthTestEpsilon = 0.;		// not enough
				//const float lightDepthTestEpsilon = 0.0001;	// not enough
				const float lightDepthTestEpsilon = 0.001;		// works for what i'm testing atm

#if 0	// debug show the light buffer
fragColor = vec4(lightBufferDepth, .5, 1. - lightBufferDepth, 0.);	// tell debug compositer to use this color here.
return;
#endif
#if 0	// debug show the light clip depth
fragColor = vec4(lightND01Coord.z, .5, 1. - lightND01Coord.z, 0.);	// tell debug compositer to use this color here.
return;
#endif
#if 0	// debug show the light clip depth
float delta = lightND01Coord.z - (lightBufferDepth + lightDepthTestEpsilon);
fragColor = vec4(.5 + delta, .5, .5 - delta, 0.);	// tell debug compositer to use this color here.
return;
#endif
				// TODO normal test here as well?
				if (!(lightND01Coord.z < (lightBufferDepth + lightDepthTestEpsilon))) {
					continue;
				}
			}

			if (!calcFromLights) {
				fragColor.xyz += vec3(1., 1., 1.);
			} else {
#if 1 // diffuse & specular with the world space surface normal
				vec3 surfaceToLightVec = lights_viewPos[lightIndex] - worldCoord.xyz;
				float surfaceToLightDist = length(surfaceToLightVec);
				vec3 surfaceToLightNormalized = surfaceToLightVec / surfaceToLightDist;
				vec3 viewDir = normalize(drawViewPos - worldCoord.xyz);
				float cosNormalToLightAngle = dot(surfaceToLightNormalized, normalizedWorldNormal);

				float cos_lightToSurface_to_lightFwd = dot(
					-surfaceToLightNormalized,
					-lights_negViewDir[lightIndex]);

				// TODO i need an input/output map or bias or something
				// outdoor lights need to disable this
				// and I have no way to do so ...
				// I can just do mx+b and then ... clamp range ...
				// thats 4 args ...
				// in min, in max, out min, out max
				float atten =
					// clamp this?  at least above zero... no negative lights.
					clamp(
						(cos_lightToSurface_to_lightFwd - lights_cosAngleRange[lightIndex].x)
						* lights_cosAngleRange[lightIndex].y,	// .y holds 1/(cos(inner) - cos(outer))
						0., 1.
					);

				vec3 lightColor =
					lights_ambientColor[lightIndex]
					+ lights_diffuseColor[lightIndex] * abs(cosNormalToLightAngle)
					// maybe you just can't do specular lighting in [0,1]^3 space ...
					// maybe I should be doing inverse-frustum-projection stuff here
					// hmmmmmmmmmm
					// I really don't want to split projection and modelview matrices ...
					+ lights_specularColor[lightIndex].xyz * pow(
						abs(dot(viewDir, reflect(-surfaceToLightNormalized, normalizedWorldNormal))),
						lights_specularColor[lightIndex].w
					);
				atten *= 1. /
					max(1e-7,
						lights_distAtten[lightIndex].x
						+ surfaceToLightDist * (lights_distAtten[lightIndex].y
							+ surfaceToLightDist * lights_distAtten[lightIndex].z
						)
					);

				// TODO scale atten by angle range

				// apply bumpmap lighting
				fragColor.xyz += lightColor * atten;
#else	// plain
				fragColor.xyz += vec3(.9, .9, .9);
#endif
			}
		}
	}

	// SSAO:
	if ((HD2DFlags & <?=ffi.C.HD2DFlags_useSSAO?>) != 0) {
		vec4 viewNormal = drawViewMat * vec4(worldNormal.xyz, 0.);
		vec3 normalizedViewNormal = normalize(viewNormal.xyz);

		// make sure normal is pointing towards the view, i.e. z+
		if (normalizedViewNormal.z < 0.) normalizedViewNormal = -normalizedViewNormal;

		vec4 viewCoord = drawViewMat * worldCoord;

		// clipCoord = drawProjMat * viewCoord
		// ndcCoord = homogeneous(clipCoord)
		// ndcCoord should == tcv.xy * 2. - 1. .......

		// current fragment in [-1,1]^2 screen coords x clipDepth
		//vec3 viewCoord = vec3(tcv.xy * 2. - 1., clipDepth);

		// TODO just save float buffer? faster?
		// TODO should this random vec be in 3D or 2D?
		vec3 rvec = texture(noiseTex, tcv * ssaoSampleTCScale).xyz;
		rvec.z = 0.;
		rvec.xy = normalize(rvec.xy * 2. - 1.);

		// frame in view coordinates
		vec3 tangent = normalize(rvec - normalizedViewNormal * dot(rvec, normalizedViewNormal));
		vec3 bitangent = cross(tangent, normalizedViewNormal);
		mat3 tangentMatrix = mat3(tangent, bitangent, normalizedViewNormal);

		float numOccluded = 0.;
		for (int i = 0; i < ssaoNumSamples; ++i) {
			// rotate random hemisphere vector into our tangent space
			// but this is still in [-1,1]^2 screen coords x clipDepth, right?
			vec3 sampleViewCoord = viewCoord.xyz + tangentMatrix * (ssaoRandomVectors[i] * ssaoSampleRadius);

			vec4 sampleClipCoord = drawProjMat * vec4(sampleViewCoord, 1.);
			vec4 sampleNDCCoord = sampleClipCoord / sampleClipCoord.w;
			float bufferClipDepthAtSample = texture(framebufferPosTex, sampleNDCCoord.xy * .5 + .5).w;

			float depthDiff = sampleClipCoord.z - bufferClipDepthAtSample;
			if (depthDiff < ssaoSampleRadius) {
				numOccluded += step(bufferClipDepthAtSample, sampleClipCoord.z);
			}
		}

		float lum = 1. - ssaoInfluence * numOccluded / float(ssaoNumSamples);
		fragColor.xyz *= lum;
	}
}
]],			{
				ffi = ffi,
				app = app,
				videoMode = self,
				glnumber = glnumber,
				width = self.calcLightTex.width,
				height = self.calcLightTex.height,
			}),
			uniforms = {
				framebufferNormalTex = 0,
				framebufferPosTex = 1,
				noiseTex = 2,
				lightDepthTex = 3,
			},
		},
		texs = {
			assert(self.framebufferNormalTex),
			assert(self.framebufferPosTex),
			assert(app.noiseTex),
			assert(app.lightDepthTex),
		},
		geometry = app.quadGeom,

		--[=[ TODO don't use this
		-- these are set every frame
		-- but I"m using these because I'm lazy
		-- instead just call glUniform yourself.
		uniforms = {
			lightmapRegion = {0,0,1,1},
			lightAmbientColor = {.4, .3, .2},
			lightDiffuseColor = {1, 1, 1},
			lightSpecularColor = {.6, .5, .4, 30},
			ssaoSampleRadius = 1,
			ssaoInfluence = 1,
		},
		--]=]
	}
	--]]


-- [=[
	-- ok TODO 
	-- before we'd combine deferred-lighting buf + framebuffer and apply directly to output
	-- but now we ...
	-- (1) need to input that into hdrTex
	-- (2) can't use framebuffer cuz it doesnt have mipmapping or filterable textures
	-- so we need a new texture here to combine calcLightTex:cur() + framebufferTex
	-- ... should I build it with calcLight stuff and combine once there and then with non-hdr just render that one in the final pass?
	-- or would that be a waste / slow?
	-- thinking about it .... yes it'd be a waste for non-HDR/DOF pathway.  why blow up the format to a float?
	-- so I should bother with this only if I'm going to use HDR or DOF.
	self.lightAndFBTex = GLPingPong{
		numBuffers = 1,	-- just for the fbo + tex
		width = self.width,
		height = self.height,
		-- does mipmap work with RGBA32F?
		-- ... for GLES3 ... technically ...no.
		-- how to know when it will and when it wont work?
		-- welp at least RGBA16F is textureFilterable
		internalFormat = gl.GL_RGBA16F,
		magFilter = gl.GL_LINEAR,
		minFilter = gl.GL_LINEAR_MIPMAP_LINEAR,
		wrap = {
			s = gl.GL_CLAMP_TO_EDGE,
			t = gl.GL_CLAMP_TO_EDGE,
		},
		generateMipmap = true,
	}
	self.lightAndFBTex.fbo
		:bind()
		:setDrawBuffers(gl.GL_COLOR_ATTACHMENT0)
		:setColorAttachmentTex2D(self.lightAndFBTex:cur().id)
	gl.glClearColor(1,1,1,1)
	gl.glClear(gl.GL_COLOR_BUFFER_BIT)
	self.lightAndFBTex.fbo
		:unbind()
	-- TODO blit here to combine calcLightTex and framebufferTex into lightAndFBTex
	-- hmm, it is going to vary depending on video mode
	-- can I just use blitScreenObj? why not?
--]=]


-- [=[
	-- now same as lights but for ... which order ...
	-- HDR then DoF?  or DoF then HDR?
	-- HDR first means more light affecting neighbor pixels before blurring neighbors
	-- DoF first means blurring light value, possibly decreasing it, before applying HDR glow ...
	-- HDR first?
	self.hdrTex = GLPingPong{
		numBuffers = 1,	-- just for the fbo + tex
		width = self.width,
		height = self.height,
		internalFormat = gl.GL_RGBA16F,
		magFilter = gl.GL_LINEAR,
		minFilter = gl.GL_LINEAR_MIPMAP_LINEAR,
		wrap = {
			s = gl.GL_CLAMP_TO_EDGE,
			t = gl.GL_CLAMP_TO_EDGE,
		},	
	}
	self.hdrTex.fbo
		:bind()
		:setDrawBuffers(gl.GL_COLOR_ATTACHMENT0)
		:setColorAttachmentTex2D(self.hdrTex:cur().id)
	gl.glClearColor(1,1,1,1)
	gl.glClear(gl.GL_COLOR_BUFFER_BIT)
	self.hdrTex.fbo
		:unbind()

	-- ... and this is gonna write out to screen, when HDR is being used:
	-- TODO pre pass, generateMipmaps on lightAndFBTex
	self.hdrBlitObj = GLSceneObject{
		program = {
			version = app.glslVersion,
			precision = 'best',
			vertexCode = [[
layout(location=0) in vec2 vertex;
out vec2 tcv;
void main() {
	tcv = vertex;
	gl_Position = vec4(vertex.xy * 2. - 1., 0., 1.);
}
]],
			fragmentCode = template([[
precision highp sampler2D;
in vec2 tcv;
layout(location=0) out vec4 fragColor;
uniform <?=videoMode.lightAndFBTex:cur():getGLSLSamplerType()?> prevTex;

void main() {
	vec4 color = texture(prevTex, tcv, 0.);

	// https://mini.gmshaders.com/p/tonemaps
	//color.rgb / (color.rgb + 0.155) * 1.019;

	fragColor.a = color.a;
	fragColor.rgb = (
		color.rgb
		+ texture(prevTex, tcv, 1.).rgb * max(vec3(0., 0., 0.), color.rgb - 1.)
		+ texture(prevTex, tcv, 2.).rgb * max(vec3(0., 0., 0.), color.rgb - 1.25)
		+ texture(prevTex, tcv, 3.).rgb * max(vec3(0., 0., 0.), color.rgb - 1.375)
	) / 4.;
}
]],			{
				videoMode = self,
			}),
			uniforms = {
				prevTex = 0,
			},
		},
		texs = {
			self.lightAndFBTex:cur(),
		},
		geometry = app.quadGeom,
	}
--]=]


-- [=[
	self.dofTex = GLPingPong{
		numBuffers = 1,	-- just for the fbo + tex
		width = self.width,
		height = self.height,
		internalFormat = gl.GL_RGBA16F,
		magFilter = gl.GL_NEAREST,
		minFilter = gl.GL_NEAREST,
		wrap = {
			s = gl.GL_CLAMP_TO_EDGE,
			t = gl.GL_CLAMP_TO_EDGE,
		},	
	}
	self.dofTex.fbo
		:bind()
		:setDrawBuffers(gl.GL_COLOR_ATTACHMENT0)
		:setColorAttachmentTex2D(self.dofTex:cur().id)
	gl.glClearColor(1,1,1,1)
	gl.glClear(gl.GL_COLOR_BUFFER_BIT)
	self.dofTex.fbo
		:unbind()

	self.dofBlitObj = GLSceneObject{
		program = {
			version = app.glslVersion,
			precision = 'best',
			vertexCode = [[
layout(location=0) in vec2 vertex;
out vec2 tcv;
void main() {
	tcv = vertex;
	gl_Position = vec4(vertex.xy * 2. - 1., 0., 1.);
}
]],
			fragmentCode = template([[
precision highp sampler2D;
in vec2 tcv;
layout(location=0) out vec4 fragColor;

// prevTex is either lightAndFBTex if HDR is disabled,
//  or hdrTex if HDR is enabled
uniform <?=videoMode.hdrTex:cur():getGLSLSamplerType()?> prevTex;

uniform <?=videoMode.framebufferPosTex:getGLSLSamplerType()?> framebufferPosTex;

uniform vec3 depthOfFieldPos;	//xyz = worldspace pos
uniform vec3 depthOfFieldAtten;	//xyz = const, linear, quadratic distance attenuation

// TODO.  for now its all just radial because that doesnt take the view
// maybe later instead of view, i'll just blur using clip depth (stored in the framebufferNormalTex.a I think)
// true = blur by distance from depthOfFieldPos
// false = blur by distance along view from depthOfFieldPos
//uniform bool radial;

void main() {
	vec3 delta = texture(framebufferPosTex, tcv).rgb - depthOfFieldPos;
	float dist = length(delta);	
	float depthBlurAmount = 1. / (depthOfFieldAtten.x + dist * (depthOfFieldAtten.y + dist * depthOfFieldAtten.z));

	fragColor.rgb = texture(prevTex, tcv, depthBlurAmount).rgb;
	fragColor.a = texture(prevTex, tcv, 0.).a;
}
]],			{
				videoMode = self,
			}),
			uniforms = {
				prevTex = 0,
				framebufferPosTex = 1,
				depthOfFieldPos = {0,0,0},
				depthOfFieldAtten = {0,0,1},
			},
		},
		texs = {
			self.hdrTex:cur(),	-- this will be self.hdrTex:cur() if hdr is on, or self.lightAndFBTex:cur() if hdr is off
			self.framebufferPosTex,
		},
		geometry = app.quadGeom,
	}
--]=]

	-- 'blitScreenObj' is actually the lighting pass
	-- should I always do it to a prev float16 buffer, or is it fine going straight to the screen?
	self.blitScreenHD2DObj = GLSceneObject{
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
in vec2 tcv;
layout(location=0) out vec4 fragColor;
uniform <?=videoMode.lightAndFBTex:cur():getGLSLSamplerType()?> prevTex;
void main() {
	fragColor = texture(prevTex, tcv);
}
]],			{
				videoMode = self,
			}),
			uniforms = {
				prevTex = 0,
			},
		},
		texs = {
			self.lightAndFBTex:cur(),
		},
		geometry = app.quadGeom,
	}

	if app.inUpdateCallback then
		app.currentVideoMode.fb:bind()
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

-- convert it here to vec4 since default UNSIGNED_SHORT_1_5_5_5_REV uses vec4
local glslCode5551 = [[
// assumes the uint is [0,0xffff]
// returns rgba in [0,0x1f]^4
uvec4 u16_to_5551_uvec4(uint x) {
	return uvec4(
		x & 0x1fu,
		(x & 0x3e0u) >> 5u,
		(x & 0x7c00u) >> 10u,
		((x & 0x8000u) >> 15u) * 0x1fu
	);
}

// assumes the uint is [0,0xffff]
// returns rgba in [0,1]^4
// only used by a commented path of blitscreen for RGB565
vec4 u16_to_5551_vec4(uint x) {
	return vec4(
		float(x & 0x1fu) / 31.,
		float((x >> 5) & 0x1fu) / 31.,
		float((x >> 10) & 0x1fu) / 31.,
		float(x >> 15)
	);
}
]]

-- code for converting 'uint colorIndex' to '(u)vec4' fragColor
-- assert palleteSize is 256 ...
-- requires glslCode5551
local colorIndexToFrag = [[
	u16_to_5551_uvec4(texelFetch(
		paletteTex,
		ivec2(int(colorIndex & 0xFFu), 0),
		0
	).r)
]]

-- I could just make a vertex shader obj of its own and link to the other programs but meh
local blitScreenVertexCode = [[
layout(location=0) in vec2 vertex;
out vec2 tcv;
uniform mat4 mvProjMat;
void main() {
	tcv = vertex;
	gl_Position = mvProjMat * vec4(vertex, 0., 1.);
}
]]

-- this string can include template code that appears in all of them
local blitScreenFragHeader = [[
precision highp sampler2D;
precision highp isampler2D;
precision highp usampler2D;	// needed by #version 300 es

in vec2 tcv;

layout(location=0) out vec4 fragColor;

uniform <?=self.framebufferRAM.tex:getGLSLSamplerType()?> framebufferTex;
uniform <?=self.framebufferPosTex:getGLSLSamplerType()?> framebufferPosTex;
uniform <?=self.calcLightTex:cur():getGLSLSamplerType()?> calcLightTex;

void doLighting() {

#if 0	// debugging - show calcLight tex
fragColor.xyz = texture(calcLightTex, tcv).xyz;
return;
#endif

#if 1	// show calcLight tex - only where alpha=0 i.e. lightmap debug display
vec4 lightColor = texture(calcLightTex, tcv);
if (lightColor.w == 0.) {
	fragColor.xyz = lightColor.xyz;
	return;
}
#endif

	fragColor.xyz *= texture(calcLightTex, tcv).xyz;
}
]]

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
	self.colorIndexToFragColorCode = [[
vec4 colorIndexToFragColor(uint colorIndex) {
	uvec4 ufragColor = ]]..colorIndexToFrag..[[;
	vec4 resultFragColor = vec4(ufragColor) / 31.;

	if (blendColorSolid.a > 0.) {
		resultFragColor.rgb = vec3(blendColorSolid.rgb);
	}

	return resultFragColor;
}
]]
	--]=]
	--[=[ internalFormat = internalFormat5551
	self.colorIndexToFragColorCode = [[
		fragColor = texelFetch(paletteTex, ivec2(int(colorIndex & 0xFFu), 0), 0);

#if 0	// if anyone needs the rgb ...
		fragColor.a = (fragColor.r >> 15) * 0x1fu;
		fragColor.b = (fragColor.r >> 10) & 0x1fu;
		fragColor.g = (fragColor.r >> 5) & 0x1fu;
		fragColor.r &= 0x1fu;
		fragColor = (fragColor << 3) | (fragColor >> 2);
#else	// I think I'll just save the alpha for the immediate-after glsl code alpha discard test ...
		fragColor.a = (fragColor.r >> 15) * 0x1fu;
#endif

		if (blendColorSolid.a > 0.) {
			fragColor.rgb = uvec3(blendColorSolid.rgb);
		}

]],
	--]=]

	-- used for drawing our 16bpp framebuffer to the screen
--DEBUG:print'mode 0 blitScreenObj'
	self.blitScreenObj = GLSceneObject{
		program = {
			version = app.glslVersion,
			precision = 'best',
			vertexCode = blitScreenVertexCode,
			fragmentCode = template(
blitScreenFragHeader..[[

void main() {
#if 1	// internalFormat == GL_RGB565
	fragColor = texture(framebufferTex, tcv);
#endif
#if 0	// internalFormat = gl.GL_R16UI
	uint rgba5551 = texture(framebufferTex, tcv).r;
	fragColor = u16_to_5551_vec4(rgba5551);
#endif

	doLighting();
}
]],			{
				app = app,
				self = self,
				glnumber = glnumber,
			}),
			uniforms = {
				framebufferTex = 0,
				framebufferPosTex = 1,
				calcLightTex = 2,
			},
		},
		texs = {
			self.framebufferRAM.tex,
			self.framebufferPosTex,
			assert(self.calcLightTex:cur()),
		},
		geometry = app.quadGeom,
		-- glUniform()'d every frame
		uniforms = {
			mvProjMat = app.blitScreenView.mvProjMat.ptr,
		},
	}
glreport'here'
end

function VideoMode:buildColorOutputAndBlitScreenObj_8bppIndex()
	local app = self.app

	-- indexed mode can't blend so ... no draw-override
	-- this part is only needed for alpha
	self.colorIndexToFragColorCode = [[
uvec4 colorIndexToFragColor(uint colorIndex) {
	uvec4 palColor = ]]..colorIndexToFrag..[[;

	uvec4 resultFragColor;
	resultFragColor.r = colorIndex;
	resultFragColor.g = 0u;
	resultFragColor.b = 0u;
	// only needed for quadSprite / quadMap:
	resultFragColor.a = (palColor.a << 3) | (palColor.a >> 2);

	// the only way to get 5551 solid color to work in 8bpp-indexed mode is performing a lookup from 5551 to the palette
	// for now I'll just use its lower byte
	if (blendColorSolid.a > 0.) {
		resultFragColor.r = 0xFFu & (
			uint(blendColorSolid.r * 31.)
			| (uint(blendColorSolid.g * 31.) << 5u)
		);
	}

	return resultFragColor;
}
]]

	-- used for drawing our 8bpp indexed framebuffer to the screen
--DEBUG:print'mode 1 blitScreenObj'
	self.blitScreenObj = GLSceneObject{
		program = {
			version = app.glslVersion,
			precision = 'best',
			vertexCode = blitScreenVertexCode,
			fragmentCode = template(
blitScreenFragHeader..[[

uniform <?=app.blobs.palette[1].ramgpu.tex:getGLSLSamplerType()?> paletteTex;

]]..glslCode5551..[[

void main() {
	uint colorIndex = texture(framebufferTex, tcv).r;
	uvec4 ufragColor = ]]..colorIndexToFrag..[[;
	fragColor = vec4(ufragColor) / 31.;

	doLighting();
}
]],			{
				app = app,
				self = self,
				glnumber = glnumber,
			}),
			uniforms = {
				framebufferTex = 0,
				framebufferPosTex = 1,
				calcLightTex = 2,
				paletteTex = 3,
			},
		},
		texs = {
			self.framebufferRAM.tex,
			self.framebufferPosTex,
			assert(self.calcLightTex:cur()),
			app.blobs.palette[1].ramgpu.tex,	-- TODO ... what if we regen the resources?  we have to rebind this right?
		},
		geometry = app.quadGeom,
		-- glUniform()'d every frame
		uniforms = {
			mvProjMat = app.blitScreenView.mvProjMat.ptr,
		},
	}
glreport'here'
end

function VideoMode:buildColorOutputAndBlitScreenObj_RGB332()
	local app = self.app
	self.colorIndexToFragColorCode = [[
uvec4 colorIndexToFragColor(uint colorIndex) {
	uvec4 palColor = ]]..colorIndexToFrag..[[;

	// only needed for quadSprite / quadMap:
	// do blendColorSolid before doing the dithering
	if (blendColorSolid.a > 0.) {
		palColor.r = uint(blendColorSolid.r * 31.);
		palColor.g = uint(blendColorSolid.g * 31.);
		palColor.b = uint(blendColorSolid.b * 31.);
	}

	/*
	palColor is 5 5 5 5
	fragColor is 3 3 2
	so we lose   2 2 3 bits
	so we can dither those in ...
	*/
#if 1	// RGB332 dithering
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
	resultFragColor.a = (palColor.a << 3) | (palColor.a >> 2);

	return resultFragColor;
}
]]

--DEBUG:print'mode 2 blitScreenObj'
	self.blitScreenObj = GLSceneObject{
		program = {
			version = app.glslVersion,
			precision = 'best',
			vertexCode = blitScreenVertexCode,
			fragmentCode = template(
blitScreenFragHeader..[[

void main() {
	uint rgb332 = texture(framebufferTex, tcv).r;
	fragColor.r = float(rgb332 & 0x7u) / 7.;
	fragColor.g = float((rgb332 >> 3) & 0x7u) / 7.;
	fragColor.b = float((rgb332 >> 6) & 0x3u) / 3.;
	fragColor.a = 1.;

	doLighting();
}
]],			{
				app = app,
				self = self,
				glnumber = glnumber,
			}),
			uniforms = {
				framebufferTex = 0,
				framebufferPosTex = 1,
				calcLightTex = 2,
			},
		},
		texs = {
			self.framebufferRAM.tex,
			self.framebufferPosTex,
			assert(self.calcLightTex:cur()),
		},
		geometry = app.quadGeom,
		-- glUniform()'d every frame
		uniforms = {
			mvProjMat = app.blitScreenView.mvProjMat.ptr,
		},
	}
glreport'here'
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
		bits 8-15 = colorIndex

for sprites:
	.x:
		bit 0/1 = render pathway = 01
		bit 2 = don't use transparentIndex (on means don't test transparency at all ... set this when transparentIndex is OOB)
		bits 3-5 = spriteBit shift
			Specifies which bit to read from at the sprite.
			Only needs 3 bits.
			  (extra.x >> 3) == 0 = read sprite low nibble.
			  (extra.x >> 3) == 4 = read sprite high nibble.

		bits 8-15 = spriteMask;
			Specifies the mask after shifting the sprite bit
			  0x01u = 1bpp
			  0x03u = 2bpp
			  0x07u = 3bpp
			  0x0Fu = 4bpp
			  0xFFu = 8bpp
			I'm giving this all 8 bits, but honestly I could just represent it as 3 bits and calculate the mask as ((1 << mask) - 1)

	.z = transparentIndex;
		Specifies which colorIndex to use as transparency.
		This is the value of the sprite texel post sprite bit shift & mask, but before applying the paletteOffset shift / high bits.
		If you want fully opaque then just choose an oob color index.

	.w = paletteOffset;
		For now this is an integer added to the 0-15 4-bits of the sprite tex.
		You can set the top 4 bits and it'll work just like OR'ing the high color index nibble.
		Or you can set it to low numbers and use it to offset the palette.
		Should this be high bits? or just an offset to OR? or to add?

for tilemap:
	.x
		bit 0/1 = render pathway = 10
		bit 2 = on = 16x16 tiles, off = 8x8 tiles

	.z = tilemapIndexOffset
*/
layout(location=3) in uvec4 extraAttr;

// flat, the bbox of the currently drawn quad, only used for round-rendering of solid-shader
// TODO just use texcoord?
layout(location=4) in vec4 boxAttr;

//GLES3 says we have at least 16 attributes to use ...

// the bbox world coordinates, used with 'boxAttr' for rounding
out vec2 tcv;

flat out vec3 worldNormalv;
flat out uvec4 extra;
flat out vec4 box;

out float clipDepth;
out vec3 worldCoordv;

uniform mat4 modelMat;
uniform mat4 viewMat;
uniform mat4 projMat;

void main() {
	tcv = texcoord;
	worldNormalv = (modelMat * vec4(normal, 0.)).xyz;
	extra = extraAttr;
	box = boxAttr;

	vec4 worldCoord = modelMat * vec4(vertex, 1.);
	worldCoordv = worldCoord.xyz;

	vec4 viewCoord = viewMat * worldCoord;
	gl_Position = projMat * viewCoord;

	// TODO is this technically "clipCoord"?  because clipping is to [-1,1]^3 volume, which is post-homogeneous transform.
	//  so what's the name of the coordinate system post-projMat but pre-homogeneous-transform?  "projection/projected coordinates" ?
	clipDepth = gl_Position.z;
}
]]),
			fragmentCode = template([[
precision highp sampler2D;
precision highp isampler2D;
precision highp usampler2D;	// needed by #version 300 es

in vec2 tcv;		// framebuffer pixel coordinates before transform , so they are sprite texels

flat in vec3 worldNormalv;
flat in uvec4 extra;	// flags (round, borderOnly), colorIndex
flat in vec4 box;		// x, y, w, h in world coordinates, used for round / border calculations

in float clipDepth;
in vec3 worldCoordv;

layout(location=0) out <?=fragType?> fragColor;
layout(location=1) out vec4 fragNormal;	// worldNormal.xyz, w=HD2DFlags
layout(location=2) out vec4 fragPos;	// worldCoord.xyz, w=clipCoord.z

uniform <?=app.blobs.palette[1].ramgpu.tex:getGLSLSamplerType()?> paletteTex;
uniform <?=app.blobs.sheet[1].ramgpu.tex:getGLSLSamplerType()?> sheetTex;
uniform <?=app.blobs.tilemap[1].ramgpu.tex:getGLSLSamplerType()?> tilemapTex;
uniform <?=app.blobs.animsheet[1].ramgpu.tex:getGLSLSamplerType()?> animSheetTex;

uniform vec4 clipRect;
uniform int HD2DFlags;
uniform vec4 blendColorSolid;
uniform uint dither;
//uniform vec2 frameBufferSize;

uniform float spriteNormalExhaggeration;

<?=glslCode5551?>

float sqr(float x) { return x * x; }
float lenSq(vec2 v) { return dot(v,v); }

//create an orthornomal basis from one vector
// assumes 'n' is normalized
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
mat3 onb2(vec3 a, vec3 b) {
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

float toGreyscale(<?=fragType?> color) {
<? if modeObj.format == 'RGB565' then ?>
	return dot(color.xyz, greyscale);
<? elseif modeObj.format == '8bppIndex' then ?>
	uint x = texelFetch(paletteTex, ivec2(color.r, 0), 0).r;
	// TODO this in uint?  any faster? meh?
	// TODO this code somewhere shared between it and the screen blit?
	vec3 rgb = vec3(
		float(x & 0x1fu) / 31.,
		float((x & 0x3e0u) >> 5u) / 31.,
		float((x & 0x7c00u) >> 10u) / 31.
	);
	return dot(rgb, greyscale);
<? elseif modeObj.format == 'RGB332' then ?>
	// TODO this code somewhere shared between it and the screen blit?
	vec3 rgb = vec3(
		float(color.r & 0x7u) / 7.,
		float((color.r >> 3) & 0x7u) / 7.,
		float((color.r >> 6) & 0x3u) / 3.
	);
	return dot(rgb, greyscale);
<? else
	error'here'
end ?>
}

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

	uint paletteOffset = extra.w;

	// sheetTex is usampler2D / returns uvec4
	// sheetTex.r holds the uint8 value of the indexed color
	uint colorIndex = texture(sheetTex, tc).r;

	colorIndex >>= spriteBit;
	colorIndex &= spriteMask;

	// if you discard based on alpha here then the bilinear interpolation that samples this 4x will cause unnecessary discards
	bool forceTransparent = colorIndex == transparentIndex;

	colorIndex += paletteOffset;
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
	uint tilemapIndexOffset = uint(extra.z);

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
	uint tileIndex = texelFetch(tilemapTex, tileTC, 0).r;

	// should tilemapOffset affect orientation2D / palHi? no
	// calculate orientation here first
	uint palHi = (tileIndex >> 10) & 7u;	// tilemap bits 10..12
	bool hflip = ((tileIndex >> 13) & 1u) != 0u;	// tilemap bit 13 = hflip
	uint rot = (tileIndex >> 14) & 3u;		// tilemap bits 14..15 = rotation

	// should tilemapOffset affect animation?  yes
	// before animation, consider tilemap offset
	tileIndex += tilemapIndexOffset;
	tileIndex &= 0x3FFu;

	// animsheet is R16UI
	tileIndex = texelFetch(
		animSheetTex,
		ivec2(int(tileIndex), 0),
		0
	).r & 0x3FFu;

	//[0, 31)^2 = 5 bits for tile tex sprite x, 5 bits for tile tex sprite y
	ivec2 tileIndexTC = ivec2(
		int(tileIndex & 0x1Fu),				// tilemap bits 0..4
		int((tileIndex >> 5) & 0x1Fu)			// tilemap bits 5..9
	);

	if (rot == 1u) {
		tci = ivec2(tci.y, ~tci.x);
	} else if (rot == 2u) {
		tci = ivec2(~tci.x, ~tci.y);
	} else if (rot == 3u) {
		tci = ivec2(~tci.y, tci.x);
	}
	if (hflip) {
		tci.x = ~tci.x;
	}

	int mask = (1 << (3u + draw16Sprites)) - 1;
	// [0, spriteSize)^2
	ivec2 tileTexTC = ivec2(
		(tci.x & mask) ^ (tileIndexTC.x << 3),
		(tci.y & mask) ^ (tileIndexTC.y << 3)
	);

	// sheetTex is R8 indexing into our palette ...
	uint colorIndex = texelFetch(sheetTex, tileTexTC, 0).r;

	colorIndex += palHi << 5;
	colorIndex &= 0xFFu;

	return colorIndexToFragColor(colorIndex);
}

// this is a horrible hack
// sheetTex is typically our blob sheet tex, GL_R8UI, usampler2D
// but for the cart display I'm binding it to a GL_RGBA8UI so I can also use usampler2D but for RGBA
// and I'm only using this in RGB565 mode when fragType==vec4
<?=fragType?> directShading(vec2 tc) {
<? if modeObj.format == 'RGB565' then ?>
	return vec4(texture(sheetTex, tc)) / 255.;
<? elseif modeObj.format == '8bppIndex' then ?>
	return uvec4(vec4(texture(sheetTex, tc)) / 255.);
<? elseif modeObj.format == 'RGB332' then ?>
	return uvec4(vec4(texture(sheetTex, tc))/ 255.);
<? else
	error'here'
end ?>
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

	if ((dither & (1u << threshold)) != 0u) discard;

	uint pathway = extra.x & 3u;

	float bumpHeight = -1.;

	// solid shading pathway
	if (pathway == 0u) {

		fragColor = solidShading(tcv);

		bumpHeight = toGreyscale(fragColor);

	// sprite shading pathway
	} else if (pathway == 1u) {

#if 0	// color and bump height LINEAR ... gotta do it here, can't do it in mag filter texture because it's a u8 texture (TODO change to a GL_RED texture?  but then no promises on the value having 8 bits (but it's 2025, who am I kidding, it'll have 8 bits))

		vec2 size = vec2(textureSize(sheetTex, 0));
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
		vec2 size = vec2(textureSize(sheetTex, 0));
		vec2 stc = tcv.xy * size - .5;
		vec2 ftc = floor(stc);
		vec2 fp = fract(stc);

		<?=fragType?> fragColorLL = spriteShading((ftc + vec2(0.5, 0.5)) / size);
		<?=fragType?> fragColorRL = spriteShading((ftc + vec2(1.5, 0.5)) / size);
		<?=fragType?> fragColorLR = spriteShading((ftc + vec2(0.5, 1.5)) / size);
		<?=fragType?> fragColorRR = spriteShading((ftc + vec2(1.5, 1.5)) / size);

		float bumpHeightLL = toGreyscale(fragColorLL);
		float bumpHeightRL = toGreyscale(fragColorRL);
		float bumpHeightLR = toGreyscale(fragColorLR);
		float bumpHeightRR = toGreyscale(fragColorRR);

		bumpHeight = mix(
			mix(bumpHeightLL, bumpHeightRL, fp.x),
			mix(bumpHeightLR, bumpHeightRR, fp.x), fp.y
		);
#endif
#endif

	} else if (pathway == 2u) {

		fragColor = tilemapShading(tcv);

		bumpHeight = toGreyscale(fragColor);

	// I had an extra pathway and I didn't know what to use it for
	// and I needed a RGB option for the cart browser (maybe I should just use this for all the menu system and just skip on the menu-palette?)
	} else if (pathway == 3u) {

		fragColor = directShading(tcv);

		bumpHeight = toGreyscale(fragColor);

	}	// pathway


<? if fragType == 'uvec4' then ?>
	if (fragColor.a == 0u) discard;
<? else ?>
	if (fragColor.a < .5) discard;
<? end ?>


// position

	fragPos = vec4(worldCoordv, clipDepth);

// lighting:

	bumpHeight *= spriteNormalExhaggeration;

	if ((HD2DFlags & <?=ffi.C.HD2DFlags_useBumpMap?>) == 0) {
		// normal from flat sided objs
		fragNormal.xyz = worldNormalv;
	} else {
#if 0	// debug - show sprite normals only
		// TODO transform from viewCoords to worldCoords by the inverse-view matrix
		fragNormal.xyz = normalize(cross(
			vec3(1., 0., dFdx(bumpHeight)),
			vec3(0., 1., dFdy(bumpHeight))));

#else	// rotate sprite normals onto frag normal plane

		//glsl matrix index access is based on columns
		//so its index notation is reversed from math index notation.
		// spriteBasis[j][i] = spriteBasis_ij = d(bumpHeight)/d(fragCoord_j)
		mat3 spriteBasis = onb2(
			vec3(1., 0., dFdx(bumpHeight)),
			vec3(0., 1., dFdy(bumpHeight)));

		// modelBasis[j][i] = modelBasis_ij = d(vertex_i)/d(fragCoord_j)
		mat3 modelBasis = onb1(normalize(worldNormalv));

	//TODO now transform the bumpmap coord into the worldnormal basis
	// probably involves an inverse view or something idk
	// (how about I cache/calc the bumpmap tangent space on tex, then no need to use dFdx)

		//result should be d(bumpHeight)/d(vertex_j)
		// = d(bumpHeight)/d(fragCoord_k) * d(fragCoord_k)/d(vertex_j)
		// = d(bumpHeight)/d(fragCoord_k) * inv(d(vertex_j)/d(fragCoord_k))
		// = spriteBasis * transpose(modelBasis)
		//modelBasis = spriteBasis * transpose(modelBasis);
		//fragNormal.xyz = transpose(modelBasis)[2];
		fragNormal.xyz = (modelBasis * transpose(spriteBasis))[2];
#endif
	}

	// save per-fragment whether lighting is enabled or not
	fragNormal.w = float(HD2DFlags);
}
]],			{
				ffi = ffi,
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
				animSheetTex = 3,
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
				stride = ffi.sizeof(Numo9Vertex),
				offset = ffi.offsetof(Numo9Vertex, 'vertex'),
			},
			texcoord = {
				type = gl.GL_FLOAT,
				size = 2,
				buffer = app.vertexBufGPU,
				stride = ffi.sizeof(Numo9Vertex),
				offset = ffi.offsetof(Numo9Vertex, 'texcoord'),
			},
			normal = {
				type = gl.GL_FLOAT,
				size = 3,
				buffer = app.vertexBufGPU,
				stride = ffi.sizeof(Numo9Vertex),
				offset = ffi.offsetof(Numo9Vertex, 'normal'),
			},
			-- 8 bytes = 32 bit so I can use memset?
			extraAttr = {
				type = gl.GL_UNSIGNED_SHORT,
				size = 4,
				--divisor = 3,
				buffer = app.vertexBufGPU,
				stride = ffi.sizeof(Numo9Vertex),
				offset = ffi.offsetof(Numo9Vertex, 'extra'),
			},
			-- 16 bytes =  128-bit ...
			boxAttr = {
				size = 4,
				type = gl.GL_FLOAT,
				--divisor = 3,	-- 6 honestly ...
				buffer = app.vertexBufGPU,
				stride = ffi.sizeof(Numo9Vertex),
				offset = ffi.offsetof(Numo9Vertex, 'box'),
			},
		},
	}
end


return {
	VideoMode = VideoMode,
	Numo9Vertex = Numo9Vertex,
}
