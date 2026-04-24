--[[
TODO tempting to store an .obj / Mesh per model
since I'm using them for loading and unloading
and since my mesh lib has all the nice mesh operations anwyays
--]]
local ffi = require 'ffi'
local table = require 'ext.table'
local string = require 'ext.string'
local range = require 'ext.range'
local assert = require 'ext.assert'
local math = require 'ext.math'
local vec2i = require 'vec-ffi.vec2i'
local vec2d = require 'vec-ffi.vec2d'
local vec3d = require 'vec-ffi.vec3d'
local quatd = require 'vec-ffi.quatd'
local vec4x4fcol = require 'numo9.vec4x4fcol'
local gl = require 'gl'

local BlobMesh3D = require 'numo9.blob.mesh3d'
local Orbit = require 'numo9.ui.orbit'
local Undo = require 'numo9.ui.undo'
local TileSelect = require 'numo9.ui.tilesel'

local numo9_rom = require 'numo9.rom'
local tileSizeInBits = numo9_rom.tileSizeInBits
local Vertex = numo9_rom.Vertex
local Vertex_p = ffi.typeof('$*', Vertex)

-- truncate stack, useful for ffi ctype ctors that can't have extra args
local function trunc(i, ...)
	if i <= 0 then return end
	return ..., trunc(i-1, select(2, ...))
end
local function trunc2(x, y) return x, y end
local function trunc3(x, y, z) return x, y, z end

local EditMesh3D = require 'numo9.ui':subclass()

function EditMesh3D:init(args)
	EditMesh3D.super.init(self, args)

	self.undo = Undo{
		get = function()
			local binstr =  self.app.blobs.mesh3d[self.mesh3DBlobIndex+1]:toBinStr()
			return {
				data = binstr,
			}
		end,
		changed = function(entry)
			return entry.data ~= self.app.blobs.mesh3d[self.mesh3DBlobIndex+1]:toBinStr()
		end,
	}

	self:onCartLoad()
end

function EditMesh3D:onCartLoad()
	self.mesh3DBlobIndex = 0
	self.sheetBlobIndex = 0
	self.paletteBlobIndex = 0

	self.drawFaces = true
	self.wireframe = true
	self.menuUseCullFace = 0	-- 0 = no, 1 = back, 2 = front
	self.drawNormals = false
	self.editTexCoords = false

	self.tileSel = TileSelect{
		edit = self,
		getMeshIndex = function(self)
			return self.edit.mesh3DBlobIndex
		end,
	}
	self.tileSel.pos.x = 2	-- initialize to one 16x16 past the 0,0 tile (which is very often clear)

	self.orbit = Orbit(self.app)

	self:resetSelection()
end

function EditMesh3D:resetSelection()
	self.mouseoverVertexIndexSet = {}	-- keys are 0-based vertex indexes
	self.selectedVertexIndexSet = {}	-- keys are 0-based vertex indexes

	self.selectedEdges = table()	-- table of vec2i's of 0-based index-of-indexes between two edges
	self.selectedTriIndexSet = {}		-- keys are 0-based triangle indexes (so 0,1,2 , not index-array values which are 0,3,6)
	self.tileSel.selectedTriIndexSet = self.selectedTriIndexSet

	self.mouseoverEdges = table()
	self.mouseoverTri = {}

	self.axisFlags = {}
	self.meshEditMode = nil			-- translate rotate scale
	self.meshEditForm = 'vertexes'	-- vertexes edges tris

	self.vtxOrig = table()					-- 1-based-index table-of-Vertex's to store original vertex before translate/rotate/scale edit operation

	self.totalTranslation = vec3d()			-- total translation since translate start, in world coordinates
	self.totalScreenTranslate = vec2d()		-- total translation since scale start, in screen coordinates.  TODO track in world coords and project to plane of vtxs
	self.totalScale = 1						-- total scale, calculated by self.totalScreenTranslate
	self.rotateMouseScreenDownPos = vec2d()	-- rotation mouse down screen coordinates relative to center

	self.undo:clear()
end


-- handy functions for indexed vs non-indexed meshes:
function EditMesh3D:getNumIndexes()
	local mesh3DBlob = assert.index(self.app.blobs.mesh3d, self.mesh3DBlobIndex+1)
	local numVtxs = mesh3DBlob:getNumVertexes()
	local numIndexes = mesh3DBlob:getNumIndexes()

	return numIndexes == 0 and numVtxs or numIndexes
end
function EditMesh3D:getIndex(i)	-- 0-based, returns index in 0..n-1 list if no index list is present, or from index list if it is present
	local mesh3DBlob = assert.index(self.app.blobs.mesh3d, self.mesh3DBlobIndex+1)
	local numVtxs = mesh3DBlob:getNumVertexes()
	local numIndexes = mesh3DBlob:getNumIndexes()
	local vtxs = mesh3DBlob:getVertexPtr()
	local inds = mesh3DBlob:getIndexPtr()

	local ii
	if numIndexes == 0 then
		ii = i
	else
		assert.le(0, i)
		assert.lt(i, numIndexes)
		ii = inds[i]
	end
	assert.le(0, ii)
	assert.lt(ii, numVtxs)
	return ii
end
function EditMesh3D:getVtxIndPtr(i)
	local mesh3DBlob = assert.index(self.app.blobs.mesh3d, self.mesh3DBlobIndex+1)
	local vtxs = mesh3DBlob:getVertexPtr()
	return vtxs + self:getIndex(i)
end



-- return a table-of-Vertex's, distinctly cloning them from the original, no ref copies
function EditMesh3D:getMeshVertexList()
	local mesh3DBlob = assert.index(self.app.blobs.mesh3d, self.mesh3DBlobIndex+1)
	local numVtxs = mesh3DBlob:getNumVertexes()
	local vtxs = mesh3DBlob:getVertexPtr()

	local vertexes = table()
	for i=0,numVtxs-1 do
		vertexes:insert(Vertex(vtxs[i]))
	end
	return vertexes
end
-- return tri list a table-of 3-refs-to-Vertex-list
-- converts from indexes to refs for you
function EditMesh3D:getMeshVtxAndTriList()
	local vertexes = self:getMeshVertexList()
	local tris = table()
	assert.eq(self:getNumIndexes() % 3, 0)
	for i=0,self:getNumIndexes()-1,3 do
		local triVtxRefs = table()
		for j=0,2 do
			triVtxRefs[1+j] = assert.index(vertexes, 1+self:getIndex(i+j))
		end
		tris:insert(triVtxRefs)
	end
	return vertexes, tris
end


