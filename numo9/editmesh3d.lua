local ffi = require 'ffi'
local gl = require 'gl'
local vec2i = require 'vec-ffi.vec2i'
local quatd = require 'vec-ffi.quatd'

local numo9_rom = require 'numo9.rom'
local mvMatType = numo9_rom.mvMatType
local clipMax = numo9_rom.clipMax

local EditMesh3D = require 'numo9.ui':subclass()

function EditMesh3D:init(args)
	EditMesh3D.super.init(self, args)
	self:onCartLoad()
end

function EditMesh3D:onCartLoad()
	self.mesh3DBlobIndex = 0
	self.sheetBlobIndex = 0	-- TODO should this default to 1 (tilemap) or 0 (spritemap) ?  or should I even keep a 1 by default around?
	self.paletteBlobIndex = 0

	self.drawFaces = true
	self.wireframe = false

	self.lastMousePos = vec2i()
	self.scale = 1
	self.ortho = false
	self.angle = quatd(0,0,0,1)
	-- TODO add 'pos' and 'orbit'
end

local mvMatPush = ffi.new(mvMatType..'[16]')
function EditMesh3D:update()
	local app = self.app

	EditMesh3D.super.update(self)

	app:drawSolidRect(0, 8, 256, 256, 0x28, nil, nil, app.paletteMenuTex)
	app:setClipRect(0, 8, 256, 256)

	local mouseX, mouseY = app.ram.mousePos:unpack()
	local dx = mouseX - self.lastMousePos.x
	local dy = mouseY - self.lastMousePos.y
	self.lastMousePos:set(mouseX, mouseY)
	local leftButtonDown = app:key'mouse_left'
	local shift = app:key'lshift' or app:key'rshift'

	local mesh3DBlob = app.blobs.mesh3d[self.mesh3DBlobIndex+1]
	if mesh3DBlob then

		-- flush before enable depth test so the flush doesn't use depth test...
		app.triBuf:flush()
		gl.glEnable(gl.GL_DEPTH_TEST)
		gl.glClear(gl.GL_DEPTH_BUFFER_BIT)

		ffi.copy(mvMatPush, app.ram.mvMat, ffi.sizeof(mvMatPush))
		app:matident()
		if self.ortho then
			local r = 1.2
			local zn, zf = -1000, 1000
			app:matortho(-r, r, r, -r, zn, zf)
			-- notice this is flipping y ... hmm TODO do that in matortho? idk...
		else
			local zn, zf = .1, 2
			app:matfrustum(-zn, zn, -zn, zn, zn, zf)
			-- fun fact, swapping top and bottom isn't the same as scaling y axis by -1  ...
			-- TODO matscale here or in matfrustum? hmm...
			app:matscale(1, -1, 1)
			app:mattrans(0, 0, -.5 * zf)
		end

		do
			if app:key'mouse_left'
			and (dx ~= 0 or dy ~= 0)
			then
				if shift then
					self.scale = self.scale * math.exp(.1 * dy)
				else
					self.angle = quatd():fromAngleAxis(dy, dx, 0, 3*math.sqrt(dx^2+dy^2)) * self.angle
				end
			end

			local x,y,z,th = self.angle:toAngleAxis():unpack()
			app:matrot(math.rad(th),x,y,z)
		end

		app:matscale(self.scale/32768, self.scale/32768, self.scale/32768)

		-- draw the 3D model here
		if self.wireframe then
			local color = 0x2e
			local thickness = 1

			local vtxs = mesh3DBlob:getVertexPtr()
			local inds = mesh3DBlob:getIndexPtr()
			local numIndexes = mesh3DBlob:getNumIndexes()
			if numIndexes == 0 then	-- no indexes? just draw all vtxs
				local numVtxs = mesh3DBlob:getNumVertexes()
				for i=0,numVtxs-3,3 do
					for j=0,2 do
						local a = vtxs + i+j
						local b = vtxs + i+(j+1)%3
						app:drawSolidLine3D(
							a.x, a.y, a.z,
							b.x, b.y, b.z,
							color,
							thickness,
							app.paletteMenuTex)
					end
				end
			else	-- draw indexed vertexes
				for i=0,numIndexes-3,3 do
					for j=0,2 do
						local a = vtxs + inds[i+j]
						local b = vtxs + inds[i+(j+1)%3]
						app:drawSolidLine3D(
							a.x, a.y, a.z,
							b.x, b.y, b.z,
							color,
							thickness,
							app.paletteMenuTex)
					end
				end
			end
		end
		if self.drawFaces then
			app:drawMesh3D(
				self.mesh3DBlobIndex,
				0,	-- uofs
				0,	-- vofs
				self.sheetBlobIndex,
				self.paletteBlobIndex
			)
		end

		ffi.copy(app.ram.mvMat, mvMatPush, ffi.sizeof(mvMatPush))
		-- flush before disable depth test so the flush will use depth test...
		app.triBuf:flush()
		gl.glDisable(gl.GL_DEPTH_TEST)

		local x, y = 0, 8
		app:drawMenuText('#vtx:'..mesh3DBlob:getNumVertexes(), x, y)
		y = y + 8
		app:drawMenuText('#ind:'..mesh3DBlob:getNumIndexes(), x, y)
		y = y + 8
		app:drawMenuText('size:'..mesh3DBlob:getSize(), x, y)
		y = y + 8
	end

	app:setClipRect(0, 0, clipMax, clipMax)

	local x, y = 50, 0
	self:guiBlobSelect(x, y, 'mesh3d', self, 'mesh3DBlobIndex')
	x = x + 12
	self:guiBlobSelect(x, y, 'sheet', self, 'sheetBlobIndex')
	x = x + 12
	self:guiBlobSelect(x, y, 'palette', self, 'paletteBlobIndex')
	x = x + 12

	if self:guiButton('F', x, y, self.drawFaces, 'faces') then
		self.drawFaces = not self.drawFaces
	end
	x = x + 8
	if self:guiButton('W', x, y, self.wireframe, 'wireframe') then
		self.wireframe = not self.wireframe
	end
	x = x + 8
	if self:guiButton(self.ortho and 'O' or 'P', x, y, false, self.ortho and 'ortho' or 'projection') then
		self.ortho = not self.ortho
	end
	x = x + 8

	self:drawTooltip()
end

return EditMesh3D
