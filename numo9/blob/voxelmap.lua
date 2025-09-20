local ffi = require 'ffi'
local assert = require 'ext.assert'

local numo9_rom = require 'numo9.rom'
local voxelmapSizeType = numo9_rom.voxelmapSizeType
local voxelMapEmptyValue = numo9_rom.voxelMapEmptyValue

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

return BlobVoxelMap
