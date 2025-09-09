local Orbit = require 'numo9.ui.orbit'

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

	-- TODO replace this with a tile-select and a 8/16 toggle
	self.tileXOffset = 0
	self.tileYOffset = 0

	self.orbit = Orbit(self.app)
end

function EditMesh3D:update()
	local app = self.app

	EditMesh3D.super.update(self)

	self.orbit:update()

	local mesh3DBlob = app.blobs.mesh3d[self.mesh3DBlobIndex+1]
	if mesh3DBlob then
		self.orbit:beginDraw()

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
			-- set the current selected palette via RAM registry to self.paletteBlobIndex
			local pushPalBlobIndex = app.ram.paletteBlobIndex
			app.ram.paletteBlobIndex = self.paletteBlobIndex
			app:drawMesh3D(
				self.mesh3DBlobIndex,
				self.tileXOffset,
				self.tileYOffset,
				self.sheetBlobIndex
			)
			app.ram.paletteBlobIndex = pushPalBlobIndex
		end

		self.orbit:endDraw()

		local x, y = 0, 8
		app:drawMenuText('#vtx:'..mesh3DBlob:getNumVertexes(), x, y)
		y = y + 8
		app:drawMenuText('#ind:'..mesh3DBlob:getNumIndexes(), x, y)
		y = y + 8
		app:drawMenuText('size:'..mesh3DBlob:getSize(), x, y)
		y = y + 8
	end

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
	if self:guiButton(self.orbit.ortho and 'O' or 'P', x, y, false, self.orbit.ortho and 'ortho' or 'projection') then
		self.orbit.ortho = not self.orbit.ortho
	end
	x = x + 8

	self:guiSpinner(x, y, function(dx)
		self.tileXOffset = bit.band(31, self.tileXOffset + dx)
	end, 'uofs='..self.tileXOffset)
	x = x + 12

	-- [[ TODO replace this with edittilemap's sheet tile selector
	self:guiSpinner(x, y, function(dx)
		self.tileYOffset = bit.band(31, self.tileYOffset + dx)
	end, 'vofs='..self.tileYOffset)
	x = x + 12


	self:drawTooltip()
end

return EditMesh3D
