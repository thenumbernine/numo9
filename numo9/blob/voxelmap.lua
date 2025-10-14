require 'ext.gc'	-- make sure luajit can __gc lua-tables
local ffi = require 'ffi'
local assert = require 'ext.assert'
local class = require 'ext.class'
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
local Voxel = numo9_rom.Voxel

local numo9_video = require 'numo9.video'
local Numo9Vertex = numo9_video.Numo9Vertex


local uint8_t_p = ffi.typeof'uint8_t*'
local int32_t = ffi.typeof'int32_t'
local Voxel_p = ffi.typeof('$*', Voxel)


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

-- orientation rotations for the upper 5 rotation bits of the voxel
-- indexed[orientation+1][axis+1][angle in 90 degree increments +1] = 0-based orientation
local orientationRotations = {
	{{16, 10, 26},{4, 8, 12},{1, 2, 3}},
	{{13, 9, 5},{17, 11, 27},{2, 3, 0}},
	{{24, 8, 18},{14, 10, 6},{3, 0, 1}},
	{{7, 11, 15},{25, 9, 19},{0, 1, 2}},
	{{17, 14, 25},{8, 12, 0},{5, 6, 7}},
	{{1, 13, 9},{18, 15, 26},{6, 7, 4}},
	{{27, 12, 19},{2, 14, 10},{7, 4, 5}},
	{{11, 15, 3},{24, 13, 16},{4, 5, 6}},
	{{18, 2, 24},{12, 0, 4},{9, 10, 11}},
	{{5, 1, 13},{19, 3, 25},{10, 11, 8}},
	{{26, 0, 16},{6, 2, 14},{11, 8, 9}},
	{{15, 3, 7},{27, 1, 17},{8, 9, 10}},
	{{19, 6, 27},{0, 4, 8},{13, 14, 15}},
	{{9, 5, 1},{16, 7, 24},{14, 15, 12}},
	{{25, 4, 17},{10, 6, 2},{15, 12, 13}},
	{{3, 7, 11},{26, 5, 18},{12, 13, 14}},
	{{10, 26, 0},{7, 24, 13},{17, 18, 19}},
	{{14, 25, 4},{11, 27, 1},{18, 19, 16}},
	{{2, 24, 8},{15, 26, 5},{19, 16, 17}},
	{{6, 27, 12},{3, 25, 9},{16, 17, 18}},
	{{11, 15, 3},{24, 13, 16},{4, 5, 6}},
	{{17, 14, 25},{8, 12, 0},{5, 6, 7}},
	{{1, 13, 9},{18, 15, 26},{6, 7, 4}},
	{{27, 12, 19},{2, 14, 10},{7, 4, 5}},
	{{8, 18, 2},{13, 16, 7},{25, 26, 27}},
	{{4, 17, 14},{9, 19, 3},{26, 27, 24}},
	{{0, 16, 10},{5, 18, 15},{27, 24, 25}},
	{{12, 19, 6},{1, 17, 11},{24, 25, 26}},
	{{9, 5, 1},{16, 7, 24},{14, 15, 12}},
	{{25, 4, 17},{10, 6, 2},{15, 12, 13}},
	{{3, 7, 11},{26, 5, 18},{12, 13, 14}},
	{{19, 6, 27},{0, 4, 8},{13, 14, 15}},
}

-- inverse orientation for orientation
-- [orientation+1] = rotated orientation
local orientationInv = {0, 3, 2, 1, 12, 19, 6, 27, 8, 9, 10, 11, 4, 25, 14, 17, 26, 15, 18, 5, 27, 12, 19, 6, 24, 13, 16, 7, 25, 14, 17, 4}

