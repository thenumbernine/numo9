require 'ext.gc'	-- make sure luajit can __gc lua-tables
local ffi = require 'ffi'
local assert = require 'ext.assert'
local table = require 'ext.table'
local vector = require 'ffi.cpp.vector-lua'
local vec3i = require 'vec-ffi.vec3i'
local vec4us = require 'vec-ffi.vec4us'
local matrix_ffi = require 'matrix.ffi'
local gl = require 'gl'
local GLArrayBuffer = require 'gl.arraybuffer'
local GLVertexArray = require 'gl.vertexarray'
local GLAttribute = require 'gl.attribute'

local Blob = require 'numo9.blob.blob'

local numo9_rom = require 'numo9.rom'
local spriteSheetSize = numo9_rom.spriteSheetSize
local voxelmapSizeType = numo9_rom.voxelmapSizeType
local voxelMapEmptyValue = numo9_rom.voxelMapEmptyValue

-- also in numo9/video.lua
-- but it doesn't calc / return w, only x y z
local function vec3to3(m, x, y, z)
	x = tonumber(x)
	y = tonumber(y)
	z = tonumber(z)
	return
		m[0] * x + m[4] * y + m[ 8] * z + m[12],
		m[1] * x + m[5] * y + m[ 9] * z + m[13],
		m[2] * x + m[6] * y + m[10] * z + m[14]
end

-- rotZ, rotY, rotX are from Voxel type, so they are from 1-2 bits in size, each representing Euler-angles 90-degree rotation
local function rotateSideByOrientation(sideIndex, rotZ, rotY, rotX)
	-- use a table or something, or flip bits
	local sign = bit.band(1, sideIndex) == 1 and -1 or 1
	local axis = bit.rshift(sideIndex, 1)
	-- rot z is x->y, y->-x
	if axis ~= 2 then
		for i=0,rotZ-1 do
			axis = 1 - axis	-- 0,1
			if axis == 0 then sign = -sign end
		end
	end
	-- rot y is z->x, x->-z
	if axis ~= 1 then
		for i=0,rotY-1 do
			axis = 2 - axis	-- 0,2
			if axis == 2 then sign = -sign end
		end
	end
	-- rot x is y->z, z->-y
	if axis ~= 0 then
		for i=0,rotX-1 do
			axis = 3 - axis	-- 1,2
			if axis == 1 then sign = -sign end
		end
	end
	return bit.bor(
		sign < 0 and 1 or 0,
		bit.lshift(axis, 1))
end

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
local BlobVoxelMap = Blob:subclass()

BlobVoxelMap.filenamePrefix = 'voxelmap'
BlobVoxelMap.filenameSuffix = '.vox'

