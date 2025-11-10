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
local glreport = require 'gl.report'
local glglobal = require 'gl.global'
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

-- orientation rotations for the upper 6 rotation bits of the voxel
-- indexed[orientation+1][axis+1][angle in 90 degree increments +1] = 0-based orientation
-- the first 3 axis are for rotations, and have 3 entries for each 90 degree rotation
-- the second 3 are for scales, and have 1 entry for the scale in the x, y, and z direction.
local orientationRotations = {
	{{16, 10, 26},{4, 8, 12},{1, 2, 3},{32},{34},{40}},
	{{13, 9, 5},{17, 11, 27},{2, 3, 0},{35},{33},{41}},
	{{24, 8, 18},{14, 10, 6},{3, 0, 1},{34},{32},{42}},
	{{7, 11, 15},{25, 9, 19},{0, 1, 2},{33},{35},{43}},
	{{17, 14, 25},{8, 12, 0},{5, 6, 7},{44},{46},{36}},
	{{1, 13, 9},{18, 15, 26},{6, 7, 4},{47},{45},{37}},
	{{27, 12, 19},{2, 14, 10},{7, 4, 5},{46},{44},{38}},
	{{11, 15, 3},{24, 13, 16},{4, 5, 6},{45},{47},{39}},
	{{18, 2, 24},{12, 0, 4},{9, 10, 11},{40},{42},{32}},
	{{5, 1, 13},{19, 3, 25},{10, 11, 8},{43},{41},{33}},
	{{26, 0, 16},{6, 2, 14},{11, 8, 9},{42},{40},{34}},
	{{15, 3, 7},{27, 1, 17},{8, 9, 10},{41},{43},{35}},
	{{19, 6, 27},{0, 4, 8},{13, 14, 15},{36},{38},{44}},
	{{9, 5, 1},{16, 7, 24},{14, 15, 12},{39},{37},{45}},
	{{25, 4, 17},{10, 6, 2},{15, 12, 13},{38},{36},{46}},
	{{3, 7, 11},{26, 5, 18},{12, 13, 14},{37},{39},{47}},
	{{10, 26, 0},{7, 24, 13},{17, 18, 19},{48},{50},{56}},
	{{14, 25, 4},{11, 27, 1},{18, 19, 16},{51},{49},{57}},
	{{2, 24, 8},{15, 26, 5},{19, 16, 17},{50},{48},{58}},
	{{6, 27, 12},{3, 25, 9},{16, 17, 18},{49},{51},{59}},
	{{11, 15, 3},{24, 13, 16},{4, 5, 6},{45},{47},{39}},
	{{17, 14, 25},{8, 12, 0},{5, 6, 7},{44},{46},{36}},
	{{1, 13, 9},{18, 15, 26},{6, 7, 4},{47},{45},{37}},
	{{27, 12, 19},{2, 14, 10},{7, 4, 5},{46},{44},{38}},
	{{8, 18, 2},{13, 16, 7},{25, 26, 27},{56},{58},{48}},
	{{4, 17, 14},{9, 19, 3},{26, 27, 24},{59},{57},{49}},
	{{0, 16, 10},{5, 18, 15},{27, 24, 25},{58},{56},{50}},
	{{12, 19, 6},{1, 17, 11},{24, 25, 26},{57},{59},{51}},
	{{9, 5, 1},{16, 7, 24},{14, 15, 12},{39},{37},{45}},
	{{25, 4, 17},{10, 6, 2},{15, 12, 13},{38},{36},{46}},
	{{3, 7, 11},{26, 5, 18},{12, 13, 14},{37},{39},{47}},
	{{19, 6, 27},{0, 4, 8},{13, 14, 15},{36},{38},{44}},
	{{48, 42, 58},{36, 40, 44},{33, 34, 35},{0},{2},{8}},
	{{45, 41, 37},{49, 43, 59},{34, 35, 32},{3},{1},{9}},
	{{56, 40, 50},{46, 42, 38},{35, 32, 33},{2},{0},{10}},
	{{39, 43, 47},{57, 41, 51},{32, 33, 34},{1},{3},{11}},
	{{49, 46, 57},{40, 44, 32},{37, 38, 39},{12},{14},{4}},
	{{33, 45, 41},{50, 47, 58},{38, 39, 36},{15},{13},{5}},
	{{59, 44, 51},{34, 46, 42},{39, 36, 37},{14},{12},{6}},
	{{43, 47, 35},{56, 45, 48},{36, 37, 38},{13},{15},{7}},
	{{50, 34, 56},{44, 32, 36},{41, 42, 43},{8},{10},{0}},
	{{37, 33, 45},{51, 35, 57},{42, 43, 40},{11},{9},{1}},
	{{58, 32, 48},{38, 34, 46},{43, 40, 41},{10},{8},{2}},
	{{47, 35, 39},{59, 33, 49},{40, 41, 42},{9},{11},{3}},
	{{51, 38, 59},{32, 36, 40},{45, 46, 47},{4},{6},{12}},
	{{41, 37, 33},{48, 39, 56},{46, 47, 44},{7},{5},{13}},
	{{57, 36, 49},{42, 38, 34},{47, 44, 45},{6},{4},{14}},
	{{35, 39, 43},{58, 37, 50},{44, 45, 46},{5},{7},{15}},
	{{42, 58, 32},{39, 56, 45},{49, 50, 51},{16},{18},{24}},
	{{46, 57, 36},{43, 59, 33},{50, 51, 48},{19},{17},{25}},
	{{34, 56, 40},{47, 58, 37},{51, 48, 49},{18},{16},{26}},
	{{38, 59, 44},{35, 57, 41},{48, 49, 50},{17},{19},{27}},
	{{43, 47, 35},{56, 45, 48},{36, 37, 38},{13},{15},{7}},
	{{49, 46, 57},{40, 44, 32},{37, 38, 39},{12},{14},{4}},
	{{33, 45, 41},{50, 47, 58},{38, 39, 36},{15},{13},{5}},
	{{59, 44, 51},{34, 46, 42},{39, 36, 37},{14},{12},{6}},
	{{40, 50, 34},{45, 48, 39},{57, 58, 59},{24},{26},{16}},
	{{36, 49, 46},{41, 51, 35},{58, 59, 56},{27},{25},{17}},
	{{32, 48, 42},{37, 50, 47},{59, 56, 57},{26},{24},{18}},
	{{44, 51, 38},{33, 49, 43},{56, 57, 58},{25},{27},{19}},
	{{41, 37, 33},{48, 39, 56},{46, 47, 44},{7},{5},{13}},
	{{57, 36, 49},{42, 38, 34},{47, 44, 45},{6},{4},{14}},
	{{35, 39, 43},{58, 37, 50},{44, 45, 46},{5},{7},{15}},
	{{51, 38, 59},{32, 36, 40},{45, 46, 47},{4},{6},{12}},
}

