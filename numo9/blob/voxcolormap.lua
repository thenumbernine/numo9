require 'ext.gc'	-- make sure luajit can __gc lua-tables
local ffi = require 'ffi'
local assert = require 'ext.assert'
local class = require 'ext.class'
local table = require 'ext.table'
local vector = require 'stl.vector-lua'
local vec3i = require 'vec-ffi.vec3i'
local vec3f = require 'vec-ffi.vec3f'
local vec4f = require 'vec-ffi.vec4f'
local gl = require 'gl'
local GLArrayBuffer = require 'gl.arraybuffer'
local GLVertexArray = require 'gl.vertexarray'
local GLAttribute = require 'gl.attribute'

local Blob = require 'numo9.blob.blob'

local numo9_rom = require 'numo9.rom'
local voxColorMapEmptyValue = numo9_rom.voxColorMapEmptyValue
local voxColorMapSizeType = numo9_rom.voxColorMapSizeType
local VoxColor = numo9_rom.VoxColor

local numo9_video = require 'numo9.video'
local Numo9Vertex = numo9_video.Numo9Vertex
local vec3to3 = numo9_video.vec3to3
local vecdir3to3 = numo9_video.vecdir3to3
local shiftDownAndRoundUp = numo9_video.shiftDownAndRoundUp


local int32_t = ffi.typeof'int32_t'


-- Chunk needs to see BlobVoxColorMap
local BlobVoxColorMap

local Chunk = class()

-- static member
Chunk.bitsize = vec3i(5, 5, 5)
Chunk.size = Chunk.bitsize:map(function(x) return 1 << x end)
Chunk.bitmask = Chunk.size - 1
Chunk.volume = Chunk.size:volume()	-- same as 1 << bitsize:sum() (if i had a :sum() function...)

local voxColorMapSizeType_p = ffi.typeof('$*', voxColorMapSizeType)
local VoxColor_p = ffi.typeof('$*', VoxColor)


function Chunk:init(args)
	local owner = assert(args.owner)
	self.owner = owner

	-- chunk position, in Chunk.size units
	self.chunkPos = vec3i((assert.index(args, 'chunkPos')))

	local volume = self.volume
	self.vertexBufCPU = vector(Numo9Vertex)

	-- hmm, how to skip the GPU side for n9a?
	if BlobVoxColorMap.skipGPU then return end

	-- oh yeah, archive uses this class, maybe I don't want to build the GLArrayBuffer in the ctor after all?
	-- but I think same argument for the blob/image classes, so meh leave it here.
	self.vertexBufGPU = GLArrayBuffer{
		size = ffi.sizeof(Numo9Vertex) * self.vertexBufCPU.capacity,
		count = self.vertexBufCPU.capacity,
		data = self.vertexBufCPU.v,
		usage = gl.GL_DYNAMIC_DRAW,
	}:unbind()

	-- says the mesh needs to be rebuilt
	self.dirtyCPU = true
end

