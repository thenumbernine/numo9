local ffi = require 'ffi'
local assert = require 'ext.assert'
local table = require 'ext.table'
local math = require 'ext.math'
local timer = require 'ext.timer'
local vector = require 'ffi.cpp.vector-lua'
local vec3d = require 'vec-ffi.vec3d'
local box3d = require 'vec-ffi.box3d'
local quatd = require 'vec-ffi.quatd'
local Image = require 'image'
local gl = require 'gl'

local clip = require 'numo9.clipboard'
local Undo = require 'numo9.ui.undo'
local Orbit = require 'numo9.ui.orbit'
local TileSelect = require 'numo9.ui.tilesel'

local numo9_rom = require 'numo9.rom'
local spriteSize = numo9_rom.spriteSize
local tileSizeInBits = numo9_rom.tileSizeInBits
local spriteSheetSize = numo9_rom.spriteSheetSize
local voxelmapSizeType = numo9_rom.voxelmapSizeType
local voxelMapEmptyValue = numo9_rom.voxelMapEmptyValue
local matArrType = numo9_rom.matArrType
local Voxel = numo9_rom.Voxel

local numo9_blobs = require 'numo9.blobs'
local blobClassForName = numo9_blobs.blobClassForName


local uint8_t = ffi.typeof'uint8_t'
local uint32_t = ffi.typeof'uint32_t'
local uint32_t_p = ffi.typeof'uint32_t*'


-- 1- based but key matches typical sideIndex which is 0-based
local dirsForSide = table{
	vec3d(1,0,0),
	vec3d(-1,0,0),
	vec3d(0,1,0),
	vec3d(0,-1,0),
	vec3d(0,0,1),
	vec3d(0,0,-1),
}

local EditVoxelMap = require 'numo9.ui':subclass()

function EditVoxelMap:init(args)
	EditVoxelMap.super.init(self, args)

	self.undo = Undo{
		get = function()
			-- for now I'll just have one undo buffer for the current sheet
			-- TODO palette too
			local app = self.app
			local voxelmap = app.blobs.voxelmap[self.voxelmapBlobIndex+1]
			return {
				data = voxelmap:toBinStr(),
			}
		end,
		changed = function(entry)
			local app = self.app
			local voxelmap = app.blobs.voxelmap[self.voxelmapBlobIndex+1]
			local voxelmapData = voxelmap:toBinStr()
			return voxelmapData ~= entry.data
		end,
	}

	self:onCartLoad()
end

function EditVoxelMap:onCartLoad()
	self.menuUseLighting = false
	self.voxelmapBlobIndex = 0
	self.sheetBlobIndex = 0
	self.paletteBlobIndex = 0

	self.moveSpeed = .3

	self.drawMode = 'draw'
	self.rectDown = nil
	self.rectUp = nil
	self.wireframe = false

	self.voxCurSel = Voxel()
	self.voxCurSel.intval = 0

	self.mousePickLastClickTime = timer.getTime()

	self.meshPickOpen = false
	self.orientationPickOpen = false
	self.meshPickOrbit = Orbit(self.app)
	self.meshPickVoxel= Voxel()

	self.tileSel = TileSelect{
		edit = self,
		onSetTile = function()
			-- update the voxCurSel tile XY
			self.voxCurSel.tileXOffset = self.tileSel.pos.x
			self.voxCurSel.tileYOffset = self.tileSel.pos.y
		end,
	}
	local editor = self
	local app = self.app
	function self.tileSel:drawSelected(winX, winY, winW, winH)
		local colorIndex = 0x1f
		local thickness = math.max(1, app.width / 256)
		local function tc(vtx)
			return
				winX + winW * (tonumber(vtx.u + bit.lshift(editor.voxCurSel.tileXOffset, 3)) + .5) / tonumber(spriteSheetSize.x),
				winY + winH * (tonumber(vtx.v + bit.lshift(editor.voxCurSel.tileYOffset, 3)) + .5) / tonumber(spriteSheetSize.y)
		end
		-- draw the texcoords offset by the voxCurSel.tileXOffset etc
		local mesh3DIndex = editor.voxCurSel.mesh3DIndex
		local mesh = app.blobs.mesh3d[mesh3DIndex+1]
		if not mesh then
			TileSelect.drawSelected(self, winX, winY, winW, winH)
		end
		local vtxs = mesh:getVertexPtr()
		for ti=0,#mesh.triList-1 do
			local i,j,k = mesh.triList.v[ti]:unpack()
			local u1, v1 = tc(vtxs + i)
			local u2, v2 = tc(vtxs + j)
			local u3, v3 = tc(vtxs + k)
			app:drawSolidLine(u1, v1, u2, v2, colorIndex, thickness, app.paletteMenuTex)
			app:drawSolidLine(u2, v2, u3, v3, colorIndex, thickness, app.paletteMenuTex)
			app:drawSolidLine(u3, v3, u1, v1, colorIndex, thickness, app.paletteMenuTex)
		end
	end

	self.orbit = Orbit(self.app)
	-- TODO init to max size of whatever blob is first loaded?
	-- and refresh on blob change?
	self.orbit.pos.z = 5

	self.undo:clear()
end

local function planeLineIntersectParam(planePt, planeN, linePt, lineDir)
	return (planePt - linePt):dot(planeN) / lineDir:dot(planeN)
end

local function axisAlignedPlaneLineIntersectParam(axis, planePtOnAxis, planeNormalOnAxis, linePt, lineDir)
	return ((planePtOnAxis - linePt.s[axis]) * planeNormalOnAxis) / (lineDir.s[axis] * planeNormalOnAxis)