-- inverse orientation for orientation
-- [orientation+1] = rotated orientation
local orientationInv = {0, 3, 2, 1, 12, 19, 6, 27, 8, 9, 10, 11, 4, 25, 14, 17, 26, 15, 18, 5, 27, 12, 19, 6, 24, 13, 16, 7, 25, 14, 17, 4, 32, 33, 34, 35, 36, 49, 46, 57, 40, 43, 42, 41, 44, 59, 38, 51, 58, 37, 50, 47, 57, 36, 49, 46, 56, 39, 48, 45, 59, 38, 51, 44}

-- [sideIndex+1][orientation+1] = rotated sideIndex
local rotateSideByOrientation = {
	{0, 2, 1, 3, 5, 5, 5, 5, 1, 3, 0, 2, 4, 4, 4, 4, 0, 2, 1, 3, 5, 5, 5, 5, 1, 3, 0, 2, 4, 4, 4, 4, 1, 3, 0, 2, 4, 4, 4, 4, 0, 2, 1, 3, 5, 5, 5, 5, 1, 3, 0, 2, 4, 4, 4, 4, 0, 2, 1, 3, 5, 5, 5, 5},
	{1, 3, 0, 2, 4, 4, 4, 4, 0, 2, 1, 3, 5, 5, 5, 5, 1, 3, 0, 2, 4, 4, 4, 4, 0, 2, 1, 3, 5, 5, 5, 5, 0, 2, 1, 3, 5, 5, 5, 5, 1, 3, 0, 2, 4, 4, 4, 4, 0, 2, 1, 3, 5, 5, 5, 5, 1, 3, 0, 2, 4, 4, 4, 4},
	{2, 1, 3, 0, 2, 1, 3, 0, 2, 1, 3, 0, 2, 1, 3, 0, 4, 4, 4, 4, 0, 2, 1, 3, 5, 5, 5, 5, 1, 3, 0, 2, 2, 1, 3, 0, 2, 1, 3, 0, 2, 1, 3, 0, 2, 1, 3, 0, 4, 4, 4, 4, 0, 2, 1, 3, 5, 5, 5, 5, 1, 3, 0, 2},
	{3, 0, 2, 1, 3, 0, 2, 1, 3, 0, 2, 1, 3, 0, 2, 1, 5, 5, 5, 5, 1, 3, 0, 2, 4, 4, 4, 4, 0, 2, 1, 3, 3, 0, 2, 1, 3, 0, 2, 1, 3, 0, 2, 1, 3, 0, 2, 1, 5, 5, 5, 5, 1, 3, 0, 2, 4, 4, 4, 4, 0, 2, 1, 3},
	{4, 4, 4, 4, 0, 2, 1, 3, 5, 5, 5, 5, 1, 3, 0, 2, 3, 0, 2, 1, 3, 0, 2, 1, 3, 0, 2, 1, 3, 0, 2, 1, 4, 4, 4, 4, 0, 2, 1, 3, 5, 5, 5, 5, 1, 3, 0, 2, 3, 0, 2, 1, 3, 0, 2, 1, 3, 0, 2, 1, 3, 0, 2, 1},
	{5, 5, 5, 5, 1, 3, 0, 2, 4, 4, 4, 4, 0, 2, 1, 3, 2, 1, 3, 0, 2, 1, 3, 0, 2, 1, 3, 0, 2, 1, 3, 0, 5, 5, 5, 5, 1, 3, 0, 2, 4, 4, 4, 4, 0, 2, 1, 3, 2, 1, 3, 0, 2, 1, 3, 0, 2, 1, 3, 0, 2, 1, 3, 0}
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
	self.billboardXYZVoxels = vector(vec3i)	-- type 20
	self.billboardXYVoxels = vector(vec3i)	-- type 21

	-- oh yeah, archive uses this class, maybe I don't want to build the GLArrayBuffer in the ctor after all?
	-- but I think same argument for the blob/image classes, so meh leave it here.
	self.vertexBufGPU = GLArrayBuffer{
		size = ffi.sizeof(Numo9Vertex) * self.vertexBufCPU.capacity,
		count = self.vertexBufCPU.capacity,
		data = self.vertexBufCPU.v,
		usage = gl.GL_DYNAMIC_DRAW,
	}
	:bind()
print('GL_ARRAY_BUFFER_BINDING', glglobal:get'GL_ARRAY_BUFFER_BINDING')
print('chunk', self.chunkPos, 'vertexBufGPU init GL_BUFFER_SIZE', self.vertexBufGPU:get'GL_BUFFER_SIZE')
	self.vertexBufGPU:unbind()

	-- says the mesh needs to be rebuilt
	self.dirtyCPU = true
end

local tmpMat = matrix_ffi({4,4}, 'float'):zeros()
function Chunk:rebuildMesh(app)
	if not self.dirtyCPU then return end
	self.dirtyCPU = false

	self.vertexBufCPU:resize(0)
	self.billboardXYZVoxels:resize(0)
	self.billboardXYVoxels:resize(0)

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

					-- traverse cols
					local vptr = voxels + (bit.lshift(ci, Chunk.bitsize.x) + voxelmapSize.x * (vj + voxelmapSize.y * vk))
					for i=0,Chunk.size.x-1 do
						local vi = bit.bor(i, bit.lshift(ci, Chunk.bitsize.x))
--DEBUG:print('cpos', ci, cj, ck, 'pos', i, j, k, 'vpos', vi, vj, vk)

						-- chunks can extend beyond the voxelmap when it isnt chunk-aligned in size
						if vi >= voxelmapSize.x then break end

						if vptr.intval ~= voxelMapEmptyValue then
							tmpMat:setTranslate(vi+.5, vj+.5, vk+.5)
							tmpMat:applyScale(1/32768, 1/32768, 1/32768)

							if vptr.orientation == 20 then
								self.billboardXYZVoxels:emplace_back()[0]:set(vi,vj,vk)
							elseif vptr.orientation == 21 then
								self.billboardXYVoxels:emplace_back()[0]:set(vi,vj,vk)
							elseif vptr.orientation == 22 then
							elseif vptr.orientation == 23 then
							elseif vptr.orientation == 28 then
							elseif vptr.orientation == 29 then
							elseif vptr.orientation == 30 then
							elseif vptr.orientation == 31 then
							elseif vptr.orientation == 52 then
							elseif vptr.orientation == 53 then
							elseif vptr.orientation == 54 then
							elseif vptr.orientation == 55 then
							elseif vptr.orientation == 60 then
							elseif vptr.orientation == 61 then
							elseif vptr.orientation == 62 then
							elseif vptr.orientation == 63 then
							else
								if vptr.scaleX == 1 then
									mp[0], mp[1], mp[2] = -mp[0], -mp[1], -mp[2]
								end

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
									mp[4], mp[5], mp[6], mp[8], mp[9], mp[10]
									= mp[8], mp[9], mp[10], -mp[4], -mp[5], -mp[6]
								elseif vptr.rotX == 6 then
									mp[4], mp[5], mp[6], mp[8], mp[9], mp[10]
									= -mp[4], -mp[5], -mp[6], -mp[8], -mp[9], -mp[10]
								elseif vptr.rotX == 3 then
									mp[4], mp[5], mp[6], mp[8], mp[9], mp[10]
									= -mp[8], -mp[9], -mp[10], mp[4], mp[5], mp[6]
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
												and nbhdVox.orientation ~= 22
												and nbhdVox.orientation ~= 23
												and nbhdVox.orientation ~= 28
												and nbhdVox.orientation ~= 29
												and nbhdVox.orientation ~= 30
												and nbhdVox.orientation ~= 31
												and nbhdVox.orientation ~= 52
												and nbhdVox.orientation ~= 53
												and nbhdVox.orientation ~= 54
												and nbhdVox.orientation ~= 55
												and nbhdVox.orientation ~= 60
												and nbhdVox.orientation ~= 61
												and nbhdVox.orientation ~= 62
												and nbhdVox.orientation ~= 63
												then
													local oppositeSideIndex = bit.bxor(1, sideIndex)
													oppositeSideIndex = rotateSideByOrientation[oppositeSideIndex+1][orientationInv[nbhdVox.orientation+1]+1]
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

											-- preserve orientation even if we are scaling
											if vptr.scaleX == 1 then
												va, vc = vc, va
											end

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

-- needs triBuf_prepAddTri to be called beforehand
function Chunk:drawMesh(app)
	if #self.vertexBufCPU == 0 then return end

	local oldVAOID = glglobal:get'GL_VERTEX_ARRAY_BINDING'
	local oldBufferID = glglobal:get'GL_ARRAY_BUFFER_BINDING'
	local oldProgramID = glglobal:get'GL_CURRENT_PROGRAM'
print('GL_VERTEX_ARRAY_BINDING', oldVAOID)
print('GL_ARRAY_BUFFER_BINDING', oldBufferID)
print('GL_CURRENT_PROGRAM', oldProgramID)

--[[ hmm why aren't things working ....
	app.lastAnimSheetTex:bind(3)
	app.lastTilemapTex:bind(2)
	app.lastSheetTex:bind(1)
	app.lastPaletteTex:bind(0)

	app:triBuf_prepAddTri(
		app.lastPaletteTex,
		app.lastSheetTex,
		app.lastTilemapTex,
		app.lastAnimSheetTex)
--]]
	local sceneObj = app.triBuf_sceneObj
	local program = sceneObj.program

print('Chunk:drawMesh self.chunkPos', self.chunkPos)

	if not self.vao 
	or program ~= self.vaoProgram
	then
		if self.vao then
			self.vao:delete()
			self.vao = nil
		end
		-- cache vao per-program, which is per-video-mode
		-- because its attrs vary per program , per-video-mode
		self.vaoProgram = program
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
		} -- init doesnt bind vao...
		self.vao:bind()