local identBox = vec4f(0,0,1,1)
local sideInfos = {
	[0] = {
		[-1] = {
			normal = vec3f(-1,0,0),
			tangent = vec3f(0,-1,0),
			{
				vec3i(0, 1, 0),
				vec3i(0, 0, 0),
				vec3i(0, 0, 1),
			},
			{
				vec3i(0, 0, 1),
				vec3i(0, 1, 1),
				vec3i(0, 1, 0),
			},
		},
		[1] = {
			normal = vec3f(1,0,0),
			tangent = vec3f(0,1,0),
			{
				vec3i(1, 1, 0),
				vec3i(1, 1, 1),
				vec3i(1, 0, 1),
			},
			{
				vec3i(1, 0, 1),
				vec3i(1, 0, 0),
				vec3i(1, 1, 0),
			},
		},
	},
	[1] = {
		[-1] = {
			normal = vec3f(0,-1,0),
			tangent = vec3f(0,0,-1),
			{
				vec3i(0, 0, 1),
				vec3i(0, 0, 0),
				vec3i(1, 0, 0),
			},
			{
				vec3i(1, 0, 0),
				vec3i(1, 0, 1),
				vec3i(0, 0, 1),
			},
		},
		[1] = {
			normal = vec3f(0,1,0),
			tangent = vec3f(0,0,1),
			{
				vec3i(0, 1, 1),
				vec3i(1, 1, 1),
				vec3i(1, 1, 0),
			},
			{
				vec3i(1, 1, 0),
				vec3i(0, 1, 0),
				vec3i(0, 1, 1),
			},
		},
	},
	[2] = {
		[-1] = {
			normal = vec3f(0,0,-1),
			tangent = vec3f(-1,0,0),
			{
				vec3i(0, 0, 0),
				vec3i(0, 1, 0),
				vec3i(1, 1, 0),
			},
			{
				vec3i(1, 1, 0),
				vec3i(1, 0, 0),
				vec3i(0, 0, 0),
			},
		},
		[1] = {
			normal = vec3f(0,0,1),
			tangent = vec3f(1,0,0),
			{
				vec3i(0, 0, 1),
				vec3i(1, 0, 1),
				vec3i(1, 1, 1),
			},
			{
				vec3i(1, 1, 1),
				vec3i(0, 1, 1),
				vec3i(0, 0, 1),
			},
		},
	},
}

function Chunk:rebuildMesh(app)
	if not self.dirtyCPU then return end
	self.dirtyCPU = false

	local vertexBufCPU = self.vertexBufCPU
	vertexBufCPU:resize(0)

	local voxelmapSize = self.owner:getVoxelSize()

	-- which to build this off of?
	-- RAMPtr since thats what AppVideo:drawVoxelMap() uses
	-- but that means it wont be present upon init() ...
	local voxels = assert(self.owner:getVoxelDataRAMPtr(), 'BlobVoxColorMap rebuildMesh .ramptr missing')
	local occludedCount = 0

	local ci, cj, ck = self.chunkPos:unpack()
--DEBUG:print('chunk', ci, cj, ck)

	local nbhd = vec3i()
	for k=0,Chunk.size.z-1 do
		local vk = k | (ck << Chunk.bitsize.z)
		if vk < voxelmapSize.z then
			for j=0,Chunk.size.y-1 do
				local vj = j | (cj << Chunk.bitsize.y)
				if vj < voxelmapSize.y then

					-- traverse cols
					local vptr = voxels + ((ci << Chunk.bitsize.x) + voxelmapSize.x * (vj + voxelmapSize.y * vk))
					for i=0,Chunk.size.x-1 do
						local vi = i | (ci << Chunk.bitsize.x)