end

local function lineBoxDist(box, linePt, lineDir, inside)
	inside = inside or false
	-- line intersect with the outer walls of a cube
	local d = math.huge
	local axis
	local sideNormalSignFlag
	for i=0,2 do
		local j = (i+1)%3
		local k = (j+1)%3

		local planeDist, planeNormalOnAxis
		if lineDir.s[i] > 0 ~= inside then
			planeDist = box.min.s[i]
			planeNormalOnAxis = -1
		else
			planeDist = box.max.s[i]
			planeNormalOnAxis = 1
		end
		local dxi = axisAlignedPlaneLineIntersectParam(i, planeDist, planeNormalOnAxis, linePt, lineDir)
		if dxi > 0 and dxi < d then
			local ptj = linePt.s[j] + lineDir.s[j] * dxi
			local ptk = linePt.s[k] + lineDir.s[k] * dxi
			if box.min.s[j] <= ptj and ptj <= box.max.s[j]
			and box.min.s[k] <= ptk and ptk <= box.max.s[k]
			then
				axis = i
				-- why is it sometimes thinking a down-pointing line intersects the bottom when it hits the top of a cube?
				--  Maybe I'm not considering 'inside' when I should be?
				--sideNormalSignFlag = planeNormalOnAxis < 0 and 1 or 0
				-- maybe using lineDir is better, yup
				sideNormalSignFlag = lineDir.s[i] > 0 and 1 or 0
				d = dxi
			end
		end
	end
	-- same as in mesh3d and voxelmap
	-- sideIndex is 0-5
	-- bit 0 = negative direction bit
	-- bits 1:2 = 0-2 for xyz, which direction the side is facing
	local sideIndex
	if axis then
		sideIndex = bit.bor(bit.lshift(axis, 1), sideNormalSignFlag)
	end
	return d, sideIndex
end

-- assumes we're already scaled down by 32768
function EditVoxelMap:drawBox(box, color)
	local app = self.app
	local thickness = math.max(1, app.width / 256)
	local epsilon = 1/32
	for i=0,7 do
		for b=0,2 do
			local j = bit.bxor(i, bit.lshift(1, b))
			if j > i then
				-- why did I say bit set = min?
				-- looks like mesh lib uses :corner so dont change it
				local ax, ay, az = box:corner(i):unpack()
				if bit.band(i, 1) == 0 then ax = ax + epsilon else ax = ax - epsilon end
				if bit.band(i, 2) == 0 then ay = ay + epsilon else ay = ay - epsilon end
				if bit.band(i, 4) == 0 then az = az + epsilon else az = az - epsilon end
				local bx, by, bz = box:corner(j):unpack()
				if bit.band(j, 1) == 0 then bx = bx + epsilon else bx = bx - epsilon end
				if bit.band(j, 2) == 0 then by = by + epsilon else by = by - epsilon end
				if bit.band(j, 4) == 0 then bz = bz + epsilon else bz = bz - epsilon end
				app:drawSolidLine3D(
					ax, ay, az,
					bx, by, bz,
					color,
					thickness,
					app.paletteMenuTex)
			end
		end
	end
end

