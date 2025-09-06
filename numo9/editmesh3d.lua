local ffi = require 'ffi'
local vec2i = require 'vec-ffi.vec2i'
local quatd = require 'vec-ffi.quatd'
local numo9_rom = require 'numo9.rom'
local mvMatType = numo9_rom.mvMatType

local EditMesh3D = require 'numo9.ui':subclass()

function EditMesh3D:init(args)
	EditMesh3D.super.init(self, args)
end

function EditMesh3D:onCartLoad()
	self.mesh3DBlobIndex = 0
	self.sheetBlobIndex = 1
	self.paletteBlobIndex = 0

	self.wireframe = false

	self.lastMousePos = vec2i()
	self.scale = 1
	self.angle = quatd(0,0,0,1)
end

local mvMatPush = ffi.new(mvMatType..'[16]')
function EditMesh3D:update()
	local app = self.app

	EditMesh3D.super.update(self)

	local mouseX, mouseY = app.ram.mousePos:unpack()
	local dx = mouseX - self.lastMousePos.x
	local dy = mouseY - self.lastMousePos.y
	self.lastMousePos:set(mouseX, mouseY)
	local leftButtonDown = app:key'mouse_left'
	local shift = app:key'lshift' or app:key'rshift'

	local mesh3DBlob = app.blobs.mesh3d[self.mesh3DBlobIndex+1]
	if mesh3DBlob then
		ffi.copy(mvMatPush, app.ram.mvMat, ffi.sizeof(mvMatPush))
		app:matident()
		app:matortho(-1.2, 1.2, 1.2, -1.2, -1.2, 1.2)

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

		local x, y = 0, 8
		app:drawMenuText('#vtx:'..mesh3DBlob:getNumVertexes(), x, y)
		y = y + 8
		app:drawMenuText('#ind:'..mesh3DBlob:getNumIndexes(), x, y)
		y = y + 8

		-- draw the 3D model here
		if self.wireframe then
			local color = 0xc
			local thickness = .5

			local vtxs = mesh3DBlob:getVertexPtr()
			local inds = mesh3DBlob:getIndexPtr()
			local numInds = mesh3DBlob:getNumIndexes()
			if numInds == 0 then	-- no indexes? just draw all vtxs
				local numVtxs = mesh3DBlob:getNumVertexes()
				for i=0,numVtxs-3,3 do
					for j=0,2 do
					local a = vtxs + i+j
					local b = vtxs + i+(j+1)%3
						app:drawSolidLine3D(
							a.x, a.y, a.z,
							b.x, b.y, b.z,
							color,
							thickness)
					end
				end
			else	-- draw indexed vertexes
				for i=0,numInds-3,3 do
					for j=0,2 do
						local a = vtxs + inds[i+j]
						local b = vtxs + inds[i+(j+1)%3]
						app:drawSolidLine3D(
							a.x, a.y, a.z,
							b.x, b.y, b.z,
							color,
							thickness)
					end
				end
			end
		else
			app:net_drawMesh3D(self.mesh3DBlobIndex, self.sheetBlobIndex, self.paletteBlobIndex)
		end

		ffi.copy(app.ram.mvMat, mvMatPush, ffi.sizeof(mvMatPush))
	end

	local x, y = 48, 0
	self:guiBlobSelect(x, y, 'mesh3d', self, 'mesh3DBlobIndex')
	x = x + 12
	self:guiBlobSelect(x, y, 'sheet', self, 'sheetBlobIndex')
	x = x + 12
	self:guiBlobSelect(x, y, 'palette', self, 'paletteBlobIndex')
	x = x + 12

	if self:guiButton('W', x, y, self.wireframe, 'wireframe') then
		self.wireframe = not self.wireframe
	end
	x = x + 8

	self:drawTooltip()
end

return EditMesh3D
