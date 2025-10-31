local ffi = require 'ffi'
local assert = require 'ext.assert'
local string = require 'ext.string'
local table = require 'ext.table'
local math = require 'ext.math'
local vector = require 'ffi.cpp.vector-lua'
local vec3i = require 'vec-ffi.vec3i'
local vec3f = require 'vec-ffi.vec3f'
local vec3d = require 'vec-ffi.vec3d'
local box3i = require 'vec-ffi.box3i'
local OBJLoader = require 'mesh.objloader'	-- has a lot of bloat, but is pretty robust for all .obj format possibilities ...

local numo9_rom = require 'numo9.rom'
local meshIndexType = numo9_rom.meshIndexType
local Vertex = numo9_rom.Vertex

local BlobDataAbs = require 'numo9.blob.dataabs'


local uint8_t_p = ffi.typeof'uint8_t*'
local int16_t = ffi.typeof'int16_t'
local Vertex_p = ffi.typeof('$*', Vertex)
local meshIndexPtrType = ffi.typeof('$*', meshIndexType)

--[[
mesh3D data
especially because I'm adding voxelmap next
mesh3D will hold...

struct {
	int16_t x, y, z;
	uint8_t u, v;
} Vertex;

uint16_t numVertexes
uint16_t numIndexes
Vertex vertexes[]
uint16_t indexes[]
--]]
local BlobMesh3D = BlobDataAbs:subclass()

BlobMesh3D.filenamePrefix = 'mesh3d'
BlobMesh3D.filenameSuffix = '.obj'

function BlobMesh3D:init(data)
	self.data = data or ''

	local minsize = 2 * ffi.sizeof(meshIndexType)	-- # vtxs, # indexes
	if #self.data < minsize then self.data = ('\0'):rep(minsize) end

	-- validate...
	local numVtxs = self:getNumVertexes()	-- maek sure its valid / asesrt-error if its not
	local numIndexes = self:getNumIndexes()
	local indexes = self:getIndexPtr()
	local vtxs = self:getVertexPtr()

	-- TODO rebuild all this if the RAM gets changed ...

	-- [[ cache tri list
	self.triList = vector(vec3i)	-- store our vtx index list here
	if numIndexes ~= 0 then
		for i=0,numIndexes-1 do
			assert.le(0, indexes[i])
			assert.lt(indexes[i], numVtxs)
		end
		for i=0,numIndexes-3,3 do
			self.triList:emplace_back():set(indexes[i], indexes[i+1], indexes[i+2])
		end
	else
		for i=0,numVtxs-3,3 do
			self.triList:emplace_back():set(i, i+1, i+2)
		end
	end
	--]]

	-- [[ cache surface normals
	local numo9_video = require 'numo9.video'
	local calcNormalForTri = numo9_video.calcNormalForTri
	local Numo9Vertex = numo9_video.Numo9Vertex
	self.normalList = vector(vec3f)
	assert.eq(
		self.normalList.type,
		ffi.typeof(select(2, table.find(Numo9Vertex.fields, nil, function(field)
			return field.name == 'normal'
		end)).type)
	)
	for ti=0,#self.triList-1 do
		local i,j,k = self.triList.v[ti]:unpack()
		local vi = vtxs + i
		local vj = vtxs + j
		local vk = vtxs + k
		local nx, ny, nz = calcNormalForTri(
			vi.x, vi.y, vi.z,
			vj.x, vj.y, vj.z,
			vk.x, vk.y, vk.z
		)
		self.normalList:emplace_back():set(nx, ny, nz)
	end
	--]]

	-- [[ here and TODO upon modification ...
	-- track which tris are on each side / can be occluded
	-- track which sides are fully covered in tris / will occlude
	local range = require 'ext.range'
	local trisPerSide = range(6):mapi(function(i) return table(), i-1 end)
	self.sideForTriIndex = {}
	for ti=0,#self.triList-1 do
		local i,j,k = self.triList.v[ti]:unpack()
		local bounds = box3i(
			vec3i(0x7fffffff, 0x7fffffff, 0x7fffffff),
			vec3i(-0x80000000, -0x80000000, -0x80000000))
		local v = vtxs+i bounds:stretch(vec3i(v.x, v.y, v.z))
		local v = vtxs+j bounds:stretch(vec3i(v.x, v.y, v.z))
		local v = vtxs+k bounds:stretch(vec3i(v.x, v.y, v.z))
		for axis=0,2 do
			local axis1 = (axis + 1) % 3
			local axis2 = (axis + 2) % 3
			for negflag=0,1 do
				local sign = 1 - 2 * negflag
				-- sideIndex is 0-5
				-- bit 0 = negative direction bit
				-- bits 1:2 = 0-2 for xyz, which direction the side is facing
				local sideIndex = bit.bor(negflag, bit.lshift(axis, 1))
				if bounds.min.s[axis] == sign * 16384
				and bounds.max.s[axis] == sign * 16384
				and -16384 <= bounds.min.s[axis1] and bounds.min.s[axis1] <= 16384
				and -16384 <= bounds.min.s[axis2] and bounds.min.s[axis2] <= 16384
				then
					-- TODO then our box is all within one side
--DEBUG:print('tri', ti, 'is on side', axis, sign)
					trisPerSide[sideIndex]:insert(ti)
					self.sideForTriIndex[ti] = sideIndex
					-- TODO check that the other two axii are *within* +-16384
					-- then last do a check for if the whole face is covered, i.e. sum of tri areas is 16384^2
				end
			end
		end
	end
	self.sidesOccluded = {}
	for sideIndex=0,5 do
		local tris = trisPerSide[sideIndex]
		local totalArea = 0
		for _,triIndex in ipairs(tris) do
			local i,j,k = self.triList.v[triIndex]:unpack()
			local vi, vj, vk = vtxs+i, vtxs+j, vtxs+k
			-- vec3i or vec3d? scale or no? scaled for now cuz i'm lazy
			local a = vec3d(vi.x, vi.y, vi.z) / 32768
			local b = vec3d(vj.x, vj.y, vj.z) / 32768
			local c = vec3d(vk.x, vk.y, vk.z) / 32768
			local len = (b - a):cross(c - b):norm()
			local area = math.abs(len * .5)
--DEBUG:print('tri', a, b, c, 'area', area)
			totalArea = totalArea + area
		end
--DEBUG:print('side', sideIndex,' has area', totalArea)
		local eps = 1e-3
		if totalArea >= 1 - eps then
--DEBUG:print('side', sideIndex, 'is fully covered')
			self.sidesOccluded[sideIndex] = true
		end
	end
	--]]
