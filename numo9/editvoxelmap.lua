local ffi = require 'ffi'
local assert = require 'ext.assert'
local gl = require 'gl'
local vector = require 'ffi.cpp.vector-lua'
local vec2i = require 'vec-ffi.vec2i'
local vec3d = require 'vec-ffi.vec3d'
local quatd = require 'vec-ffi.quatd'

local Orbit = require 'numo9.ui.orbit'

local numo9_rom = require 'numo9.rom'
local mvMatType = numo9_rom.mvMatType
local clipMax = numo9_rom.clipMax
local voxelmapSizeType = numo9_rom.voxelmapSizeType
local voxelMapEmptyValue = numo9_rom.voxelMapEmptyValue

local numo9_blobs = require 'numo9.blobs'
local blobClassForName = numo9_blobs.blobClassForName

local numo9_video = require 'numo9.video'
local vec3to4 = numo9_video.vec3to4 


local EditVoxelMap = require 'numo9.ui':subclass()

function EditVoxelMap:init(args)
	EditVoxelMap.super.init(self, args)
	self:onCartLoad()
end

function EditVoxelMap:onCartLoad()
	self.voxelmapBlobIndex = 0
	self.sheetBlobIndex = 0
	self.paletteBlobIndex = 0

	-- TODO replace this with a tile-select and a 8/16 toggle
	self.tileXOffset = 0
	self.tileYOffset = 0

	self.orientation = 0

	self.orbit = Orbit(self.app)
	-- TODO init to max size of whatever blob is first loaded?
	-- and refresh on blob change?
	self.orbit.pos.z = 5
end

local mvMatPush = ffi.new(mvMatType..'[16]')
function EditVoxelMap:update()
	local app = self.app

	EditVoxelMap.super.update(self)

	app:setClipRect(0, 8, 256, 256)

	self.orbit:update()

	local voxelmapBlob = app.blobs.voxelmap[self.voxelmapBlobIndex+1]
	local size = voxelmapBlob
		and vec3d(
			voxelmapBlob:getWidth(),
			voxelmapBlob:getHeight(),
			voxelmapBlob:getDepth())
	if voxelmapBlob then
		-- flush before enable depth test so the flush doesn't use depth test...
		app.triBuf:flush()
		gl.glEnable(gl.GL_DEPTH_TEST)
		gl.glClear(gl.GL_DEPTH_BUFFER_BIT)

		ffi.copy(mvMatPush, app.ram.mvMat, ffi.sizeof(mvMatPush))
		self.orbit:applyMatrix()	-- this scales down by 32768 for the sake f 3d model's sint16 type

		app:mattrans(-32768*.5*size.x, -32768*.5*size.y, -32768*.5*size.z)

		local function corner(i)
			return bit.band(i, 1) ~= 0 and size.x * 32768 or 0,
				bit.band(i, 2) ~= 0 and size.y * 32768 or 0,
				bit.band(i, 4) ~= 0 and size.z * 32768 or 0
		end

		for i=0,7 do
			for b=0,2 do
				local j = bit.bxor(i, bit.lshift(1, b))
				if j > i then
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

		-- set the current selected palette via RAM registry to self.paletteBlobIndex
		local pushPalBlobIndex = app.ram.paletteBlobIndex
		app.ram.paletteBlobIndex = self.paletteBlobIndex
		app:drawVoxelMap(
			self.voxelmapBlobIndex,
			self.sheetBlobIndex
		)
		app.ram.paletteBlobIndex = pushPalBlobIndex

		-- TODO
		-- mouse line, intersect only with far bounding planes of the voxelmap
		-- or intersect with march through the voxelmap
		-- how to get mouse line?
		-- transform mouse coords by view matrix
		local mouseX, mouseY = app.ram.mousePos:unpack()
		local mousePos = self.orbit.pos + size * .5
		-- assume fov is 90°
		local mouseDir = 
			- self.orbit.angle:zAxis()
			+ self.orbit.angle:xAxis() * (mouseX - 128) / 128
			+ self.orbit.angle:yAxis() * (128 - mouseY) / 128
		-- or alternatively use the inverse of the modelview matrix... but meh ...
		if not (
			mousePos.x >= 0 and mousePos.x < size.x
			and mousePos.y >= 0 and mousePos.y < size.y
			and mousePos.z >= 0 and mousePos.z < size.z
		) then
			-- now line intersect with the camera-facing planes of the bbox

			local function planePointDist(planePt, planeN, linePt, lineDir)
				return (planePt - linePt):dot(planeN) / lineDir:dot(planeN)
			end

			local d = math.huge
			local dxL = planePointDist(vec3d(0,0,0), vec3d(-1,0,0), mousePos, mouseDir)
			if dxL > 0 then d = math.min(d, dxL) end
			local dyL = planePointDist(vec3d(0,0,0), vec3d(0,-1,0), mousePos, mouseDir)
			if dyL > 0 then d = math.min(d, dyL) end
			local dzL = planePointDist(vec3d(0,0,0), vec3d(0,0,-1), mousePos, mouseDir)
			if dzL > 0 then d = math.min(d, dzL) end
			local dxR = planePointDist(vec3d(size.x,0,0), vec3d(1,0,0), mousePos, mouseDir)
			if dxR > 0 then d = math.min(d, dxR) end
			local dyR = planePointDist(vec3d(0,size.y,0), vec3d(0,1,0), mousePos, mouseDir)
			if dyR > 0 then d = math.min(d, dyR) end
			local dzR = planePointDist(vec3d(0,0,size.z), vec3d(0,0,1), mousePos, mouseDir)
			if dzR > 0 then d = math.min(d, dzR) end
