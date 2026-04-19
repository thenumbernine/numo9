--[[
TODO tempting to store an .obj / Mesh per model
since I'm using them for loading and unloading
and since my mesh lib has all the nice mesh operations anwyays
--]]
local ffi = require 'ffi'
local table = require 'ext.table'
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

-- truncate stack, useful for ffi ctype ctors that can't have extra args
local function trunc(i, ...)
	if i <= 0 then return end
	return ..., trunc(i-1, select(2, ...))
end
local function trunc2(x, y) return x, y end

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
	self.wireframe = false
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
	self.selectedTris = table()		-- table of the index into the indexes list of the first of 3 for a triangle.  elements will always be divisible by 3.

	self.mouseoverEdges = table()
	self.mouseoverTris = table()

	self.axisFlags = {}
	self.meshEditMode = nil			-- translate rotate scale
	self.meshEditForm = 'vertexes'	-- vertexes edges tris

	self.vtxOrigPos = table()				-- 1-based-index table-of-vec3d's to store original vertex positions before edit operation
	self.vtxOrigTCs = table()				-- " " vec2d's to store original vertex texcoords
	self.totalTranslation = vec3d()			-- total translation since translate start, in world coordinates
	self.totalScreenTranslate = vec2d()		-- total translation since scale start, in screen coordinates.  TODO track in world coords and project to plane of vtxs
	self.rotateMouseScreenDownPos = vec2d()	-- rotation mouse down screen coordinates relative to center

	self.undo:clear()
end

