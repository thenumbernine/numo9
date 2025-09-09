local ffi = require 'ffi'
local gl = require 'gl'
local vector = require 'ffi.cpp.vector-lua'
local vec2i = require 'vec-ffi.vec2i'
local vec3i = require 'vec-ffi.vec3i'
local quatd = require 'vec-ffi.quatd'

local Orbit = require 'numo9.ui.orbit'

local numo9_rom = require 'numo9.rom'
local mvMatType = numo9_rom.mvMatType
local clipMax = numo9_rom.clipMax
local voxelmapSizeType = numo9_rom.voxelmapSizeType

local numo9_blobs = require 'numo9.blobs'
local blobClassForName = numo9_blobs.blobClassForName

local EditVoxelMap = require 'numo9.ui':subclass()

function EditVoxelMap:init(args)
	EditVoxelMap.super.init(self, args)
	self:onCartLoad()
end

function EditVoxelMap:onCartLoad()
	self.voxelmapBlobIndex = 0
	self.sheetBlobIndex = 0
	self.paletteBlobIndex = 0

	self.tileXOffset = 0
	self.tileYOffset = 0
	self.orientation = 0

	self.orbit = Orbit(self.app)
end

local mvMatPush = ffi.new(mvMatType..'[16]')
function EditVoxelMap:update()
	local app = self.app

	EditVoxelMap.super.update(self)

	app:setClipRect(0, 8, 256, 256)

	self.orbit:update()

	local voxelmapBlob = app.blobs.voxelmap[self.voxelmapBlobIndex+1]
	if voxelmapBlob then

		-- flush before enable depth test so the flush doesn't use depth test...
		app.triBuf:flush()
		gl.glEnable(gl.GL_DEPTH_TEST)
		gl.glClear(gl.GL_DEPTH_BUFFER_BIT)

		ffi.copy(mvMatPush, app.ram.mvMat, ffi.sizeof(mvMatPush))
		self.orbit:applyMatrix()

		local size = {voxelmapBlob:getWidth(), voxelmapBlob:getHeight(), voxelmapBlob:getDepth()}
		local function corner(i)
			return bit.band(i, 1) ~= 0 and size[1] or 0,
				bit.band(i, 2) ~= 0 and size[2] or 0,
				bit.band(i, 3) ~= 0 and size[3] or 0
		end

		for i=0,7 do
			for j=0,2 do
				local k = bit.bxor(i, bit.lshift(1, j))
				if k > i then
					local ax, ay, az = corner(i)
					local bx, by, bz = corner(j)
					app:drawSolidLine3D(
						ax, ay, az,
						bx, by, bz,
						0x31,
						nil,
						app.paletteMenuTex)
				end
			end
		end

		app:drawVoxelMap(
			self.voxelmapBlobIndex,
			self.sheetBlobIndex,
			self.paletteBlobIndex
		)

		ffi.copy(app.ram.mvMat, mvMatPush, ffi.sizeof(mvMatPush))
		-- flush before disable depth test so the flush will use depth test...
		app.triBuf:flush()
		gl.glDisable(gl.GL_DEPTH_TEST)

		local x, y = 0, 8
		app:drawMenuText('w='..voxelmapBlob:getWidth(), x, y)
		y = y + 8
		app:drawMenuText('h='..voxelmapBlob:getHeight(), x, y)
		y = y + 8
		app:drawMenuText('d='..voxelmapBlob:getDepth(), x, y)
		y = y + 8
	end

	app:setClipRect(0, 0, clipMax, clipMax)

	local x, y = 50, 0
	self:guiBlobSelect(x, y, 'voxelmap', self, 'voxelmapBlobIndex')
	x = x + 12
	self:guiBlobSelect(x, y, 'sheet', self, 'sheetBlobIndex')
	x = x + 12
	self:guiBlobSelect(x, y, 'palette', self, 'paletteBlobIndex')
	x = x + 12

	if self:guiButton(self.orbit.ortho and 'O' or 'P', x, y, false, self.orbit.ortho and 'orbit.ortho' or 'projection') then
		self.orbit.ortho = not self.orbit.ortho
	end
	x = x + 8

	self:guiSpinner(x, y, function(dx)
		self.tileXOffset = bit.band(31, self.tileXOffset + dx)
	end, 'uofs='..self.tileYOffset)
	x = x + 12

	-- [[ TODO replace this with edittilemap's sheet tile selector
	self:guiSpinner(x, y, function(dx)
		self.tileYOffset = bit.band(31, self.tileYOffset + dx)
	end, 'vofs='..self.tileXOffset)
	x = x + 12

	self:guiSpinner(x, y, function(dx)
		self.orientation = bit.band(31, self.orientation + dx)
	end, 'orient='..self.orientation)
	x = x + 12
	--]]

	if voxelmapBlob then
		self:guiSpinner(x, y, function(dx)
			self:resizeVoxelmap(
				math.max(1, self:getWidth() + dx),
				self:getHeight(),
				self:getDepth()
			)
		end, 'width='..voxelmapBlob:getWidth())
		x = x + 12

		self:guiSpinner(x, y, function(dx)
			self:resizeVoxelmap(
				self:getWidth(),
				math.max(1, self:getHeight() + dx),
				self:getDepth()
			)
		end, 'height='..voxelmapBlob:getHeight())
		x = x + 12

		self:guiSpinner(x, y, function(dx)
			self:resizeVoxelmap(
				self:getWidth(),
				self:getHeight(),
				math.max(1, self:getDepth() + dx)
			)
		end, 'depth='..voxelmapBlob:getDepth())
		x = x + 12
	end

	-- TODO selector for which mesh3D to place

	self:drawTooltip()
end

function EditVoxelMap:resizeVoxelmap(nx, ny, nz)
	local voxelmapBlob = app.blobs.voxelmap[self.voxelmapBlobIndex+1]
	if not voxelmapBlob then return end

	assert.eq(ffi.sizeof(voxelmapSizeType), ffi.sizeof'Voxel')	-- just put everything in uint32_t

	local o = vector(voxelmapSizeType)
	o:emplace_back()[0] = nx
	o:emplace_back()[0] = ny
	o:emplace_back()[0] = nz
	for k=0,nz-1 do
		for j=0,ny-1 do
			for i=0,nx-1 do
				if i < voxelmapBlob:getWidth()
				and j < voxelmapBlob:getHeight()
				and k < voxelmapBlob:getDepth()
				then
					-- TODO or ffi.copy per-row to speed things up
					o:emplace_back()[0] = voxelmapBlob:getVoxelPtr()[
						i + voxelmapBlob:getWidth() * (
							j + voxelmapBlob:getHeight() * k
						)
					]
				else
					o:emplace_back()[0] = Voxel()	-- default type ... of 0, right?
				end
			end
		end
	end

	self.app.blobs.voxelmap[self.voxelmapBlobIndex+1] = blobClassForName.voxelmap(o:dataToStr())
	-- TODO refresh anything?
end

return EditVoxelMap