--print('dists', d, dxL, dyL, dzL, dxR, dyR, dzR)			
			mousePos = mousePos + mouseDir * (d + 1e-5)
			-- this could still be OOB if the user isn't mouse'd over the box ...
		end
		if (
			mousePos.x >= 0 and mousePos.x < size.x
			and mousePos.y >= 0 and mousePos.y < size.y
			and mousePos.z >= 0 and mousePos.z < size.z
		) then
			
			-- then march through the voxelmap
			-- stop at the last empty voxel
			print'mouseover'
		else
			print'not mouseover'
		end


		ffi.copy(app.ram.mvMat, mvMatPush, ffi.sizeof(mvMatPush))
		-- flush before disable depth test so the flush will use depth test...
		app.triBuf:flush()
		gl.glDisable(gl.GL_DEPTH_TEST)

		local x, y = 0, 8
		app:drawMenuText('w='..size.x, x, y)
		y = y + 8
		app:drawMenuText('h='..size.y, x, y)
		y = y + 8
		app:drawMenuText('d='..size.z, x, y)
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
	end, 'uofs='..self.tileXOffset)
	x = x + 12

	-- [[ TODO replace this with edittilemap's sheet tile selector
	self:guiSpinner(x, y, function(dx)
		self.tileYOffset = bit.band(31, self.tileYOffset + dx)
	end, 'vofs='..self.tileYOffset)
	x = x + 12

	self:guiSpinner(x, y, function(dx)
		self.orientation = bit.band(31, self.orientation + dx)
	end, 'orient='..self.orientation)
	x = x + 12
	--]]

	if voxelmapBlob then
		self:guiSpinner(x, y, function(dx)
			self:resizeVoxelmap(
				math.max(1, size.x + dx),
				size.y,
				size.z
			)
		end, 'width='..size.x)
		x = x + 12

		self:guiSpinner(x, y, function(dx)
			self:resizeVoxelmap(
				size.x,
				math.max(1, size.y + dx),
				size.z
			)
		end, 'height='..size.y)
		x = x + 12

		self:guiSpinner(x, y, function(dx)
			self:resizeVoxelmap(
				size.x,
				size.y,
				math.max(1, size.z + dx)
			)
		end, 'depth='..size.z)
		x = x + 12
	end

	self:drawTooltip()
end

function EditVoxelMap:resizeVoxelmap(nx, ny, nz)
	local app = self.app
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
					].intval
				else
					o:emplace_back()[0] = voxelMapEmptyValue		-- default type ... of 0, right?
				end
			end
		end
	end

	self.app.blobs.voxelmap[self.voxelmapBlobIndex+1] = blobClassForName.voxelmap(o:dataToStr())
	-- TODO refresh anything?
end

return EditVoxelMap
