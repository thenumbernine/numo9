local ffi = require 'ffi'
local assert = require 'ext.assert'
local vector = require 'ffi.cpp.vector-lua'
local vec3i = require 'vec-ffi.vec3i'

local numo9_rom = require 'numo9.rom'
local voxelmapSizeType = numo9_rom.voxelmapSizeType
local voxelMapEmptyValue = numo9_rom.voxelMapEmptyValue

-- also in numo9/video.lua
-- but this doesn't have mvMatInvScale
-- and it doesn't return w, only x y z
local function vec3to3(m, x, y, z)
	x = tonumber(x)
	y = tonumber(y)
	z = tonumber(z)
	return
		(m[0] * x + m[4] * y + m[ 8] * z + m[12]),
		(m[1] * x + m[5] * y + m[ 9] * z + m[13]),
		(m[2] * x + m[6] * y + m[10] * z + m[14])
end

-- rotZ, rotY, rotX are from Voxel type, so they are from 1-2 bits in size, each representing Euler-angles 90-degree rotation
local function rotateSideByOrientation(sideIndex, rotZ, rotY, rotX)
	-- use a table or something, or flip bits
	local sign = bit.band(1, sideIndex) == 1 and -1 or 1
	local axis = bit.rshift(sideIndex, 1)
	-- rot z is x->y, y->-x
	for i=0,rotZ-1 do
		if axis ~= 2 then
			axis = 1 - axis	-- 0,1
			if axis == 0 then sign = -sign end
		end
	end
	-- rot y is z->x, x->-z
	for i=0,rotY-1 do
		if axis ~= 1 then
			axis = 2 - axis	-- 0,2
			if axis == 2 then sign = -sign end
		end
	end
	-- rot x is y->z, z->-y
	for i=0,rotX-1 do
		if axis ~= 0 then
			axis = 3 - axis	-- 1,2
			if axis == 1 then sign = -sign end
		end
	end
	return bit.bor(
		sign < 0 and 1 or 0,
		bit.lshift(axis, 1))
end

local BlobDataAbs = require 'numo9.blob.dataabs'

--[[
format:
uint32_t width, height, depth;
typedef struct {
	uint32_t modelIndex : 17;
	uint32_t tileXOffset: 5;
	uint32_t tileYOffset: 5;
	uint32_t orientation : 5;	// 2: z-axis yaw, 2: x-axis roll, 1:y-axis pitch
} VoxelBlock;
VoxelBlock data[width*height*depth];
--]]
local BlobVoxelMap = BlobDataAbs:subclass()

BlobVoxelMap.filenamePrefix = 'voxelmap'
BlobVoxelMap.filenameSuffix = '.vox'

function BlobVoxelMap:init(data)
	self.data = data
	if not self.data then
		-- prefill with a 1x1x1
		self.data = ('\0'):rep(3 * ffi.sizeof(voxelmapSizeType) + ffi.sizeof'Voxel')
		local p = ffi.cast(voxelmapSizeType..'*', self.data)
		p[0] = 1
		p[1] = 1
		p[2] = 1
		local v = ffi.cast('Voxel*', p+3)
		v[0].intval = voxelMapEmptyValue
	end

	-- validate that the header at least works
	assert.gt(self:getWidth(), 0)
	assert.gt(self:getHeight(), 0)
	assert.gt(self:getDepth(), 0)

	self.billboardXYZVoxels = vector'vec3i_t'	-- type 20
	self.billboardXYVoxels = vector'vec3i_t'	-- type 21
	self.triVtxs = vector'VertexFloat'
	self.dirtyCPU = true
	-- can't do this yet, not until .ramptr is defined
	--self:rebuildMesh()
end

function BlobVoxelMap:getWidth()
	return ffi.cast(voxelmapSizeType..'*', self:getPtr())[0]
end

function BlobVoxelMap:getHeight()
	return ffi.cast(voxelmapSizeType..'*', self:getPtr())[1]
end

function BlobVoxelMap:getDepth()
	return ffi.cast(voxelmapSizeType..'*', self:getPtr())[2]
end

function BlobVoxelMap:getVoxelDataBlobPtr()
	return ffi.cast('Voxel*', self:getPtr() + ffi.sizeof(voxelmapSizeType) * 3)
end

function BlobVoxelMap:getVoxelDataRAMPtr()
	return ffi.cast('Voxel*', self.ramptr + ffi.sizeof(voxelmapSizeType) * 3)
end

function BlobVoxelMap:getVoxelDataAddr()
	return self.addr + ffi.sizeof(voxelmapSizeType) * 3
end

function BlobVoxelMap:getVoxelBlobPtr(x,y,z)
	x = math.floor(x)
	y = math.floor(y)
	z = math.floor(z)
	if x < 0 or x >= self:getWidth()
	or y < 0 or y >= self:getHeight()
	or z < 0 or z >= self:getDepth()
	then return end
	return self:getVoxelDataBlobPtr() + x + self:getWidth() * (y + self:getHeight() * z)
end

function BlobVoxelMap:getVoxelAddr(x,y,z)
	x = math.floor(x)
	y = math.floor(y)
	z = math.floor(z)
	if x < 0 or x >= self:getWidth()
	or y < 0 or y >= self:getHeight()
	or z < 0 or z >= self:getDepth()
	then return end
	return self:getVoxelDataAddr() + ffi.sizeof'Voxel' * (x + self:getWidth() * (y + self:getHeight() * z))
end

