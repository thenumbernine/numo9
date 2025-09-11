local ffi = require 'ffi'
local assert = require 'ext.assert'
local vector = require 'ffi.cpp.vector-lua'
local vec3d = require 'vec-ffi.vec3d'
local box3d = require 'vec-ffi.box3d'

local Orbit = require 'numo9.ui.orbit'

local numo9_rom = require 'numo9.rom'
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

	self.wireframe = false

	self.voxCurSel = ffi.new'Voxel'
	self.voxCurSel.intval = 0

	self.orbit = Orbit(self.app)
	-- TODO init to max size of whatever blob is first loaded?
	-- and refresh on blob change?
	self.orbit.pos.z = 5
end

local function planeLineIntersectParam(planePt, planeN, linePt, lineDir)
	return (planePt - linePt):dot(planeN) / lineDir:dot(planeN)
end

local function axisAlignedPlaneLineIntersectParam(axis, planePtOnAxis, planeNormalOnAxis, linePt, lineDir)
	return ((planePtOnAxis - linePt.s[axis]) * planeNormalOnAxis) / (lineDir.s[axis] * planeNormalOnAxis)
end

local function lineBoxDist(box, linePt, lineDir, inside)
	inside = inside or false
	-- line intersect with the outer walls of a cube
	local d = math.huge
	local axis
	for i=0,2 do
		local j = (i+1)%3
		local k = (j+1)%3
		local dxi = lineDir.s[i] > 0 ~= inside
			and axisAlignedPlaneLineIntersectParam(i, box.min.s[i], -1, linePt, lineDir)
			or axisAlignedPlaneLineIntersectParam(i, box.max.s[i], 1, linePt, lineDir)
		if dxi > 0 then
			local ptj = linePt.s[j] + lineDir.s[j] * dxi
			local ptk = linePt.s[k] + lineDir.s[k] * dxi
			if box.min.s[j] <= ptj and ptj <= box.max.s[j]
			and box.min.s[k] <= ptk and ptk <= box.max.s[k]
			then
				axis = i
				d = math.min(d, dxi)
			end
		end
	end
	return d, axis
end

-- assumes we're already scaled down by 32768
function EditVoxelMap:drawBox(box, color)
	local app = self.app
	for i=0,7 do
		for b=0,2 do
			local j = bit.bxor(i, bit.lshift(1, b))
			if j > i then
				local ax, ay, az = box:corner(i):unpack()
				local bx, by, bz = box:corner(j):unpack()
				app:drawSolidLine3D(
					ax, ay, az,
					bx, by, bz,
					color,
					nil,
					app.paletteMenuTex)
			end
		end
	end
end