end

function BlobMesh3D:getNumVertexes()
	return ffi.cast(meshIndexPtrType, self:getPtr())[0]
end

function BlobMesh3D:getNumIndexes()
	return ffi.cast(meshIndexPtrType, self:getPtr())[1]
end

function BlobMesh3D:getVertexPtr()
	local vtxptr = ffi.cast(Vertex_p,
		self:getPtr()
		+ ffi.sizeof(meshIndexType) * 2	-- skip header
	)
	assert.le(0, ffi.cast(uint8_t_p, vtxptr + self:getNumVertexes()) - self:getPtr())
	assert.le(ffi.cast(uint8_t_p, vtxptr + self:getNumVertexes()) - self:getPtr(), #self.data)
	return vtxptr
end

function BlobMesh3D:getIndexPtr()
	local ptr = ffi.cast(uint8_t_p,
		self:getVertexPtr()
		+ self:getNumVertexes()
	) -- skip vertexes
	local indptr = ffi.cast(meshIndexPtrType, ptr)
	assert.le(0, ffi.cast(uint8_t_p, indptr + self:getNumIndexes()) - self:getPtr())
	assert.eq(ffi.cast(uint8_t_p, indptr + self:getNumIndexes()) - self:getPtr(), #self.data)
	return indptr
end

function BlobMesh3D:saveFile(filepath, blobIndex, blobs)
	--[[ use mesh library objloader
	local mesh = OBJLoader():save(filepath)
	--]]
	-- [[ save ourselves, so we can specify higher precision (TODO add this feature to OBJLoader)
	-- x / 2^8 <=> needs 8 digits of precision
	-- but (x + .5) / 2^8 <=> needs 9 digits of precision
	local o = table()
	local vtxs = self:getVertexPtr()
	local numVtxs = self:getNumVertexes()
	for i=0,numVtxs-1 do
		local v = vtxs + i
		o:insert('v '..table{v.x, v.y, v.z}:mapi(function(x)
			return ('%.9f'):format((x + .5) / 256)
		end):concat' ')
	end
	for i=0,numVtxs-1 do
		local v = vtxs + i
		o:insert('vt '..table{v.u, v.v}:mapi(function(x)
			return ('%.9f'):format((x + .5) / 256)
		end):concat' ')
	end
	for ti=0,#self.triList-1 do
		local i,j,k = self.triList.v[ti]:unpack()
		o:insert('f '..(i+1)..' '..(j+1)..' '..(k+1))
	end
	filepath:write(o:concat'\n'..'\n')
	--]]
end

-- static method
function BlobMesh3D:loadFile(filepath, basepath, blobIndex)
	-- [[ bloated, and lower res (TODO change OBJLoader to double instead of float, though if I'm saving vtxs in u16 then float32 can hold all its precision with its 23 mantissa bits)
	local mesh = OBJLoader():load(tostring(filepath))
	local vs = table()
	local vts = table()
	for i=0,#mesh.vtxs-1 do
		local vtx = mesh.vtxs.v + i
		vs:insert{
			math.clamp(math.floor(vtx.pos.x * 256), -32768, 32767),
			math.clamp(math.floor(vtx.pos.y * 256), -32768, 32767),
			math.clamp(math.floor(vtx.pos.z * 256), -32768, 32767)
		}
		vts:insert{
			math.clamp(math.floor(vtx.texcoord.x * 256), 0, 255),
			math.clamp(math.floor(vtx.texcoord.y * 256), 0, 255)
		}
	end
	local is = table()
	for i=0,#mesh.triIndexes-1 do
		is:insert(mesh.triIndexes.v[i]+1)
	end
	--]]
	--[[ more lightweight loader
	local vs = table()
	local vts = table()
	local is = table()
	for line in io.lines(tostring(filepath)) do
		if not line:match'^%s*#' then
			local words = string.split(string.trim(line), '%s+')
			local lineType = words:remove(1):lower()
			if lineType == 'v' then
				assert.ge(#words, 2)
				vs:insert{
					-- TODO I wasn't adding .5 before floor() but should I?
					math.clamp(math.floor((tonumber(words[1]) or 0) * 256), -32768, 32767),
					math.clamp(math.floor((tonumber(words[2]) or 0) * 256), -32768, 32767),
					math.clamp(math.floor((tonumber(words[3]) or 0) * 256), -32768, 32767),
				}
			elseif lineType == 'vt' then
				assert.ge(#words, 2)
				vts:insert{
					-- clamp so .obj texcoords [0,1] still map to [0,255] correctly
					-- TODO I wasn't adding .5 before floor() but should I?
					math.clamp(math.floor((tonumber(words[1]) or 0) * 256), 0, 255),
					math.clamp(math.floor((tonumber(words[2]) or 0) * 256), 0, 255)
				}
			elseif lineType == 'f' then
				assert(not line:find'/', "sorry I don't support faces with /'s in them, go delete that trash right now.")
				assert.len(words, 3, "sorry I only support triangles")
				for i=1,3 do
					is:insert((assert(tonumber(words[i]))))
				end
			elseif lineType == 'usemtl' then
			elseif lineType == 'mtllib' then
			else
				print('ignoring lineType', lineType)
			end
		end
	end
	--]]

	local o = vector(int16_t)
	o:emplace_back()[0] = #vs
	o:emplace_back()[0] = #is
	assert.eq(#vs, #vts, "your vertexes and texcoords must match.  Sorry I don't do any splitting and re-merging of geometry here")
	for i=1,#vs do
		local v = assert.index(vs, i)
		local vt = assert.index(vts, i)
		o:emplace_back()[0] = v[1]
		o:emplace_back()[0] = v[2]
		o:emplace_back()[0] = v[3]
		local uv = ffi.cast(uint8_t_p, o:emplace_back())
		uv[0] = vt[1]
		uv[1] = vt[2]
	end

	local allInARow = true
	for i,j in ipairs(is) do
		if i ~= j then
			allInARow = false
			break
		end
	end
	-- if indexes are sequential then don't save them
	if allInARow then
		o.v[1] = 0	-- clear index count
	else
		for _,i in ipairs(is) do
			o:emplace_back()[0] = i-1	-- convert from 1-based to 0-based
		end
	end
	return self.class(o:dataToStr())
end

return BlobMesh3D