--DEBUG:print('cpos', ci, cj, ck, 'pos', i, j, k, 'vpos', vi, vj, vk)

						-- chunks can extend beyond the voxelmap when it isnt chunk-aligned in size
						if vi >= voxelmapSize.x then break end

						if vptr[0] ~= voxColorMapEmptyValue then
							-- resize first then offest back in case we get a resize ...
							vertexBufCPU:reserve(#vertexBufCPU + 24)

							for axis=0,2 do
								for sign=-1,1 do
									local sideInfo = sideInfos[axis][sign]

									-- see if this face is aligned to an AABB
									-- see if its neighbors face is occluding on that AABB
									-- if both are true then skip
									local occluded

									nbhd.x, nbhd.y, nbhd.z = vi,vj,vk
									nbhd.s[axis] = nbhd.s[axis] + sign
									if nbhd.x >= 0 and nbhd.x < voxelmapSize.x
									and nbhd.y >= 0 and nbhd.y < voxelmapSize.y
									and nbhd.z >= 0 and nbhd.z < voxelmapSize.z
									then
										-- if it occludes the opposite side then skip this side
										local nbhdVox = voxels[nbhd.x + voxelmapSize.x * (nbhd.y + voxelmapSize.y * nbhd.z)]
										occluded = nbhdVox ~= voxColorMapEmptyValue
									end

									if occluded then
										occludedCount = occludedCount + 1
									else
										local axis2 = (axis+1) % 3
										for _,tri in ipairs(sideInfo) do
											local srcv = tri[1]
											local dstVtx1 = vertexBufCPU:emplace_back()
											dstVtx1.vertex.x, dstVtx1.vertex.y, dstVtx1.vertex.z = vi + srcv.x, vj + srcv.y, vk + srcv.z
											dstVtx1.texcoord.x = 0
											dstVtx1.texcoord.y = 0
											dstVtx1.normal = sideInfo.normal
											dstVtx1.tangent = sideInfo.tangent
											dstVtx1.extra.x = vptr[0] << 8
											dstVtx1.box = identBox

											local srcv = tri[2]
											local dstVtx2 = vertexBufCPU:emplace_back()
											dstVtx2.vertex.x, dstVtx2.vertex.y, dstVtx2.vertex.z = vi + srcv.x, vj + srcv.y, vk + srcv.z
											dstVtx2.texcoord.x = 1
											dstVtx2.texcoord.y = 0
											dstVtx2.normal = sideInfo.normal
											dstVtx2.tangent = sideInfo.tangent
											dstVtx2.extra.x = vptr[0] << 8
											dstVtx2.box = identBox

											local srcv = tri[3]
											local dstVtx3 = vertexBufCPU:emplace_back()
											dstVtx3.vertex.x, dstVtx3.vertex.y, dstVtx3.vertex.z = vi + srcv.x, vj + srcv.y, vk + srcv.z
											dstVtx3.texcoord.x = 0
											dstVtx3.texcoord.y = 1
											dstVtx3.normal = sideInfo.normal
											dstVtx3.tangent = sideInfo.tangent
											dstVtx3.extra.x = vptr[0] << 8
											dstVtx3.box = identBox
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
--DEBUG:print('created', #vertexBufCPU/3, 'tris')
--DEBUG:print('occluded', occludedCount, 'tris')

	local vertexBufGPU = self.vertexBufGPU
	vertexBufGPU:bind()
	if vertexBufCPU.capacity ~= vertexBufCPU.numo9LastCapacity then
		vertexBufGPU:setData{
			data = vertexBufCPU.v,
			count = vertexBufCPU.capacity,
			size = ffi.sizeof(Numo9Vertex) * vertexBufCPU.capacity,
		}
	else
		vertexBufGPU
			:updateData(0,
				--vertexBufCPU:getNumBytes())
				ffi.sizeof(Numo9Vertex) * vertexBufCPU.capacity)
	end
	vertexBufGPU:unbind()
end

-- needs triBuf_prepAddTri to be called beforehand
function Chunk:drawMesh(app)
	local vertexBufCPU = self.vertexBufCPU
	local vertexBufGPU = self.vertexBufGPU
	if #vertexBufCPU == 0 then return end

	local sceneObj = app.triBuf_sceneObj
	if sceneObj.program ~= self.vaoProgram then
		if self.vao then
			self.vao:delete()
		end
		-- init this just like GLSceneObject builds its vao, with program = sceneObj ...
		self.vao = GLVertexArray{
			program = sceneObj,
			attrs = sceneObj.attrs,
		}

		self.vao:bind()
		for _,attr in ipairs(self.vao.attrs) do
			attr.buffer = vertexBufGPU
			attr:enableAndSet()
		end
		self.vaoProgram = sceneObj.program
	else
		self.vao:bind()
	end

	app.vertexBufCPU = vertexBufCPU
	app.vertexBufGPU = vertexBufGPU
	sceneObj.vao = self.vao

	-- The buffers are currently pointed at this Chunk's buffers,
	-- not the dynamic per-frame buffer, so don't clear them.
	app:triBuf_flushButDontClear()
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
uint16_t width, height, depth;
uint8_t data[width*height*depth];
--]]
BlobVoxColorMap = Blob:subclass()

BlobVoxColorMap.filenamePrefix = 'voxcolormap'
BlobVoxColorMap.filenameSuffix = '.vox'