function EditMesh3D:update()
	local app = self.app
	local orbit = self.orbit

	local handled = EditMesh3D.super.update(self)

	app:matMenuReset()
	--self:guiSetClipRect(-1000, 16, 3000, 240)

	local mouseULX, mouseULY = app.ram.mousePos:unpack()
	local lastMouseULX, lastMouseULY = app.ram.lastMousePos:unpack()

	local mouseX, mouseY = app:invTransform(mouseULX, mouseULY)
	local lastMouseX, lastMouseY = app:invTransform(lastMouseULX, lastMouseULY)

	local shift = app:key'lshift' or app:key'rshift'

	local mesh3DBlob = app.blobs.mesh3d[self.mesh3DBlobIndex+1]
	local numVtxs
	local numIndexes
	local vtxs
	local inds

	-- handy functions for indexed vs non-indexed meshes:
	local function getNumIndexes()
		return numIndexes == 0 and numVtxs or numIndexes
	end
	local function getIndex(i)	-- 0-based, returns index in 0..n-1 list if no index list is present, or from index list if it is present
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
	local function getVtxIndPtr(i)
		return vtxs + getIndex(i)
	end
	local function getMeshVertexList()
		local vs = table()
		for i=0,numVtxs-1 do
			local v = vtxs + i
			vs:insert(vec3d(v.x, v.y, v.z))
		end
		return vs
	end
	local function getMeshTexCoordList()
		local vts = table()
		for i=0,numVtxs-1 do
			local v = vtxs + i
			vts:insert(vec2d(v.u, v.v))
		end
		return vts
	end
	local function getMeshIndexList()
		-- table indexes ar 1-based, though is values are 0-based
		local is = table()
		for i=0,getNumIndexes()-1 do
			is:insert(getIndex(i))
		end
		return is
	end
	local function getMeshLists()
		return getMeshVertexList(),
			getMeshTexCoordList(),
			getMeshIndexList()
	end
	local function refreshSelection(skipEdges, skipTris)
		-- TODO we could do calcCOM here isntead of when we start to do a translate/rotate/scale ...
		if not skipEdges then
			self.selectedEdges = table()	-- table of pairs of 0-based indexes between two edges
		end
		if not skipTris then
			self.selectedTris = table()
		end

		for i=0,getNumIndexes()-1,3 do
			if not skipEdges then
				for j=0,2 do
					local i1 = i+j
					local i2 = i+((j+1)%3)
					if self.selectedVertexIndexSet[getIndex(i1)]
					and self.selectedVertexIndexSet[getIndex(i2)]
					then
						self.selectedEdges:insert(vec2i(table{i1, i2}:sort():unpack()))
					end
				end
			end
			if not skipTris then
				if self.selectedVertexIndexSet[getIndex(i)]
				and self.selectedVertexIndexSet[getIndex(i+1)]
				and self.selectedVertexIndexSet[getIndex(i+2)]
				then
					self.selectedTris:insert(i)
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
		self.vtxOrigPos = getMeshVertexList()
		self.vtxOrigTCs = getMeshTexCoordList()
	end
	local function resetVtxEditPos()
		for i=0,numVtxs-1 do
			local v = vtxs + i
			local origXYZ = self.vtxOrigPos[1+i]
			local origUV = self.vtxOrigTCs[1+i]
			v.x, v.y, v.z, v.u, v.v = origXYZ.x, origXYZ.y, origXYZ.z, origUV.x, origUV.y
		end
	end


	if mesh3DBlob then
		numVtxs = mesh3DBlob:getNumVertexes()
		numIndexes = mesh3DBlob:getNumIndexes()
		vtxs = mesh3DBlob:getVertexPtr()
		inds = mesh3DBlob:getIndexPtr()
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
				local color = 0xd
				local thickness = 1.5
				for i=0,getNumIndexes()-3,3 do
					for j=0,2 do
						local a = getVtxIndPtr(i+j)
						local b = getVtxIndPtr(i+(j+1)%3)
						app:drawSolidLine3D(
							a.x, a.y, a.z,
							b.x, b.y, b.z,
							color,
							thickness,
							app.paletteMenuTex)
					end
				end
			end
			if self.drawNormals then
				local color = 0xb
				local thickness = 2
				for i=0,getNumIndexes()-3,3 do
					local v0 = getVtxIndPtr(i+0)
					local v1 = getVtxIndPtr(i+1)
					local v2 = getVtxIndPtr(i+2)
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
						local s = .5 * (
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
					local bestDistSq = math.huge
					local bestVtxIndexSet
					for i=0,numVtxs-1 do
						local v = vtxs + i
						-- sx sy are in [0,app.width)x[0,app.height) coords
						local s = vec2d(trunc2(app:transform(v.x, v.y, v.z, 1)))
						local distSq = (mouseUL - s):lenSq()
						if distSq < bestDistSq then
							bestDistSq = distSq
							bestVtxIndexSet = {[i]=true}
						-- only select the first one
						-- maybe later I'll add a selection screen-space bbox like blender...
						--elseif distSq == bestDistSq then
						--	bestVtxIndexSet[i] = true
						end
					end
					if bestVtxIndexSet then
						self.mouseoverVertexIndexSet = bestVtxIndexSet
					end
				elseif self.meshEditForm == 'edges' then
					-- find the best edge, toggle its selection if not selected
					local bestDistSq = math.huge
					local bestEdges
					for i=0,getNumIndexes()-1,3 do
--DEBUG:print('edge sel', i, getNumIndexes())
						local v0 = getVtxIndPtr(i + 0)
						local v1 = getVtxIndPtr(i + 1)
						local v2 = getVtxIndPtr(i + 2)
						local s0 = vec2d(trunc2(app:transform(v0.x, v0.y, v0.z, 1)))
						local s1 = vec2d(trunc2(app:transform(v1.x, v1.y, v1.z, 1)))
						local s2 = vec2d(trunc2(app:transform(v2.x, v2.y, v2.z, 1)))
						local sd1 = s2 - s1
						local sd0 = s1 - s0
						local curl = sd1:det(sd0)
						local s = table{s0, s1, s2}
						if curl > 0 then -- skip edges on tris pointing away from the camera, maybe
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
									-- only select the first one
									--elseif distSq == bestDistSq then
									--	bestEdges:insert(vec2i(table{ii1, ii2}:sort():unpack()))
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
					local bestDistSq = math.huge
					local bestTris
					for i=0,getNumIndexes()-1,3 do
						local i0 = getIndex(i)
						local i1 = getIndex(i + 1)
						local i2 = getIndex(i + 2)
						local v0 = vtxs + i0
						local v1 = vtxs + i1
						local v2 = vtxs + i2
						local s0 = vec2d(trunc2(app:transform(v0.x, v0.y, v0.z, 1)))
						local s1 = vec2d(trunc2(app:transform(v1.x, v1.y, v1.z, 1)))
						local s2 = vec2d(trunc2(app:transform(v2.x, v2.y, v2.z, 1)))
						local sd1 = s2 - s1
						local sd0 = s1 - s0
						local curl = sd1:det(sd0)
						local s = table{s0, s1, s2}
						local n = table()	-- normal in screen-space, pointing out of the tri, perp to line from s[j] to s[j+1 mod-based-1 3]
						for j=1,3 do
							local delta = s[(j%3)+1] - s[j]
							n[j] = delta:perp():normalize()
						end
						-- skip edges on tris pointing away from the camera, maybe
						-- test det = half of area in pixels to skip degen cases where tri is a line
						if curl > 2 then
							-- find mouse screen coords on tri barycenter screen coords
							-- project to tri

							local closest = mouseUL:clone()
							for j=1,3 do
								local cd = closest - s[j]
								local cdn = cd:dot(n[j])
								if cdn > 0 then	-- if mouse is out of this edge then
									cd = cd - n[j] * cdn	-- then project back to edge
									closest = cd + s[j]
								end
							end

							local distSq = (closest - mouseUL):lenSq()
							if distSq < bestDistSq then
								bestTris = table{i}
								bestDistSq = distSq
							-- only select the first one
							--elseif distSq == bestDistSq then
							--	bestTris:insert(i)
							end
						end
					end
					if bestTris then
						self.mouseoverTris = bestTris
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
			and app:keyr'mouse_left'
			then
				if self.meshEditMode == nil then
					if self.meshEditForm == 'vertexes' then
						-- toggle
						for i in pairs(self.mouseoverVertexIndexSet) do
							self.selectedVertexIndexSet[i] = not self.selectedVertexIndexSet[i] or nil
						end
						refreshSelection()
					elseif self.meshEditForm == 'edges' then

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

						-- now rebuild vertexes from selected edges
						self.selectedVertexIndexSet = {}
						for _,e in ipairs(self.selectedEdges) do
							for _,ii in ipairs{e:unpack()} do
								local i = getIndex(ii)
								self.selectedVertexIndexSet[i] = true
							end
						end
						refreshSelection(true)	-- true = don't also rebuild selectedEdges
					elseif self.meshEditForm == 'tris' then
						for _,t in ipairs(self.mouseoverTris) do
							local j = self.selectedTris:find(t)
							if j then	-- if we have then remove
								self.selectedTris:remove(j)
							else		-- if we don't have then add
								self.selectedTris:insert(t)
							end
						end

						-- now rebuild vertexes from selected edges
						self.selectedVertexIndexSet = {}
						for _,t in ipairs(self.selectedTris) do
							for ii=0,2 do
								local i = getIndex(t+ii)
								self.selectedVertexIndexSet[i] = true
							end
						end
						refreshSelection(nil, true)	-- second true = don't also rebuild selectedTris
					else
						error'here'
					end
				else
					self.meshEditMode = nil
				end
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
				end

				for i in pairs(self.selectedVertexIndexSet) do
					if i >= 0 and i < numVtxs then
						local v = vtxs + i
						local origXYZ = self.vtxOrigPos[1+i]
						local origUV = self.vtxOrigTCs[1+i]
						if self.meshEditMode == 'translate' then
							if not self.editTexCoords then
								v.x, v.y, v.z = origXYZ.x, origXYZ.y, origXYZ.z
								if usedx then v.x = v.x + self.totalTranslation.x end
								if usedy then v.y = v.y + self.totalTranslation.y end
								if usedz then v.z = v.z + self.totalTranslation.z end
							else
								-- TODO TODO TODO bumpmapping-like, construct a basis in uv coords and transform the mouse movement into texcoord space
								v.u, v.v = origUV.x, origUV.y
								if usedx then v.u = tonumber(v.u) - math.round(self.totalTranslation.x / 256) end
								if usedy then v.v = tonumber(v.v) - math.round(self.totalTranslation.y / 256) end
							end
						elseif self.meshEditMode == 'scale' then
							-- TODO instead, project dx,dy,dz onto the regression plane of all selected vtxs
							local s = 1 + .01 * self.totalScreenTranslate.x
							if not self.editTexCoords then
								v.x, v.y, v.z = origXYZ.x, origXYZ.y, origXYZ.z
								if usedx then v.x = (v.x - self.selVtxCOM.x) * s + self.selVtxCOM.x end
								if usedy then v.y = (v.y - self.selVtxCOM.y) * s + self.selVtxCOM.y end
								if usedz then v.z = (v.z - self.selVtxCOM.z) * s + self.selVtxCOM.z end
							else
								v.u, v.v = origUV.x, origUV.y
								if usedx then v.u = (tonumber(v.u) - self.selTexCoordCOM.x) * s + self.selTexCoordCOM.x end
								if usedy then v.v = (tonumber(v.v) - self.selTexCoordCOM.y) * s + self.selTexCoordCOM.y end
							end
						elseif self.meshEditMode == 'rotate' then
							local mouseCurrentAngle = math.round(math.deg((vec2d(mouseX, mouseY) - 128):angle()))
							-- negative because screen coordinates are a LHS system
							-- TODO TODO TODO make *everything* RHS and even screen-space origin in lower-left
							self.screenRotateAngle = -(mouseCurrentAngle - self.rotateMouseScreenDownAngle)

							if not self.editTexCoords then
								local q = quatd():fromAngleAxis(
									rotAxis.x,
									rotAxis.y,
									rotAxis.z,
									self.screenRotateAngle
								)
								local pos = origXYZ - self.selVtxCOM
								pos = q:rotate(pos)
								pos = pos + self.selVtxCOM
								v.x, v.y, v.z = pos.x, pos.y, pos.z
							else
								local cosTheta = math.cos(math.rad(self.screenRotateAngle))
								local sinTheta = math.sin(math.rad(self.screenRotateAngle))
								local pos = origUV - self.selTexCoordCOM
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
				local v1 = vtxs + getIndex(i1)
				local v2 = vtxs + getIndex(i2)
				app:drawSolidLine3D(
					v1.x, v1.y, v1.z,
					v2.x, v2.y, v2.z,
					0x1a, 4, app.paletteMenuTex)
			end
			for _,i in ipairs(self.selectedTris) do
				local v0 = getVtxIndPtr(i)
				local v1 = getVtxIndPtr(i+1)
				local v2 = getVtxIndPtr(i+2)
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
				local s = 1 + .01 * self.totalScreenTranslate.x
				app:drawMenuText('scale='..s, x, y)
			elseif self.meshEditMode == 'rotate' then
				local usedx, usedy, usedz = self.axisFlags.x, self.axisFlags.y, self.axisFlags.z
				local rotAxis
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

				app:drawMenuText('rot='..self.screenRotateAngle..' @ '..rotAxis, x, y)
			end
			y = y + 8
			x = 0
			if self.meshEditMode then
				app:drawMenuText('>'..self.meshEditModeText, x, y)
			end
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
		local vs, vts, is = getMeshLists()	--- table-of-vec3d/vec2d's, 0-based indexes
		local oldNumVtxs = #vs
		local cvs, cvts, cis = BlobMesh3D.getDefaultCubeLists()	-- table-of-tables, 1-based indexes

		vs:append(cvs:mapi(function(v) return vec3d(table.unpack(v)) end))
		vts:append(cvts:mapi(function(vt) return vec2d(table.unpack(vt)) end))
		is:append(table.mapi(cis, function(ci) return ci-1 + oldNumVtxs end))	-- convert to 0-based and offset by old # vtxs

		self:replaceMeshBlobWithLists(vs, vts, is)

		-- reset mouseover selection-testing tables to only select the new indexes
		self.mouseoverVertexIndexSet = {}
		self.selectedVertexIndexSet = range(oldNumVtxs, oldNumVtxs + #cvs - 1)
			:mapi(function(i) return true, i end)
			:setmetatable(nil)	-- select new vtxs only
		refreshSelection()
	end
	x = x + 7

	if self:guiButton('X', x, y, false, 'x-axis') then
		local fwd = -orbit.angle:zAxis()
		if fwd.x < 0 then
			orbit.angle:set(.5, -.5, -.5, .5)
		else
			orbit.angle:set(.5, .5, .5, .5)
		end
		local dist = (orbit.pos - orbit.orbit):length()
		orbit.pos = orbit.angle:zAxis() * dist + orbit.orbit
	end
	x = x + 6
	if self:guiButton('Y', x, y, false, 'x-axis') then
		local fwd = -orbit.angle:zAxis()
		if fwd.y < 0 then
			orbit.angle:set(math.sqrt(.5), 0, 0, math.sqrt(.5))
		else
			orbit.angle:set(0, math.sqrt(.5), math.sqrt(.5), 0)
		end
		local dist = (orbit.pos - orbit.orbit):length()
		orbit.pos = orbit.angle:zAxis() * dist + orbit.orbit
	end
	x = x + 6
	if self:guiButton('Z', x, y, false, 'x-axis') then
		local fwd = -orbit.angle:zAxis()
		if fwd.z < 0 then	-- looking along z-, toggle to z+
			orbit.angle:set(0,1,0,0)
		else
			orbit.angle:set(0,0,0,1)	-- identity = looking along z-
		end
		local dist = (orbit.pos - orbit.orbit):length()
		orbit.pos = orbit.angle:zAxis() * dist + orbit.orbit
	end
	x = x + 7

	if self.meshEditForm == 'tris' then
		-- TODO maybe flip-edge should maybe be an edge function?
		if self:guiButton('F', x, y, false, 'flip') then
			-- flip tris ...
			-- 1) get tris selected
			-- 2) flip ...
			-- how to generalize that for any more than two tris that share 1 edge?
			if #self.selectedTris ~= 2 then
				print('need 2 tris, got '..#self.selectedTris..' tris')
			else
				-- and if # selected vtxs == 4 exactly ...
				local vs, vts, is = getMeshLists()

				-- find the common edge between the two tris
				-- and exchange tris
				local found
				local t1, t2 = table.unpack(self.selectedTris)
				for i=0,2 do
					for j=0,2 do
						local a1 = is[1+t1+i]
						local a2 = is[1+t1+((i+1)%3)]
						local a3 = is[1+t1+((i+2)%3)]
						local b1 = is[1+t2+j]
						local b2 = is[1+t2+((j+1)%3)]
						local b3 = is[1+t2+((j+2)%3)]
						if a1 == b1 and a2 == b2 then
							-- swap indexes
							is[1+t1+0] = a3
							is[1+t1+1] = b1
							is[1+t1+2] = b3
							is[1+t2+0] = b3
							is[1+t2+1] = b2
							is[1+t2+2] = a3
							found = true
							goto done
						elseif a2 == b1 and a1 == b2 then
							is[1+t1+0] = a3
							is[1+t1+1] = b1
							is[1+t1+2] = b3
							is[1+t2+0] = b3
							is[1+t2+1] = b2
							is[1+t2+2] = a3
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
					self:replaceMeshBlobWithLists(vs, vts, is)

					-- refresh edges and tris, but vtxs shouldn't change
					refreshSelection()
				end
			end
		end
		x = x + 6
	elseif self.meshEditForm == 'edges' then
		if self:guiButton('S', x, y, false, 'split') then
			local vs, vts, is = getMeshLists()
			local trisToRemove = {}		-- keys are 0-based indexes of tris (divisible by 3)
			for _,e in ipairs(self.selectedEdges) do
				-- find the tris on either side
				-- remove the tris on either side
				-- insert a vertex between these two
				local ei0, ei1 = e:unpack()	-- edges are of indexes-of-indexes
				local evi0 = getIndex(ei0)
				local evi1 = getIndex(ei1)
				local i1 = is[1+ei0]
				local i2 = is[1+ei1]
				local v1 = vtxs + i1
				local v2 = vtxs + i2
				local pos1 = vec3d(v1.x, v1.y, v1.z)
				local pos2 = vec3d(v2.x, v2.y, v2.z)
				local tc1 = vec2d(v1.u, v1.v)
				local tc2 = vec2d(v2.u, v2.v)
				local newvtxindex = #vs	-- indexes are 0-based
				vs:insert((pos1 + pos2) * .5)
				vts:insert((tc1 + tc2) * .5)
				for ti=0,#is-3,3 do
					for j=0,2 do
						local tij0 = is[1 + ti + j]
						local tij1 = is[1 + ti + (j+1)%3]
						local tij2 = is[1 + ti + (j+2)%3]
						if (tij0 == evi0 and tij1 == evi1)
						or (tij0 == evi1 and tij1 == evi0)
						then
							-- if we are to remove this tri, then add its replacements as well
							is:append{
								tij0, newvtxindex, tij2,
								newvtxindex, tij1, tij2,
							}
							trisToRemove[ti] = true
						end
					end
				end
				self.selectedVertexIndexSet[newvtxindex] = true
			end
			-- traverse from greatest to least
			for _,ti in ipairs(table.keys(trisToRemove):sort(function(a,b) return a > b end)) do
				for j=0,2 do
					-- notice that removing elements from indexes will invalidate any further index-of-indexes
					-- which means selectedTris becomes invalidated, selectedEdges becomes invalidated
					is:remove(1 + ti)
				end
			end

			self.undo:push()
			self:replaceMeshBlobWithLists(vs, vts, is)
			refreshSelection()
		end
	end


	app:drawMenuText(('fwd {%.3f, %.3f, %.3f}'):format((-orbit.angle:zAxis()):unpack()), 0, 240)
	app:drawMenuText(('q {%.3f, %.3f, %.3f, %.3f}'):format(orbit.angle:unpack()), 0, 248)

	---------------- KEYBOARD ----------------

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

					if #self.meshEditModeText > 0 then
						self.meshEditModeText = self.meshEditModeText:sub(1, -2)
					else
						resetVtxEditPos()
						self.meshEditMode = nil
					end

				else
					-- if we're not in an edit mode then delete vertexes
					-- and then regen blobs or something
					-- hmm
					local vs, vts, is = getMeshLists()
assert.eq(#is % 3, 0)
					-- delete selected vertexes
					-- delete or merge touching triangles?
					-- then rebuild current mesh blob from arrays

--DEBUG:print('old')
--DEBUG:print('vs', #vs, require 'ext.tolua'(vs))
--DEBUG:print('vts', #vts, require 'ext.tolua'(vts))
--DEBUG:print('is', #is, require 'ext.tolua'(is))

					local newvs = table()
					local newvts = table()
					local newis = table()

					if self.meshEditForm == 'vertexes'
					or self.meshEditForm == 'edges'
					then
						local vimap = {}	-- 0-based map from old index to new (post-delete) index
						local newvi = 0
--DEBUG:print('vimap')
						for i=0,numVtxs-1 do
							if not self.selectedVertexIndexSet[i] then
								vimap[i] = newvi
--DEBUG:print('', i..' => '..newvi)
								newvi = newvi + 1
								newvs:insert(vs[1+i])
								newvts:insert(vts[1+i])
							end
						end
--DEBUG:print('selectedTris', require 'ext.tolua'(self.selectedTris))
						for i=0,#is-3,3 do
--DEBUG:print('remapping tri', i)
							local i1 = is[i+1]
							local i2 = is[i+2]
							local i3 = is[i+3]
							-- in delete-vertex mode , delete all tris touching the deleted vertex
							-- TODO or should we merge, and only delete upon degen-tri-to-line case?
							local newi1 = vimap[i1]
							local newi2 = vimap[i2]
							local newi3 = vimap[i3]
							if newi1 and newi2 and newi3 then
--DEBUG:print('tri indexes from', i1, i2, i3, 'to', newi1, newi2, newi3)
								newis:insert(newi1)
								newis:insert(newi2)
								newis:insert(newi3)
							end
						end
					elseif self.meshEditForm == 'tris' then
						-- delete the face, and then remove/remap any unused vtxs
						newis = table(is)
						newvs = table(vs)
						newvts = table(vts)
						-- j is 0-based mod-3 index of the start of a triangle in our index buffer
						-- so traverse in reverse order and remove-3 per tri we want to remove
						for _,i in ipairs(table(self.selectedTris):sort():reverse()) do
--DEBUG:print('removing tri', i)
							for k=0,2 do
								newis:remove(1+i)	-- newis is 1-based ...
							end
						end
						-- now flag good vtxs ...
						local vused = {}	-- keys are 0-based vtx indexes
						for _,i in ipairs(newis) do
							vused[i] = true
						end
						-- and any unflagged vtxs, remove (and remap indexes)
						for i=numVtxs-1,0,-1 do	-- i is 0-based vtx index
							if not vused[i] then
								-- remap indexes...
								for j=1,#newis do
									if newis[j] > i then
										newis[j] = newis[j] - 1
									end
								end
								-- remove...
								newvs:remove(i+1)
								newvts:remove(i+1)
							end
						end
					else
						error'here'
					end
					assert.eq(#newis % 3, 0)

--DEBUG:print('new')
--DEBUG:print('vs', #newvs, require 'ext.tolua'(newvs))
--DEBUG:print('vts', #newvts, require 'ext.tolua'(newvts))
--DEBUG:print('is', #newis, require 'ext.tolua'(newis))

					self.undo:push()
					self:replaceMeshBlobWithLists(newvs, newvts, newis)

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
					self.screenRotateAngle = 0

					local drawViewInvMat = vec4x4fcol()
					drawViewInvMat:inv4x4(app.ram.viewMat)
					self.selRotFwdDir = vec3d(
						drawViewInvMat.ptr[8],
						drawViewInvMat.ptr[9],
						drawViewInvMat.ptr[10]
					):normalize()
				end
			end

			-- TODO or maybe use this for flipping common edge between two tris?
			if app:keyp'f' then
				self.drawFaces = not self.drawFaces
			end
			if app:keyp'n' then
				self.drawNormals = not self.drawNormals
			end
			if app:keyp'w' then
				self.wireframe = not self.wireframe
			end
			if app:keyp'o' then
				orbit.ortho = not orbit.ortho
			end

			if app:keyp'v' then
				self.meshEditForm = 'vertexes'
			end
			if app:keyp'e' then
				self.meshEditForm = 'edges'
			end
			if app:keyp't' then
				self.meshEditForm = 'tris'
			end

			if app:keyp'x' then
				self.axisFlags.x = not self.axisFlags.x or nil	-- 'or nil' so false's are nil's, so next(self.axisFlags) == nil means its empty
				resetVtxEditPos()
			end
			if app:keyp'y' then
				self.axisFlags.y = not self.axisFlags.y or nil
				resetVtxEditPos()
			end
			if app:keyp'z' then
				self.axisFlags.z = not self.axisFlags.z or nil
				resetVtxEditPos()
			end

			-- collect translate/scale/rotate text input ...
			-- TODO perfect time to use EditMesh3D:event() ........
			if self.meshEditMode then
				local numo9_keys = require 'numo9.keys'
				local getAsciiForKeyCode = numo9_keys.getAsciiForKeyCode
				local keyCodeForName = numo9_keys.keyCodeForName
				for _,key in ipairs{'minus', 'period', '0', '1', '2', '3', '4', '5', '6', '7', '8', '9'} do
					if app:keyp(key) then
						self.meshEditModeText = self.meshEditModeText .. string.char(getAsciiForKeyCode(keyCodeForName[key]))
					end
				end
				if app:keyp'return' then
					-- then use this transform # for our transformation
					error'TODO'
				end
			end
		end
	end

	self:guiSetClipRect(-1000, 0, 3000, 256)
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
	self.selectedTris = table()
	self.mouseoverEdges = table()
	self.mouseoverTris = table()

	self:updateBlobChanges()
end

-- expects 0-based indexes (like the blob stores)
function EditMesh3D:replaceMeshBlobWithLists(vs, vts, is)
	local app = self.app
	local newblob = BlobMesh3D:loadFromLists(
		-- OBJloader compat, convert vec3d to lua-table
		vs:mapi(function(v) return {v:unpack()} end),
		vts:mapi(function(v) return {v:unpack()} end),
		-- convert to 1-based because the next function is made to be OBJloader-compatible and .obj format is 1-based
		is:mapi(function(i) return i + 1 end)
	)
	app.blobs.mesh3d[self.mesh3DBlobIndex+1] = newblob
	self:updateBlobChanges()
end

return EditMesh3D