function EditVoxelMap:update()
	local app = self.app
	local orbit = self.orbit

	-- this is going to draw the menu
	local handled = EditVoxelMap.super.update(self)

	app:matMenuReset()
	self:guiSetClipRect(-1000, 16, 3000, 240)

	local mouseX, mouseY = app:invTransform(app.ram.mousePos:unpack())

	local shift = app:key'lshift' or app:key'rshift'

	local voxelmap = app.blobs.voxelmap[self.voxelmapBlobIndex+1]
	local mapsize = voxelmap
		and vec3d(
			voxelmap:getWidth(),
			voxelmap:getHeight(),
			voxelmap:getDepth())
	local mapbox = mapsize and box3d(vec3d(0,0,0), mapsize)
	local mapboxIE = mapsize and box3d(vec3d(0,0,0), mapsize-1)	-- mapbox, [incl,excl), for integer testing

	if self.tileSel:doPopup() then
		-- handled in doPopup()
	elseif self.meshPickOpen
	or self.orientationPickOpen
	then
		-- use menu coords which are odd and determined by matMenuReset
		-- height is 256, width is aspect ratio proportional
		-- TODO is it this or size / min(something)?
		local ar = app.width / app.height
		local menuCoordH = 256
		local menuCoordW = math.floor(menuCoordH * ar)

		local winW = menuCoordW - 4 * spriteSize.x
		local winH = menuCoordH - 4 * spriteSize.y

		local winX = 2 * spriteSize.x - (menuCoordW - 256) * .5
		local winY = 2 * spriteSize.y

		handled = self.meshPickOrbit:handleInput() or handled

		app:drawBorderRect(
			winX-1,
			winY-1,
			winW+2,
			winH+2,
			10,
			nil,
			app.paletteMenuTex
		)
		app:drawSolidRect(
			winX,
			winY,
			winW,
			winH,
			1,
			nil,
			nil,
			app.paletteMenuTex
		)

		app:clearScreen(nil, nil, true)
		gl.glEnable(gl.GL_DEPTH_TEST)

		--[[
		local meshPreviewW = 64
		local meshPreviewH = 64
		--]]
		--[[
		local meshPreviewW = 256
		local meshPreviewH = 256
		--]]

		-- meh I'll just use the viewport
		--[[
		local maxcols = 10
		local maxrows = math.floor(maxcols / ar)
		local meshPreviewH = math.floor(256 / maxrows)
		local meshPreviewW = meshPreviewH
		--]]
		-- [[
		local maxrows = 6
		local maxcols = math.floor(maxrows * winW / winH)
		local meshPreviewW = math.ceil(winW / maxcols)
		local meshPreviewH = meshPreviewW
		--]]
		for row=0,maxrows-1 do
			for col=0,maxcols-1 do

				self.meshPickVoxel.intval = self.voxCurSel.intval

				local issel
				local index = col + maxcols * row
				local indexOOB = false	-- cuz i can't test orientation oob cuz it is only 6 bits and it wraps....
				if self.orientationPickOpen then
					issel = self.meshPickVoxel.orientation == index
					self.meshPickVoxel.orientation = index
					indexOOB = index >= 64
				else	-- meshPickOpen
					issel = self.meshPickVoxel.mesh3DIndex == index
					self.meshPickVoxel.mesh3DIndex = index
					indexOOB = self.meshPickVoxel.mesh3DIndex >= #app.blobs.mesh3d
				end


				if not indexOOB then
					app:triBuf_flush()

					app:setClipRect(-1000, -1000, 3000, 3000)
					--self:guiSetClipRect(-1000, -1000, 3000, 3000)

					gl.glViewport(
						-- winX but without the left offset
						app.width * ((2 * spriteSize.x + col * meshPreviewW) / menuCoordW),
						-- winH
						app.height * (1 - (2 * spriteSize.y + (row+1) * meshPreviewH) / menuCoordH),
						app.width * meshPreviewW / menuCoordW,
						app.height * meshPreviewH / menuCoordH)


			--		self:guiSetClipRect(winX, winY, meshPreviewW, meshPreviewH) --winW, winH)

					-- now draw 3D views of models here
					app:matident(0)
					app:matident(1)
					app:matident(2)	-- 2 = projection

					-- how to do pick matrix / how to offset frustum in screenspace....

			--[[
					app:mattrans(
						-- win coords without left offset
						(1 - 2 * spriteSize.x) / meshPreviewW,
						(1 - 2 * spriteSize.y) / meshPreviewH,
						0,
						2)	-- 2 = projection
			--]]
			--[[
					app:matscale(
						1 / meshPreviewW,
						1 / meshPreviewH,
						1,
						2)	-- 2 = projectoin
			--]]
					if issel then
						local epsilon = 1e-2
						app:drawBorderRect(-1 + epsilon, -1 + epsilon, 2 - 2 * epsilon, 2 -2 * epsilon, 10, nil, app.paletteMenuTex)
					end

					--[[
					local zn, zf = .1, 1000
					app:matfrustum(
						-zn, zn,
						-zn, zn,
						zn, zf)
					--]]
					-- [[
					app:matortho(-1, 1, -1, 1, -100, 100)
					--]]

					app:mattrans(0, 0, -1, 1)	-- 1 = view transform

					-- TODO why does my quat lib use degrees? smh
					local x,y,z,th = self.meshPickOrbit.angle:toAngleAxis():unpack()
					app:matrot(-math.rad(th), x, y, z, 1)	-- 1 = view transform

					app:mattrans(-.5, -.5, -.5)	-- undo app:drawVoxel recentering to [0,1]^3

					-- and try to draw our object
					local pushPalBlobIndex = app.ram.paletteBlobIndex
					app.ram.paletteBlobIndex = self.paletteBlobIndex

					app:drawVoxel(
						self.meshPickVoxel.intval,
						self.sheetBlobIndex
					)
					app.ram.paletteBlobIndex = pushPalBlobIndex

					if mouseX >= winX + col * meshPreviewW
					and mouseX < winX + (col+1) * meshPreviewW
					and mouseY >= winY + row * meshPreviewH
					and mouseY < winY + (row+1) * meshPreviewH
					then

						if not self.tooltip then
							self:setTooltip(tostring(index), mouseX-8, mouseY-8, 0xfc, 0)
						end

						if not handled then

							-- TODO I'm getting double-clicks always
							-- is it because keyp doesn't get refreshed as often as menu updates do?
							local doubleClick
							if app:keyp'mouse_left' then
								local thisTime = timer.getTime()
								local doubleClickThreshold = 1	-- seconds
								if thisTime - self.mousePickLastClickTime < doubleClickThreshold then
									doubleClick = true
								end
								self.mousePickLastClickTime = thisTime
							end

							--if doubleClick then-- TODO fix double click
							if app:keyp'mouse_right' then
								self.meshPickOpen = false
								self.orientationPickOpen = false

								app.editMode = 'mesh3d'
								app:setMenu(app.editMesh3D)
								-- why this doens't work? proly cuz before i had this outside the mouse region test block....
								--app.editMesh3D.mesh3DBlobIndex = self.meshPickVoxel.mesh3DIndex
								app.editMesh3D.mesh3DBlobIndex = self.voxCurSel.mesh3DIndex
								handled = true
								return
							end

							-- on release so we dont mess with paint mode
							if app:keyr'mouse_left' then
								self.voxCurSel.intval = self.meshPickVoxel.intval
								if self.orientationPickOpen then
									self.orientationPickOpen = false	-- close orientation on click
								else
									self.meshPickOpen = false	-- close mesh-pick on click too?  or?
								end

								handled = true
							end
						end
					end
				end
			end
		end

		app:triBuf_flush()
		gl.glViewport(0, 0, app.width, app.height)
		gl.glDisable(gl.GL_DEPTH_TEST)

		app:matMenuReset()
		self:guiSetClipRect(-1000, 16, 3000, 240)

	elseif voxelmap then

		-- init lighting before beginDraw() so that we get the clear depth call that will clear the lighting as well
		local pushUseHardwareLighting = app.ram.useHardwareLighting
		app.ram.useHardwareLighting = self.menuUseLighting and 1 or 0
		if app.ram.useHardwareLighting ~= pushUseHardwareLighting then
			app:onUseHardwareLightingChange()
		end

		handled = orbit:beginDraw() or handled


		-- view or not view?
		-- as a view mat means that the lighting covers it all
		app:mattrans(-.5*mapsize.x, -.5*mapsize.y, -.5*mapsize.z, 1)


		-- TODO push and pop lighting vars?

		-- also clear this to force the next view to be the one that the lighting uses
		-- which is the editor's orbit view
		--- And do it here *AFTER* oribt:beginDraw and not *BEFORE*
		-- because orbit does a pre pass for the XYZ widget which is an ortho display,
		-- and if you set this before ortho:beginDraw then that'll get caputred by the lighting instead of the scene's view mat
		--self.haveCapturedDrawMatsForLightingThisFrame = false
		-- nope that doesnt even work
		-- meh just force it here.
		app.haveCapturedDrawMatsForLightingThisFrame = true
		ffi.copy(app.drawViewMatForLighting.ptr, app.ram.viewMat, ffi.sizeof(matArrType))
		ffi.copy(app.drawProjMatForLighting.ptr, app.ram.projMat, ffi.sizeof(matArrType))

		-- force capture draw view and proj for lighting
		-- (same as just ffi.copy?)
		app:triBuf_prepAddTri(
			app.lastPaletteTex,
			app.lastSheetTex,
			app.lastTilemapTex,
			app.lastAnimSheetTex)


		self:drawBox(mapbox, 0x31)

		-- set the current selected palette via RAM registry to self.paletteBlobIndex
		local pushPalBlobIndex = app.ram.paletteBlobIndex
		app.ram.paletteBlobIndex = self.paletteBlobIndex
		app:drawVoxelMap(
			self.voxelmapBlobIndex,
			self.sheetBlobIndex
		)
		app.ram.paletteBlobIndex = pushPalBlobIndex

		if self.wireframe then
			local v = voxelmap:getVoxelDataRAMPtr()
			for k=0,mapsize.z-1 do
				for j=0,mapsize.y-1 do
					for i=0,mapsize.x-1 do
						if v.intval ~= voxelMapEmptyValue then
							self:drawBox(box3d(vec3d(i,j,k), vec3d(i,j,k)+1), 0xa)
						end
						v = v + 1
					end
				end
			end
		end

		if not handled
		and mouseY >= 16
		then
			-- mouse line, intersect only with far bounding planes of the voxelmap
			-- or intersect with march through the voxelmap
			-- how to get mouse line?
			-- transform mouse coords by view matrix
			local mousePos = orbit.pos + mapsize * .5
			-- assume fov is 90°
			local mouseDir =
				- orbit.angle:zAxis()
				+ orbit.angle:xAxis() * (mouseX - 128) / 128
				- orbit.angle:yAxis() * (mouseY - 128) / 128

			local sideIndex
			-- or alternatively use the inverse of the modelview matrix... but meh ...
			if not mapbox:contains(mousePos) then
				-- now line intersect with the camera-facing planes of the bbox

				local d
				d, sideIndex = lineBoxDist(
					mapbox,
					mousePos,
					mouseDir)

	--print('dists', d, dx, dy, dz)
				mousePos = mousePos + mouseDir * (d + 1e-5)
				-- this could still be OOB if the user isn't mouse'd over the box ...
			end
			if mapbox:contains(mousePos) then
				local npti = mousePos:map(math.floor)
				local pti = npti:clone()
				-- then march through the voxelmap
				while true do
					local vaddr = voxelmap:getVoxelAddr(npti:unpack())
					if vaddr and app:peekl(vaddr) ~= voxelMapEmptyValue then
						break
					end

					pti = npti

					-- intersect with cube [pti, pti+1]
					local d
					d, sideIndex = lineBoxDist(
						box3d(pti, pti+1),
						mousePos,
						mouseDir,
						true)	-- true = inside the cube intersecting with outside

					mousePos = mousePos + mouseDir * (d + 1e-5)
					npti = mousePos:map(math.floor)

					-- stop at the last empty voxel
					-- if we're oob then we're done with 'pti' as our final point inside the box
					if not mapboxIE:contains(npti) then
						npti = pti:clone()
						break
					end
				end

				-- show selection
				self:drawBox(box3d(npti, npti+1), 0x1b)

				if not handled then
					-- only on click?
					-- or how about mousedown as well?
					-- but only when the voxel changes?
					-- tough to make it not just keep stacking towards the view ...
					if shift then
						if app:key'mouse_left' then
							if mapboxIE:contains(npti) then
								local vaddr = voxelmap:getVoxelAddr(npti:unpack())
								if vaddr then
									local voxval = app:peekl(vaddr)
									if voxval ~= voxelMapEmptyValue then
										self.voxCurSel.intval = voxval
										self.tileSel.pos.x = self.voxCurSel.tileXOffset
										self.tileSel.pos.y = self.voxCurSel.tileYOffset
									end
								end
							end
						end
					else
						-- draw = place blocks per click
						if self.drawMode == 'draw' then

							-- right click to destroy single tile
							if app:keyp'mouse_right'
							and mapboxIE:contains(npti)
							then
								local addr = voxelmap:getVoxelAddr(npti:unpack())
								if addr then
									self.undo:pushContinuous()
									self:edit_pokel(addr, voxelMapEmptyValue)
								end
							end

							if app:keyp'mouse_left' then
								self.undo:pushContinuous()
								local addr = voxelmap:getVoxelAddr(pti:unpack())
								-- can pti be oob?
								if addr then
									self:edit_pokel(addr, self.voxCurSel.intval)
								end
							end
						-- paint = draw on surface per mousedown
						elseif self.drawMode == 'paint' then

							-- right click to destroy single tile ... ? or not?
							if app:keyp'mouse_right'
							and mapboxIE:contains(npti)
							then
								local addr = voxelmap:getVoxelAddr(npti:unpack())
								if addr then
									self.undo:pushContinuous()
									self:edit_pokel(addr, voxelMapEmptyValue)
								end
							end

							if app:key'mouse_left' then
								if mapboxIE:contains(npti) then
									local addr = voxelmap:getVoxelAddr(npti:unpack())
									if addr then
										self.undo:pushContinuous()
										self:edit_pokel(addr, self.voxCurSel.intval)
									end
								end
							end
						elseif self.drawMode == 'rect' then

							-- right click to destroy rectangular region
							-- don't push left and right at the same time ....
							if app:keyp'mouse_right' then
								-- use npti to dig one tile into the voxel
								self.rectDown = npti:clone()
								self.rectUp = npti:clone()
							elseif app:keyr'mouse_right' then
								self.undo:push()
								if self.rectDown then
									for k=math.min(self.rectDown.z,pti.z),math.max(self.rectDown.z,pti.z) do
										for j=math.min(self.rectDown.y,pti.y),math.max(self.rectDown.y,pti.y) do
											for i=math.min(self.rectDown.x,pti.x),math.max(self.rectDown.x,pti.x) do
												local addr = voxelmap:getVoxelAddr(i,j,k)
												if addr then	 -- TODO clamp bounds
													self:edit_pokel(addr, voxelMapEmptyValue)
												end
											end
										end
									end
								end
								self.rectDown = nil
								self.rectUp = nil
							elseif app:key'mouse_right' then
								self.rectUp = pti:clone()
							end

							if app:keyp'mouse_left' then
								-- use pti to build on the surface
								self.rectDown = pti:clone()
								self.rectUp = pti:clone()
							elseif app:keyr'mouse_left' then
								self.undo:push()
								if self.rectDown then
									for k=math.min(self.rectDown.z,pti.z),math.max(self.rectDown.z,pti.z) do
										for j=math.min(self.rectDown.y,pti.y),math.max(self.rectDown.y,pti.y) do
											for i=math.min(self.rectDown.x,pti.x),math.max(self.rectDown.x,pti.x) do
												local addr = voxelmap:getVoxelAddr(i,j,k)
												if addr then	 -- TODO clamp bounds
													self:edit_pokel(addr, self.voxCurSel.intval)
												end
											end
										end
									end
								end
								self.rectDown = nil
								self.rectUp = nil
							elseif app:key'mouse_left' then
								self.rectUp = pti:clone()
							end
						elseif self.drawMode == 'select' then

							-- right click to destroy rectangular region
							-- same as rect
							-- don't push left and right at the same time ....
							if app:keyp'mouse_right' then
								-- use npti to dig one tile into the voxel
								self.rectDown = npti:clone()
								self.rectUp = npti:clone()
							elseif app:keyr'mouse_right' then
								self.undo:push()
								if self.rectDown then
									for k=math.min(self.rectDown.z,pti.z),math.max(self.rectDown.z,pti.z) do
										for j=math.min(self.rectDown.y,pti.y),math.max(self.rectDown.y,pti.y) do
											for i=math.min(self.rectDown.x,pti.x),math.max(self.rectDown.x,pti.x) do
												local addr = voxelmap:getVoxelAddr(i,j,k)
												if addr then	 -- TODO clamp bounds
													self:edit_pokel(addr, voxelMapEmptyValue)
												end
											end
										end
									end
								end
								self.rectDown = nil
								self.rectUp = nil
							elseif app:key'mouse_right' then
								self.rectUp = pti:clone()
							end

							if app:keyp'mouse_left' then
								self.rectDown = pti:clone()
								self.rectUp = pti:clone()
							elseif app:keyr'mouse_left' then
							elseif app:key'mouse_left' then
								self.rectUp = pti:clone()
							end
						elseif self.drawMode == 'fill' then

							-- right click to destroy single tile
							if app:keyp'mouse_right'
							and mapboxIE:contains(npti)
							then
								local addr = voxelmap:getVoxelAddr(npti:unpack())
								if addr then
									self.undo:pushContinuous()
									self:edit_pokel(addr, voxelMapEmptyValue)
								end
							end

							if app:keyp'mouse_left' then
								local addr = voxelmap:getVoxelAddr(npti:unpack())
								if addr then
									local srcColor = app:peekl(addr)
									if srcColor ~= voxelMapEmptyValue
									and srcColor ~= self.voxCurSel.intval
									then
										self.undo:push()

										local fillstack = table()

										self:edit_pokel(addr, self.voxCurSel.intval)

										fillstack:insert(npti:clone())
										while #fillstack > 0 do
											local pt = fillstack:remove()
											for _,dir in ipairs(dirsForSide) do
												local pt2 = pt + dir
												local addr = voxelmap:getVoxelAddr(pt2:unpack())
												if addr	-- addr won't exist if it's oob
												and app:peekl(addr) == srcColor
												then
													self:edit_pokel(addr, self.voxCurSel.intval)
													fillstack:insert(pt2)
												end
											end
										end
									end
								end
							end
						elseif self.drawMode == 'surfacefill' then
							-- right click to destroy single tile
							if app:keyp'mouse_right'
							and mapboxIE:contains(npti)
							then
								local addr = voxelmap:getVoxelAddr(npti:unpack())
								if addr then
									self.undo:pushContinuous()
									self:edit_pokel(addr, voxelMapEmptyValue)
								end
							end

							if app:keyp'mouse_left' then
								print('surfaceFill with sideIndex', sideIndex)
								-- figure out what side of the cube we're on ...
								-- try to get the surface normal pointing back at the player, i.e. prev cube minus next cube pos
								-- needs to know what side you clicked on
								-- these dirs match sideIndex in mesh3d and voxelmap except that sideIndex is 0-based
								local dirs = table(dirsForSide)
								if sideIndex == 0 or sideIndex == 1 then
									dirs:remove(1)
									dirs:remove(1)
								elseif sideIndex == 2 or sideIndex == 3  then
									dirs:remove(3)
									dirs:remove(3)
								elseif sideIndex == 4 or sideIndex == 5 then
									dirs:remove(5)
									dirs:remove(5)
								end
								if #dirs ~= 4 then
									print("somehow removed too many dirs, must have a weird sideIndex: "..sideIndex)
								else
									local addr = voxelmap:getVoxelAddr(npti:unpack())
									if addr then
										local srcColor = app:peekl(addr)
										if srcColor ~= voxelMapEmptyValue
										and srcColor ~= self.voxCurSel.intval
										then
											self.undo:push()

											local fillstack = table()

											self:edit_pokel(addr, self.voxCurSel.intval)

											fillstack:insert(npti:clone())
											while #fillstack > 0 do
												local pt = fillstack:remove()
												for _,dir in ipairs(dirs) do
													local pt2 = pt + dir

													local nbhdAddr = voxelmap:getVoxelAddr((pt2 + dirsForSide[1+sideIndex]):unpack())
													if not nbhdAddr	-- oob means no addr means empty, so crawl along this surface
													or app:peekl(nbhdAddr) == voxelMapEmptyValue -- is really empty value
													then
														local addr = voxelmap:getVoxelAddr(pt2:unpack())
														if addr	-- addr won't exist if it's oob
														and app:peekl(addr) == srcColor
														then
															self:edit_pokel(addr, self.voxCurSel.intval)
															fillstack:insert(pt2)
														end
													end
												end
											end
										end
									end
								end
							end
						end
					end
				end

				if self.rectDown and self.rectUp then
					self:drawBox(box3d(
						vec3d(
							math.min(self.rectDown.x, self.rectUp.x),
							math.min(self.rectDown.y, self.rectUp.y),
							math.min(self.rectDown.z, self.rectUp.z)),
						vec3d(
							math.max(self.rectDown.x, self.rectUp.x)+1,
							math.max(self.rectDown.y, self.rectUp.y)+1,
							math.max(self.rectDown.z, self.rectUp.z)+1)
					), 0x1b)
				end

				if not self.tooltip then
					self:setTooltip(npti.x..','..npti.y..','..npti.z, mouseX-8, mouseY-8, 0xfc, 0)
				end
			end
		end

		if app.ram.useHardwareLighting ~= pushUseHardwareLighting then
			app.ram.useHardwareLighting = pushUseHardwareLighting
			app:onUseHardwareLightingChange()
		end

		orbit:endDraw()

		-- TODO should this go here or in the caller:
		app:matMenuReset()

		local x, y = 0, 16
		app:drawMenuText(mapsize.x..'x'..mapsize.y..'x'..mapsize.z, x, y)
		y = y + 8
	end


	self:guiSetClipRect(0, 0, 256, 256)

	local x, y = 48, 0
	self:guiBlobSelect(x, y, 'voxelmap', self, 'voxelmapBlobIndex', function()
		self.undo:clear()
	end)
	x = x + 11
	self:guiBlobSelect(x, y, 'sheet', self, 'sheetBlobIndex')
	x = x + 11
	self:guiBlobSelect(x, y, 'palette', self, 'paletteBlobIndex')
	x = x + 11

	if self:guiButton('W', x, y, self.wireframe, 'wireframe') then
		self.wireframe = not self.wireframe
	end
	x = x + 6
	if self:guiButton(orbit.ortho and 'O' or 'P', x, y, false, orbit.ortho and 'orbit.ortho' or 'projection') then
		orbit.ortho = not orbit.ortho
	end
	x = x + 6
	if self:guiButton('L', x, y, false, 'light='..tostring(self.menuUseLighting)) then
		self.menuUseLighting = not self.menuUseLighting
	end
	x = x + 6

	-- TODO text input also for just the mesh portion? or handle it in the voxel index?
	if self:guiButton('M', x, y, self.meshPickOpen, 'mesh='..self.voxCurSel.mesh3DIndex) then
		self.meshPickOpen = not self.meshPickOpen

		-- show orientation in mesh pick as you would in view
		-- allow rotations in mesh pick, but dont let rotations affect view
		self.meshPickOrbit.angle:set(self.orbit.angle:unpack())
	end
	x = x + 6

	if self:guiButton('O', x, y, self.orientationPickOpen, 'orientation='..self.voxCurSel.orientation) then
		self.orientationPickOpen = not self.orientationPickOpen

		-- show orientation in mesh pick as you would in view
		-- allow rotations in mesh pick, but dont let rotations affect view
		if not self.meshPickOpen then
			self.meshPickOrbit.angle:set(self.orbit.angle:unpack())
		end
	end
	x = x + 6

	self.tileSel:button(x,y)
	x = x + 6

	-- tools ... maybe I should put these somewhere else
	self:guiRadio(x, y, {
		self.drawMode == 'draw' and 'draw' or 'paint',	-- TODO cycle sub-list per-click on it
		'rect',
		self.drawMode == 'fill' and 'fill' or 'surfacefill',
		'select'
	}, self.drawMode, function(result)
		-- TODO sublist:
		if result == 'draw' and self.drawMode == 'draw' then
			self.drawMode = 'paint'
		elseif result == 'paint' and self.drawMode == 'paint' then
			self.drawMode = 'draw'
		elseif result == 'fill' and self.drawMode == 'fill' then
			self.drawMode = 'surfacefill'
		elseif result == 'surfacefill' and self.drawMode == 'surfacefill' then
			self.drawMode = 'fill'
		else
			self.drawMode = result
		end
	end)
	x = x + 25

	if voxelmap then
		self:guiSpinner(x, y, function(dx)
			self:resizeVoxelmap(
				math.max(1, mapsize.x + dx),
				mapsize.y,
				mapsize.z
			)
		end, 'width='..mapsize.x)
		x = x + 11

		self:guiSpinner(x, y, function(dx)
			self:resizeVoxelmap(
				mapsize.x,
				math.max(1, mapsize.y + dx),
				mapsize.z
			)
		end, 'height='..mapsize.y)
		x = x + 11

		self:guiSpinner(x, y, function(dx)
			self:resizeVoxelmap(
				mapsize.x,
				mapsize.y,
				math.max(1, mapsize.z + dx)
			)
		end, 'depth='..mapsize.z)
		x = x + 11

		self:guiTextField(
			189, 0, 20,
			('%08X'):format(self.voxCurSel.intval), nil,
			function(result)
				result = tonumber(result, 16)
				if result then
					self.voxCurSel.intval = result
					self.tileSel.pos.x = self.voxCurSel.tileXOffset
					self.tileSel.pos.y = self.voxCurSel.tileYOffset
				end
			end
		)

		-- wasd should have been esdf ...
		-- home row!
		if app:key'w' then
			orbit.pos = orbit.pos - orbit.angle:zAxis() * self.moveSpeed
			orbit.orbit = orbit.orbit - orbit.angle:zAxis() * self.moveSpeed
		end
		if app:key's' then
			orbit.pos = orbit.pos + orbit.angle:zAxis() * self.moveSpeed
			orbit.orbit = orbit.orbit + orbit.angle:zAxis() * self.moveSpeed
		end
		if app:key'a' then
			orbit.pos = orbit.pos - orbit.angle:xAxis() * self.moveSpeed
			orbit.orbit = orbit.orbit - orbit.angle:xAxis() * self.moveSpeed
		end
		if app:key'd' then
			orbit.pos = orbit.pos + orbit.angle:xAxis() * self.moveSpeed
			orbit.orbit = orbit.orbit + orbit.angle:xAxis() * self.moveSpeed
		end
		if app:key'q' then
			orbit.pos = orbit.pos + orbit.angle:yAxis() * self.moveSpeed
			orbit.orbit = orbit.orbit + orbit.angle:yAxis() * self.moveSpeed
		end
		if app:key'e' then
			orbit.pos = orbit.pos - orbit.angle:yAxis() * self.moveSpeed
			orbit.orbit = orbit.orbit - orbit.angle:yAxis() * self.moveSpeed
		end

		local turnSpeed = 3
		if app:key'i' then
			orbit.angle = orbit.angle * quatd():fromAngleAxis(1, 0, 0, turnSpeed)
			orbit.orbit = orbit.pos - orbit.angle:zAxis() * (orbit.pos - orbit.orbit):length()
		end
		if app:key'k' then
			orbit.angle = orbit.angle * quatd():fromAngleAxis(-1, 0, 0, turnSpeed)
			orbit.orbit = orbit.pos - orbit.angle:zAxis() * (orbit.pos - orbit.orbit):length()
		end
		if app:key'j' then
			orbit.angle = orbit.angle * quatd():fromAngleAxis(0, 1, 0, turnSpeed)
			orbit.orbit = orbit.pos - orbit.angle:zAxis() * (orbit.pos - orbit.orbit):length()
		end
		if app:key'l' then
			orbit.angle = orbit.angle * quatd():fromAngleAxis(0, -1, 0, turnSpeed)
			orbit.orbit = orbit.pos - orbit.angle:zAxis() * (orbit.pos - orbit.orbit):length()
		end
		if app:key'u' then
			orbit.angle = orbit.angle * quatd():fromAngleAxis(0, 0, 1, turnSpeed)
			orbit.orbit = orbit.pos - orbit.angle:zAxis() * (orbit.pos - orbit.orbit):length()
		end
		if app:key'o' then
			orbit.angle = orbit.angle * quatd():fromAngleAxis(0, 0, -1, turnSpeed)
			orbit.orbit = orbit.pos - orbit.angle:zAxis() * (orbit.pos - orbit.orbit):length()
		end
	end

	local uikey
	if ffi.os == 'OSX' then
		uikey = app:key'lgui' or app:key'rgui'
	else
		uikey = app:key'lctrl' or app:key'rctrl'
	end
	if uikey then
		if app:keyp'x' or app:keyp'c' then
			if self.rectDown and self.rectUp then
				local min = vec3d(
					math.min(self.rectUp.x, self.rectDown.x),
					math.min(self.rectUp.y, self.rectDown.y),
					math.min(self.rectUp.z, self.rectDown.z))
				local max = vec3d(
					math.max(self.rectUp.x, self.rectDown.x),
					math.max(self.rectUp.y, self.rectDown.y),
					math.max(self.rectUp.z, self.rectDown.z))
				local size = max - min + 1
				local o = vector(uint32_t)
				o:emplace_back()[0] = size.x
				o:emplace_back()[0] = size.y
				o:emplace_back()[0] = size.z
				for z=0,size.z-1 do
					for y=0,size.y-1 do
						for x=0,size.x-1 do
							local v = voxelmap:getVoxelBlobPtr(x + min.x, y + min.y, z + min.z)
							o:emplace_back()[0] = v and v.intval or voxelMapEmptyValue
						end
					end
				end
				-- now encode it in an image ...
				local w = math.ceil(math.sqrt(#o))
				local h = math.ceil(#o / w)
				local img = Image(w, h, 4, uint8_t)
				ffi.fill(img.buffer, img:getBufferSize())
				ffi.copy(img.buffer, o.v, #o * ffi.sizeof(uint32_t))
				clip.image(img)
				if app:keyp'x' then
					self.undo:push()
					for z=0,size.z-1 do
						for y=0,size.y-1 do
							for x=0,size.x-1 do
								local addr = voxelmap:getVoxelAddr(x + min.x, y + min.y, z + min.z)
								if addr then	 -- TODO clamp bounds
									self:edit_pokel(addr, voxelMapEmptyValue)
								end
							end
						end
					end
				end
			end
		elseif app:keyp'v' then
			local min = vec3d(
				math.min(self.rectUp.x, self.rectDown.x),
				math.min(self.rectUp.y, self.rectDown.y),
				math.min(self.rectUp.z, self.rectDown.z))
			local max = vec3d(
				math.max(self.rectUp.x, self.rectDown.x),
				math.max(self.rectUp.y, self.rectDown.y),
				math.max(self.rectUp.z, self.rectDown.z))
			local cb = function()
				local image = clip.image()
				if not image then return end
				if image.channels ~= 4 then
					print('paste got an image with invalid channels', image.channels)
					return
				end
				if image:getBufferSize() < 3 * ffi.sizeof(uint32_t) then	-- make sure the header is at least there
					print('paste got an image with not enough buffer size', image:getBufferSize())
					return
				end
				local p = ffi.cast(uint32_t_p, image.buffer)
				local sx, sy, sz = p[0], p[1], p[2]
				if ffi.sizeof(uint32_t) * (3 + sx * sy * sz) > image:getBufferSize() then
					print('paste got a bad sized image: '..sx..', '..sy..', '..sz..' versus its buffer size '..image:getBufferSize())
					return
				end
				self.undo:push()
				for z=0,sz-1 do
					for y=0,sy-1 do
						for x=0,sx-1 do
							local addr = voxelmap:getVoxelAddr(x + min.x, y + min.y, z + min.z)
							if addr then	 -- TODO clamp bounds
								self:edit_pokel(addr, p[3 + x + sx * (y + sy * z)])
							end
						end
					end
				end
			end
			cb()
		elseif app:keyp'z' then
			self:popUndo(shift)
		end
	end

	for ch = 1,10 do
		if app:keyp( string.char(('0'):byte() + (ch % 10)) ) then
			self.moveSpeed = 10 ^ ((ch - 5) / 4)
		end
	end

	self:drawTooltip()
end

--[[ TODO just use lua.gui ... gui scenegraph ...
function EditVoxelMap:event(e)
end
--]]

function EditVoxelMap:resizeVoxelmap(nx, ny, nz)
	local app = self.app
	local voxelmap = app.blobs.voxelmap[self.voxelmapBlobIndex+1]
	if not voxelmap then return end

	self.undo:push()

	assert.eq(ffi.sizeof(voxelmapSizeType), ffi.sizeof(Voxel))	-- just put everything in uint32_t

	local o = vector(voxelmapSizeType)
	o:emplace_back()[0] = nx
	o:emplace_back()[0] = ny
	o:emplace_back()[0] = nz
	for k=0,nz-1 do
		for j=0,ny-1 do
			for i=0,nx-1 do
				if i < voxelmap:getWidth()
				and j < voxelmap:getHeight()
				and k < voxelmap:getDepth()
				then
					-- TODO or ffi.copy per-row to speed things up
					o:emplace_back()[0] = voxelmap:getVoxelDataBlobPtr()[
						i + voxelmap:getWidth() * (
							j + voxelmap:getHeight() * k
						)
					].intval
				else
					o:emplace_back()[0] = voxelMapEmptyValue		-- default type ... of 0, right?
				end
			end
		end
	end

	self.app.blobs.voxelmap[self.voxelmapBlobIndex+1] = blobClassForName.voxelmap(o:dataToStr())

	self:updateBlobChanges()
end

function EditVoxelMap:popUndo(redo)
	local app = self.app
	local entry = self.undo:pop(redo)
	if not entry then return end
	app.blobs.voxelmap[self.voxelmapBlobIndex+1] = blobClassForName.voxelmap(entry.data)
	self:updateBlobChanges()
end

return EditVoxelMap
