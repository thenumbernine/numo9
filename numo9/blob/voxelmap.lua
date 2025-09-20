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
	return
		(m[0] * x + m[4] * y + m[ 8] * z + m[12]),
		(m[1] * x + m[5] * y + m[ 9] * z + m[13]),
		(m[2] * x + m[6] * y + m[10] * z + m[14])
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
	self.triVtxs = vector'Vertex_16_16'	-- x y z u v: int16_t
	self.meshNeedsRebuild = true
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
	if not self.meshNeedsRebuild then return end
	self.meshNeedsRebuild = false

	self.billboardXYZVoxels:resize(0)
	self.billboardXYVoxels:resize(0)
	self.triVtxs:resize(0)

	local width, height, depth= self:getWidth(), self:getHeight(), self:getDepth()
	-- which to build this off of?
	-- RAMPtr since thats what AppVideo:drawVoxelMap() uses
	-- but that means it wont be present upon init() ...
	local matrix_ffi = require 'matrix.ffi'
	local m = matrix_ffi({4,4}, 'double'):zeros()
	local vptr = assert(self:getVoxelDataRAMPtr(), 'BlobVoxelMap rebuildMesh .ramptr missing')
	for k=0,depth-1 do
		for j=0,height-1 do
			for i=0,width-1 do
				local vox = vptr[0]
				if vox.intval ~= voxelMapEmptyValue then
					m:setTranslate(i+.5, j+.5, k+.5)
					m:applyScale(1/32768, 1/32768, 1/32768)

					if vox.orientation == 20 then
						self.billboardXYZVoxels:emplace_back()[0]:set(i,j,k)
					elseif vox.orientation == 21 then
						self.billboardXYVoxels:emplace_back()[0]:set(i,j,k)
					elseif vox.orientation == 22 then
						-- TODO
					elseif vox.orientation == 23 then
						-- TODO
					else
						local c, s

						c, s = 1, 0
						for i=0,vox.rotZ-1 do c, s = -s, c end
						m:applyRotateCosSinUnit(c, s, 0, 0, 1)

						c, s = 1, 0
						for i=0,vox.rotY-1 do c, s = -s, c end
						m:applyRotateCosSinUnit(c, s, 0, 1, 0)

						c, s = 1, 0
						for i=0,vox.rotX-1 do c, s = -s, c end
						m:applyRotateCosSinUnit(c, s, 1, 0, 0)

						local mesh3DIndex = vox.mesh3DIndex
						local uofs = bit.lshift(vox.tileXOffset, 3)
						local vofs = bit.lshift(vox.tileYOffset, 3)

						local mesh = app.blobs.mesh3d[mesh3DIndex+1]
						if mesh then

							-- emplace_back() and resize() one by one is slow...
							local numVtxs = mesh:getNumVertexes()	-- maek sure its valid / asesrt-error if its not
							local numIndexes = mesh:getNumIndexes()
							local numTriVtxs = numIndexes == 0 and numVtxs or numIndexes
assert.eq(numTriVtxs % 3, 0)
							local srcVtxs = mesh:getVertexPtr()	-- TODO blob vs ram location ...

							-- resize first then offest back in case we get a resize ...
							self.triVtxs:resize(#self.triVtxs + numTriVtxs)
							local dstVtx = self.triVtxs:iend() - numTriVtxs

							for ai,bi,ci in mesh:triIter() do
								local a = srcVtxs + ai
								local b = srcVtxs + bi
								local c = srcVtxs + ci

								dstVtx.x, dstVtx.y, dstVtx.z = vec3to3(m.ptr, a.x, a.y, a.z)
								dstVtx.u, dstVtx.v = a.u + uofs, a.v + vofs
								dstVtx = dstVtx + 1

								dstVtx.x, dstVtx.y, dstVtx.z = vec3to3(m.ptr, b.x, b.y, b.z)
								dstVtx.u, dstVtx.v = b.u + uofs, b.v + vofs
								dstVtx = dstVtx + 1

								dstVtx.x, dstVtx.y, dstVtx.z = vec3to3(m.ptr, c.x, c.y, c.z)
								dstVtx.u, dstVtx.v = c.u + uofs, c.v + vofs
								dstVtx = dstVtx + 1
							end

-- how to pointer-compare without using its contents-compare ...
--DEBUG:assert.eq(ffi.cast('uint8_t*', dstVtx), ffi.cast('uint8_t*', self.triVtxs:iend()))
						end
					end
				end
				vptr = vptr + 1
			end
		end
	end
end

return BlobVoxelMap
