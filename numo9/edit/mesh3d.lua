--[[
TODO tempting to store an .obj / Mesh per model
since I'm using them for loading and unloading
and since my mesh lib has all the nice mesh operations anwyays
--]]
local ffi = require 'ffi'
local table = require 'ext.table'
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



local EditMesh3D = require 'numo9.ui':subclass()

function EditMesh3D:init(args)
	EditMesh3D.super.init(self, args)

	self.undo = Undo{
		get = function()
			return {
				data = self.app.blobs.mesh3d[self.mesh3DBlobIndex+1]:toBinStr(),
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

	self.tileSel = TileSelect{edit=self}
	self.tileSel.pos.x = 2	-- initialize to one 16x16 past the 0,0 tile (which is very often clear)

	self.orbit = Orbit(self.app)

	self.mouseoverVertexIndexSet = {}	-- keys are 0-based vertex indexes
	self.selectedVertexIndexSet = {}	-- keys are 0-based vertex indexes

	self.selectedEdges = table()	-- table of vec2i's of 0-based index-of-indexes between two edges
	self.selectedTris = table()		-- table of triplets " " "

	self.mouseoverEdges = table()

	self.axisFlags = {}
	self.meshEditMode = nil			-- translate rotate scale
	self.meshEditForm = 'vertexes'	-- vertexes edges faces

	-- table-of-vec3d's to store original vertex positiosn before edit operation
	self.vtxOrigPos = table()
	self.totalTranslation = vec3d()		-- total translation since translate start, in world coordinates
	self.totalScreenTranslate = vec2d()	-- total translation since scale start, in screen coordinates.  TODO track in world coords and project to plane of vtxs
	self.totalScreenRotate = 0			-- total rotation since rotate start, in screen coordinates, angle around center, in degrees

	self.undo:clear()
end

local function linePointDist(linePos, lineDir, pt)
	local d = pt - linePos
	local n = d:cross(linePos)
	local n2 = lineDir:cross(n)
	local dist = n2:dot(d)
	return dist
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
	local function getMeshLists()
		local vs = table()
		local vts = table()
		for i=0,numVtxs-1 do
			local v = vtxs + i
			vs:insert(vec3d(v.x, v.y, v.z))
			vts:insert(vec2d(v.u, v.v))
		end
		local is = table()
		for i=0,getNumIndexes()-1 do
			is:insert(getIndex(i))
		end
		-- table indexes ar 1-based, though is values are 0-based
		return vs, vts, is
	end
	local function refreshSelection(skipEdges)
		-- TODO we could do calcCOM here isntead of when we start to do a translate/rotate/scale ...
		if not skipEdges then
			self.selectedEdges = table()	-- table of pairs of 0-based indexes between two edges
		end
		self.selectedTris = table()

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
			local i1 = i+1
			local i2 = i+2
			if self.selectedVertexIndexSet[getIndex(i)]
			and self.selectedVertexIndexSet[getIndex(i1)]
			and self.selectedVertexIndexSet[getIndex(i2)]
			then
				self.selectedTris:insert{i, i1, i2}
			end
		end
	end



	if mesh3DBlob then
		numVtxs = mesh3DBlob:getNumVertexes()
		numIndexes = mesh3DBlob:getNumIndexes()
		vtxs = mesh3DBlob:getVertexPtr()
		inds = mesh3DBlob:getIndexPtr()
	end

	if not self.tileSel:doPopup() then
		if mesh3DBlob then
			handled = orbit:beginDraw() or handled
			app:matscale(1/32768, 1/32768, 1/32768)

			-- draw the 3D model here
			-- TODO this goes slow af
			-- instead please swap out polygon mode (is it possible?) or (can't do geom shaders and be webgl2 compat) hmm ...
			if self.wireframe then
				local color = 0x2e
				local thickness = 2

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
					local sx, sy = app:transform(v.x, v.y, v.z, 1)
					local distSq = (mouseULX - sx)^2 + (mouseULY - sy)^2
					if distSq < bestDistSq then
						bestDistSq = distSq
						bestVtxIndexSet = {[i]=true}
					elseif distSq == bestDistSq then
						bestVtxIndexSet[i] = true
					end
				end
				if bestVtxIndexSet then
					self.mouseoverVertexIndexSet = bestVtxIndexSet
				end
			elseif self.meshEditForm == 'edges' then
				-- find the best edge, toggle its selection if not selected
				local bestDist = math.huge
				local bestEdges
				for i=0,getNumIndexes()-1,3 do
					-- TODO here maybe skip edges on faces pointing away from the camera, maybe
					for j=0,2 do
						local ii1 = i+j
						local ii2 = i+((j+1)%3)
						local i1 = getIndex(ii1)
						local i2 = getIndex(ii2)
						local v1 = vtxs + i1
						local v2 = vtxs + i2
						local sx1, sy1 = app:transform(v1.x, v1.y, v1.z, 1)
						local sx2, sy2 = app:transform(v2.x, v2.y, v2.z, 1)
						-- line segment from edge v1 to v2 in screen space
						local sdx = sx2 - sx1
						local sdy = sy2 - sy1
						local sdlen = math.sqrt(sdx^2 + sdy^2)
						if sdlen > 0.1 then
							local nsdx = sdx / sdlen
							local nsdy = sdy / sdlen
							-- line segment from start of edge to mouse
							local mdx = mouseULX - sx1
							local mdy = mouseULY - sy1
							local mouseToV1Len = math.sqrt(mdx^2 + mdy^2)
							local mouseToV2Len = math.sqrt((mouseULX - sx2)^2 + (mouseULY - sy2)^2)
							-- mouse-delta dot normalized-segment-delta = how far along s1->s2 that the nearest point to the mouse-coordinates is
							-- if this is outside [0,sdlen] then clamp it to that
							local param = mdx * nsdx + mdy * nsdy
							param = math.clamp(param, 0, sdlen)
							local mousePtOnSegX = sx1 + nsdx * param
							local mousePtOnSegY = sy1 + nsdy * param
							local mousePtToMouseLen = math.sqrt((mousePtOnSegX - mouseULX)^2 + (mousePtOnSegY - mouseULY)^2)
							local dist = math.min(mouseToV1Len, mouseToV2Len, mousePtToMouseLen)
							if dist < bestDist then
								bestEdges = table{vec2i(table{ii1, ii2}:sort():unpack())}
								bestDist = dist
							elseif dist == bestDist then
								bestEdges:insert(vec2i(table{ii1, ii2}:sort():unpack()))
							end
						end
					end
				end
				if bestEdges then
					self.mouseoverEdges = bestEdges
				end
			elseif self.meshEditForm == 'faces' then
				-- find the best tri, toggle its selection if not selected
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

			local function calcSelVtxCOM()
				self.selVtxCOM = vec3d()
				local count = 0
				for i in pairs(self.selectedVertexIndexSet) do
					if i >= 0 and i < numVtxs then
						local v = vtxs + i
						self.selVtxCOM = self.selVtxCOM + vec3d(v.x, v.y, v.z)
						count = count + 1
					end
				end
				if count == 0 then
					self.meshEditMode = nil
				else
					self.selVtxCOM = self.selVtxCOM / count
				end
			end

			local function setVtxEditPos()
				for i=0,numVtxs-1 do
					local v = vtxs + i
					self.vtxOrigPos[i] = vec3d(v.x, v.y, v.z)
				end
			end
			local function resetVtxEditPos()
				for i=0,numVtxs-1 do
					local v = vtxs + i
					v.x, v.y, v.z = self.vtxOrigPos[i]:unpack()
				end
			end


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
					end
				else
					--self.undo:pushContinuous()
					self.undo:push()
					self.meshEditMode = nil
				end
			end

			if app:keyp'backspace'
			or app:keyp'delete'
			then
				-- if we're in an edit mode then reset it
				-- TODO or is there a better 'cancel edit' button because 'escape' and '`' is taken....
				if self.meshEditMode then
					resetVtxEditPos()
					self.meshEditMode = nil
				else
					self.undo:push()

					-- if we're not in an edit mode then delete vertexes
					-- and then regen blobs or something
					-- hmm
					local vs, vts, is = getMeshLists()
					-- delete selected vertexes
					-- delete or merge touching triangles?
					-- then rebuild current mesh blob from arrays

					local imap = {}	-- 0-based map from old index to new (post-delete) index
					local newvi = 0
					local newvs = table()
					local newvts = table()
					for i=0,numVtxs-1 do
						if not self.selectedVertexIndexSet[i] then
							imap[i] = newvi
							newvi = newvi + 1
							newvs:insert(vs[1+i])
							newvts:insert(vts[1+i])
						end
					end
					local newis = table()
					assert.eq(#is % 3, 0)
					for i=#is-2,1,-3 do
						local i1 = is[i]
						local i2 = is[i+1]
						local i3 = is[i+2]
						if not (self.selectedVertexIndexSet[i1]
							or self.selectedVertexIndexSet[i2]
							or self.selectedVertexIndexSet[i3]
						) then
							newis:insert(imap[is[i1]])
							newis:insert(imap[is[i2]])
							newis:insert(imap[is[i3]])
						end
					end

					self:replaceMeshBlobWithLists(newvs, newvts, newis)

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
				self.meshEditMode = 'translate'
				setVtxEditPos()
				calcSelVtxCOM()	-- COM not needed but this exits meshEditMode if none are selected
				self.totalTranslation:set(0,0,0)
			end
			if app:keyp's' then
				self.meshEditMode = 'scale'
				setVtxEditPos()
				calcSelVtxCOM()
				self.totalScreenTranslate:set(0,0)
			end
			if app:keyp'r' then
				self.meshEditMode = 'rotate'
				setVtxEditPos()
				calcSelVtxCOM()
				self.totalScreenRotate = 0

				local drawViewInvMat = vec4x4fcol()
				drawViewInvMat:inv4x4(app.ram.viewMat)
				self.selRotFwdDir = vec3d(
					drawViewInvMat.ptr[8],
					drawViewInvMat.ptr[9],
					drawViewInvMat.ptr[10]
				):normalize()
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
					self.totalTranslation.x = self.totalTranslation.x + dx
					self.totalTranslation.y = self.totalTranslation.y + dy
					self.totalTranslation.z = self.totalTranslation.z + dz
				elseif self.meshEditMode == 'scale' then
					self.totalScreenTranslate.x = self.totalScreenTranslate.x + mouseULX - lastMouseULX
					self.totalScreenTranslate.y = self.totalScreenTranslate.y + mouseULY - lastMouseULY
				elseif self.meshEditMode == 'rotate' then
					self.totalScreenRotate = 0
				end

				for i in pairs(self.selectedVertexIndexSet) do
					if i >= 0 and i < numVtxs then
						local v = vtxs + i
						local orig = self.vtxOrigPos[i]
						if self.meshEditMode == 'translate' then
							v.x, v.y, v.z = orig.x, orig.y, orig.z
							if usedx then v.x = v.x + self.totalTranslation.x end
							if usedy then v.y = v.y + self.totalTranslation.y end
							if usedz then v.z = v.z + self.totalTranslation.z end
						elseif self.meshEditMode == 'scale' then
							-- TODO instead, project dx,dy,dz onto the regression plane of all selected vtxs
							v.x, v.y, v.z = orig.x, orig.y, orig.z
							local s = math.exp(.1 * self.totalScreenTranslate.x)
							if usedx then v.x = (v.x - self.selVtxCOM.x) * s + self.selVtxCOM.x end
							if usedy then v.y = (v.y - self.selVtxCOM.y) * s + self.selVtxCOM.y end
							if usedz then v.z = (v.z - self.selVtxCOM.z) * s + self.selVtxCOM.z end
						elseif self.meshEditMode == 'rotate' then
							local pos = orig - self.selVtxCOM
							local lastMouseNormalized = (vec2d(lastMouseX, lastMouseY) - 128):normalize()
							local mouseNormalized = (vec2d(mouseX, mouseY) - 128):normalize()
							local sinTheta = mouseNormalized:det(lastMouseNormalized)
							local deltaAngle = math.deg(math.asin(sinTheta))
							self.totalScreenRotate = self.totalScreenRotate + deltaAngle

							local q = quatd():fromAngleAxis(
								rotAxis.x,
								rotAxis.y,
								rotAxis.z,
								self.totalScreenRotate
							)
							pos = q:rotate(pos)
							pos = pos + self.selVtxCOM
							v.x, v.y, v.z = pos.x, pos.y, pos.z
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
			for _,tri in ipairs(self.selectedTris) do
				local i0, i1, i2 = table.unpack(tri)
				local v0 = getVtxIndPtr(i0)
				local v1 = getVtxIndPtr(i1)
				local v2 = getVtxIndPtr(i2)
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
				app:drawMenuText('xlate='..dx..', '..dy..', '..dz, x, y)
			elseif self.meshEditMode == 'scale' then
				local s = math.exp(.1 * self.totalScreenTranslate.x)
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

				app:drawMenuText('rot='..self.totalScreenRotate..' @ '..rotAxis, x, y)
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
			self.undo:clear()
		end,
		BlobMesh3D.generateDefaultCube				-- new blob generator:
	)
	x = x + 6

	self:guiBlobSelect(x, y, 'sheet', self, 'sheetBlobIndex')
	x = x + 6
	self:guiBlobSelect(x, y, 'palette', self, 'paletteBlobIndex')
	x = x + 6

	if self:guiButton('F', x, y, self.drawFaces, 'faces') then
		self.drawFaces = not self.drawFaces
	end
	x = x + 6
	if self:guiButton('W', x, y, self.wireframe, 'wireframe') then
		self.wireframe = not self.wireframe
	end
	x = x + 6
	if self:guiButton(orbit.ortho and 'O' or 'P', x, y, false, orbit.ortho and 'ortho' or 'projection') then
		orbit.ortho = not orbit.ortho
	end
	x = x + 6

	self.tileSel:button(x,y)
	x = x + 7

	self:guiRadio(x, y, {'vertexes', 'edges', 'faces'}, self.meshEditForm, function(result)
		self.meshEditForm = result
	end)
	x = x + 6*3 + 1

	-- TODO only show up in face-mode?
	-- or only flip faces selected regardless of mode?
	-- it's tempting to just make all selections vertex-driven...
	if self:guiButton('F', x, y, false, 'flip') then
		-- flip faces ...
		-- 1) get faces selected
		-- 2) flip ...
		-- how to generalize that for any more than two faces that share 1 edge?
		if not #self.selectedTris == 2 then
			print('need 2 tris, got '..#self.selectedTris..' tris')
		else
			self.undo:push()

			-- and if # selected vtxs == 4 exactly ...
			local vs, vts, is = getMeshLists()

			-- find the common edge between the two tris
			-- and exchange tris
			local found
			local t1, t2 = table.unpack(self.selectedTris)
			for i=0,2 do
				for j=0,2 do
					local a1 = is[1+t1[1+i]]
					local a2 = is[1+t1[1+((i+1)%3)]]
					local a3 = is[1+t1[1+((i+2)%3)]]
					local b1 = is[1+t2[1+j]]
					local b2 = is[1+t2[1+((j+1)%3)]]
					local b3 = is[1+t2[1+((j+2)%3)]]
					if a1 == b1 and a2 == b2 then
						-- swap indexes
						is[1+t1[1]] = a3
						is[1+t1[2]] = b1
						is[1+t1[3]] = b3
						is[1+t2[1]] = b3
						is[1+t2[2]] = b2
						is[1+t2[3]] = a3
						found = true
						goto done
					elseif a2 == b1 and a1 == b2 then
						is[1+t1[1]] = a3
						is[1+t1[2]] = b1
						is[1+t1[3]] = b3
						is[1+t2[1]] = b3
						is[1+t2[2]] = b2
						is[1+t2[3]] = a3
						found = true
						goto done
					end
				end
			end
::done::
			if not found then
				print"couldn't find, not flipping"
			else
				self:replaceMeshBlobWithLists(vs, vts, is)

				-- refresh edges and tris, but vtxs shouldn't change
				refreshSelection()
			end
		end
	end
	x = x + 6

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
		end
	end

	self:guiSetClipRect(-1000, 0, 3000, 256)
	self:drawTooltip()
end

function EditMesh3D:popUndo(redo)
	local app = self.app
	local entry = self.undo:pop(redo)
	if not entry then return end
	app.blobs.mesh3d[self.mesh3DBlobIndex+1] = blobClassForName.mesh3d(entry.data)
	self:updateBlobChanges()
end

-- expects 0-based indexes (like the blob stores)
function EditMesh3D:replaceMeshBlobWithLists(vs, vts, is)
	local app = self.app
	app.blobs.mesh3d[self.mesh3DBlobIndex+1] = BlobMesh3D:loadFromLists(
		-- OBJloader compat, convert vec3d to lua-table
		vs:mapi(function(v) return {v:unpack()} end),
		vts:mapi(function(v) return {v:unpack()} end),
		-- convert to 1-based because the next function is made to be OBJloader-compatible and .obj format is 1-based
		is:mapi(function(i) return i + 1 end)
	)
	self:updateBlobChanges()
end

return EditMesh3D
