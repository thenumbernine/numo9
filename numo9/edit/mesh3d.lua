local table = require 'ext.table'
local math = require 'ext.math'
local vec3d = require 'vec-ffi.vec3d'
local Orbit = require 'numo9.ui.orbit'
local TileSelect = require 'numo9.ui.tilesel'
local BlobMesh3D = require 'numo9.blob.mesh3d'

local numo9_rom = require 'numo9.rom'
local tileSizeInBits = numo9_rom.tileSizeInBits

local EditMesh3D = require 'numo9.ui':subclass()

function EditMesh3D:init(args)
	EditMesh3D.super.init(self, args)
	self:onCartLoad()
end

function EditMesh3D:onCartLoad()
	self.mesh3DBlobIndex = 0
	self.sheetBlobIndex = 0
	self.paletteBlobIndex = 0

	self.drawFaces = true
	self.wireframe = false

	self.tileSel = TileSelect{edit=self}

	self.orbit = Orbit(self.app)

	self.selectedVertexIndexSet = {}
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

	local mesh3DBlob = app.blobs.mesh3d[self.mesh3DBlobIndex+1]
	local numVtxs
	local numIndexes
	local vtxs
	local inds
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
				local thickness = 1

				if numIndexes == 0 then	-- no indexes? just draw all vtxs
					for i=0,numVtxs-3,3 do
						for j=0,2 do
							local a = vtxs + i+j
							local b = vtxs + i+(j+1)%3
							app:drawSolidLine3D(
								a.x, a.y, a.z,
								b.x, b.y, b.z,
								color,
								thickness,
								app.paletteMenuTex)
						end
					end
				else	-- draw indexed vertexes
					for i=0,numIndexes-3,3 do
						for j=0,2 do
							local a = vtxs + inds[i+j]
							local b = vtxs + inds[i+(j+1)%3]
							app:drawSolidLine3D(
								a.x, a.y, a.z,
								b.x, b.y, b.z,
								color,
								thickness,
								app.paletteMenuTex)
						end
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
			gl.glDepthMask(gl.GL_FALSE)

			--[[
			local mouseDir =
				- orbit.angle:zAxis()
				+ orbit.angle:xAxis() * (mouseX - 128) / 128
				- orbit.angle:yAxis() * (mouseY - 128) / 128
			local mousePos = orbit.pos + .1 * mouseDir
			-- TODO need to also rotate this by orbit orientation...
			--]]

--print('mouse XY', mouseULX, mouseULY)
			local bestDistSq = math.huge
			local bestVtxIndexSet
			for i=0,numVtxs-1 do
				local v = vtxs + i
				-- sx sy are in [0,app.width)x[0,app.height) coords
				local sx, sy = app:transform(v.x, v.y, v.z, 1)
				local distSq = (mouseULX - sx)^2 + (mouseULY - sy)^2
--print(i, v, sx, sy, math.sqrt(distSq))
				if distSq < bestDistSq then
					bestDistSq = distSq
					bestVtxIndexSet = {[i]=true}
				elseif distSq == bestDistSq then
					bestVtxIndexSet[i] = true
				end
			end
--print('mouseLine', mousePos, mouseDir, math.sqrt(bestDistSq), bestVtxIndexSet)
			if bestVtxIndexSet then
				self.mouseoverVertexIndexSet = bestVtxIndexSet
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

			if app:keyp'mouse_left' then
				if self.meshEditMode == nil then
					-- toggle
					for i in pairs(self.mouseoverVertexIndexSet) do
						self.selectedVertexIndexSet[i] = not self.selectedVertexIndexSet[i] or nil
					end
				elseif self.meshEditMode == 'translate' then
					self.meshEditMode = nil
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
			end

			if app:keyp'g' then
				self.meshEditMode = 'translate'

			-- esc is menu toggle, backtick is console toggle
			-- what's left for undo translation? regular ctrl+z?
			--elseif app:keyp'esc' then
				--self.meshEditMode = nil
				-- TODO reset selected vertex positions back to their origin
			end

			if self.meshEditMode == 'translate'
			and (mouseULX ~= lastMouseULX or mouseULY ~= lastMouseULY)
			then
				-- inverse-transform screen-coordinates into world-coordinates
				-- translate accordingly

				-- [[ TODO parameterize along mouseline, translate at same depth
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
				--]]
				--[[
				local sz = 0
				--]]

				local x1b, y1b, z1b, w1b = app:invTransform(mouseULX, mouseULY, sz or 0)
				local invw1b = 1 / w1b
				x1b = x1b * invw1b
				y1b = y1b * invw1b
				z1b = z1b * invw1b

				local x2b, y2b, z2b, w2b = app:invTransform(lastMouseULX, lastMouseULY, sz or 0)
				local invw2b = 1 / w2b
				x2b = x2b * invw2b
				y2b = y2b * invw2b
				z2b = z2b * invw2b

				local dx = x2b - x1b
				local dy = y2b - y1b
				local dz = z2b - z1b