assert(glreport'here')
		self.vertexBufGPU:bind()
assert(glreport'here')
	end
assert(glreport'here')
	self.vao:bind()
assert(glreport'here')

print('self.vertexBufCPU.capacity', self.vertexBufCPU.capacity)
print('self.vertexBufCPULastCapacity', self.vertexBufCPULastCapacity)	
	if self.vertexBufCPU.capacity ~= self.vertexBufCPULastCapacity then
		self.vertexBufGPU:bind()
assert(glreport'here')
print('GL_ARRAY_BUFFER_BINDING', glglobal:get'GL_ARRAY_BUFFER_BINDING')
print('vertexBufGPU before setData GL_BUFFER_SIZE', self.vertexBufGPU:get'GL_BUFFER_SIZE')
assert(glreport'here')
		self.vertexBufGPU:setData{
			data = self.vertexBufCPU.v,
			count = self.vertexBufCPU.capacity,
			size = ffi.sizeof(Numo9Vertex) * self.vertexBufCPU.capacity,
		}
print('GL_ARRAY_BUFFER_BINDING', glglobal:get'GL_ARRAY_BUFFER_BINDING')
print('vertexBufGPU after setData GL_BUFFER_SIZE', self.vertexBufGPU:get'GL_BUFFER_SIZE')
print('ffi.sizeof(Numo9Vertex)', ffi.sizeof(Numo9Vertex))
print('vertexBufGPU:setData count', self.vertexBufCPU.capacity)
print('vertexBufGPU:setData size', ffi.sizeof(Numo9Vertex) * self.vertexBufCPU.capacity)
print('vertexBufGPU:setData data', self.vertexBufCPU.v)
assert(glreport'here')
	-- [[ TODO only do this when we init or poke RAM
	-- TODO TODO this is causing GL errors
	else
--DEBUG:assert.eq(self.vertexBufGPU.data, self.vertexBufCPU.v)
print('vertexBufGPU:updateData old size', self.vertexBufGPU.size)
print('vertexBufGPU:updateData old data', self.vertexBufGPU.data)
print('vertexBufGPU:updateData data should be', self.vertexBufCPU.v)
print('vertexBufGPU:updateData vertexBufCPU:getNumBytes()', self.vertexBufCPU:getNumBytes())	
		self.vertexBufGPU:bind()
print('GL_ARRAY_BUFFER_BINDING', glglobal:get'GL_ARRAY_BUFFER_BINDING')
print('vertexBufGPU before updateData GL_BUFFER_SIZE', self.vertexBufGPU:get'GL_BUFFER_SIZE')
assert(glreport'here')
		self.vertexBufGPU
			:updateData(0, 
				--self.vertexBufCPU:getNumBytes())
				ffi.sizeof(Numo9Vertex) * self.vertexBufCPU.capacity)
assert(glreport'here')
	--]]