-- [sideIndex+1][orientation+1] = rotated sideIndex
local rotateSideByOrientation = {
	{0, 2, 1, 3, 5, 5, 5, 5, 1, 3, 0, 2, 4, 4, 4, 4, 0, 2, 1, 3, 5, 5, 5, 5, 1, 3, 0, 2, 4, 4, 4, 4},
	{1, 3, 0, 2, 4, 4, 4, 4, 0, 2, 1, 3, 5, 5, 5, 5, 1, 3, 0, 2, 4, 4, 4, 4, 0, 2, 1, 3, 5, 5, 5, 5},
	{2, 1, 3, 0, 2, 1, 3, 0, 2, 1, 3, 0, 2, 1, 3, 0, 4, 4, 4, 4, 0, 2, 1, 3, 5, 5, 5, 5, 1, 3, 0, 2},
	{3, 0, 2, 1, 3, 0, 2, 1, 3, 0, 2, 1, 3, 0, 2, 1, 5, 5, 5, 5, 1, 3, 0, 2, 4, 4, 4, 4, 0, 2, 1, 3},
	{4, 4, 4, 4, 0, 2, 1, 3, 5, 5, 5, 5, 1, 3, 0, 2, 3, 0, 2, 1, 3, 0, 2, 1, 3, 0, 2, 1, 3, 0, 2, 1},
	{5, 5, 5, 5, 1, 3, 0, 2, 4, 4, 4, 4, 0, 2, 1, 3, 2, 1, 3, 0, 2, 1, 3, 0, 2, 1, 3, 0, 2, 1, 3, 0}
}

local function shiftDownAndRoundUp(x, bits)
	local y = bit.rshift(x, bits)
	local mask = bit.lshift(1, bits) - 1
	if bit.band(x, mask) ~= 0 then y = y + 1 end
	return y
end



local Chunk = class()

-- static member
Chunk.bitsize = vec3i(5, 5, 5)
Chunk.size = Chunk.bitsize:map(function(x) return bit.lshift(1, x) end)
Chunk.bitmask = Chunk.size - 1
Chunk.volume = Chunk.size:volume()	-- same as 1 << bitsize:sum() (if i had a :sum() function...)

local VoxelChunkVolumeArr = ffi.typeof('$['..Chunk.volume..']', Voxel)

function Chunk:init(args)
	local voxelmap = assert(args.voxelmap)
	self.voxelmap = voxelmap

	-- chunk position, in Chunk.size units
	self.chunkPos = vec3i((assert.index(args, 'chunkPos')))

	-- for now don't store data in chunks, just meshes.
	--[[
	self.v = ffi.new(VoxelChunkVolumeArr, self.volume)
	ffi.fill(self.v, ffi.sizeof(VoxelChunkVolumeArr), -1)	-- fills with 0xff, right?
	--]]

	local volume = self.volume
	self.vertexBufCPU = vector(Numo9Vertex)

	-- says the mesh needs to be rebuilt
	self.dirtyCPU = true
end

local tmpMat = matrix_ffi({4,4}, 'float'):zeros()
function Chunk:rebuildMesh(app)
	if not self.dirtyCPU then return end
	self.dirtyCPU = false

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
		0,
		transparentIndex,
		paletteIndex)

	local voxelmapSize = self.voxelmap:getVoxelSize()

	-- which to build this off of?
	-- RAMPtr since thats what AppVideo:drawVoxelMap() uses
	-- but that means it wont be present upon init() ...
	local mp = tmpMat.ptr
	local voxels = assert(self.voxelmap:getVoxelDataRAMPtr(), 'BlobVoxelMap rebuildMesh .ramptr missing')
	local occludedCount = 0

	local ci, cj, ck = self.chunkPos:unpack()
--DEBUG:print('chunk', ci, cj, ck)

	local nbhd = vec3i()
	for k=0,Chunk.size.z-1 do
		local vk = bit.bor(k, bit.lshift(ck, Chunk.bitsize.z))
		if vk < voxelmapSize.z then
			for j=0,Chunk.size.y-1 do
				local vj = bit.bor(j, bit.lshift(cj, Chunk.bitsize.y))
				if vj < voxelmapSize.y then

					-- at least traverse rows
					local vptr = voxels + (bit.lshift(ci, Chunk.bitsize.x) + voxelmapSize.x * (vj + voxelmapSize.y * vk))

					for i=0,Chunk.size.x-1 do
						local vi = bit.bor(i, bit.lshift(ci, Chunk.bitsize.x))

