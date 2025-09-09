-- putting the orbit stuff that editmesh3d and editvoxelmap both use into here
local class = require 'ext.class'
local vec2i = require 'vec-ffi.vec2i'
local quatd = require 'vec-ffi.quatd'

local Orbit = class()

function Orbit:init(app)
	self.app = app

	self.lastMousePos = vec2i()
	self.mouseMove = vec2i()
	self.scale = 1
	self.distance = 1	-- projection uses this
	self.ortho = false
	self.angle = quatd(0,0,0,1)
	-- TODO add 'pos' and 'orbit'
end

function Orbit:update()
	local app = self.app
	local mouseX, mouseY = app.ram.mousePos:unpack()
	self.mouseMove:set(
		mouseX - self.lastMousePos.x,
		mouseY - self.lastMousePos.y)
	self.lastMousePos:set(mouseX, mouseY)
end

function Orbit:applyMatrix()
	local app = self.app
	local dx, dy = self.mouseMove:unpack()
	if app:key'mouse_left'
	and (dx ~= 0 or dy ~= 0)
	then
		local shift = app:key'lshift' or app:key'rshift'
		if shift then
			self.scale = self.scale * math.exp(.1 * dy)
		else
			self.angle = quatd():fromAngleAxis(dy, dx, 0, 3*math.sqrt(dx^2+dy^2)) * self.angle
		end
	end
	local x,y,z,th = self.angle:toAngleAxis():unpack()

	app:matident()
	-- draw orientation widget
	app:matortho(-20, 2, -2, 20, -2, 2)
	app:matrot(math.rad(th),x,y,z)
	app:drawSolidLine3D(
		0, 0, 0, 1, 0, 0,
		0x19,
		nil,
		app.paletteMenuTex)
	app:drawSolidLine3D(
		0, 0, 0, 0, 1, 0,
		0x1a,
		nil,
		app.paletteMenuTex)
	app:drawSolidLine3D(
		0, 0, 0, 0, 0, 1,
		0x1c,
		nil,
		app.paletteMenuTex)

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
		app:mattrans(0, 0, -self.distance)
	end

	app:matrot(math.rad(th),x,y,z)
	app:matscale(self.scale/32768, self.scale/32768, self.scale/32768)
end

return Orbit