print('GL_ARRAY_BUFFER_BINDING', glglobal:get'GL_ARRAY_BUFFER_BINDING')
print('vertexBufGPU after updateData GL_BUFFER_SIZE', self.vertexBufGPU:get'GL_BUFFER_SIZE')
	end

	gl.glDrawArrays(gl.GL_TRIANGLES, 0, #self.vertexBufCPU)
assert(glreport'here')

	-- TODO also draw lightmap stuff here
	
	self.vao:unbind()
	self.vertexBufGPU:unbind()

	gl.glBindBuffer(gl.GL_ARRAY_BUFFER, oldBufferID)
	gl.glUseProgram(oldProgramID)
	gl.glBindVertexArray(oldVAOID)

	-- reset the vectors and store the last capacity
	self.vertexBufCPULastCapacity = self.vertexBufCPU.capacity
end

function Chunk:delete()
	if self.vertexBufGPU then
		self.vertexBufGPU:delete()
		self.vertexBufGPU = nil
	end
	if self.vao then
		self.vao:delete()
		self.vao = nil
	end
end

Chunk.__gc = Chunk.delete




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

	-- after any chunk goes dirty rebuild it, then rebuild the master list so I just have to do one copy into the draw buffer
	-- or TODO if I do use GPU resources then meh dont bother use a master list, right? cuz gpu multiple draws should be fast enough and an extra CPU copy would be slower right?
	self.vertexBufCPU = vector(Numo9Vertex)
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
	self.chunkVolume = self.sizeInChunks:volume()

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

	self.vertexBufCPU:resize(0)
	self.billboardXYZVoxels:resize(0)
	self.billboardXYVoxels:resize(0)

	for chunkIndex=0,self.chunkVolume-1 do
		self.chunks[chunkIndex]:rebuildMesh(app)
	end

	-- [[ now that all chunks have been rebuilt, rebuild our master list
	-- optional TODO if I switch to GPU then dont do this master list, just use individual GPU buffers
	for i=0,self.chunkVolume-1 do
		do
			local chunk = self.chunks[i]
			local srcVtxs = chunk.vertexBufCPU
			local srcLen = #srcVtxs

			local dstVtxs = self.vertexBufCPU
			local dstLen = #dstVtxs
			local writeOfs = dstLen

--DEBUG:assert.eq(srcVtxs.type, dstVtxs.type)
			dstVtxs:resize(dstLen + srcLen)
			local dstVtxPtr = dstVtxs.v + writeOfs
			ffi.copy(dstVtxPtr, srcVtxs.v, ffi.sizeof(srcVtxs.type) * srcLen)
		end

		do
			local chunk = self.chunks[i]
			local srcVtxs = chunk.billboardXYZVoxels
			local srcLen = #srcVtxs

			local dstVtxs = self.billboardXYZVoxels
			local dstLen = #dstVtxs
			local writeOfs = dstLen

--DEBUG:assert.eq(srcVtxs.type, dstVtxs.type)
			dstVtxs:resize(dstLen + srcLen)
			local dstVtxPtr = dstVtxs.v + writeOfs
			ffi.copy(dstVtxPtr, srcVtxs.v, ffi.sizeof(srcVtxs.type) * srcLen)
		end

		do
			local chunk = self.chunks[i]
			local srcVtxs = chunk.billboardXYVoxels
			local srcLen = #srcVtxs

			local dstVtxs = self.billboardXYVoxels
			local dstLen = #dstVtxs
			local writeOfs = dstLen

--DEBUG:assert.eq(srcVtxs.type, dstVtxs.type)
			dstVtxs:resize(dstLen + srcLen)
			local dstVtxPtr = dstVtxs.v + writeOfs
			ffi.copy(dstVtxPtr, srcVtxs.v, ffi.sizeof(srcVtxs.type) * srcLen)
		end
	end
	--]]
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

function BlobVoxelMap:drawMesh(app)
	local sceneObj = app.triBuf_sceneObj
	sceneObj.program:use()	-- wait, is it already bound?

	for i=0,self.chunkVolume-1 do
		self.chunks[i]:drawMesh(app)
	end

	-- rebind the old VAO
	sceneObj.vao:bind()
assert(glreport'here')
end

return BlobVoxelMap