--DEBUG:print('cpos', ci, cj, ck, 'pos', i, j, k, 'vpos', vi, vj, vk)

						-- lookup each voxel
						--local vptr = voxels + (vi + voxelmapSize.x * (vj + voxelmapSize.y * vk))

						-- chunks can extend beyond the voxelmap when it isnt chunk-aligned in size
						if vi < voxelmapSize.x
						and vptr.intval ~= voxelMapEmptyValue
						then
							tmpMat:setTranslate(vi+.5, vj+.5, vk+.5)
							tmpMat:applyScale(1/32768, 1/32768, 1/32768)

							if vptr.orientation == 20 then
								self.voxelmap.billboardXYZVoxels:emplace_back()[0]:set(vi,vj,vk)
							elseif vptr.orientation == 21 then
								self.voxelmap.billboardXYVoxels:emplace_back()[0]:set(vi,vj,vk)
							elseif vptr.orientation == 22 then
								-- TODO
							elseif vptr.orientation == 23 then
								-- TODO
							else
								--[[
								0 c= 1 s= 0
								1 c= 0 s= 1
								2 c=-1 s= 0
								3 c= 0 s=-1
								--]]

								if vptr.rotZ == 1 then
									--[[
									[ m0 m4 m8  m12] [ 0 -1 0 0 ]
									[ m1 m5 m9  m13] [ 1  0 0 0 ]
									[ m2 m6 m10 m14] [ 0  0 1 0 ]
									[ m3 m7 m11 m15] [ 0  0 0 1 ]
									--]]
									mp[0], mp[1], mp[2], mp[4], mp[5], mp[6]
									= mp[4], mp[5], mp[6], -mp[0], -mp[1], -mp[2]
								elseif vptr.rotZ == 2 then
									--[[
									[ m0 m4 m8  m12] [ -1  0 0 0 ]
									[ m1 m5 m9  m13] [  0 -1 0 0 ]
									[ m2 m6 m10 m14] [  0  0 1 0 ]
									[ m3 m7 m11 m15] [  0  0 0 1 ]
									--]]
									mp[0], mp[1], mp[2], mp[4], mp[5], mp[6]
									= -mp[0], -mp[1], -mp[2], -mp[4], -mp[5], -mp[6]
								elseif vptr.rotZ == 3 then
									--[[
									[ m0 m4 m8  m12] [  0 1 0 0 ]
									[ m1 m5 m9  m13] [ -1 0 0 0 ]
									[ m2 m6 m10 m14] [  0 0 1 0 ]
									[ m3 m7 m11 m15] [  0 0 0 1 ]
									--]]
									mp[0], mp[1], mp[2], mp[4], mp[5], mp[6]
									= -mp[4], -mp[5], -mp[6], mp[0], mp[1], mp[2]
								end

								if vptr.rotY == 1 then
									--[[
									[ m0 m4 m8  m12] [  0 0 1 0 ]
									[ m1 m5 m9  m13] [  0 1 0 0 ]
									[ m2 m6 m10 m14] [ -1 0 0 0 ]
									[ m3 m7 m11 m15] [  0 0 0 1 ]
									--]]
									mp[0], mp[1], mp[2], mp[8], mp[9], mp[10]
									= -mp[8], -mp[9], -mp[10], mp[0], mp[1], mp[2]
								elseif vptr.rotY == 2 then
									mp[0], mp[1], mp[2], mp[8], mp[9], mp[10]
									= -mp[0], -mp[1], -mp[2], -mp[8], -mp[9], -mp[10]
								elseif vptr.rotY == 3 then
									mp[0], mp[1], mp[2], mp[8], mp[9], mp[10]
									= mp[8], mp[9], mp[10], -mp[0], -mp[1], -mp[2]
								end

								if vptr.rotX == 1 then
									--[[
									[ m0 m4 m8  m12] [ 1 0  0 0 ]
									[ m1 m5 m9  m13] [ 0 0 -1 0 ]
									[ m2 m6 m10 m14] [ 0 1  0 0 ]
									[ m3 m7 m11 m15] [ 0 0  0 1 ]
									--]]
									mp[0], mp[1], mp[2], mp[12], mp[13], mp[14]
									= mp[12], mp[13], mp[14], -mp[0], -mp[1], -mp[2]
								elseif vptr.rotX == 2 then
									mp[0], mp[1], mp[2], mp[12], mp[13], mp[14]
									= -mp[0], -mp[1], -mp[2], -mp[12], -mp[13], -mp[14]
								elseif vptr.rotX == 3 then
									mp[0], mp[1], mp[2], mp[12], mp[13], mp[14]
									= -mp[12], -mp[13], -mp[14], mp[0], mp[1], mp[2]
								end

								local uofs = bit.lshift(vptr.tileXOffset, 3)
								local vofs = bit.lshift(vptr.tileYOffset, 3)

								local mesh = app.blobs.mesh3d[vptr.mesh3DIndex+1]
								if mesh then
									local srcVtxs = mesh:getVertexPtr()	-- TODO blob vs ram location ...

									-- resize first then offest back in case we get a resize ...
									self.vertexBufCPU:reserve(#self.vertexBufCPU + #mesh.triList)

									for ti=0,#mesh.triList-1 do
										local tri = mesh.triList.v[ti]
										local ai, bi, ci = tri.x, tri.y, tri.z

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


										local sideIndex = mesh.sideForTriIndex[ti]
										if sideIndex then
											-- TODO TODO sides need to be influenced by orientation too ...
											sideIndex = rotateSideByOrientation[sideIndex+1][vptr.orientation+1]

											-- offet into 'sideIndex'
											local sign = 1 - 2 * bit.band(1, sideIndex)
											local axis = bit.rshift(sideIndex, 1)

											nbhd.x, nbhd.y, nbhd.z = vi,vj,vk
											nbhd.s[axis] = nbhd.s[axis] + sign
											if nbhd.x >= 0 and nbhd.x < voxelmapSize.x
											and nbhd.y >= 0 and nbhd.y < voxelmapSize.y
											and nbhd.z >= 0 and nbhd.z < voxelmapSize.z
											then
												-- if it occludes the opposite side then skip this tri
												local nbhdVox = voxels[nbhd.x + voxelmapSize.x * (nbhd.y + voxelmapSize.y * nbhd.z)]
												local nbhdmesh = app.blobs.mesh3d[nbhdVox.mesh3DIndex+1]
												if nbhdmesh
												and nbhdVox.orientation ~= 20
												and nbhdVox.orientation ~= 21
												then
													local oppositeSideIndex = bit.bxor(1, sideIndex)
													oppositeSideIndex = rotateSideByOrientation[oppositeSideIndex+1][nbhdVox.orientation+1]
													occluded = nbhdmesh.sidesOccluded[oppositeSideIndex]
												end
											end
										end

										if occluded then
											occludedCount = occludedCount + 1
										else
											local va = srcVtxs + ai
											local vb = srcVtxs + bi
											local vc = srcVtxs + ci

											local normal = mesh.normalList.v[ti]

											local srcv = va
											local dstVtx = self.vertexBufCPU:emplace_back()
											dstVtx.vertex.x, dstVtx.vertex.y, dstVtx.vertex.z = vec3to3(mp, srcv.x, srcv.y, srcv.z)
											dstVtx.texcoord.x = (tonumber(srcv.u + uofs) + .5) / tonumber(spriteSheetSize.x)
											dstVtx.texcoord.y = (tonumber(srcv.v + vofs) + .5) / tonumber(spriteSheetSize.y)
											dstVtx.normal = normal
											dstVtx.extra = extra
											dstVtx.box.x, dstVtx.box.y, dstVtx.box.z, dstVtx.box.w = 0, 0, 1, 1

											local srcv = vb
											local dstVtx = self.vertexBufCPU:emplace_back()
											dstVtx.vertex.x, dstVtx.vertex.y, dstVtx.vertex.z = vec3to3(mp, srcv.x, srcv.y, srcv.z)
											dstVtx.texcoord.x = (tonumber(srcv.u + uofs) + .5) / tonumber(spriteSheetSize.x)
											dstVtx.texcoord.y = (tonumber(srcv.v + vofs) + .5) / tonumber(spriteSheetSize.y)
											dstVtx.normal = normal
											dstVtx.extra = extra
											dstVtx.box.x, dstVtx.box.y, dstVtx.box.z, dstVtx.box.w = 0, 0, 1, 1

											local srcv = vc
											local dstVtx = self.vertexBufCPU:emplace_back()
											dstVtx.vertex.x, dstVtx.vertex.y, dstVtx.vertex.z = vec3to3(mp, srcv.x, srcv.y, srcv.z)
											dstVtx.texcoord.x = (tonumber(srcv.u + uofs) + .5) / tonumber(spriteSheetSize.x)
											dstVtx.texcoord.y = (tonumber(srcv.v + vofs) + .5) / tonumber(spriteSheetSize.y)
											dstVtx.normal = normal
											dstVtx.extra = extra
											dstVtx.box.x, dstVtx.box.y, dstVtx.box.z, dstVtx.box.w = 0, 0, 1, 1
										end
									end
								end
							end
						end
						vptr = vptr + 1
					end
				end
			end
		end
	end
--DEBUG:print('created', #self.vertexBufCPU/3, 'tris')
--DEBUG:print('occluded', occludedCount, 'tris')
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

assert.eq(ffi.sizeof(voxelmapSizeType), ffi.sizeof(Voxel))
function BlobVoxelMap:init(data)
	self.vec = vector(Voxel)	-- use .intptr for the first x y z entries
	local minsize = ffi.sizeof(Voxel) * 3
	if not data or #data < minsize then
		self.vec:emplace_back()[0].intval = 1
		self.vec:emplace_back()[0].intval = 1
		self.vec:emplace_back()[0].intval = 1
		self.vec:emplace_back()[0].intval = voxelMapEmptyValue
	else
		self.vec:resize(math.ceil(#data / ffi.sizeof(Voxel)))
		ffi.copy(self.vec.v, data, #data)
	end

	-- validate that the header at least works
	assert.gt(self:getWidth(), 0)
	assert.gt(self:getHeight(), 0)
	assert.gt(self:getDepth(), 0)

	self.billboardXYZVoxels = vector(vec3i)	-- type 20
	self.billboardXYVoxels = vector(vec3i)	-- type 21


	-- can't build the mesh yet, not until .ramptr is defined
	--self:rebuildMesh()

	-- TODO instead of storing ... three times in memory:
	-- 	- once as the blob from the cart file
	--	- once in RAM
	--	- once in the chunks
	-- how about just storing it in RAM and chunks only?
	-- For one, because the archiver wants the data continuous in :getPtr() ...
	-- how to work around this ...
	local voxptr = self:getVoxelDataBlobPtr()

	-- says that some chunk's mesh needs to be rebuilt
	self.dirtyCPU = true

	-- 0-based, index from interleaving chunkPos with self:voxelSizeInChunks()
	self.chunks = {}
	local voxelmapSize = self:getVoxelSize()

	-- need to update this if the size ever changes...
	self.sizeInChunks = self:getVoxelSizeInChunks()

	-- create the chunks
	do
		local chunkIndex = 0
		for ck=0,self.sizeInChunks.z-1 do
			for cj=0,self.sizeInChunks.y-1 do
				for ci=0,self.sizeInChunks.x-1 do
					local chunk = Chunk{
						voxelmap = self,
						chunkPos = vec3i(ci,cj,ck),
					}
					self.chunks[chunkIndex] = chunk

					-- for now don't store data in chunks, just meshes.
					--[[ can't always do this ...
					ffi.copy(chunk.v, voxptr + chunkIndex * Chunk.volume, ffi.sizeof(VoxelChunkVolumeArr))
					--]]
					--[[
					for k=0,Chunk.size.z-1 do
						for j=0,Chunk.size.y-1 do
							for i=0,Chunk.size.x-1 do
								-- voxelmap index:
								local vi = bit.bor(i, bit.lshift(ci, Chunk.bitsize.x))
								local vj = bit.bor(j, bit.lshift(cj, Chunk.bitsize.y))
								local vk = bit.bor(k, bit.lshift(ck, Chunk.bitsize.z))
								-- copy block by block
								-- TODO maybe ffi.copy by row eventually
								chunk.v[i + Chunk.size.x * (j + Chunk.size.y * k)]
									= voxptr[vi + voxelmapSize.x * (vj + voxelmapSize.y * vk)]
							end
						end
					end
					--]]

					chunkIndex = chunkIndex + 1
				end
			end
		end
	end
end

function BlobVoxelMap:getPtr()
	return ffi.cast(uint8_t_p, self.vec.v)
end

function BlobVoxelMap:getSize()
	return self.vec:getNumBytes()
end

-- get size by the blob, not the RAM...
function BlobVoxelMap:getWidth()
	return self.vec.v[0].intval
end

function BlobVoxelMap:getHeight()
	return self.vec.v[1].intval
end

function BlobVoxelMap:getDepth()
	return self.vec.v[2].intval
end

function BlobVoxelMap:getVoxelSize()
	return vec3i(self:getWidth(), self:getHeight(), self:getDepth())
end

function BlobVoxelMap:getVoxelSizeInChunks()
	local size = self:getVoxelSize()
	return vec3i(
		shiftDownAndRoundUp(size.x, Chunk.bitsize.x),
		shiftDownAndRoundUp(size.y, Chunk.bitsize.y),
		shiftDownAndRoundUp(size.z, Chunk.bitsize.z))
end

function BlobVoxelMap:getVoxelDataBlobPtr()
	return self.vec.v + 3
end

function BlobVoxelMap:getVoxelDataRAMPtr()
	return ffi.cast(Voxel_p, self.ramptr + ffi.sizeof(voxelmapSizeType) * 3)
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
	return self:getVoxelDataAddr() + ffi.sizeof(Voxel) * (x + self:getWidth() * (y + self:getHeight() * z))
end

--[[
app = used to search list of mesh3d blobs
--]]
function BlobVoxelMap:rebuildMesh(app)
	if not self.dirtyCPU then return end
	self.dirtyCPU = false

select(2, require 'ext.timer'('BlobVoxelMap:rebuildMesh', function()
	self.billboardXYZVoxels:resize(0)
	self.billboardXYVoxels:resize(0)

local lastTime = os.time()

	self.chunkVolume = self:getVoxelSizeInChunks():volume()
	for chunkIndex=0,self.chunkVolume-1 do

local thisTime = os.time()
if thisTime ~= lastTime then
	print(('...%f%%'):format(100 * chunkIndex / self.chunkVolume))
	lastTime = thisTime
end

		self.chunks[chunkIndex]:rebuildMesh(app)
	end
end))
end

local warnedAboutTouchingSize

-- touchAddrStart, touchAddrEnd are inclusive
function BlobVoxelMap:onTouchRAM(touchAddrStart, touchAddrEnd, app)
	--if (0, 2) touches-inclusive (addr, addrend) then
	local voxelStartAddr = self.addr + ffi.sizeof(voxelmapSizeType) * 3
	local sizeAddrEnd = voxelStartAddr - 1	-- -1 for inclusive range
	if touchAddrEnd >= self.addr and touchAddrStart <= sizeAddrEnd then
		-- size was touched ... rebuild everything
if not warnedAboutTouchingSize then
	warnedAboutTouchingSize = true
	print("I don't support live changing voxelmap chunk sizes.  Changing this to a value exceeding the limit of RAM could have devastating consequences.")
	print(debug.traceback())
	print()
end
		return
	end

	local width, height, depth = self:getWidth(), self:getHeight(), self:getDepth()

	-- TODO since data is stored [z][y][x] across the whole voxelmap, i could look for rows that touch
	-- this is me being lazy though
	for touchAddr=tonumber(touchAddrStart),tonumber(touchAddrEnd) do
		-- get the chunk index
		-- flag it as dirty
		-- TODO floor vs cast as int? which is faster?
		local voxelIndex = ffi.cast(int32_t, (touchAddr - voxelStartAddr) / ffi.sizeof(Voxel))
		local tmp = voxelIndex
		local vi = tmp % width
		tmp = ffi.cast(int32_t, tmp / width)
		local vj = tmp % height
		tmp = ffi.cast(int32_t, tmp / height)
		local vk = tmp

		local ci = bit.rshift(vi, Chunk.bitsize.x)
		local cj = bit.rshift(vj, Chunk.bitsize.y)
		local ck = bit.rshift(vk, Chunk.bitsize.z)

		local chunkIndex = tonumber(ci + self.sizeInChunks.x * (cj + self.sizeInChunks.y * ck))
		local chunk = self.chunks[chunkIndex]

		chunk.dirtyCPU = true
		self.dirtyCPU = true
	end
end

--[====[ I don't think I'll bring this back until it is in the Chunk class
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
			size = ffi.sizeof(Numo9Vertex) * self.vertexBufCPU.capacity,
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
			size = ffi.sizeof(Numo9Vertex) * self.vertexBufCPU.capacity,
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
--]====]

return BlobVoxelMap