--[[
app = used to search list of mesh3d blobs
--]]
function BlobVoxelMap:rebuildMesh(app)
	if not self.dirtyCPU then return end
	self.dirtyCPU = false

	self.billboardXYZVoxels:resize(0)
	self.billboardXYVoxels:resize(0)
	self.triVtxs:resize(0)

	local width, height, depth= self:getWidth(), self:getHeight(), self:getDepth()
	-- which to build this off of?
	-- RAMPtr since thats what AppVideo:drawVoxelMap() uses
	-- but that means it wont be present upon init() ...
	local matrix_ffi = require 'matrix.ffi'
	local m = matrix_ffi({4,4}, 'double'):zeros()
	local voxels = assert(self:getVoxelDataRAMPtr(), 'BlobVoxelMap rebuildMesh .ramptr missing')
	local vptr = voxels
	local occludedCount = 0
	for k=0,depth-1 do
		for j=0,height-1 do
			for i=0,width-1 do
				if vptr.intval ~= voxelMapEmptyValue then
					m:setTranslate(i+.5, j+.5, k+.5)
					m:applyScale(1/32768, 1/32768, 1/32768)

					if vptr.orientation == 20 then
						self.billboardXYZVoxels:emplace_back()[0]:set(i,j,k)
					elseif vptr.orientation == 21 then
						self.billboardXYVoxels:emplace_back()[0]:set(i,j,k)
					elseif vptr.orientation == 22 then
						-- TODO
					elseif vptr.orientation == 23 then
						-- TODO
					else
						local c, s

						c, s = 1, 0
						for i=0,vptr.rotZ-1 do c, s = -s, c end
						m:applyRotateCosSinUnit(c, s, 0, 0, 1)

						c, s = 1, 0
						for i=0,vptr.rotY-1 do c, s = -s, c end
						m:applyRotateCosSinUnit(c, s, 0, 1, 0)

						c, s = 1, 0
						for i=0,vptr.rotX-1 do c, s = -s, c end
						m:applyRotateCosSinUnit(c, s, 1, 0, 0)

						local uofs = bit.lshift(vptr.tileXOffset, 3)
						local vofs = bit.lshift(vptr.tileYOffset, 3)

						local mesh = app.blobs.mesh3d[vptr.mesh3DIndex+1]
						if mesh then

							-- emplace_back() and resize() one by one is slow...
							local numVtxs = mesh:getNumVertexes()	-- maek sure its valid / asesrt-error if its not
							local numIndexes = mesh:getNumIndexes()
							local numTriVtxs = numIndexes == 0 and numVtxs or numIndexes
assert.eq(numTriVtxs % 3, 0)
							local srcVtxs = mesh:getVertexPtr()	-- TODO blob vs ram location ...

							-- resize first then offest back in case we get a resize ...
							self.triVtxs:reserve(#self.triVtxs + numTriVtxs)

							for ai,bi,ci,ti in mesh:triIter() do

								-- see if this face is aligned to an AABB
								-- see if its neighbors face is occluding on that AABB
								-- if both are true then skip
								local occluded
-- [[
								local sideIndex = mesh.sideForTriIndex[ti]
								if sideIndex then
									-- TODO TODO sides need to be influenced by orientation too ...
									sideIndex = rotateSideByOrientation(sideIndex, vptr.rotZ, vptr.rotY, vptr.rotX)

									-- offet into 'sideIndex'
									local sign = 1 - 2 * bit.band(1, sideIndex)
									local axis = bit.rshift(sideIndex, 1)

									local nbhd = vec3i(i,j,k)
									nbhd.s[axis] = nbhd.s[axis] + sign
									if nbhd.x >= 0 and nbhd.x < width
									and nbhd.y >= 0 and nbhd.y < height
									and nbhd.z >= 0 and nbhd.z < depth
									then

										-- if it occludes the opposite side then skip this tri
										local nbhdVox = voxels[nbhd.x + width * (nbhd.y + height * nbhd.z)]
										local nbhdmesh = app.blobs.mesh3d[nbhdVox.mesh3DIndex+1]
										if nbhdmesh then
											local oppositeSideIndex = bit.bxor(1, sideIndex)
											oppositeSideIndex = rotateSideByOrientation(oppositeSideIndex, nbhdVox.rotZ, nbhdVox.rotY, nbhdVox.rotX)
											occluded = nbhdmesh.sidesOccluded[oppositeSideIndex]
										end
									end
								end
--]]

								if occluded then
									occludedCount = occludedCount + 1
								else
									local srcv = srcVtxs + ai
									local dstVtx = self.triVtxs:emplace_back()
									dstVtx.x, dstVtx.y, dstVtx.z = vec3to3(m.ptr, srcv.x, srcv.y, srcv.z)
									dstVtx.u, dstVtx.v = srcv.u + uofs, srcv.v + vofs
									dstVtx = dstVtx + 1

									local srcv = srcVtxs + bi
									local dstVtx = self.triVtxs:emplace_back()
									dstVtx.x, dstVtx.y, dstVtx.z = vec3to3(m.ptr, srcv.x, srcv.y, srcv.z)
									dstVtx.u, dstVtx.v = srcv.u + uofs, srcv.v + vofs
									dstVtx = dstVtx + 1

									local srcv = srcVtxs + ci
									local dstVtx = self.triVtxs:emplace_back()
									dstVtx.x, dstVtx.y, dstVtx.z = vec3to3(m.ptr, srcv.x, srcv.y, srcv.z)
									dstVtx.u, dstVtx.v = srcv.u + uofs, srcv.v + vofs
									dstVtx = dstVtx + 1
								end
							end
						end
					end
				end
				vptr = vptr + 1
			end
		end
	end

	print('created', #self.triVtxs/3, 'tris')
	print('occluded', occludedCount, 'tris')
end

return BlobVoxelMap