--print(dx, dy, dz)

				for i in pairs(self.selectedVertexIndexSet) do
					if i >= 0
					and i < numVtxs
					then
						local v = vtxs + i
						v.x = v.x - dx
						v.y = v.y - dy
						v.z = v.z - dz
					end
				end
			end

			if self.mouseoverVertexIndexSet then
				for i in pairs(self.mouseoverVertexIndexSet) do
					if i >= 0
					and i < numVtxs
					then
						local v = vtxs + i

						app:drawSolidLine3D(
							v.x-1024, v.y, v.z,
							v.x+1024, v.y, v.z,
							0x19, 8, app.paletteMenuTex)
						app:drawSolidLine3D(
							v.x, v.y-1024, v.z,
							v.x, v.y+1024, v.z,
							0x19, 8, app.paletteMenuTex)
						app:drawSolidLine3D(
							v.x, v.y, v.z-1024,
							v.x, v.y, v.z+1024,
							0x19, 8, app.paletteMenuTex)

						if not self.tooltip then
							self:setTooltip(tostring(v), mouseX-8, mouseY-8, 0xfc, 0)
						end
					end
				end
			end
			if self.selectedVertexIndexSet then
				for i in pairs(self.selectedVertexIndexSet) do
					if i >= 0
					and i < numVtxs
					then
						local v = vtxs + i

						app:drawSolidLine3D(
							v.x-1024, v.y, v.z,
							v.x+1024, v.y, v.z,
							0x1a, 8, app.paletteMenuTex)
						app:drawSolidLine3D(
							v.x, v.y-1024, v.z,
							v.x, v.y+1024, v.z,
							0x1a, 8, app.paletteMenuTex)
						app:drawSolidLine3D(
							v.x, v.y, v.z-1024,
							v.x, v.y, v.z+1024,
							0x1a, 8, app.paletteMenuTex)

						if not self.tooltip then
							self:setTooltip(tostring(v), mouseX-8, mouseY-8, 0xfc, 0)
						end
					end
				end
			end

			gl.glDepthMask(gl.GL_TRUE)

			orbit:endDraw()

			local x, y = 0, 8
			app:drawMenuText('#vtx:'..mesh3DBlob:getNumVertexes(), x, y)
			y = y + 8
			app:drawMenuText('#ind:'..mesh3DBlob:getNumIndexes(), x, y)
			y = y + 8
			app:drawMenuText('size:'..mesh3DBlob:getSize(), x, y)
			y = y + 8
		end
	end

	local x, y = 50, 0

	self:guiBlobSelect(
		x, y, 						-- widget screen x,y
		'mesh3d', 					-- blobName
		self, 'mesh3DBlobIndex', 	-- table, indexKey
		nil, 						-- callback upon text change or spinner click
		function()					-- new blob generator:
			-- TODO TODO maybe I should do like sfx and just have a default minimal set ...
			-- but at the same time, I should always include a way to create vertexes/polys from nothing...
			-- we have just inserted an empty mesh into the mesh3d list
			-- but for convenience's sake, let's replace the empty mesh with an identity cube mesh...
			local Vertex = numo9_rom.Vertex
			local vector = require 'stl.vector-lua'
			local vtxs = vector(Vertex)

			local vertexes = table{
				-- x-
				{-16384, 16384, -16384},
				{-16384, -16384, -16384},
				{-16384, -16384, 16384},
				{-16384, 16384, 16384},
				-- x+
				{16384, 16384, -16384},
				{16384, -16384, -16384},
				{16384, -16384, 16384},
				{16384, 16384, 16384},
				-- y-
				{-16384, -16384, 16384},
				{-16384, -16384, -16384},
				{16384, -16384, -16384},
				{16384, -16384, 16384},
				-- y+
				{-16384, 16384, 16384},
				{-16384, 16384, -16384},
				{16384, 16384, -16384},
				{16384, 16384, 16384},
				-- z-
				{-16384, -16384, -16384},
				{-16384, 16384, -16384},
				{16384, 16384, -16384},
				{16384, -16384, -16384},
				-- z+
				{-16384, -16384, 16384},
				{-16384, 16384, 16384},
				{16384, 16384, 16384},
				{16384, -16384, 16384},
			}
			local texcoords = table{
				-- x-
				{0, 15},
				{15, 15},
				{15, 0},
				{0, 0},
				-- x+
				{15, 15},
				{0, 15},
				{0, 0},
				{15, 0},
				-- y-
				{0, 0},
				{0, 15},
				{15, 15},
				{15, 0},
				-- y+
				{15, 0},
				{15, 15},
				{0, 15},
				{0, 0},
				-- z-
				{0, 0},
				{0, 15},
				{15, 15},
				{15, 0},
				-- z+
				{0, 0},
				{0, 15},
				{15, 15},
				{15, 0},
			}
			-- 1-based list
			local indexes = {
				-- x-
				1, 2, 3,
				3, 4, 1,
				-- x+
				5, 8, 7,
				7, 6, 5,
				-- y-
				9, 10, 11,
				11, 12, 9,
				-- y+
				13, 16, 15,
				15, 14, 13,
				-- z-
				17, 18, 19,
				19, 20, 17,
				-- z+
				21, 24, 23,
				23, 22, 21,
			}
			return BlobMesh3D:loadFromLists(vertexes, texcoords, indexes)
		end
	)
	x = x + 12

	self:guiBlobSelect(x, y, 'sheet', self, 'sheetBlobIndex')
	x = x + 12
	self:guiBlobSelect(x, y, 'palette', self, 'paletteBlobIndex')
	x = x + 12

	if self:guiButton('F', x, y, self.drawFaces, 'faces') then
		self.drawFaces = not self.drawFaces
	end
	x = x + 8
	if self:guiButton('W', x, y, self.wireframe, 'wireframe') then
		self.wireframe = not self.wireframe
	end
	x = x + 8
	if self:guiButton(orbit.ortho and 'O' or 'P', x, y, false, orbit.ortho and 'ortho' or 'projection') then
		orbit.ortho = not orbit.ortho
	end
	x = x + 8

	self.tileSel:button(x,y)
	x = x + 8

	if not handled
	and mouseY >= 8
	then
		if mesh3DBlob then

		end
	end

	self:guiSetClipRect(-1000, 0, 3000, 256)
	self:drawTooltip()
end

return EditMesh3D