function EditVoxelMap:update()
	local app = self.app

	EditVoxelMap.super.update(self)

	local voxelmapBlob = app.blobs.voxelmap[self.voxelmapBlobIndex+1]
	local mapsize = voxelmapBlob
		and vec3d(
			voxelmapBlob:getWidth(),
			voxelmapBlob:getHeight(),
			voxelmapBlob:getDepth())
	local mapbox = box3d(vec3d(0,0,0), mapsize)
	local mapboxIE = box3d(vec3d(0,0,0), mapsize-1)	-- mapbox, [incl,excl), for integer testing

	if voxelmapBlob then
		self.orbit:beginDraw()
		app:mattrans(-.5*mapsize.x, -.5*mapsize.y, -.5*mapsize.z)

		self:drawBox(mapbox, 0x31)

		-- set the current selected palette via RAM registry to self.paletteBlobIndex
		local pushPalBlobIndex = app.ram.paletteBlobIndex
		app.ram.paletteBlobIndex = self.paletteBlobIndex
		app:drawVoxelMap(
			self.voxelmapBlobIndex,
			self.sheetBlobIndex
		)
		app.ram.paletteBlobIndex = pushPalBlobIndex

		if self.wireframe then
			local v = voxelmapBlob:getVoxelPtr()
			for k=0,mapsize.z-1 do
				for j=0,mapsize.y-1 do
					for i=0,mapsize.x-1 do
						if v.intval ~= voxelMapEmptyValue then
							self:drawBox(box3d(vec3d(i,j,k),vec3d(i,j,k)+1), 0xa)
						end
						v = v + 1
					end
				end
			end
		end

		local mouseX, mouseY = app.ram.mousePos:unpack()
		if mouseY >= 8 then
			-- mouse line, intersect only with far bounding planes of the voxelmap
			-- or intersect with march through the voxelmap
			-- how to get mouse line?
			-- transform mouse coords by view matrix
			local mousePos = self.orbit.pos + mapsize * .5
			-- assume fov is 90°
			local mouseDir =
				- self.orbit.angle:zAxis()
				+ self.orbit.angle:xAxis() * (mouseX - 128) / 128
				- self.orbit.angle:yAxis() * (mouseY - 128) / 128
			-- or alternatively use the inverse of the modelview matrix... but meh ...
			if not mapbox:contains(mousePos) then
				-- now line intersect with the camera-facing planes of the bbox

				local d = lineBoxDist(
					mapbox,
					mousePos,
					mouseDir)

	--print('dists', d, dx, dy, dz)
				mousePos = mousePos + mouseDir * (d + 1e-5)
				-- this could still be OOB if the user isn't mouse'd over the box ...
			end
			if mapbox:contains(mousePos) then
				local pti, npti = mousePos:map(math.floor)
				-- then march through the voxelmap
				while true do
					-- intersect with cube [pti, pti+1]
					local d, axis = lineBoxDist(
						box3d(pti, pti+1),
						mousePos,
						mouseDir,
						true)	-- true = inside the cube intersecting with outside

					mousePos = mousePos + mouseDir * (d + 1e-5)
					npti = mousePos:map(math.floor)

					-- stop at the last empty voxel
					-- if we're oob then we're done with 'pti' as our final point inside the box
					if not mapboxIE:contains(npti) then
						npti = pti
						break
					end
					local v = voxelmapBlob:get(npti.x, npti.y, npti.z)
					if v.intval ~= voxelMapEmptyValue then break end

					pti = npti
				end

				-- show selection
				self:drawBox(box3d(npti, npti+1), 0x1b)

				if app:keyp'mouse_left' then
					local shift = app:key'lshift' or app:key'rshift'
					if shift then
						if mapboxIE:contains(npti) then
							local v = voxelmapBlob:get(npti:unpack())
							if v.intval ~= voxelMapEmptyType then
								self.voxCurSel.mesh3DIndex = v.mesh3DIndex
								self.voxCurSel.tileXOffset = v.tileXOffset
								self.voxCurSel.tileYOffset = v.tileYOffset
								self.voxCurSel.orientation = v.orientation
							end
						end
					else
						local v = voxelmapBlob:get(pti:unpack())
						v.mesh3DIndex = self.voxCurSel.mesh3DIndex
						v.tileXOffset = self.voxCurSel.tileXOffset
						v.tileYOffset = self.voxCurSel.tileYOffset
						v.orientation = self.voxCurSel.orientation
					end
				end

				if app:keyp'mouse_right'
				and mapboxIE:contains(npti)
				then
					local v = voxelmapBlob:get(npti:unpack())
					v.intval = voxelMapEmptyValue
				end


				if not self.tooltip then
					self:setTooltip(npti.x..','..npti.y..','..npti.z, mouseX-8, mouseY-8, 0xfc, 0)
				end
			end
		end

		self.orbit:endDraw()

		local x, y = 0, 8
		app:drawMenuText('w='..mapsize.x, x, y)
		y = y + 8
		app:drawMenuText('h='..mapsize.y, x, y)
		y = y + 8
		app:drawMenuText('d='..mapsize.z, x, y)
		y = y + 8
	end

	local x, y = 50, 0
	self:guiBlobSelect(x, y, 'voxelmap', self, 'voxelmapBlobIndex')
	x = x + 12
	self:guiBlobSelect(x, y, 'sheet', self, 'sheetBlobIndex')
	x = x + 12
	self:guiBlobSelect(x, y, 'palette', self, 'paletteBlobIndex')
	x = x + 12

	if self:guiButton('W', x, y, self.wireframe, 'wireframe') then
		self.wireframe = not self.wireframe
	end
	x = x + 8
	if self:guiButton(self.orbit.ortho and 'O' or 'P', x, y, false, self.orbit.ortho and 'orbit.ortho' or 'projection') then
		self.orbit.ortho = not self.orbit.ortho
	end
	x = x + 8

	self:guiSpinner(x, y, function(dx)
		self.voxCurSel.mesh3DIndex = math.max(0, self.voxCurSel.mesh3DIndex + dx)
	end, 'mesh='..self.voxCurSel.mesh3DIndex)
	x = x + 12

	self:guiSpinner(x, y, function(dx)
		self.voxCurSel.tileXOffset = bit.band(31, self.voxCurSel.tileXOffset + dx)
	end, 'uofs='..self.voxCurSel.tileXOffset)
	x = x + 12

	-- [[ TODO replace this with edittilemap's sheet tile selector
	self:guiSpinner(x, y, function(dx)
		self.voxCurSel.tileYOffset = bit.band(31, self.voxCurSel.tileYOffset + dx)
	end, 'vofs='..self.voxCurSel.tileYOffset)
	x = x + 12

	self:guiSpinner(x, y, function(dx)
		self.voxCurSel.orientation = bit.band(31, self.voxCurSel.orientation + dx)
	end, 'orient='..self.voxCurSel.orientation)
	x = x + 12
	--]]

	if voxelmapBlob then
		self:guiSpinner(x, y, function(dx)
			self:resizeVoxelmap(
				math.max(1, mapsize.x + dx),
				mapsize.y,
				mapsize.z
			)
		end, 'width='..mapsize.x)
		x = x + 12

		self:guiSpinner(x, y, function(dx)
			self:resizeVoxelmap(
				mapsize.x,
				math.max(1, mapsize.y + dx),
				mapsize.z
			)
		end, 'height='..mapsize.y)
		x = x + 12

		self:guiSpinner(x, y, function(dx)
			self:resizeVoxelmap(
				mapsize.x,
				mapsize.y,
				math.max(1, mapsize.z + dx)
			)
		end, 'depth='..mapsize.z)
		x = x + 12

		self:guiTextField(
			188, 0, 20,
			('%08X'):format(self.voxCurSel.intval), nil,
			function(result)
				result = tonumber(result, 16)
				if result then
					self.voxCurSel.intval = result
				end
			end
		)
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
