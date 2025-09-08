local ffi = require 'ffi'
local gl = require 'gl'
local vec2i = require 'vec-ffi.vec2i'
local quatd = require 'vec-ffi.quatd'

local numo9_rom = require 'numo9.rom'
local mvMatType = numo9_rom.mvMatType
local clipMax = numo9_rom.clipMax

local EditVoxelMap = require 'numo9.ui':subclass()

function EditVoxelMap:init(args)
	EditVoxelMap.super.init(self, args)
	self:onCartLoad()
end

function EditVoxelMap:onCartLoad()
	self.voxelmapBlobIndex = 0
	self.sheetBlobIndex = 0
	self.paletteBlobIndex = 0

	self.lastMousePos = vec2i()
	self.scale = 1
	self.ortho = false
	self.angle = quatd(0,0,0,1)
end

local mvMatPush = ffi.new(mvMatType..'[16]')
function EditVoxelMap:update()
	local app = self.app

	EditVoxelMap.super.update(self)
	
	app:setClipRect(0, 8, 256, 256)

	local mouseX, mouseY = app.ram.mousePos:unpack()
	local dx = mouseX - self.lastMousePos.x
	local dy = mouseY - self.lastMousePos.y
	self.lastMousePos:set(mouseX, mouseY)
	local leftButtonDown = app:key'mouse_left'
	local shift = app:key'lshift' or app:key'rshift'

	local voxelmapBlob = app.blobs.voxelmap[self.voxelmapBlobIndex+1]
	if voxelmapBlob then
		
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

		-- TODO here draw the voxelmap ...
		self:net_drawVoxelMap(
			self.voxelmapBlobIndex,
			self.sheetBlobIndex,
			self.paletteBlobIndex
		)

		ffi.copy(app.ram.mvMat, mvMatPush, ffi.sizeof(mvMatPush))
		-- flush before disable depth test so the flush will use depth test...
		app.triBuf:flush()
		gl.glDisable(gl.GL_DEPTH_TEST)
	end

	app:setClipRect(0, 0, clipMax, clipMax)

	local x, y = 48, 0
	self:guiBlobSelect(x, y, 'voxelmap', self, 'voxelmapBlobIndex')
	x = x + 12
	self:guiBlobSelect(x, y, 'sheet', self, 'sheetBlobIndex')
	x = x + 12
	self:guiBlobSelect(x, y, 'palette', self, 'paletteBlobIndex')
	x = x + 12

	if self:guiButton(self.ortho and 'O' or 'P', x, y, false, self.ortho and 'ortho' or 'projection') then
		self.ortho = not self.ortho
	end
	x = x + 8

	self:drawTooltip()
end

return EditVoxelMap