function BlobVoxColorMap:init(data)
	self.vec = vector(VoxColor)
	local minsize = ffi.sizeof(VoxColor) * 6
	if not data or #data < minsize then
		self.vec:resize(7)
		self:getWidthPtr()[0] = 1
		self:getHeightPtr()[0] = 1
		self:getDepthPtr()[0] = 1
		self.vec.v[6] = voxColorMapEmptyValue
	else
		self.vec:resize(#data)
		ffi.copy(self.vec.v, data, #data)
	end

	-- validate that the header at least works
	assert.gt(self:getWidth(), 0)
	assert.gt(self:getHeight(), 0)
	assert.gt(self:getDepth(), 0)


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
	self.stepInChunks = vec3i(1, self.sizeInChunks.x, self.sizeInChunks.x * self.sizeInChunks.y)
	self.chunkVolume = self.sizeInChunks:volume()

	-- create the chunks
	do
		local chunkIndex = 0
		for ck=0,self.sizeInChunks.z-1 do
			for cj=0,self.sizeInChunks.y-1 do
				for ci=0,self.sizeInChunks.x-1 do
					local chunk = Chunk{
						owner = self,
						chunkPos = vec3i(ci,cj,ck),
					}
					self.chunks[chunkIndex] = chunk

					chunkIndex = chunkIndex + 1
				end
			end
		end
	end
end

function BlobVoxColorMap:getPtr()
	return self.vec.v+0
end

function BlobVoxColorMap:getSize()
	return self.vec:getNumBytes()
end

-- get size by the blob, not the RAM...
function BlobVoxColorMap:getWidthPtr()
	return ffi.cast(voxColorMapSizeType_p, self.vec.v+0)
end
function BlobVoxColorMap:getWidth()
	return self:getWidthPtr()[0]
end

function BlobVoxColorMap:getHeightPtr()
	return ffi.cast(voxColorMapSizeType_p, self.vec.v+2)
end
function BlobVoxColorMap:getHeight()
	return self:getHeightPtr()[0]
end

function BlobVoxColorMap:getDepthPtr()
	return ffi.cast(voxColorMapSizeType_p, self.vec.v+4)
end
function BlobVoxColorMap:getDepth()
	return self:getDepthPtr()[0]
end

function BlobVoxColorMap:getVoxelSize()
	return vec3i(self:getWidth(), self:getHeight(), self:getDepth())
end

function BlobVoxColorMap:getVoxelSizeInChunks()
	local size = self:getVoxelSize()
	return vec3i(
		shiftDownAndRoundUp(size.x, Chunk.bitsize.x),
		shiftDownAndRoundUp(size.y, Chunk.bitsize.y),
		shiftDownAndRoundUp(size.z, Chunk.bitsize.z))
end

function BlobVoxColorMap:getVoxelDataBlobPtr()
	return self.vec.v + 6
end

function BlobVoxColorMap:getVoxelDataRAMPtr()
	return ffi.cast(VoxColor_p, self.ramptr + ffi.sizeof(voxColorMapSizeType) * 3)
end

function BlobVoxColorMap:getVoxelDataAddr()
	return self.addr + ffi.sizeof(voxColorMapSizeType) * 3
end

function BlobVoxColorMap:getVoxelBlobPtr(x,y,z)
	x = math.floor(x)
	y = math.floor(y)
	z = math.floor(z)
	if x < 0 or x >= self:getWidth()
	or y < 0 or y >= self:getHeight()
	or z < 0 or z >= self:getDepth()
	then return end
	return self:getVoxelDataBlobPtr() + x + self:getWidth() * (y + self:getHeight() * z)
end

function BlobVoxColorMap:getVoxelAddr(x,y,z)
	x = math.floor(x)
	y = math.floor(y)
	z = math.floor(z)
	if x < 0 or x >= self:getWidth()
	or y < 0 or y >= self:getHeight()
	or z < 0 or z >= self:getDepth()
	then return end
	return self:getVoxelDataAddr() + (x + self:getWidth() * (y + self:getHeight() * z))
end

--[[
app = used to search list of mesh3d blobs
--]]
function BlobVoxColorMap:rebuildMesh(app)
	if not self.dirtyCPU then return end
	self.dirtyCPU = false

	for chunkIndex=0,self.chunkVolume-1 do
		self.chunks[chunkIndex]:rebuildMesh(app)
	end
end

local warnedAboutTouchingSize

-- touchAddrStart, touchAddrEnd are inclusive
function BlobVoxColorMap:onTouchRAM(touchAddrStart, touchAddrEnd, app)
	--if (0, 2) touches-inclusive (addr, addrend) then
	local voxelStartAddr = self.addr + ffi.sizeof(voxColorMapSizeType) * 3
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

	local bitsizex, bitsizey, bitsizez = Chunk.bitsize.x, Chunk.bitsize.y, Chunk.bitsize.z
	local bitmaskx, bitmasky, bitmaskz = Chunk.bitmask.x, Chunk.bitmask.y, Chunk.bitmask.z
	local width, height, depth = self:getWidth(), self:getHeight(), self:getDepth()
	local chunksSizex, chunksSizey, chunksSizez = self.sizeInChunks.x, self.sizeInChunks.y, self.sizeInChunks.z
	local chunksStepx, chunksStepy, chunksStepz = self.stepInChunks.x, self.stepInChunks.y, self.stepInChunks.z

	-- TODO since data is stored [z][y][x] across the whole voxelmap, i could look for rows that touch
	-- this is me being lazy though
	for touchAddr=tonumber(touchAddrStart),tonumber(touchAddrEnd) do
		-- get the chunk index
		local voxelIndex = ffi.cast(int32_t, touchAddr - voxelStartAddr)
		local tmp = voxelIndex
		local vi = tmp % width
		tmp = ffi.cast(int32_t, tmp / width)
		local vj = tmp % height
		tmp = ffi.cast(int32_t, tmp / height)
		local vk = tmp

		local ci = vi >> bitsizex
		local cj = vj >> bitsizey
		local ck = vk >> bitsizez

		local chunkIndex = tonumber(chunksStepx * ci + chunksStepy * cj + chunksStepz * ck)
		self.chunks[chunkIndex].dirtyCPU = true

		-- set each side's voxel's chunk to dirty as well
		if vi & bitmaskx == 0
		and ci - 1 >= 0
		then
			self.chunks[chunkIndex - chunksStepx].dirtyCPU = true
		end
		if vi & bitmaskx == bitmaskx
		and ci + 1 < chunksSizex
		then
			self.chunks[chunkIndex + chunksStepx].dirtyCPU = true
		end
		if vj & bitmasky == 0
		and cj - 1 >= 0
		then
			local chunkNbhdIndex = chunkIndex - chunksStepy
			self.chunks[chunkNbhdIndex ].dirtyCPU = true
		end
		if vj & bitmasky == bitmasky
		and cj + 1 < chunksSizey
		then
			self.chunks[chunkIndex + chunksStepy].dirtyCPU = true
		end
		if vk & bitmaskz == 0
		and ck - 1 >= 0
		then
			self.chunks[chunkIndex + chunksStepz].dirtyCPU = true
		end
		if vk & bitmaskz == bitmaskz
		and ck + 1 < chunksSizez
		then
			self.chunks[chunkIndex - chunksStepz].dirtyCPU = true
		end

		self.dirtyCPU = true
	end
end

function BlobVoxColorMap:onVoxelmapCullSideFlagsChange()
	self.dirtyCPU = true
	for i=0,self.chunkVolume-1 do
		-- TODO compare old bits vs new bits, only flag the chunks on the sides that changed.
		self.chunks[i].dirtyCPU = true
	end
end

function BlobVoxColorMap:drawMesh(app)
	local sceneObj = app.triBuf_sceneObj

	local pushVAO = sceneObj.vao
	local pushVertexBufCPU = app.vertexBufCPU
	local pushVertexBufGPU = app.vertexBufGPU

	for i=0,self.chunkVolume-1 do
		self.chunks[i]:drawMesh(app)
	end

	-- restore old buffers
	app.vertexBufCPU = pushVertexBufCPU
	app.vertexBufGPU = pushVertexBufGPU

	sceneObj.vao = pushVAO
end

return BlobVoxColorMap
