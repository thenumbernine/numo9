local EditMesh3D = require 'numo9.ui':subclass()

function EditMesh3D:init(args)
	EditMesh3D.super.init(self, args)
end

function EditMesh3D:onCartLoad()
	self.mesh3DBlobIndex = 0
	self.sheetBlobIndex = 1
	self.paletteBlobIndex = 0
end

function EditMesh3D:update()
	local app = self.app

	EditBrushmap.super.update(self)

	local mesh3DBlob = app.blobs.mesh3d[self.mesh3DBlobIndex+1]
	if mesh3DBlob then
		local x, y = 0, 8
		app:drawMenuText('#vtx:'..mesh3DBlob:getNumVertexes(), x, y)
		y = y + 8
		app:drawMenuText('#ind:'..mesh3DBlob:getNumIndexes(), x, y)
		y = y + 8
	
		-- draw the 3D model here
		app:net_drawMesh3D(self.mesh3DBlobIndex, self.sheetBlobIndex, self.paletteBlobIndex)
	end

	local x, y = 40, 0
	self:guiBlobSelect(x, y, 'brushmap', self, 'brushmapBlobIndex')
	x = x + 12
	self:guiBlobSelect(x, y, 'sheet', self, 'sheetBlobIndex')
	x = x + 12
	self:guiBlobSelect(x, y, 'palette', self, 'paletteBlobIndex')

	self:drawTooltip()
end

return EditMesh3D
