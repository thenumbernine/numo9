-- putting the orbit stuff that editmesh3d and editvoxelmap both use into here
-- TODO tempted to make this a proper UI component i.e. it includes the viewport and clipping stuff too
local ffi = require 'ffi'
local class = require 'ext.class'
local vec2i = require 'vec-ffi.vec2i'
local vec3d = require 'vec-ffi.vec3d'
local quatd = require 'vec-ffi.quatd'
local gl = require 'gl'

local numo9_rom = require 'numo9.rom'
local mvMatType = numo9_rom.mvMatType
local clipMax = numo9_rom.clipMax

local Orbit = class()

function Orbit:init(app)
	self.app = app

	self.scale = 1
	self.ortho = false
	self.angle = quatd(0,0,0,1)
	self.orbit = vec3d(0,0,0)
	self.pos = vec3d(0,0,1)

	self.mvMatPush = ffi.new(mvMatType..'[16]')
end

function Orbit:beginDraw()
	local app = self.app

	local mouseX, mouseY = app.ram.mousePos:unpack()
	local dx = mouseX - app.ram.lastMousePos.x
	local dy = mouseY - app.ram.lastMousePos.y

	local app = self.app
	app:drawSolidRect(0, 8, 256, 256, 0x28, nil, nil, app.paletteMenuTex)
	app:setClipRect(0, 8, 256, 256)

	-- flush before enable depth test so the flush doesn't use depth test...
	app.triBuf:flush()
	gl.glEnable(gl.GL_DEPTH_TEST)
	gl.glClear(gl.GL_DEPTH_BUFFER_BIT)

	ffi.copy(self.mvMatPush, app.ram.mvMat, ffi.sizeof(self.mvMatPush))

	local height = 256
	if app:key'mouse_left'
	and (dx ~= 0 or dy ~= 0)
	then
		local shift = app:key'lshift' or app:key'rshift'
		local uikey
		if ffi.os == 'OSX' then
			uikey = app:key'lgui' or app:key'rgui'
		else
			uikey = app:key'lctrl' or app:key'rctrl'
		end
		if shift then
			if self.ortho then
				self.scale = self.scale * math.exp(.1 * dy)
			else
				self.pos = (self.pos - self.orbit) * math.exp(dy * -.03) + self.orbit
			end
		elseif uikey then
			local dist = (self.pos - self.orbit):length()
			self.orbit = self.orbit + self.angle:rotate(vec3d(-dx,dy,0) * (dist / height))
			self.pos = self.angle:zAxis() * dist + self.orbit
		else
			self.angle = self.angle * quatd():fromAngleAxis(-dy,-dx, 0, 3*math.sqrt(dx^2+dy^2))
			self.pos = self.angle:zAxis() * (self.pos - self.orbit):length() + self.orbit
		end
	end
	local x,y,z,th = self.angle:toAngleAxis():unpack()

	app:matident()
	-- draw orientation widget
	app:matortho(-20, 2, 20, -2, -2, 2)
	app:matrot(-math.rad(th), x, y, z)	-- -th or +th?
	app:drawSolidLine3D(0, 0, 0, 1, 0, 0, 0x19, nil, app.paletteMenuTex)
	app:drawSolidLine3D(0, 0, 0, 0, 1, 0, 0x1a, nil, app.paletteMenuTex)
	app:drawSolidLine3D(0, 0, 0, 0, 0, 1, 0x1c, nil, app.paletteMenuTex)
	app:matident()

	if self.ortho then
		local r = 1.2
		local zn, zf = -1000, 1000
		app:matortho(-r, r, r, -r, zn, zf)
		-- notice this is flipping y ... hmm TODO do that in matortho? idk...
	else
		local zn, zf = .1, 1000
		app:matfrustum(-zn, zn, -zn, zn, zn, zf)
		-- fun fact, swapping top and bottom isn't the same as scaling y axis by -1  ...
		-- TODO matscale here or in matfrustum? hmm...
		app:matscale(1, -1, 1)
	end

	app:matrot(-math.rad(th),x,y,z)
	app:mattrans(-self.pos.x, -self.pos.y, -self.pos.z)
	app:matscale(self.scale, self.scale, self.scale)
end

function Orbit:endDraw()
	local app = self.app
	ffi.copy(app.ram.mvMat, self.mvMatPush, ffi.sizeof(self.mvMatPush))
	-- flush before disable depth test so the flush will use depth test...
	app.triBuf:flush()
	gl.glDisable(gl.GL_DEPTH_TEST)

	app:setClipRect(0, 0, clipMax, clipMax)
end

return Orbit