assert.eq(ffi.sizeof(voxelmapSizeType), ffi.sizeof'Voxel')
function BlobVoxelMap:init(data)
	self.vec = vector'Voxel'	-- use .intptr for the first x y z entries
	local minsize = ffi.sizeof'Voxel' * 3
	if not data or #data < minsize then
		self.vec:emplace_back()[0].intval = 1
		self.vec:emplace_back()[0].intval = 1
		self.vec:emplace_back()[0].intval = 1
		self.vec:emplace_back()[0].intval = voxelMapEmptyValue
	else
		self.vec:resize(math.ceil(#data / ffi.sizeof'Voxel'))
		ffi.copy(self.vec.v, data, #data)
	end

	-- validate that the header at least works
	assert.gt(self:getWidth(), 0)
	assert.gt(self:getHeight(), 0)
	assert.gt(self:getDepth(), 0)

	self.billboardXYZVoxels = vector'vec3i_t'	-- type 20
	self.billboardXYVoxels = vector'vec3i_t'	-- type 21

	self.vertexBufCPU = vector'Numo9Vertex'

	self.dirtyCPU = true
	-- can't do this yet, not until .ramptr is defined
	--self:rebuildMesh()
end

function BlobVoxelMap:getPtr()
	return ffi.cast('uint8_t*', self.vec.v)
end

function BlobVoxelMap:getSize()
	return self.vec:getNumBytes()
end

function BlobVoxelMap:getWidth()
	return self.vec.v[0].intval
end

function BlobVoxelMap:getHeight()
	return self.vec.v[1].intval
end

function BlobVoxelMap:getDepth()
	return self.vec.v[2].intval
end

function BlobVoxelMap:getVoxelDataBlobPtr()
	return self.vec.v + 3
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
select(2, require 'ext.timer'('BlobVoxelMap:rebuildMesh', function()
	self.dirtyCPU = false

	self.billboardXYZVoxels:resize(0)
	self.billboardXYVoxels:resize(0)

	self.vertexBufCPU:resize(0)

	-- ok here I shoot myself in the foot just a bit
	-- cuz now that I'm baking extra flags,
	-- that means I can no longer update the voxelmap spriteBit, spriteMask, transparentIndex, paletteIndex,
	-- not without rebuilding the whole mesh
	-- but even before it meant recalculating extra every time we draw so *shrug* I don't miss it
	-- maybe those should all be uniforms anyways?
	local spriteBit = 0
	local spriteMask = 0xFF
	local transparentIndex = -1
	local paletteIndex = 0

	-- also in drawTexTri3D:
	local drawFlags = bit.bor(
		-- bits 0/1 == 01b <=> use sprite pathway:
		1,
		-- if transparency is oob then flag the "don't use transparentIndex" bit:
		(transparentIndex < 0 or transparentIndex >= 256) and 4 or 0,
		-- store sprite bit shift in the next 3 bits:
		bit.lshift(spriteBit, 3),

		bit.lshift(spriteMask, 8)
	)

	local extra = vec4us(
		drawFlags,
		0,	-- dither ... can't use it with meshes anymore, sad.
		transparentIndex,
		paletteIndex)

	local width, height, depth= self:getWidth(), self:getHeight(), self:getDepth()
	-- which to build this off of?
	-- RAMPtr since thats what AppVideo:drawVoxelMap() uses
	-- but that means it wont be present upon init() ...
	local m = matrix_ffi({4,4}, 'double'):zeros()
	local voxels = assert(self:getVoxelDataRAMPtr(), 'BlobVoxelMap rebuildMesh .ramptr missing')
	local vptr = voxels
	local occludedCount = 0

	local nbhd = vec3i()
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
--DEBUG:assert.eq(numTriVtxs % 3, 0)
							local srcVtxs = mesh:getVertexPtr()	-- TODO blob vs ram location ...

							-- resize first then offest back in case we get a resize ...
							self.vertexBufCPU:reserve(#self.vertexBufCPU + numTriVtxs)

							for ti=0,#mesh.triList-1 do
								local ai,bi,ci = mesh.triList.v[ti]:unpack()

								-- see if this face is aligned to an AABB
								-- see if its neighbors face is occluding on that AABB
								-- if both are true then skip
								local occluded

								-- TODO
								-- transparency
								-- hmm
								-- I'd say "check every used texel for trnsparency and don't occulde if any are transparent"
								-- but nothing's to stop from shifting palettes later
								-- hmmmmmmm


-- occluding takes our build time from 84s to 10s
-- [[
								local sideIndex = mesh.sideForTriIndex[ti]
								if sideIndex then
									-- TODO TODO sides need to be influenced by orientation too ...
									sideIndex = rotateSideByOrientation(sideIndex, vptr.rotZ, vptr.rotY, vptr.rotX)

									-- offet into 'sideIndex'
									local sign = 1 - 2 * bit.band(1, sideIndex)
									local axis = bit.rshift(sideIndex, 1)

									nbhd:set(i,j,k)
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

-- 10s slowdown still present in here:
-- [[ 
								if occluded then
									occludedCount = occludedCount + 1
								else
									local va = srcVtxs + ai
									local vb = srcVtxs + bi
									local vc = srcVtxs + ci

									local normal = mesh.normalList.v[ti]

									local srcv = va
									local dstVtx = self.vertexBufCPU:emplace_back()
									dstVtx.vertex.x, dstVtx.vertex.y, dstVtx.vertex.z = vec3to3(m.ptr, srcv.x, srcv.y, srcv.z)
									dstVtx.texcoord.x = (tonumber(srcv.u + uofs) + .5) / tonumber(spriteSheetSize.x)
									dstVtx.texcoord.y = (tonumber(srcv.v + vofs) + .5) / tonumber(spriteSheetSize.y)
									dstVtx.normal = normal
									dstVtx.extra = extra
									dstVtx.box.x, dstVtx.box.y, dstVtx.box.z, dstVtx.box.w = 0, 0, 1, 1

									local srcv = vb
									local dstVtx = self.vertexBufCPU:emplace_back()
									dstVtx.vertex.x, dstVtx.vertex.y, dstVtx.vertex.z = vec3to3(m.ptr, srcv.x, srcv.y, srcv.z)
									dstVtx.texcoord.x = (tonumber(srcv.u + uofs) + .5) / tonumber(spriteSheetSize.x)
									dstVtx.texcoord.y = (tonumber(srcv.v + vofs) + .5) / tonumber(spriteSheetSize.y)
									dstVtx.normal = normal
									dstVtx.extra = extra
									dstVtx.box.x, dstVtx.box.y, dstVtx.box.z, dstVtx.box.w = 0, 0, 1, 1

									local srcv = vc
									local dstVtx = self.vertexBufCPU:emplace_back()
									dstVtx.vertex.x, dstVtx.vertex.y, dstVtx.vertex.z = vec3to3(m.ptr, srcv.x, srcv.y, srcv.z)
									dstVtx.texcoord.x = (tonumber(srcv.u + uofs) + .5) / tonumber(spriteSheetSize.x)
									dstVtx.texcoord.y = (tonumber(srcv.v + vofs) + .5) / tonumber(spriteSheetSize.y)
									dstVtx.normal = normal
									dstVtx.extra = extra
									dstVtx.box.x, dstVtx.box.y, dstVtx.box.z, dstVtx.box.w = 0, 0, 1, 1
								end
--]]
							end
						end
					end
				end
				vptr = vptr + 1
			end
		end
	end
end))
--DEBUG:print('created', #self.vertexes/3, 'tris')
--DEBUG:print('occluded', occludedCount, 'tris')
end

-- needs triBuf_prepAddTri to be called beforehand
function BlobVoxelMap:drawMesh(app)
	if #self.vertexBufCPU == 0 then return end

--[[ hmm why aren't things working ....
	app.lastTilemapTex:bind(2)
	app.lastSheetTex:bind(1)
	app.lastPaletteTex:bind(0)

	app:triBuf_prepAddTri(app.lastPaletteTex, app.lastSheetTex, app.lastTilemapTex)
--]]

	local sceneObj = app.triBuf_sceneObj
	local program = sceneObj.program
	program:use()

	if not self.vertexBufGPU then
		self.vertexBufGPU = GLArrayBuffer{
			size = ffi.sizeof'Numo9Vertex' * self.vertexBufCPU.capacity,
			data = self.vertexBufCPU.v,
			usage = gl.GL_DYNAMIC_DRAW,
		}
	else
		self.vertexBufGPU:bind()
	end

	if self.vertexBufCPU.capacity ~= self.vertexBufCPULastCapacity then
		self.vertexBufGPU:setData{
			data = self.vertexBufCPU.v,
			count = self.vertexBufCPU.capacity,
			size = ffi.sizeof'Numo9Vertex' * self.vertexBufCPU.capacity,
		}
	else
--DEBUG:assert.eq(self.vertexBufGPU.data, self.vertexBufCPU.v)
		self.vertexBufGPU:updateData(0, self.vertexBufCPU:getNumBytes())
	end

	if not self.vao then
		self.vao = GLVertexArray{
			program = program,
			attrs = table.map(sceneObj.attrs, function(attr)
				--[[
				local newattr = GLAttribute(attr)
				newattr.buffer = self.vertexBufGPU
				return newattr
				--]]
				-- [[
				local newattr = setmetatable({}, GLAttribute)
				for k,v in pairs(attr) do newattr[k] = v end
				newattr.buffer = self.vertexBufGPU
				return newattr
				--]]
			end),
		}
	end
	--sceneObj:enableAndSetAttrs()
	self.vao:bind()

	sceneObj.geometry:draw()

	--sceneObj:disableAttrs()
	self.vao:unbind()

	-- reset the vectors and store the last capacity
	self.vertexBufCPULastCapacity = self.vertexBufCPU.capacity
end

function BlobVoxelMap:delete()
	if self.vertexBufGPU then
		self.vertexBufGPU:delete()
		self.vertexBufGPU = nil
	end
	if self.vao then
		self.vao:delete()
		self.vao = nil
	end
end

BlobVoxelMap.__gc = BlobVoxelMap.delete

return BlobVoxelMap