function EditMesh3D:update()
	local app = self.app
	local orbit = self.orbit
	local fwd = -orbit.angle:zAxis()

	local handled = EditMesh3D.super.update(self)

	local mouseULX, mouseULY = app.ram.mousePos:unpack()
	local lastMouseULX, lastMouseULY = app.ram.lastMousePos:unpack()


	app:matMenuReset()
	--self:guiSetClipRect(-1000, 16, 3000, 240)


	local mouseX, mouseY = app:invTransform(mouseULX, mouseULY)
	local lastMouseX, lastMouseY = app:invTransform(lastMouseULX, lastMouseULY)

	local shift = app:key'lshift' or app:key'rshift'

	local mesh3DBlob = app.blobs.mesh3d[self.mesh3DBlobIndex+1]
	local numVtxs
	local numIndexes
	local vtxs
	local inds


	local function refreshSelection(skipEdges, skipTris)
		-- TODO we could do calcCOM here isntead of when we start to do a translate/rotate/scale ...
		if not skipEdges then
			self.selectedEdges = table()	-- table of pairs of 0-based indexes between two edges
		end
		if not skipTris then
			self.selectedTriIndexSet = {}
			self.tileSel.selectedTriIndexSet = self.selectedTriIndexSet
		end

		for ti=0,self:getNumIndexes()/3-1 do
			if not skipEdges then
				for j=0,2 do
					local i1 = 3*ti+j
					local i2 = 3*ti+((j+1)%3)
					if self.selectedVertexIndexSet[self:getIndex(i1)]
					and self.selectedVertexIndexSet[self:getIndex(i2)]
					then
						self.selectedEdges:insert(vec2i(table{i1, i2}:sort():unpack()))
					end
				end
			end
			if not skipTris then
				if self.selectedVertexIndexSet[self:getIndex(3*ti)]
				and self.selectedVertexIndexSet[self:getIndex(3*ti+1)]
				and self.selectedVertexIndexSet[self:getIndex(3*ti+2)]
				then
					self.selectedTriIndexSet[ti] = true
				end
			end
		end
	end
	local function calcSelVtxCOM()
		self.selVtxCOM = vec3d()
		self.selTexCoordCOM = vec2d()
		local count = 0
		for i in pairs(self.selectedVertexIndexSet) do
			if i >= 0 and i < numVtxs then
				local v = vtxs + i
				self.selVtxCOM = self.selVtxCOM + vec3d(v.x, v.y, v.z)
				self.selTexCoordCOM = self.selTexCoordCOM + vec2d(v.u, v.v)
				count = count + 1
			end
		end
		if count == 0 then
			self.meshEditMode = nil
		else
			self.selVtxCOM = self.selVtxCOM / count
			self.selTexCoordCOM = self.selTexCoordCOM / count
		end
	end

	local function setVtxEditPos()
		self.vtxOrig = self:getMeshVertexList()
	end
	local function resetVtxEditPos()
		for i=0,numVtxs-1 do
			local v = vtxs + i
			local orig = self.vtxOrig[1+i]
			-- can I use ffi.copy here?
			v.x, v.y, v.z, v.u, v.v = orig.x, orig.y, orig.z, orig.u, orig.v
		end
	end


	if mesh3DBlob then
		numVtxs = mesh3DBlob:getNumVertexes()
		vtxs = mesh3DBlob:getVertexPtr()
		inds = mesh3DBlob:getIndexPtr()
	end


	local function applyMeshEditMode()
		local usedx = self.axisFlags.x
		local usedy = self.axisFlags.y
		local usedz = self.axisFlags.z
		-- none set == all set
		if next(self.axisFlags) == nil then
			usedx, usedy, usedz = true, true, true
		end

		for i in pairs(self.selectedVertexIndexSet) do
			if i >= 0 and i < numVtxs then
				local v = vtxs + i
				local orig = self.vtxOrig[1+i]
				if self.meshEditMode == 'translate' then
					if not self.editTexCoords then
						v.x, v.y, v.z = orig.x, orig.y, orig.z
						if usedx then v.x = v.x + self.totalTranslation.x end
						if usedy then v.y = v.y + self.totalTranslation.y end
						if usedz then v.z = v.z + self.totalTranslation.z end
					else
						-- TODO TODO TODO bumpmapping-like, construct a basis in uv coords and transform the mouse movement into texcoord space
						v.u, v.v = orig.u, orig.v
						if usedx then v.u = tonumber(v.u) - math.round(self.totalTranslation.x / 256) end
						if usedy then v.v = tonumber(v.v) - math.round(self.totalTranslation.y / 256) end
					end
				elseif self.meshEditMode == 'scale' then
					if not self.editTexCoords then
						v.x, v.y, v.z = orig.x, orig.y, orig.z
						if usedx then v.x = (v.x - self.selVtxCOM.x) * self.totalScale + self.selVtxCOM.x end
						if usedy then v.y = (v.y - self.selVtxCOM.y) * self.totalScale + self.selVtxCOM.y end
						if usedz then v.z = (v.z - self.selVtxCOM.z) * self.totalScale + self.selVtxCOM.z end
					else
						v.u, v.v = orig.u, orig.v
						if usedx then v.u = (tonumber(v.u) - self.selTexCoordCOM.x) * self.totalScale + self.selTexCoordCOM.x end
						if usedy then v.v = (tonumber(v.v) - self.selTexCoordCOM.y) * self.totalScale + self.selTexCoordCOM.y end
					end
				elseif self.meshEditMode == 'rotate' then
					if not self.editTexCoords then
						local q = quatd():fromAngleAxis(
							self.screenRotateAngle.x,
							self.screenRotateAngle.y,
							self.screenRotateAngle.z,
							self.screenRotateAngle.w
						)
						local pos = vec3d(orig.x, orig.y, orig.z) - self.selVtxCOM
						pos = q:rotate(pos)
						pos = pos + self.selVtxCOM
						v.x, v.y, v.z = pos.x, pos.y, pos.z
					else
						local cosTheta = math.cos(math.rad(self.screenRotateAngle.w))
						local sinTheta = math.sin(math.rad(self.screenRotateAngle.w))
						local pos = vec2d(orig.u, orig.v) - self.selTexCoordCOM
						pos = vec2d(
							pos.x * cosTheta - pos.y * sinTheta,
							pos.x * sinTheta + pos.y * cosTheta
						)
						pos = pos + self.selTexCoordCOM
						v.u, v.v = pos.x, pos.y
					end
				end
			end
		end
	end

	local tileSelHandled = self.tileSel:doPopup()
	if mesh3DBlob then

		if not tileSelHandled then
			handled = orbit:beginDraw() or handled

			app:matscale(1/32768, 1/32768, 1/32768)

			-- draw the 3D model here
			-- TODO this goes slow af
			-- instead please swap out polygon mode (is it possible?) or (can't do geom shaders and be webgl2 compat) hmm ...
			if self.wireframe then
				local eps = .01
				local color = 0xd
				local thickness = 1.5
				for i=0,self:getNumIndexes()-3,3 do
					for j=0,2 do
						local a = self:getVtxIndPtr(i+j)
						local b = self:getVtxIndPtr(i+(j+1)%3)
						app:drawSolidLine3D(
							tonumber(a.x) - fwd.x * eps, tonumber(a.y) - fwd.y * eps, tonumber(a.z) - fwd.z * eps,
							tonumber(b.x) - fwd.x * eps, tonumber(b.y) - fwd.y * eps, tonumber(b.z) - fwd.z * eps,
							color,
							thickness,
							app.paletteMenuTex)
					end
				end
			end
			if self.drawNormals then
				local color = 0xb
				local thickness = 2
				for i=0,self:getNumIndexes()-3,3 do
					local v0 = self:getVtxIndPtr(i+0)
					local v1 = self:getVtxIndPtr(i+1)
					local v2 = self:getVtxIndPtr(i+2)
					local v0x, v0y, v0z = tonumber(v0.x), tonumber(v0.y), tonumber(v0.z)
					local v1x, v1y, v1z = tonumber(v1.x), tonumber(v1.y), tonumber(v1.z)
					local v2x, v2y, v2z = tonumber(v2.x), tonumber(v2.y), tonumber(v2.z)
					local d0x = v1x - v0x
					local d0y = v1y - v0y
					local d0z = v1z - v0z
					local d1x = v2x - v1x
					local d1y = v2y - v1y
					local d1z = v2z - v1z
					local nx = d0y * d1z - d0z * d1y
					local ny = d0z * d1x - d0x * d1z
					local nz = d0x * d1y - d0y * d1x
					local nlenSq = nx^2 + ny^2 + nz^2
					if nlenSq > 1e-7 then
						--local s = 8192 / math.sqrt(nlenSq)
						-- |n| = |dx| * |dy| * sin(theta) angle between them
						-- |n| = 1/2 area of the triangle formed by dx & dy
						-- I want the resulting normal length to be proportional to the sides.
						-- ideally, equal to the cube-root of the product of all 3 sides
						-- or maybe the maximum length of all 3 sides
						local s = .25 * (
							math.sqrt(d0x^2 + d0y^2 + d0z^2)
							+ math.sqrt(d1x^2 + d1y^2 + d1z^2)
						) / math.sqrt(nlenSq)
						--local s = 1/32768
						nx = nx * s
						ny = ny * s
						nz = nz * s
						local cx = (v0x + v1x + v2x) / 3
						local cy = (v0y + v1y + v2y) / 3
						local cz = (v0z + v1z + v2z) / 3
						app:drawSolidLine3D(
							cx, cy, cz,
							cx + nx, cy + ny, cz + nz,
							color,
							thickness,
							app.paletteMenuTex)
					end
				end
			end


			local pushCullFace = app.ram.cullFace
			app.ram.cullFace = self.menuUseCullFace
			if app.ram.cullFace ~= pushCullFace then
				app:onCullFaceChange()
			end

			if self.drawFaces then
				-- set the current selected palette via RAM registry to self.paletteBlobIndex
				local pushPalBlobIndex = app.ram.paletteBlobIndex
				app.ram.paletteBlobIndex = self.paletteBlobIndex
				app:drawMesh3D(
					self.mesh3DBlobIndex,
					bit.lshift(self.tileSel.pos.x, tileSizeInBits),
					bit.lshift(self.tileSel.pos.y, tileSizeInBits),
					self.sheetBlobIndex
				)
				app.ram.paletteBlobIndex = pushPalBlobIndex
			end

			if app.ram.cullFace ~= pushCullFace then
				app.ram.cullFace = pushCullFace
				app:onCullFaceChange()
			end

			-- from here on, no depth mask, since it is all mesh highlights
			local pushBlend = app.currentBlendMode
			app:triBuf_flush()
			app:setBlendMode(1)	-- average
			gl.glDisable(gl.GL_DEPTH_TEST)


			if mouseULX ~= lastMouseULX or mouseULY ~= lastMouseULY then
				local mouseUL = vec2d(mouseULX, mouseULY)
				if self.meshEditForm == 'vertexes' then
					--[[
					click-to-toggle in vertex mode
					what to do for multiple overlapping vertexes ...
					how does blender handle it?
					--]]
					local bestDistSq = 7*7	-- 7 = max pixel dist to click to select
					local bestVtxIndex
					for i=0,numVtxs-1 do
						local v = vtxs + i
						-- sx sy are in [0,app.width)x[0,app.height) coords
						local s = vec2d(trunc2(app:transform(v.x, v.y, v.z, 1)))
						local distSq = (mouseUL - s):lenSq()
						if distSq < bestDistSq then
							bestDistSq = distSq
							bestVtxIndex = i
						-- only select the first one
						end
					end
					if bestVtxIndex then
						self.mouseoverVertexIndexSet = {[bestVtxIndex] = true}
					elseif next(self.mouseoverVertexIndexSet) then
						self.mouseoverVertexIndexSet = {}
					end
				elseif self.meshEditForm == 'edges' then
					-- find the best edge, toggle its selection if not selected
					local bestDistSq = math.huge
					local bestEdges
					for i=0,self:getNumIndexes()-1,3 do
--DEBUG:print('edge sel', i, self:getNumIndexes())
						local v0 = self:getVtxIndPtr(i + 0)
						local v1 = self:getVtxIndPtr(i + 1)
						local v2 = self:getVtxIndPtr(i + 2)
						local s0 = vec2d(trunc2(app:transform(v0.x, v0.y, v0.z, 1)))
						local s1 = vec2d(trunc2(app:transform(v1.x, v1.y, v1.z, 1)))
						local s2 = vec2d(trunc2(app:transform(v2.x, v2.y, v2.z, 1)))
						local curl = vec2d.det(s2 - s1, s1 - s0)
						local s = table{s0, s1, s2}

						if self.menuUseCullFace == 0
						or (self.menuUseCullFace == 1 and curl > 0)
						or (self.menuUseCUllFace == 2 and curl < 0)
						then -- skip edges on tris pointing away from the camera, maybe

							for j=0,2 do
								local ii1 = i+j
								local ii2 = i+((j+1)%3)
								local sj1 = s[1+j]
								local sj2 = s[1+((j+1)%3)]
								-- line segment from edge v1 to v2 in screen space
								local sd = sj2 - sj1
								local sdlen = sd:length()
								if sdlen > .1 then
									local nsd = sd / sdlen
									-- line segment from start of edge to mouse
									local md = mouseUL - sj1
									local mouseToV1LenSq = md:lenSq()
									local mouseToV2LenSq = (mouseUL - sj2):lenSq()
									-- mouse-delta dot normalized-segment-delta = how far along s1->s2 that the nearest point to the mouse-coordinates is
									-- if this is outside [0,sdlen] then clamp it to that
									local param = md:dot(nsd)
									param = math.clamp(param, 0, sdlen)
									local mousePtOnSeg = sj1 + nsd * param
									local mousePtToMouseLenSq = (mousePtOnSeg - mouseUL):lenSq()
									local distSq = math.min(mouseToV1LenSq, mouseToV2LenSq, mousePtToMouseLenSq)
									if distSq < bestDistSq then
										bestEdges = table{vec2i(table{ii1, ii2}:sort():unpack())}
										bestDistSq = distSq
									end
								end
							end
						end
					end
					if bestEdges then
						self.mouseoverEdges = bestEdges
					end
				elseif self.meshEditForm == 'tris' then
					-- find the best tri, toggle its selection if not selected
					local bestDist = math.huge
					local bestTri
					local mousePos = orbit.pos * 32768
					local mouseDir = fwd
						+ orbit.angle:xAxis() * (mouseX - 128) / 128
						- orbit.angle:yAxis() * (mouseY - 128) / 128
					for i=0,self:getNumIndexes()-1,3 do
						local i0 = self:getIndex(i)
						local i1 = self:getIndex(i + 1)
						local i2 = self:getIndex(i + 2)
						local v0 = vtxs + i0
						local v1 = vtxs + i1
						local v2 = vtxs + i2
						local p0 = vec3d(v0.x, v0.y, v0.z)
						local p1 = vec3d(v1.x, v1.y, v1.z)
						local p2 = vec3d(v2.x, v2.y, v2.z)
						local pc = (p0 + p1 + p2) / 3
						local normal = (p2 - p1):cross(p1 - p0)
						local curl = mouseDir:dot(normal)
						-- skip edges on tris pointing away from the camera, maybe
						-- test det = half of area in pixels to skip degen cases where tri is a line
						if self.menuUseCullFace == 0
						or (self.menuUseCullFace == 1 and curl > .01)
						or (self.menuUseCullFace == 2 and curl < -.01)
						then
							-- find mouse screen coords on tri barycenter screen coords
							-- project to tri

							--[[
							plane = {x | (x - pc) dot normal = 0}
							mouseRay = {t > 0 | mousePos + mouseDir * t}
							plane U mouseRay = {t | (mousePos + mouseDir * t - pc) dot normal = 0}
							(mousePos + mouseDir * t - pc) dot normal = 0
							(mousePos - pc) dot normal + (mouseDir dot normal) * t = 0
							t = -(mousePos - pc) dot normal / (mouseDir dot normal)
							--]]
							local ptMouseDist = normal:dot(pc - mousePos) / normal:dot(mouseDir)
							local mouseOnTriPlane = mousePos + mouseDir * ptMouseDist

							local allInside = true
							local allOutside = true
							local ps = {p0, p1, p2}
							for j=0,2 do
								local pi = ps[1+j]
								local pj = ps[1+(j+1)%3]
								local dp = pj - pi
								local curl = normal:dot(dp:cross(mouseOnTriPlane - pi))
								-- idk which is which, i guess cull face influences it
								allInside = allInside and curl > 0
								allOutside = allOutside and curl < 0
							end

							if allInside or allOutside then
								if ptMouseDist < bestDist then
									bestTri = i/3
									bestDist = ptMouseDist
								end
							end
						end
					end
					if bestTri then
						self.mouseoverTris = {[bestTri] = true}
					end
				else
					error'here'
				end
			end


			--[[
			controls ...
			blender-like?
			click to toggle selection of vertex
			then ... how to translate? press 'g'?
				and then mousemove to translate
				and then 'xyz' to lock axis?
				and then push #s to input amount to translate?

			what else ...
			vtxs:
			- translate 'g'
			- scale ... about COM ... 's'
			- rotate ... along some axis? regression plane?
			- delete (and delete all tris that use this vtx?)
			- make fan from list of selected vtxs (how to determine order / inside / outside?)
			edge:
			- delete (and delete all tris that use this edge ... )
			- split
			- collapse (to first? second? middle?)
			tris:
			- delete
			- split (between which vtx and which edge?)
			- subdiv (center-of-face, center-of-edge)
			- flip normal
			- extrude
			- extrude-and-rotate-along-axis (cylinder sweep)
			texcoords ....
			- translate in sheet
			- scale in sheet
			- rotate in sheet
			--]]

			if mouseY > 8
			and not handled
			and app:keyp'mouse_left'
			then
				self.mouseLeftButtonDown = vec2d(mouseULX, mouseULY)
			end

			if mouseY > 8
			and not handled
			and app:keyr'mouse_left'
			then
				if self.meshEditMode == nil then
					local mouseUL = vec2d(mouseULX, mouseULY)

					local selxL, selyL, selxR, selyR
					if self.mouseLeftButtonDown then
						selxL = math.min(mouseUL.x, self.mouseLeftButtonDown.x)
						selyL = math.min(mouseUL.y, self.mouseLeftButtonDown.y)
						selxR = math.max(mouseUL.x, self.mouseLeftButtonDown.x)
						selyR = math.max(mouseUL.y, self.mouseLeftButtonDown.y)
					end

					if self.meshEditForm == 'vertexes' then
						if not shift then
							self.selectedVertexIndexSet = {}
						end

						if self.mouseLeftButtonDown
						and (mouseUL - self.mouseLeftButtonDown):lInfLength() > 3
						then
							-- select all within the screen bbox
							for i=0,numVtxs-1 do
								local v = vtxs + i
								local s = vec2d(trunc2(app:transform(v.x, v.y, v.z, 1)))
								if selxL <= s.x and s.x <= selxR
								and selyL <= s.y and s.y <= selyR
								then
									self.selectedVertexIndexSet[i] = true
								end
							end
						else
							-- select closest to mouse
							for i in pairs(self.mouseoverVertexIndexSet) do
								self.selectedVertexIndexSet[i] = true
							end
						end
						self.mouseLeftButtonDown = nil	-- clear mousedown pos
						refreshSelection()
					elseif self.meshEditForm == 'edges' then
						if not shift then
							self.selectedVertexIndexSet = {}
							self.selectedEdges = table()
						end

						if self.mouseLeftButtonDown
						and (mouseUL - self.mouseLeftButtonDown):lInfLength() > 3
						then
							-- select all within the screen bbox
							for i=0,self:getNumIndexes()-3,3 do
								for j=0,2 do
									local ti1 = i + j
									local ti2 = i+(j+1)%3
									local i1 = self:getIndex(ti1)
									local i2 = self:getIndex(ti2)
									local v1 = vtxs + i1
									local v2 = vtxs + i2
									local s1 = vec2d(trunc2(app:transform(v1.x, v1.y, v1.z, 1)))
									local s2 = vec2d(trunc2(app:transform(v2.x, v2.y, v2.z, 1)))
									if selxL <= s1.x and s1.x <= selxR
									and selyL <= s1.y and s1.y <= selyR
									and selxL <= s2.x and s2.x <= selxR
									and selyL <= s2.y and s2.y <= selyR
									then
										self.selectedEdges:insertUnique(
											vec2i(table{ti1, ti2}:sort():unpack())
										)
									end
								end
							end
						else
							--self.mouseoverEdges
							-- traverse it,
							-- add/remove toggle its edges in self.selectedEdges
							for _,e in ipairs(self.mouseoverEdges) do
								local j = self.selectedEdges:find(e)
								if j then	-- if we have then remove
									self.selectedEdges:remove(j)
								else		-- if we don't have then add
									self.selectedEdges:insert(e)
								end
							end
						end
						self.mouseLeftButtonDown = nil	-- clear mousedown pos

						-- now rebuild vertexes from selected edges
						self.selectedVertexIndexSet = {}
						for _,e in ipairs(self.selectedEdges) do
							for _,ii in ipairs{e:unpack()} do
								local i = self:getIndex(ii)
								self.selectedVertexIndexSet[i] = true
							end
						end
						refreshSelection(true)	-- true = don't also rebuild selectedEdges
					elseif self.meshEditForm == 'tris' then
						if not shift then
							self.selectedVertexIndexSet = {}
							self.selectedTriIndexSet = {}
							self.tileSel.selectedTriIndexSet = self.selectedTriIndexSet
						end

						if self.mouseLeftButtonDown
						and (mouseUL - self.mouseLeftButtonDown):lInfLength() > 3
						then
							-- select all within the screen bbox
							for ti=0,self:getNumIndexes()-3,3 do
								local v0 = vtxs + self:getIndex(ti)
								local v1 = vtxs + self:getIndex(ti+1)
								local v2 = vtxs + self:getIndex(ti+2)
								local s0 = vec2d(trunc2(app:transform(v0.x, v0.y, v0.z, 1)))
								local s1 = vec2d(trunc2(app:transform(v1.x, v1.y, v1.z, 1)))
								local s2 = vec2d(trunc2(app:transform(v2.x, v2.y, v2.z, 1)))
								if selxL <= s0.x and s0.x <= selxR
								and selyL <= s0.y and s0.y <= selyR
								and selxL <= s1.x and s1.x <= selxR
								and selyL <= s1.y and s1.y <= selyR
								and selxL <= s2.x and s2.x <= selxR
								and selyL <= s2.y and s2.y <= selyR
								then
									self.selectedTriIndexSet[ti/3] = true
								end
							end

						else
							for ti in pairs(self.mouseoverTris) do
								self.selectedTriIndexSet[ti] = not self.selectedTriIndexSet[ti] or nil
							end
						end

						-- now rebuild vertexes from selected edges
						self.selectedVertexIndexSet = {}
						for ti in pairs(self.selectedTriIndexSet) do
							for ii=0,2 do
								local i = self:getIndex(3*ti+ii)
								self.selectedVertexIndexSet[i] = true
							end
						end
						refreshSelection(nil, true)	-- second true = don't also rebuild selectedTriIndexSet
					else
						error'here'
					end
				else
					-- meshEditMode is in use and we clicked?
					-- stop moving & set the vertexes to their position
					self.meshEditMode = nil
					self.axisFlags = {}
					if self:removeDegenTris() then
						-- TODO just stop using indexes for these...
						self.mouseoverVertexIndexSet = {}
						self.selectedVertexIndexSet = {}
					end
					--return	-- don't let our mouse sets go bad or something
					-- but I want mouse left down cleared...
				end
				self.mouseLeftButtonDown = nil	-- clear mousedown pos
			end

			if (
				self.meshEditMode == 'translate'
				or self.meshEditMode == 'scale'
				or self.meshEditMode == 'rotate'
			)
			and (
				mouseULX ~= lastMouseULX
				or mouseULY ~= lastMouseULY
			)
			then
				-- inverse-transform screen-coordinates into world-coordinates
				-- translate/scale accordingly

				local sx, sy, sz
				for i in pairs(self.selectedVertexIndexSet) do
					if i >= 0
					and i < numVtxs
					then
						local v = vtxs + i
						sx, sy, sz = app:transform(v.x, v.y, v.z, 1)
						break
					end
				end

				local x1b, y1b, z1b, w1b = app:invTransform(lastMouseULX, lastMouseULY, sz or 0)
				local invw1b = 1 / w1b
				x1b = x1b * invw1b
				y1b = y1b * invw1b
				z1b = z1b * invw1b

				local x2b, y2b, z2b, w2b = app:invTransform(mouseULX, mouseULY, sz or 0)
				local invw2b = 1 / w2b
				x2b = x2b * invw2b
				y2b = y2b * invw2b
				z2b = z2b * invw2b

				local dx = x2b - x1b
				local dy = y2b - y1b
				local dz = z2b - z1b

				local usedx = self.axisFlags.x
				local usedy = self.axisFlags.y
				local usedz = self.axisFlags.z
				-- none set == all set
				if next(self.axisFlags) == nil then
					usedx, usedy, usedz = true, true, true
				end

				local rotAxis
				if self.meshEditMode == 'rotate' then
					if usedx and usedy and usedz then
						rotAxis = self.selRotFwdDir
					else
						rotAxis = self.selRotFwdDir:clone()
						-- if you press 'r' then 'x', you expect x-axis rotations, which means ... none of the other axii ...
						if usedx and not usedy and not usedz then
							rotAxis:set(1,0,0)
						elseif not usedx and usedy and not usedz then
							rotAxis:set(0,1,0)
						elseif not usedx and not usedy and usedz then
							rotAxis:set(0,0,1)
						-- push 'x' and 'y' means rotate the xy plane ...
						elseif usedx and usedy and not usedz then
							rotAxis.z = 0
						elseif usedx and not usedy and usedz then
							rotAxis.y = 0
						elseif not usedx and usedy and usedz then
							rotAxis.x = 0
						end
						rotAxis = rotAxis:normalize()
					end
				end

				if self.meshEditMode == 'translate' then
					--if not self.editTexCoords then
						self.totalTranslation.x = self.totalTranslation.x + dx
						self.totalTranslation.y = self.totalTranslation.y + dy
						self.totalTranslation.z = self.totalTranslation.z + dz
					--else
					--	self.totalTranslation.x = self.totalTranslation.x + mouseULX - lastMouseULX
					--	self.totalTranslation.y = self.totalTranslation.y + mouseULY - lastMouseULY
					--end
				elseif self.meshEditMode == 'scale' then
					self.totalScreenTranslate.x = self.totalScreenTranslate.x + mouseULX - lastMouseULX
					self.totalScreenTranslate.y = self.totalScreenTranslate.y + mouseULY - lastMouseULY
					-- TODO instead, project dx,dy,dz onto the regression plane of all selected vtxs
					self.totalScale = 1 + .01 * self.totalScreenTranslate.x
				elseif self.meshEditMode == 'rotate' then
					local mouseCurrentAngle = math.round(math.deg((vec2d(mouseX, mouseY) - 128):angle()))
					-- negative because screen coordinates are a LHS system
					-- TODO TODO TODO make *everything* RHS and even screen-space origin in lower-left
					self.screenRotateAngle.x = rotAxis.x
					self.screenRotateAngle.y = rotAxis.y
					self.screenRotateAngle.z = rotAxis.z
					self.screenRotateAngle.w = -(mouseCurrentAngle - self.rotateMouseScreenDownAngle)
				end

				-- actually translate/rotate/scale based on the state vars
				-- for translate, this is self.totalTranslation
				-- for scale, this is self.totalScale
				-- for rotate, this is self.screenRotateAngle
				applyMeshEditMode()
			end

			local function drawVertexSet(set, color)
				for i in pairs(set) do
					if i >= 0
					and i < numVtxs
					then
						local v = vtxs + i

						app:drawSolidLine3D(
							v.x-1024, v.y, v.z,
							v.x+1024, v.y, v.z,
							color, 8, app.paletteMenuTex)
						app:drawSolidLine3D(
							v.x, v.y-1024, v.z,
							v.x, v.y+1024, v.z,
							color, 8, app.paletteMenuTex)
						app:drawSolidLine3D(
							v.x, v.y, v.z-1024,
							v.x, v.y, v.z+1024,
							color, 8, app.paletteMenuTex)

						if not self.tooltip then
							self:setTooltip(tostring(v), mouseX-8, mouseY-8, 0xfc, 0)
						end
					end
				end
			end
			drawVertexSet(self.mouseoverVertexIndexSet, 0x19)
			drawVertexSet(self.selectedVertexIndexSet, 0x1a)

			-- now draw edge highlights
			-- TODO only in vertex mode show veretx highlights, and only edge mode edge hihglighs, etc?
			for _,edge in ipairs(self.selectedEdges) do
				local i1, i2 = edge:unpack()
				-- then line is selected
				-- or TODO keep track of selected-lines list as well?
				local v1 = vtxs + self:getIndex(i1)
				local v2 = vtxs + self:getIndex(i2)
				app:drawSolidLine3D(
					v1.x, v1.y, v1.z,
					v2.x, v2.y, v2.z,
					0x1a, 4, app.paletteMenuTex)
			end
			for ti in pairs(self.selectedTriIndexSet) do
				local v0 = self:getVtxIndPtr(3*ti)
				local v1 = self:getVtxIndPtr(3*ti+1)
				local v2 = self:getVtxIndPtr(3*ti+2)
				app:drawSolidTri3D(
					v0.x, v0.y, v0.z,
					v1.x, v1.y, v1.z,
					v2.x, v2.y, v2.z,
					0x1a)
			end


			app:triBuf_flush()
			app:setBlendMode(pushBlend)
			gl.glEnable(gl.GL_DEPTH_TEST)

			orbit:endDraw()

			local x, y = 0, 8
			app:drawMenuText('#vtx:'..mesh3DBlob:getNumVertexes(), x, y)
			y = y + 8
			app:drawMenuText('#ind:'..mesh3DBlob:getNumIndexes(), x, y)
			y = y + 8
			app:drawMenuText('size:'..mesh3DBlob:getSize(), x, y)
			y = y + 8
			x = 0

			if self.axisFlags.x then app:drawMenuText('x', x, y) end
			x = x + 8
			if self.axisFlags.y then app:drawMenuText('y', x, y) end
			x = x + 8
			if self.axisFlags.z then app:drawMenuText('z', x, y) end
			y = y + 8
			x = 0

			if self.meshEditMode == 'translate' then
				local dx, dy, dz = self.totalTranslation:map(math.round):unpack()
				local usedx, usedy, usedz = self.axisFlags.x, self.axisFlags.y, self.axisFlags.z
				if next(self.axisFlags) == nil then usedx, usedy, usedz = true, true, true end
				if not usedx then dx = 0 end
				if not usedy then dy = 0 end
				if not usedz then dz = 0 end
				if not self.editTexCoords then
					app:drawMenuText('xlate='..dx..', '..dy..', '..dz, x, y)
				else
					app:drawMenuText('xlate='..math.round(dx / 256)..', '..math.round(dy / 256), x, y)
				end
			elseif self.meshEditMode == 'scale' then
				app:drawMenuText('scale='..self.totalScale, x, y)
			elseif self.meshEditMode == 'rotate' then
				app:drawMenuText('rot='..self.screenRotateAngle.w..' @ '..vec3d(trunc3(self.screenRotateAngle:unpack())), x, y)
			end
			y = y + 8
		end
	end

	local x, y = 50, 0

	self:guiBlobSelect(
		x, y, 						-- widget screen x,y
		'mesh3d', 					-- blobName
		self, 'mesh3DBlobIndex', 	-- table, indexKey
		function() 					-- callback upon text change or spinner click
			self:resetSelection()
		end,
		BlobMesh3D.generateDefaultCube				-- new blob generator:
	)
	x = x + 11
	self:guiBlobSelect(x, y, 'sheet', self, 'sheetBlobIndex')
	x = x + 11
	self:guiBlobSelect(x, y, 'palette', self, 'paletteBlobIndex')
	x = x + 11

	if self:guiButton('F', x, y, self.drawFaces, 'draw tris') then
		self.drawFaces = not self.drawFaces
	end
	x = x + 6

	if self:guiButton('W', x, y, self.wireframe, 'wireframe') then
		self.wireframe = not self.wireframe
	end
	x = x + 6

	if self:guiButton('N', x, y, self.drawNormals, 'normals') then
		self.drawNormals = not self.drawNormals
	end
	x = x + 6

	if self:guiButton(orbit.ortho and 'O' or 'P', x, y, false, orbit.ortho and 'ortho' or 'perspective') then
		orbit.ortho = not orbit.ortho
	end
	x = x + 6

	if self:guiButton('C', x, y, false, 'cull='..self.menuUseCullFace) then
		self.menuUseCullFace = (self.menuUseCullFace + 1) % 3
	end
	x = x + 6

	if self:guiButton('U', x, y, self.editTexCoords, 'edit texcoords') then
		self.editTexCoords = not self.editTexCoords
	end
	x = x + 6

	self.tileSel:button(x,y)
	x = x + 7

	self:guiRadio(x, y, {'vertexes', 'edges', 'tris'}, self.meshEditForm, function(result)
		self.meshEditForm = result
	end)
	x = x + 6*3 + 1

	if self:guiButton('+', x, y, false, 'add cube') then
		self.undo:push()

		local vs, ts = self:getMeshVtxAndTriList()

		local cubeVtxPoss, cubeTCs, cubeIndexes = BlobMesh3D.getDefaultCubeLists()	-- table-of-tables, 0-based indexes

		local oldNumVtxs = #vs
		for i=1,#cubeVtxPoss do
			local pos = cubeVtxPoss[i]
			local tc = cubeTCs[i]
			local newv = Vertex()
			newv.x, newv.y, newv.z = pos[1], pos[2], pos[3]
			newv.u, newv.v = tc[1], tc[2]
			vs:insert(newv)
		end

		for i=1,#cubeIndexes-2,3 do
assert.index(vs, oldNumVtxs + 1 + cubeIndexes[i])
assert.index(vs, oldNumVtxs + 1 + cubeIndexes[i+1])
assert.index(vs, oldNumVtxs + 1 + cubeIndexes[i+2])
			ts:insert{
				vs[oldNumVtxs + 1 + cubeIndexes[i]],
				vs[oldNumVtxs + 1 + cubeIndexes[i+1]],
				vs[oldNumVtxs + 1 + cubeIndexes[i+2]],
			}
		end

		self:replaceMeshBlobWithVtxRefAndTriList(vs, ts)

		-- reset mouseover selection-testing tables to only select the new indexes
		self.mouseoverVertexIndexSet = {}
		self.selectedVertexIndexSet = range(oldNumVtxs, oldNumVtxs + #cubeVtxPoss - 1)
			:mapi(function(i) return true, i end)
			:setmetatable(nil)	-- select new vtxs only
		refreshSelection()
	end
	x = x + 7

	if self:guiButton('X', x, y, false, 'x-axis') then
		if fwd.x < 0 then
			orbit.angle:set(.5, -.5, -.5, .5)
		else
			orbit.angle:set(.5, .5, .5, .5)
		end
		local dist = (orbit.pos - orbit.orbit):length()
		orbit.pos = orbit.angle:zAxis() * dist + orbit.orbit
	end
	x = x + 6
	if self:guiButton('Y', x, y, false, 'y-axis') then
		if fwd.y < 0 then
			orbit.angle:set(math.sqrt(.5), 0, 0, math.sqrt(.5))
		else
			orbit.angle:set(0, math.sqrt(.5), math.sqrt(.5), 0)
		end
		local dist = (orbit.pos - orbit.orbit):length()
		orbit.pos = orbit.angle:zAxis() * dist + orbit.orbit
	end
	x = x + 6
	if self:guiButton('Z', x, y, false, 'z-axis') then
		if fwd.z < 0 then	-- looking along z-, toggle to z+
			orbit.angle:set(0,1,0,0)
		else
			orbit.angle:set(0,0,0,1)	-- identity = looking along z-
		end
		local dist = (orbit.pos - orbit.orbit):length()
		orbit.pos = orbit.angle:zAxis() * dist + orbit.orbit
	end
	x = x + 7

	if self.meshEditForm == 'vertexes' then
		if self:guiButton('T', x, y, false, 'add tri') then
			local selVtxIndexes = table.keys(self.selectedVertexIndexSet):sort()
			if #selVtxIndexes ~= 3 then
				print('need 3 vertexes, got '..#selVtxIndexes..' vertexes')
			else
				local vs, ts = self:getMeshVtxAndTriList()

				local v0 = vs[1 + selVtxIndexes[1]]
				local v1 = vs[1 + selVtxIndexes[2]]
				local v2 = vs[1 + selVtxIndexes[3]]
				-- can't use app:transform cuz we're drawing the gui so the matrices are gui matrices...
				-- so do it in model space
				local pos0 = vec3d(v0.x, v0.y, v0.z) / 32768
				local pos1 = vec3d(v1.x, v1.y, v1.z) / 32768
				local pos2 = vec3d(v2.x, v2.y, v2.z) / 32768
				local curl = (pos2 - pos1):cross(pos1 - pos0):dot(orbit.pos - (pos0 + pos1 + pos2) / 3)

				-- make a new tri facing the camera
				if curl < 0 then
					ts:insert{v0, v1, v2}
				else
					ts:insert{v2, v1, v0}
				end

				self.undo:push()
				self:replaceMeshBlobWithVtxRefAndTriList(vs, ts)
				refreshSelection()
			end
		end
		x = x + 6

		-- TODO this is a good reason to add select-by-rect-in-screen-space
		-- and then shift+select to add to selection, otherwise just only select recent pressed / dragged-box-around
		if self:guiButton('M', x, y, false, 'merge vtxs') then
			local visToMerge = table.keys(self.selectedVertexIndexSet):sort()	-- 0-based list of selected vertexes
			if #visToMerge >= 2 then
--DEBUG:print('#visToMerge', #visToMerge)
				local vs, ts = self:getMeshVtxAndTriList()

				local vsToMerge = visToMerge:mapi(function(vi) return vs[1+vi] end)

				local destv = vsToMerge[1]
				--[[ average or replace?
				do
					local x,y,z,u,v = 0,0,0,0,0
					for _,srcv in ipairs(vsToMerge) do
						x = x + tonumber(srcv.x)
						y = y + tonumber(srcv.y)
						z = z + tonumber(srcv.z)
						u = u + tonumber(srcv.u)
						v = v + tonumber(srcv.v)
					end
					destv.x = x / #vsToMerge
					destv.y = y / #vsToMerge
					destv.z = z / #vsToMerge
					destv.u = u / #vsToMerge
					destv.v = v / #vsToMerge
				end
				--]]
				-- merge into the lowest index
				-- sort from largest to 2nd-to-smallest
				for i=2,#vsToMerge do
					local v = vsToMerge[i]
					local vp = ffi.cast(Vertex_p, v)
					for _,t in ipairs(ts) do
						for j,tv in ipairs(t) do
							local tvp = ffi.cast(Vertex_p, tv)
							if tvp == vp then
								t[j] = destv
							end
						end
					end
				end

				self.undo:push()
				self:replaceMeshBlobWithVtxRefAndTriList(vs, ts)
				self.mouseoverVertexIndexSet = {}
				self.selectedVertexIndexSet = {}
				refreshSelection()
				return
			end
		end
		x = x + 6

		if self:guiButton('S', x, y, false, 'split vtxs') then
			local vs, ts = self:getMeshVtxAndTriList()

			-- like refs will use the same keys right?
			-- if not then get their address and use that
			local selVtxRefSet = table.map(
				self.selectedVertexIndexSet,
				function(true_, index) return true, vs[1+index] end
			)

			for _,tri in ipairs(ts) do
				for i,tv in ipairs(tri) do
					if selVtxRefSet[tv] then
						local newv = Vertex(tv)
						vs:insert(newv)
						tri[i] = newv
					end
				end
			end

			-- now automatically pick out unused vtxs and degenerate tris
			self.undo:push()
			self:replaceMeshBlobWithVtxRefAndTriList(vs, ts)
			self.mouseoverVertexIndexSet = {}
			self.selectedVertexIndexSet = {}
			refreshSelection()
			return
		end
		x = x + 6


	elseif self.meshEditForm == 'edges' then
		if self:guiButton('S', x, y, false, 'split edge') then
			-- currently it splits all edges with the selected vertexes
			-- should I have it operate by selected edges instead?

			local vs, ts = self:getMeshVtxAndTriList()

			for _,e in ipairs(self.selectedEdges) do
				-- find the tris on either side
				-- remove the tris on either side
				-- insert a vertex between these two
				local ei0, ei1 = e:unpack()	-- edges are of indexes-of-indexes
				local v0 = assert.index(vs, 1+self:getIndex(ei0))
				local v1 = assert.index(vs, 1+self:getIndex(ei1))
				local vp0 = ffi.cast(Vertex_p, v0)
				local vp1 = ffi.cast(Vertex_p, v1)
				local pos1 = vec3d(v0.x, v0.y, v0.z)
				local pos2 = vec3d(v1.x, v1.y, v1.z)
				local tc1 = vec2d(v0.u, v0.v)
				local tc2 = vec2d(v1.u, v1.v)
				local newvtxindex = #vs	-- indexes are 0-based
				local newpos = (pos1 + pos2) * .5
				local newtc = (tc1 + tc2) * .5
				local newvtx = Vertex()
				self.selectedVertexIndexSet[#vs] = true	-- new vertex index selected
				vs:insert(newvtx)
				newvtx.x = newpos.x
				newvtx.y = newpos.y
				newvtx.z = newpos.z
				newvtx.u = newtc.x
				newvtx.v = newtc.y
				for ti=#ts,1,-1 do
					local t = ts[ti]
					for j=0,2 do
						local tj0 = t[1+j]
						local tj1 = t[1+(j+1)%3]
						local tj2 = t[1+(j+2)%3]
assert(tj0)
assert(tj1)
assert(tj2)

						local tjp0 = ffi.cast(Vertex_p, tj0)
						local tjp1 = ffi.cast(Vertex_p, tj1)
						if (tjp0 == vp0 and tjp1 == vp1)
						or (tjp0 == vp1 and tjp1 == vp0)
						then
							-- if we are to remove this tri, then add its replacements as well
							ts:insert{tj0, newvtx, tj2}
							ts:insert{newvtx, tj1, tj2}

							ts:remove(ti)
							-- you can only split one edge of one tri
							-- if you select two edges of the same tri and push 'split', only the first will split
							-- cuz i dont want to go through the hassle of remapping selections from old tris to newly split tris
							-- tho if i stored selected edges by vtx ref then this would be easier to do ....
							-- ... but still there would be conditional behavior based on split order.
							break
						end
					end
				end
			end

			self.undo:push()
			self:replaceMeshBlobWithVtxRefAndTriList(vs, ts)
			refreshSelection()
		end
		x = x + 6
	elseif self.meshEditForm == 'tris' then
		-- TODO maybe flip-edge should maybe be an edge function?
		if self:guiButton('F', x, y, false, 'flip') then
			-- flip tris ...
			-- 1) get tris selected
			-- 2) flip ...
			-- how to generalize that for any more than two tris that share 1 edge?
			local selTriInds = table.keys(self.selectedTriIndexSet)
			if #selTriInds ~= 2 then
				print('need 2 tris, got '..#selTriInds..' tris')
			else
				-- and if # selected vtxs == 4 exactly ...
				local vs, ts = self:getMeshVtxAndTriList()

				-- find the common edge between the two tris
				-- and exchange tris
				local found
				local ti1, ti2 = table.unpack(selTriInds:sort())	-- 0-based-sequential tri indxes
				local t1 = ts[ti1+1]
				local t2 = ts[ti2+1]
--DEBUG:print('flipping', ti1, ti2)
--DEBUG:print(ti1, 'has 1-based vtx indexes', vs:find(t1[1]), vs:find(t1[2]), vs:find(t1[3]))
--DEBUG:print(ti2, 'has 1-based vtx indexes', vs:find(t2[1]), vs:find(t2[2]), vs:find(t2[3]))
				for i=0,2 do
					for j=0,2 do
						local a1 = t1[1+i]
						local a2 = t1[1+(i+1)%3]
						local a3 = t1[1+(i+2)%3]
						local b1 = t2[1+j]
						local b2 = t2[1+(j+1)%3]
						local b3 = t2[1+(j+2)%3]
						local ap1 = ffi.cast(Vertex_p, a1)
						local ap2 = ffi.cast(Vertex_p, a2)
						local bp1 = ffi.cast(Vertex_p, b1)
						local bp2 = ffi.cast(Vertex_p, b2)
						if (ap1 == bp1 and ap2 == bp2)
						or (ap2 == bp1 and ap1 == bp2)
						then
--DEBUG:print('found at subind', i, j)
							t1[1], t1[2], t1[3] = a3, b1, b3
							t2[1], t2[2], t2[3] = b3, b2, a3
							found = true
							goto done
						end
					end
				end
::done::
				if not found then
					print"couldn't find, not flipping"
				else
					self.undo:push()
					self:replaceMeshBlobWithVtxRefAndTriList(vs, ts)

					-- refresh edges and tris, but vtxs shouldn't change
					refreshSelection()
				end
			end
		end
		x = x + 6
	end


	app:drawMenuText(('fwd {%.3f, %.3f, %.3f}'):format(fwd:unpack()), 0, 240)
	app:drawMenuText(('q {%.3f, %.3f, %.3f, %.3f}'):format(orbit.angle:unpack()), 0, 248)

	---------------- KEYBOARD ----------------

	local handledKey
	if mesh3DBlob then
		-- TODO if meshEditMode == 'translate' then
		-- accept input like a textarea for a number string, and let that be the amount to translate or rotate or whatever

		local uikey
		if ffi.os == 'OSX' then
			uikey = app:key'lgui' or app:key'rgui'
		else
			uikey = app:key'lctrl' or app:key'rctrl'
		end

		if uikey then
			if app:keyp'z' then
				self:popUndo(shift)
			end
		else	-- non-ctrl:

			if app:keyp'backspace'
			or app:keyp'delete'
			then
				-- if we're in an edit mode then reset it
				-- TODO or is there a better 'cancel edit' button because 'escape' and '`' is taken....
				if self.meshEditMode then

					--[[
					if #self.meshEditModeText > 0 then
						self.meshEditModeText = self.meshEditModeText:sub(1, -2)
					else
						resetVtxEditPos()
						self.meshEditMode = nil
					end
					--]]

				else
					-- if we're not in an edit mode then delete vertexes
					-- and then regen blobs or something
					-- hmm
					local vs, ts = self:getMeshVtxAndTriList()
					-- delete selected vertexes
					-- delete touching triangles

					local selVtxRefSet = table.map(
						self.selectedVertexIndexSet,
						function(true_, index) return true, vs[1+index] end
					)

					if self.meshEditForm == 'vertexes' then
						-- delete selected vertexes
						for i=#vs,1,-1 do
							if selVtxRefSet[vs[i]] then
								vs:remove(i)
							end
						end

						-- delete any tris that use it
						for ti=#ts,1,-1 do
							local t = ts[ti]
							if selVtxRefSet[t[1]]
							or selVtxRefSet[t[2]]
							or selVtxRefSet[t[3]]
							then
								ts:remove(ti)
							end
						end
					elseif self.meshEditForm == 'edges' then
						-- currently edge-sel is based on tri edge, not based on vtxs.
						-- so just delete the tri that the edge is on.
						local trisToRemove = table()
						for _,e in ipairs(self.selectedEdges) do
							local ei0, ei1 = e:unpack()	-- edges are of indexes-of-indexes
							for ti=#ts,1,-1 do
								for j=0,2 do
									local tj0 = 3*(ti-1) + j
									local tj1 = 3*(ti-1) + (j+1)%3
									if (tj0 == ei0 and tj1 == ei1)
									or (tj0 == ei1 and tj1 == ei0)
									then
										trisToRemove[ti] = true	-- keys are 1-based indexes
										break
									end
								end
							end
						end
						for _,ti in ipairs(trisToRemove:keys():sort():reverse()) do
							ts:remove(ti)
						end
					elseif self.meshEditForm == 'tris' then
						-- delete the face, and then remove/remap any unused vtxs
						-- self.selectedTriIndexSet is 0-based mod-3 index of the start of a triangle in our index buffer
						-- so traverse in reverse order and remove-3 per tri we want to remove
						for _,ti in ipairs(
							table(self.selectedTriIndexSet)
							:sort()
							:reverse()
						) do
							ts:remove(ti+1)	-- selectedTriIndexSet keys are 0-based-sequential
						end
					else
						error'here'
					end

					self.undo:push()
					self:replaceMeshBlobWithVtxRefAndTriList(vs, ts)

					-- reset mouseover selection-testing tables
					self.mouseoverVertexIndexSet = {}
					-- select-none
					self.selectedVertexIndexSet = {}
					refreshSelection()

					-- return and don't let anything else use the invalidated mesh functions until we refresh things
					return
				end
			end

			if app:keyp'a' then
				if next(self.selectedVertexIndexSet) == nil then
					-- select all
					self.selectedVertexIndexSet = {}
					for i=0,numVtxs-1 do
						self.selectedVertexIndexSet[i] = true
					end
				else
					-- select none
					self.selectedVertexIndexSet = {}
				end
				refreshSelection()
				handledKey = true
			end

			if app:keyp'g' then
				if self.meshEditMode ~= nil then
					-- TODO maybe even pop the last undo push?
					resetVtxEditPos()
					self.meshEditMode = nil
				else
					self.meshEditMode = 'translate'
					self.meshEditModeText = ''
					setVtxEditPos()
					calcSelVtxCOM()	-- COM not needed but this exits meshEditMode if none are selected
					self.totalTranslation:set(0,0,0)
					self.undo:push()
				end
				handledKey = true
			end
			if app:keyp's' then
				if self.meshEditMode ~= nil then
					resetVtxEditPos()
					self.meshEditMode = nil
				else
					self.meshEditMode = 'scale'
					self.meshEditModeText = ''
					setVtxEditPos()
					calcSelVtxCOM()
					self.totalScreenTranslate:set(0,0)
					self.undo:push()
				end
				handledKey = true
			end
			if app:keyp'r' then
				if self.meshEditMode ~= nil then
					resetVtxEditPos()
					self.meshEditMode = nil
				else
					self.meshEditMode = 'rotate'
					self.meshEditModeText = ''
					setVtxEditPos()
					calcSelVtxCOM()
					self.undo:push()
					self.rotateMouseScreenDownPos = (vec2d(mouseX, mouseY) - 128):normalize()
					self.rotateMouseScreenDownAngle = math.round(math.deg(self.rotateMouseScreenDownPos:angle()))
					self.screenRotateAngle = quatd(0,0,1,0)	-- angle-axis

					local drawViewInvMat = vec4x4fcol()
					drawViewInvMat:inv4x4(app.ram.viewMat)
					self.selRotFwdDir = vec3d(
						drawViewInvMat.ptr[8],
						drawViewInvMat.ptr[9],
						drawViewInvMat.ptr[10]
					):normalize()
				end
				handledKey = true
			end

			-- TODO or maybe use this for flipping common edge between two tris?
			if app:keyp'f' then
				self.drawFaces = not self.drawFaces
				handledKey = true
			end
			if app:keyp'n' then
				self.drawNormals = not self.drawNormals
				handledKey = true
			end
			if app:keyp'w' then
				self.wireframe = not self.wireframe
				handledKey = true
			end
			if app:keyp'o' then
				orbit.ortho = not orbit.ortho
				handledKey = true
			end

			if app:keyp'v' then
				self.meshEditForm = 'vertexes'
				handledKey = true
			end
			if app:keyp'e' then
				self.meshEditForm = 'edges'
				handledKey = true
			end
			if app:keyp't' then
				self.meshEditForm = 'tris'
				handledKey = true
			end

			if app:keyp'x' then
				self.axisFlags.x = not self.axisFlags.x or nil	-- 'or nil' so false's are nil's, so next(self.axisFlags) == nil means its empty
				resetVtxEditPos()
				handledKey = true
			end
			if app:keyp'y' then
				self.axisFlags.y = not self.axisFlags.y or nil
				resetVtxEditPos()
				handledKey = true
			end
			if app:keyp'z' then
				self.axisFlags.z = not self.axisFlags.z or nil
				resetVtxEditPos()
				handledKey = true
			end
		end
	end


	-- this is a bit of a mess of order but ...
	-- handle the keyboard *before* handling the guiTextField of the input
	-- so that the keyboard shortcut keys don't get added

	-- collect translate/scale/rotate text input ...
	-- TODO perfect time to use EditMesh3D:event() ........
	if self.meshEditMode
	and not handledKey
	then
		-- TODO make sure this is selected so all keys go here ...
		self.menuTabIndex = self.menuTabCounter
		self:guiTextField(
			0, 48, 10,					-- x, y, w
			self, 'meshEditModeText', 	-- t, k
			function(value)			-- write
				-- TODO do this after every change ...

				value = value:gsub('[xyz]', '')
				-- TODO don't add these to the text at all
				-- in fact TODO better capture-keyboard-focus overall...

				-- upon enter, right?
				-- do I even need to write self.meshEditModeText?
				-- do I even need self.meshEditModeText?
				self.meshEditModeText = value

				local parts = string.split(value, ','):mapi(function(x)
					return tonumber(string.trim(x))
				end)

				if self.meshEditMode == 'translate' then
					local dx, dy, dz = self.totalTranslation:map(math.round):unpack()
					local usedx, usedy, usedz = self.axisFlags.x, self.axisFlags.y, self.axisFlags.z
					if next(self.axisFlags) == nil then usedx, usedy, usedz = true, true, true end
					if usedx then self.totalTranslation.x = parts[1] and parts:remove(1) or 0 end
					if usedy then self.totalTranslation.y = parts[1] and parts:remove(1) or 0 end
					if usedz then self.totalTranslation.z = parts[1] and parts:remove(1) or 0 end
					applyMeshEditMode()
				elseif self.meshEditMode == 'scale' then
					self.totalScale = parts[1] or 1
					applyMeshEditMode()
				elseif self.meshEditMode == 'rotate' then
					self.screenRotateAngle.w = parts[1] and parts:remove(1) or 0
					-- it should already by set to whatever fixed axis by axisFlags already, right?
					self.screenRotateAngle.x = parts[1] and parts:remove(1) or 0
					self.screenRotateAngle.y = parts[1] and parts:remove(1) or 0
					self.screenRotateAngle.z = parts[1] and parts:remove(1) or 1
					applyMeshEditMode()
				end

				self.meshEditMode = nil
				self.axisFlags = {}
				if self:removeDegenTris() then
					-- TODO just stop using indexes for these...
					self.mouseoverVertexIndexSet = {}
					self.selectedVertexIndexSet = {}
				end
				return
			end
		)
	end


	self:guiSetClipRect(-1000, 0, 3000, 256)

	app:matident(0)
	app:matident(1)
	app:matident(2)
	app:matortho(
		0, app.ram.screenWidth,
		app.ram.screenHeight, 0)

	if self.mouseLeftButtonDown then
		app:drawSolidRect(
			mouseULX, mouseULY,
			self.mouseLeftButtonDown.x - mouseULX, self.mouseLeftButtonDown.y - mouseULY,
			31,
			true,	-- border
			false,	-- round
			app.paletteMenuTex
		)
	end

	app:matMenuReset()

	self:drawTooltip()
end

function EditMesh3D:popUndo(redo)
	local app = self.app
	local entry = self.undo:pop(redo)
	if not entry then return end
	app.blobs.mesh3d[self.mesh3DBlobIndex+1] = BlobMesh3D(entry.data)

	-- and invalidate all selections (or maybe i should save selection with the undo buffer....)
	self.mouseoverVertexIndexSet = {}
	self.selectedVertexIndexSet = {}
	self.selectedEdges = table()

	self.selectedTriIndexSet = table()
	self.tileSel.selectedTriIndexSet = self.selectedTriIndexSet

	self.mouseoverEdges = table()
	self.mouseoverTris = {}	-- keys are 0-based tri-index 0,1,2 (not index-index 0,3,6...)

	self:updateBlobChanges()
	self:invalidateVoxelmaps()
end

-- remove degen tris <-> just get the vtxs-and-refs, and rebuild the blob with it
function EditMesh3D:removeDegenTris()
	return self:replaceMeshBlobWithVtxRefAndTriList(self:getMeshVtxAndTriList())
end

-- vs = list-of-Vertexes
-- ts = list-of- lists-of-3-Vertex-refs that have to be in vs
-- removes degen tris and unused vtxs automatically, so it's an improvement over the above function
function EditMesh3D:replaceMeshBlobWithVtxRefAndTriList(vs, ts, args)
	args = args or {}
	local didRemoveTris, didRemoveVtxs

	-- merge matching vertexes
	--[[ maybe this should be the exception and not the rule?
	-- after all I do have a whole separate 'merge' operation ...
	if not args.skipMergeMatchingVertexes then
		for i=#vs-1,1,-1 do
			local vi = vs[i]
			for j=i+1,#vs do
				local vj = vs[j]
				assert.ne(vi, vj)
				if vi.x == vj.x
				and vi.y == vj.y
				and vi.z == vj.z
				and vi.u == vj.u
				and vi.v == vj.v
				then
					for _,t in ipairs(ts) do
						for k=1,3 do
							if t[k] == vj then t[k] = vi end
						end
					end
				end
--DEBUG:print('merging identical vertexes '..j..' into '..i)
				vs:remove(j)
			end
		end
	end
	--]]

	for i=#ts,1,-1 do
		-- remove degenerate tris by reference
		local t = ts[i]
assert.index(t, 1)
assert.index(t, 2)
assert.index(t, 3)
		-- I guess you gotta cast to ptr or else it will compare value?
		local tp1 = ffi.cast(Vertex_p, t[1])
		local tp2 = ffi.cast(Vertex_p, t[2])
		local tp3 = ffi.cast(Vertex_p, t[3])
		if tp1 == tp2 or tp2 == tp3 or tp3 == tp1 then
--DEBUG:print('removing triangle '..(i-1)..' with degenerate vertex references (1-based vertex indexes:)', vs:find(t[1]), vs:find(t[2]), vs:find(t[3]))
			didRemoveTris = true
			ts:remove(i)
			goto done
		end

		-- remove degen tris by identical positions <-> area = 0
		if (t[1].x == t[2].x and t[1].y == t[2].y and t[1].z == t[2].z)
		or (t[2].x == t[3].x and t[2].y == t[3].y and t[2].z == t[3].z)
		or (t[3].x == t[1].x and t[3].y == t[1].y and t[3].z == t[1].z)
		then
--DEBUG:print('removing zero-area triangle', i-1)
			didRemoveTris = true
			ts:remove(i)
			goto done
		end
::done::
	end

	local vertexToIndex = vs:mapi(function(v,i) return i-1, v end)	-- map from vertex-rev to 0-based-index
	local used = range(#vs):mapi(function() return false end)	-- 1-based array of bool of used vs not used per vtx
	-- flag used vertexes
	for _,t in ipairs(ts) do
		for j,tv in ipairs(t) do
assert.index(vertexToIndex, tv)
			used[1+vertexToIndex[tv]] = true
		end
	end
	-- remove unused vertexes
	for i=#vs,1,-1 do
		if not used[i] then
--DEBUG:print('removing unused vertex', i-1)
			didRemoveVtxs = true
			vs:remove(i)
		end
	end
	-- refresh vertex-to-index after we removed some
	vertexToIndex = vs:mapi(function(v,i) return i-1, v end)

	-- build our index map from our tri-ref list
	local is = table()
	for _,t in ipairs(ts) do
		for j,tv in ipairs(t) do
assert.index(vertexToIndex, tv)
			is:insert(vertexToIndex[tv])
		end
	end
	assert.eq(#is % 3, 0)

	self.app.blobs.mesh3d[self.mesh3DBlobIndex+1] = BlobMesh3D:loadFromVertexAndIndexLists(vs, is)
	self:updateBlobChanges()
	self:invalidateVoxelmaps()

	return didRemoveVtxs, didRemoveTris
end

function EditMesh3D:invalidateVoxelmaps()
	for _,voxelmap in ipairs(self.app.blobs.voxelmap) do
		voxelmap.dirtyCPU = true
		for _,chunk in pairs(voxelmap.chunks) do
			chunk.dirtyCPU = true
		end
	end
end

return EditMesh3D
