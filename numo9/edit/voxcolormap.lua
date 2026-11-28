local ffi = require 'ffi'
local assert = require 'ext.assert'
local table = require 'ext.table'
local math = require 'ext.math'
local timer = require 'ext.timer'
local vector = require 'stl.vector-lua'
local vec3d = require 'vec-ffi.vec3d'
local box3d = require 'vec-ffi.box3d'
local quatd = require 'vec-ffi.quatd'
local Image = require 'image'
local gl = require 'gl'

local clip = require 'numo9.clipboard'
local Undo = require 'numo9.ui.undo'
local Orbit = require 'numo9.ui.orbit'
local TileSelect = require 'numo9.ui.tilesel'

local UIWidget = require 'numo9.ui.widget'
local UIBlobSelect = require 'numo9.ui.blobselect'
local UIButton = require 'numo9.ui.button'
local UISpinner = require 'numo9.ui.spinner'
local UITextField = require 'numo9.ui.textfield'
local UICheckbox = require 'numo9.ui.checkbox'
local UIRadio = require 'numo9.ui.radio'

local numo9_rom = require 'numo9.rom'
local spriteSize = numo9_rom.spriteSize
local matArrType = numo9_rom.matArrType
local voxColorMapSizeType = numo9_rom.voxColorMapSizeType
local voxColorMapEmptyValue = numo9_rom.voxColorMapEmptyValue
local voxColorMapSizeType = numo9_rom.voxColorMapSizeType
local VoxColor = numo9_rom.VoxColor


local numo9_blobs = require 'numo9.blobs'
local blobClassForName = numo9_blobs.blobClassForName

local blobName = 'voxcolormap'
local blobClass = assert.index(blobClassForName, blobName)

local uint8_t = ffi.typeof'uint8_t'

local voxColorMapSizeType_p = ffi.typeof('$*', voxColorMapSizeType)
local VoxColor_p = ffi.typeof('$*', VoxColor)


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
			return {
				data = self.app.blobs[blobName][self.voxColorMapBlobIndex+1]:toBinStr(),
			}
		end,
		changed = function(entry)
			return entry.data ~= self.app.blobs[blobName][self.voxColorMapBlobIndex+1]:toBinStr()
		end,
	}

	self:newUI_setup()
	self:newUI_addEditTabs()

	local x, y = 6*9, 0

	self.voxColorMapBlobSelect = UIBlobSelect{
		owner = self,
		pos = {x, y},
		blobName = blobName,
		valueTable = self,
		valueKey = 'voxColorMapBlobIndex',
		setValue = function(value)
			self.undo:clear()
		end,
	}
	self:addChild(self.voxColorMapBlobSelect)
	x = x + 11

	self.paletteBlobSelect = UIBlobSelect{
		owner = self,
		pos = {x, y},
		blobName = 'palette',
		valueTable = self,
		valueKey = 'paletteBlobIndex',
		setValue = function(value)
			self.undo:clear()
		end,
	}
	self:addChild(self.paletteBlobSelect)
	x = x + 11

	do
		self.resizePopup = UIWidget{
			owner = self,
			pos = {64,64},	-- TODO center
			size = {100,40},
			zIndex = -10,
			-- TODO size autogen from children...
		}
		self.resizePopup.visibility = 'hidden'
		self:addChild(self.resizePopup)
		do
			local UILabel = require 'numo9.ui.label'
			local padding = 4
			for row,name in ipairs{
				'width',
				'height',
				'depth',
			} do
				local y = padding + (row-1) * 8
				local x = padding
				self.resizePopup:addChild(UILabel{
					owner = self,
					pos = {x,y},
					text = name..':',
				})
				x=x+6*7
				local sizeText, spinner, ofsText
				spinner = UISpinner{
					owner = self,
					pos = {x,y},
					setValue = function(dx)
						local x = tonumber(sizeText.value) or 0
						x = math.max(1, x + dx)
						sizeText.value = tostring(x)
					end,
				}
				self.resizePopup:addChild(spinner)
				self.resizePopup[name..'Spinner'] = spinner
				x=x+13
				sizeText = UITextField{
					owner = self,
					pos = {x,y},
					width = 12,
				}
				self.resizePopup:addChild(sizeText)
				self.resizePopup[name..'Text'] = sizeText
				x=x+20

				ofsText = UITextField{
					owner = self,
					pos = {x,y},
					width = 12,
				}
				self.resizePopup:addChild(ofsText)
				self.resizePopup[name..'OfsText'] = ofsText
				x=x+20
			end
			self.resizePopup:addChild(UIButton{
				owner = self,
				pos = {10, 4*8},
				text = 'ok',
				events = {
					click = function(target, e)
						e:stopPropagation()	-- don't fall thru to click on the screen

						self.resizePopup.visibility = 'hidden'
						--
						local voxColorMap = self.app.blobs[blobName][self.voxColorMapBlobIndex+1]
						assert(voxColorMap, "wait how did you open this with no voxColorMap selected?")
						self:resizeVoxColorMap(
							math.max(1, tonumber(self.resizePopup.widthText.value) or 0),
							math.max(1, tonumber(self.resizePopup.heightText.value) or 0),
							math.max(1, tonumber(self.resizePopup.depthText.value) or 0),
							tonumber(self.resizePopup.widthOfsText.value) or 0,
							tonumber(self.resizePopup.heightOfsText.value) or 0,
							tonumber(self.resizePopup.depthOfsText.value) or 0
						)
					end,
				},
			})
			self.resizePopup:addChild(UIButton{
				owner = self,
				pos = {30, 4*8},
				text = 'cancel',
				events = {
					click = function()
						self.resizePopup.visibility = 'hidden'
					end,
				},
			})
		end

		self:addChild(UIButton{
			owner = self,
			pos = {x, y},
			text = 'R',
			tooltip = 'resize...',
			events = {
				click = function()
					local voxColorMap = self.app.blobs[blobName][self.voxColorMapBlobIndex+1]
					if not voxColorMap then return end
					self.resizePopup.widthText.value = tostring(voxColorMap:getWidth())
					self.resizePopup.heightText.value = tostring(voxColorMap:getHeight())
					self.resizePopup.depthText.value = tostring(voxColorMap:getDepth())
					self.resizePopup.widthOfsText.value = '0'
					self.resizePopup.heightOfsText.value = '0'
					self.resizePopup.depthOfsText.value = '0'
					self.resizePopup.visibility = 'visible'
				end,
			},
		})
		x = x + 6
		--]]

		self.voxCurSelTextField = UITextField{
			owner = self,
			pos = {189, 0},
			width = 5,
			--value = ('%08X'):format(self.voxCurSel),
			events = {
				focus = function(target, e)
					target.value = ('%02X'):format(self.voxCurSel)
				end,
				change = function(target, e)
					local result = target.value
					result = tonumber(result, 16)
					if result then
						self.voxCurSel = result
						self:updateVoxCurSel()
					end
				end,
			},
		}
		self:addChild(self.voxCurSelTextField)
	end

	do
		local palettePopup = UIWidget{
			owner = self,
			pos = {0, 16},
			size = {128, 128},
			zIndex = -10,
		}
		for i=1,255 do
			local x = i & 0xf
			local y = i >> 4
			local colorButton = UIWidget{
				owner = self,
				pos = {x<<3, y<<3},
				size = {8,8},
				bgColorIndex = i,
				events = {
					click = function()
						self.voxCurSel = i
					end,
				},
			}
			function colorButton:draw()
				local owner = self.owner
				local app = owner.app

				local paletteBlob = app.blobs.palette[owner.paletteBlobIndex+1]
				local paletteRAM = paletteBlob.ramgpu

				-- same as typical UIWidget.draw except custom palette blob
				app:drawSolidRect(
					0, 0,						-- x, y
					self.size.x, self.size.y,	-- w, h
					self.bgColorIndex,			-- colorIndex
					nil,						-- borderOnly
					true,						-- round
					paletteRAM.tex				-- palette
				)

				-- same as borderColorIndex...
				if self.bgColorIndex == owner.voxCurSel then
					app:drawSolidRect(
						0, 0,						-- x, y
						self.size.x, self.size.y,	-- w, h
						27,							-- colorIndex
						true,						-- borderOnly
						true,						-- round
						app.paletteMenuTex			-- palette
					)
				end
			end
			palettePopup:addChild(colorButton)
		end
		palettePopup.visibility = 'hidden'
		self:addChild(palettePopup)
		self.palettePopup = palettePopup
	end
	self:addChild(UIButton{
		owner = self,
		pos = {x, y},
		text = 'P',
		tooltip = 'palette...',
		events = {
			click = function()
				if self.palettePopup.visibility == 'visible' then
					self.palettePopup.visibility = 'hidden'
				else
					self.palettePopup.visibility = 'visible'
				end
			end,
		},
	})
	x = x + 6

	self.orthoButton = UIButton{
		owner = self,
		pos = {x, y},
		text = 'O',
		--[[
		text = function()
			return self.orbit.ortho and 'O' or 'P'
		end,
		isset = function() return false end,	-- maybe it's a button
		--]]
		tooltip = function()
			return self.orbit.ortho and 'ortho' or 'perspective'
		end,
		events = {
			click = function()
				self.orbit.ortho = not self.orbit.ortho
				if self.orbit.ortho then
					self.orthoButton.text = 'O'
				else
					self.orthoButton.text = 'P'
				end
			end
		},
	}
	self:addChild(self.orthoButton)
	x = x + 6

	self:addChild(UIButton{
		owner = self,
		pos = {x, y},
		text = 'L',
		tooltip = function() return 'light='..tostring(self.menuUseLighting) end,
		events = {
			click = function()
				self.menuUseLighting = not self.menuUseLighting
			end,
		},
	})
	x = x + 6

	self:addChild(UIButton{
		owner = self,
		pos = {x, y},
		text = 'C',
		tooltip = function() return 'cull='..tostring(self.menuUseCullFace) end,
		events = {
			click = function()
				self.menuUseCullFace = (self.menuUseCullFace + 1) % 3
			end,
		},
	})
	x = x + 6

	do --if voxColorMap then
		local x = 0
		local y = 8

		-- tools ... maybe I should put these somewhere else
		self:addChild(UIRadio{
			owner = self,
			pos = {x, y},
			options = {
				-- minecraft-place-block style.
				-- single-click to plop voxels off of the surface.
				'draw',

				-- plop voxels perpendicular to the click plane.
				-- lets you click-and-drag, but since penSize is only orthogonal,
				--  it doesnt immedaitely stack voxels to the view position.
				'orthodraw',

				-- only changes non-empty voxels on-surface
				-- click-and-drag
				-- penSize = paint region.
				'paint',

				-- rectangle, left click = fill, right click = erase.
				'rect',

				-- 3D floodfill.
				'fill',

				-- 2D floodfill.
				'surfacefill',

				-- cut/copy/paste
				'select',
			},
			getSelected = function()
				return self.drawMode
			end,
			setSelected = function(result)
				self.drawMode = result
			end,
		})
		x = x + 6*7

		self:addChild(UISpinner{
			owner = self,
			pos = {x, y},
			tooltip = function()
				return 'pensize='..self.penSize
			end,
			setValue = function(dx)
				self.penSize = math.max(1, self.penSize + dx)
			end,
		})
		x = x + 11 + 3
	end

	require 'numo9.ui.addgetset'(self, {
		voxColorMapBlobIndex = {
			set = function(private, self, k, v)
				private[k] = v
				self.voxColorMapBlobSelect.textfield.value = tostring(v)
			end,
		},
		paletteBlobIndex = {
			set = function(private, self, k, v)
				private[k] = v
				self.paletteBlobSelect.textfield.value = tostring(v)
			end,
		},
		voxCurSel = {
			set = function(private, self, k, v)
				private[k] = v
				self:updateVoxCurSel()
			end,
		},
	})

	self:onCartLoad()
end

-- call this if voxCurSel or its values change
function EditVoxelMap:updateVoxCurSel()
	self.voxCurSelTextField.value = ('%02X'):format(self.voxCurSel)
end

function EditVoxelMap:onCartLoad()
	self.voxColorMapBlobIndex = 0
	self.paletteBlobIndex = 0

	self.moveSpeed = .3

	self.drawMode = 'draw'
	self.menuUseLighting = false
	self.menuUseCullFace = 0	-- 0 = no, 1 = back, 2 = front
	self.rectDown = nil
	self.rectUp = nil
	self.penSize = 1

	self.palettePickOpen = false

	self.voxCurSel = 1
	self:updateVoxCurSel()

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
	local denom = lineDir.s[axis]
	if math.abs(denom) < 1e-7 then return math.huge end
	return ((planePtOnAxis - linePt.s[axis]) * planeNormalOnAxis) / (denom * planeNormalOnAxis)
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
		if math.abs(lineDir.s[i]) < 1e-7 then
			-- within epsilon, skip
		else
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
				if box.min.s[j] <= ptj and ptj < box.max.s[j]
				and box.min.s[k] <= ptk and ptk < box.max.s[k]
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
	end
	-- same as in mesh3d and voxColorMap
	-- sideIndex is 0-5
	-- bit 0 = negative direction bit
	-- bits 1:2 = 0-2 for xyz, which direction the side is facing
	local sideIndex
	if axis then
		sideIndex = (axis << 1) | sideNormalSignFlag
	end
	return d, sideIndex
end

-- assumes we're already scaled down by voxelVertexScale_x2
function EditVoxelMap:drawBox(box, color)
	local app = self.app
	local thickness = math.max(1, app.width / 256)
	local epsilon = 1/32
	for i=0,7 do
		for b=0,2 do
			local j = i ~ (1 << b)
			if j > i then
				-- why did I say bit set = min?
				-- looks like mesh lib uses :corner so dont change it
				local ax, ay, az = box:corner(i):unpack()
				if i & 1 == 0 then ax = ax + epsilon else ax = ax - epsilon end
				if i & 2 == 0 then ay = ay + epsilon else ay = ay - epsilon end
				if i & 4 == 0 then az = az + epsilon else az = az - epsilon end
				local bx, by, bz = box:corner(j):unpack()
				if j & 1 == 0 then bx = bx + epsilon else bx = bx - epsilon end
				if j & 2 == 0 then by = by + epsilon else by = by - epsilon end
				if j & 4 == 0 then bz = bz + epsilon else bz = bz - epsilon end
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

	self:newUI_realignChildren()

	local orbit = self.orbit

	-- this is going to draw the menu
	local handled = EditVoxelMap.super.update(self)

	app:matMenuReset()
	self:guiSetClipRect(-1000, 16, 3000, 240)

	local mouseX, mouseY = app:invTransform(app.ram.mousePos:unpack())

	local shift = app:key'lshift' or app:key'rshift'

	local voxColorMap = app.blobs[blobName][self.voxColorMapBlobIndex+1]
	local mapsize = voxColorMap
		and vec3d(
			voxColorMap:getWidth(),
			voxColorMap:getHeight(),
			voxColorMap:getDepth())
	local mapbox = mapsize and box3d(vec3d(0,0,0), mapsize)
	local mapboxIE = mapsize and box3d(vec3d(0,0,0), mapsize-1)	-- mapbox, [incl,excl), for integer testing

	if voxColorMap then

		-- init lighting before beginDraw() so that we get the clear depth call that will clear the lighting as well
		local pushHD2DFlags = app.ram.HD2DFlags
		app.ram.HD2DFlags = self.menuUseLighting and 0xff or 0
		if app.ram.HD2DFlags ~= pushHD2DFlags then
			app:onHD2DFlagsChange()
		end

		local pushCullFace = app.ram.cullFace
		app.ram.cullFace = self.menuUseCullFace
		if app.ram.cullFace ~= pushCullFace then
			app:onCullFaceChange()
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
		app:drawVoxColorMap(
			self.voxColorMapBlobIndex,
			self.paletetBlobIndex
		)

		if not handled
		and mouseY >= 16
		then
			-- mouse line, intersect only with far bounding planes of the voxColorMap
			-- or intersect with march through the voxColorMap
			-- how to get mouse line?
			-- transform mouse coords by view matrix
			local mousePos = orbit.pos + mapsize * .5
			-- assume fov is 90°
			local mouseDir =
				- orbit.angle:zAxis()
				+ orbit.angle:xAxis() * (mouseX - 128) / 128
				- orbit.angle:yAxis() * (mouseY - 128) / 128

			-- step along dir a small bit so all ray origins aren't in the same spot (which gets us into a bad place when deciding which way to go when raytracing)
			mousePos = mousePos + .1 * mouseDir

			local sideIndex
			-- or alternatively use the inverse of the modelview matrix... but meh ...
			if not mapbox:contains(mousePos) then
				-- now line intersect with the camera-facing planes of the bbox

				local d
				d, sideIndex = lineBoxDist(
					mapbox,
					mousePos,
					mouseDir
				)
				-- [[
				if sideIndex then
					-- because it's not inside the cube, flip the sideIndex +-
					-- ... or should I do this within lineBoxDist when 'inside' is false?
					sideIndex = 1 ~ sideIndex
				end
				--]]

				mousePos = mousePos + mouseDir * (d + 1e-5)
				-- this could still be OOB if the user isn't mouse'd over the box ...
			end
			if mapbox:contains(mousePos) then
				local npti = mousePos:map(math.floor)
				local pti = npti:clone()
				-- then march through the voxColorMap
				while true do
					local vaddr = voxColorMap:getVoxelAddr(npti:unpack())
					if vaddr and app:peek(vaddr) ~= voxColorMapEmptyValue then
						break
					end

					pti = npti

					-- intersect with cube [pti, pti+1]
					local d
					d, sideIndex = lineBoxDist(
						box3d(pti, pti+1),
						mousePos,
						mouseDir,
						true	-- true = inside the cube intersecting with outside
					)
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

					local function drawVoxelBrush(vox, cx, cy, cz)
						local b = self.penSize-1
						for z=math.max(cz-b,0),math.min(cz+b,mapsize.z-1) do
							for y=math.max(cy-b,0),math.min(cy+b,mapsize.y-1) do
								for x=math.max(cx-b,0),math.min(cx+b,mapsize.x-1) do
									local addr = voxColorMap:getVoxelAddr(x,y,z)
									if addr then
										-- timer based so it shouldnt push multiple per drawVoxelBrush(), right?
										self.undo:pushContinuous()
										-- TODO make this a callback for optional autotiling
										self:edit_poke(addr, vox)
									end
								end
							end
						end
					end

					-- draw = place blocks per click
					if self.drawMode == 'draw' then
						if shift then
							if app:key'mouse_left' then
								self:dropper(voxColorMap, npti:unpack())
							end
						else
							-- right click to destroy single tile
							if app:keyp'mouse_right' then
								drawVoxelBrush(voxColorMapEmptyValue, npti:unpack())
							end

							if app:keyp'mouse_left' then
								drawVoxelBrush(self.voxCurSel, pti:unpack())
							end
						end

					-- like paint but changes empty voxels as well, and only does penSize extents perpendicular to click side.
					elseif self.drawMode == 'orthodraw' then

						if shift then
							if app:key'mouse_left' then
								self:dropper(voxColorMap, npti:unpack())
							end
						else
							-- right click to destroy single tile ... ? or not?
							if app:keyp'mouse_right' then
								drawVoxelBrush(voxColorMapEmptyValue, npti:unpack())
							end

							-- left press = paint on tile
							-- like paint but also does non-empty
							-- but only goes over extent in dir orthogonal to click face.
							if app:key'mouse_left' then
								local axis = sideIndex >> 1
								local cx, cy, cz = npti:unpack()
								local b = self.penSize - 1
								local bx = axis == 0 and 0 or b
								local by = axis == 1 and 0 or b
								local bz = axis == 2 and 0 or b
								for z=math.max(cz-bz,0),math.min(cz+bz,mapsize.z-1) do
									for y=math.max(cy-by,0),math.min(cy+by,mapsize.y-1) do
										for x=math.max(cx-bx,0),math.min(cx+bx,mapsize.x-1) do
											local addr = voxColorMap:getVoxelAddr(x,y,z)
											if addr then
												-- timer based so it shouldnt push multiple per drawVoxelBrush(), right?
												self.undo:pushContinuous()
												-- TODO make this a callback for optional autotiling
												self:edit_poke(addr, self.voxCurSel)
											end
										end
									end
								end
							end
						end

					-- paint = draw on surface per mousedown
					elseif self.drawMode == 'paint' then
						if shift then
							if app:key'mouse_left' then
								self:dropper(voxColorMap, npti:unpack())
							end
						else
							-- right click to destroy single tile ... ? or not?
							if app:keyp'mouse_right' then
								drawVoxelBrush(voxColorMapEmptyValue, npti:unpack())
							end

							-- left press = paint on tile, but only if its present
							-- for penSize==1 this is just writing 'npti' .. except at borders where 'npti' isnt within a solid.
							-- but for any bigger I should verify tile is not empty before painting
							if app:key'mouse_left' then
								local cx, cy, cz = npti:unpack()
								local b = self.penSize-1
								for z=math.max(cz-b,0),math.min(cz+b,mapsize.z-1) do
									for y=math.max(cy-b,0),math.min(cy+b,mapsize.y-1) do
										for x=math.max(cx-b,0),math.min(cx+b,mapsize.x-1) do
											local addr = voxColorMap:getVoxelAddr(x,y,z)
											if addr
											and app:peek(addr) ~= voxColorMapEmptyValue
											then
												-- timer based so it shouldnt push multiple per drawVoxelBrush(), right?
												self.undo:pushContinuous()
												-- TODO make this a callback for optional autotiling
												self:edit_poke(addr, self.voxCurSel)
											end
										end
									end
								end
							end
						end
					elseif self.drawMode == 'rect' then

						if shift then
							if app:key'mouse_left' then
								self:dropper(voxColorMap, npti:unpack())
							end
						else
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
												local addr = voxColorMap:getVoxelAddr(i,j,k)
												if addr then	 -- TODO clamp bounds
													self:edit_poke(addr, voxColorMapEmptyValue)
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
												local addr = voxColorMap:getVoxelAddr(i,j,k)
												if addr then	 -- TODO clamp bounds
													self:edit_poke(addr, self.voxCurSel)
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
						end
					elseif self.drawMode == 'select' then

						-- show where paste would go if we have copied ... ?
						-- only in select mode
						-- TODO instead of saving 'lastCopySize' upon copy/cut
						--  ... do a SDL on-copy event handler.
						if self.lastCopySize then
							local halfSize = (.5 * self.lastCopySize):map(math.floor)
							self:drawBox(
								box3d(
									npti - halfSize,
									npti - halfSize + self.lastCopySize
								),
								0x1d)
						end


						-- right-click to paste on surface at pti / outside
						if app:keyp'mouse_right' then
							self:pasteAtCenter(voxColorMap, pti, sideIndex)
						end

						-- npti / inside is intuitive for selection
						-- but for pasting it is more intuitive to use pti / outside
						if app:keyp'mouse_left' then
							self.rectDown = npti:clone()
							self.rectUp = npti:clone()
						elseif app:keyr'mouse_left' then
						elseif app:key'mouse_left' then
							if shift then
								-- hold shift while moving to only grow rect area
								local min = vec3d(
									math.min(self.rectUp.x, self.rectDown.x, npti.x),
									math.min(self.rectUp.y, self.rectDown.y, npti.y),
									math.min(self.rectUp.z, self.rectDown.z, npti.z))
								local max = vec3d(
									math.max(self.rectUp.x, self.rectDown.x, npti.x),
									math.max(self.rectUp.y, self.rectDown.y, npti.y),
									math.max(self.rectUp.z, self.rectDown.z, npti.z))
								-- hmm todo when you release shift, which one should have down and which should have up ...
								-- TODO up should be closest to npti
								self.rectDown:set(min:unpack())
								self.rectUp:set(max:unpack())
							else
								self.rectUp = npti:clone()
							end
						end
					elseif self.drawMode == 'fill' then

						if shift then
							if app:key'mouse_left' then
								self:dropper(voxColorMap, npti:unpack())
							end
						else
							-- right click to destroy single tile
							if app:keyp'mouse_right'
							and mapboxIE:contains(npti)
							then
								local addr = voxColorMap:getVoxelAddr(npti:unpack())
								if addr then
									self.undo:pushContinuous()
									self:edit_poke(addr, voxColorMapEmptyValue)
								end
							end

							if app:keyp'mouse_left' then
								local addr = voxColorMap:getVoxelAddr(npti:unpack())
								if addr then
									local srcColor = app:peek(addr)
									if srcColor ~= voxColorMapEmptyValue
									and srcColor ~= self.voxCurSel
									then
										self.undo:push()

										local fillstack = table()

										self:edit_poke(addr, self.voxCurSel)

										fillstack:insert(npti:clone())
										while #fillstack > 0 do
											local pt = fillstack:remove()
											for _,dir in ipairs(dirsForSide) do
												local pt2 = pt + dir
												local addr = voxColorMap:getVoxelAddr(pt2:unpack())
												if addr	-- addr won't exist if it's oob
												and app:peek(addr) == srcColor
												then
													self:edit_poke(addr, self.voxCurSel)
													fillstack:insert(pt2)
												end
											end
										end
									end
								end
							end
						end
					elseif self.drawMode == 'surfacefill' then
						if shift then
							if app:key'mouse_left' then
								self:dropper(voxColorMap, npti:unpack())
							end
						else
							-- right click to destroy single tile
							if app:keyp'mouse_right'
							and mapboxIE:contains(npti)
							then
								local addr = voxColorMap:getVoxelAddr(npti:unpack())
								if addr then
									self.undo:pushContinuous()
									self:edit_poke(addr, voxColorMapEmptyValue)
								end
							end

							if app:keyp'mouse_left' then
								-- figure out what side of the cube we're on ...
								-- try to get the surface normal pointing back at the player, i.e. prev cube minus next cube pos
								-- needs to know what side you clicked on
								-- these dirs match sideIndex in mesh3d and voxColorMap except that sideIndex is 0-based
								local dirs = table(dirsForSide)
								if sideIndex == 0 or sideIndex == 1 then
									dirs:remove(1)
									dirs:remove(1)
								elseif sideIndex == 2 or sideIndex == 3 then
									dirs:remove(3)
									dirs:remove(3)
								elseif sideIndex == 4 or sideIndex == 5 then
									dirs:remove(5)
									dirs:remove(5)
								end
								if #dirs ~= 4 then
									print("somehow removed too many dirs, must have a weird sideIndex: "..sideIndex)
								else
									local addr = voxColorMap:getVoxelAddr(npti:unpack())
									if addr then
										local srcColor = app:peek(addr)
										if srcColor ~= voxColorMapEmptyValue
										and srcColor ~= self.voxCurSel
										then
											self.undo:push()

											local fillstack = table()

											self:edit_poke(addr, self.voxCurSel)

											fillstack:insert(npti:clone())
											while #fillstack > 0 do
												local pt = fillstack:remove()
												for _,dir in ipairs(dirs) do
													local pt2 = pt + dir

													local nbhdAddr = voxColorMap:getVoxelAddr((pt2 + dirsForSide[1+sideIndex]):unpack())
													if not nbhdAddr	-- oob means no addr means empty, so crawl along this surface
													or app:peek(nbhdAddr) == voxColorMapEmptyValue -- is really empty value
													then
														local addr = voxColorMap:getVoxelAddr(pt2:unpack())
														if addr	-- addr won't exist if it's oob
														and app:peek(addr) == srcColor
														then
															self:edit_poke(addr, self.voxCurSel)
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
					), 0x1c)
				end

				if not self.tooltip then
					self:setTooltip(npti.x..','..npti.y..','..npti.z, mouseX-8, mouseY-8, 0xfc, 0)
				end
			end
		end


		if app.ram.cullFace ~= pushCullFace then
			app.ram.cullFace = pushCullFace
			app:onCullFaceChange()
		end
		if self.menuUseLighting then
			app:flushToFinalRGB(true)
			if app.ram.HD2DFlags ~= pushHD2DFlags then
				app.ram.HD2DFlags = pushHD2DFlags
				app:onHD2DFlagsChange()
			end
		end

		orbit:endDraw()

		-- TODO should this go here or in the caller:
		app:matMenuReset()

		local x, y = 0, 16
		app:drawMenuText(mapsize.x..'x'..mapsize.y..'x'..mapsize.z, x, y)
		y = y + 8
	end


	self:guiSetClipRect(0, 0, 256, 256)
	--self:guiSetClipRect(-1000, 0, 3000, 256)


	---------------- KEYBOARD ----------------

	if voxColorMap then
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

		for ch = 1,10 do
			if app:keyp( string.char(('0'):byte() + (ch % 10)) ) then
				self.moveSpeed = 10 ^ ((ch - 5) / 4)
			end
		end

		local uikey
		if ffi.os == 'OSX' then
			uikey = app:key'lgui' or app:key'rgui'
		else
			uikey = app:key'lctrl' or app:key'rctrl'
		end
		if uikey then
			if app:keyp'a' then
				-- select-all
				self.rectUp = vec3d(0,0,0)
				self.rectDown = vec3d(mapboxIE.max:unpack())
			elseif app:keyp'x'
			or app:keyp'c'
			then
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
					self.lastCopySize = size:clone()
					local o = vector(VoxColor)
					o:resize(6)
					ffi.cast(voxColorMapSizeType_p, o.v+0)[0] = size.x
					ffi.cast(voxColorMapSizeType_p, o.v+0)[1] = size.y
					ffi.cast(voxColorMapSizeType_p, o.v+0)[2] = size.z
					for z=0,size.z-1 do
						for y=0,size.y-1 do
							for x=0,size.x-1 do
								local v = voxColorMap:getVoxelBlobPtr(x + min.x, y + min.y, z + min.z)
								o:emplace_back()[0] = v or voxColorMapEmptyValue
							end
						end
					end
					-- now encode it in an image ...
					local w = math.ceil(math.sqrt(#o))
					local h = math.ceil(#o / w)
					local img = Image(w, h, 1, uint8_t)
					ffi.fill(img.buffer, img:getBufferSize())
					ffi.copy(img.buffer, o.v, #o)
					clip.image(img)
					if app:keyp'x' then
						self.undo:push()
						for z=0,size.z-1 do
							for y=0,size.y-1 do
								for x=0,size.x-1 do
									local addr = voxColorMap:getVoxelAddr(x + min.x, y + min.y, z + min.z)
									if addr then	 -- TODO clamp bounds
										self:edit_poke(addr, voxColorMapEmptyValue)
									end
								end
							end
						end
					end
				end
			elseif app:keyp'v' then
				self:pasteAtCenter(voxColorMap, vec3d(
					(self.rectUp.x + self.rectDown.x) >> 1,
					(self.rectUp.y + self.rectDown.y) >> 1,
					(self.rectUp.z + self.rectDown.z) >> 1))
			elseif app:keyp'z' then
				self:popUndo(shift)
			end
		end
	end

	---------------- TOOLTIP ----------------

	self:guiSetClipRect(-1000, 0, 3000, 256)
	self:newUI_update()
end

function EditVoxelMap:dropper(voxColorMap, x,y,z)
	local app = self.app
	local sx = voxColorMap:getWidth()
	local sy = voxColorMap:getHeight()
	local sz = voxColorMap:getDepth()

	if x < 0 or x >= sx
	or y < 0 or y >= sy
	or z < 0 or z >= sz
	then return end

	local addr = voxColorMap:getVoxelAddr(x, y, z)
	if not addr then return end

	local voxval = app:peek(addr)
	-- how about shift+click on an empty tile works
	-- that way you can shift+click on the map border to quickly grab empty tile
	-- sometimes you want it, i.e. when you're flood-filling empty tiles
	--if voxval ~= voxColorMapEmptyValue then
	self.voxCurSel = voxval
	self:updateVoxCurSel()
	--end
end

-- if 'sideIndex' is defined (i.e. right-click select mode)
-- then make sure the size is all on one side of 'sideIndex'
function EditVoxelMap:pasteAtCenter(voxColorMap, centerpos, sideIndex)
	local image = clip.image()
	if not image then return end
	if image.channels ~= 4 then
		print('paste got an image with invalid channels', image.channels)
		return
	end
	if image:getBufferSize() < 3 * ffi.sizeof(voxColorMapSizeType) then	-- make sure the header is at least there
		print('paste got an image with not enough buffer size', image:getBufferSize())
		return
	end
	local sp = ffi.cast(voxColorMapSizeType_p, image.buffer)
	local sx, sy, sz = sp[0], sp[1], sp[2]
	local p = ffi.cast(VoxColor_p, sp+3)
	if ffi.sizeof(voxColorMapSizeType) * 3 + ffi.sizeof(VoxColor) * sx * sy * sz > image:getBufferSize() then
		print('paste got a bad sized image: '..sx..', '..sy..', '..sz..' versus its buffer size '..image:getBufferSize())
		return
	end
	self.undo:push()
	local ofsx = centerpos.x - (sx >> 1)
	local ofsy = centerpos.y - (sy >> 1)
	local ofsz = centerpos.z - (sz >> 1)
	if sideIndex == 0 then
		ofsx = centerpos.x
	elseif sideIndex == 1 then
		ofsx = centerpos.x - (sx - 1)
	elseif sideIndex == 2 then
		ofsy = centerpos.y
	elseif sideIndex == 3 then
		ofsy = centerpos.y - (sy - 1)
	elseif sideIndex == 4 then
		ofsz = centerpos.z
	elseif sideIndex == 5 then
		ofsz = centerpos.z - (sz - 1)
	end
	for z=0,sz-1 do
		for y=0,sy-1 do
			for x=0,sx-1 do
				local addr = voxColorMap:getVoxelAddr(x + ofsx, y + ofsy, z + ofsz)
				if addr then	 -- TODO clamp bounds
					self:edit_poke(addr, p[x + sx * (y + sy * z)])
				end
			end
		end
	end
end

function EditVoxelMap:resizeVoxColorMap(nx, ny, nz, dx, dy, dz)
	dx = dx or 0
	dy = dy or 0
	dz = dz or 0

	local app = self.app
	local voxColorMap = app.blobs[blobName][self.voxColorMapBlobIndex+1]
	if not voxColorMap then return end

	self.undo:push()

	local o = vector(VoxColor)
	o:resize(6)
	ffi.cast(voxColorMapSizeType_p, o.v+0)[0] = nx
	ffi.cast(voxColorMapSizeType_p, o.v+0)[1] = ny
	ffi.cast(voxColorMapSizeType_p, o.v+0)[2] = nz
	for k=0,nz-1 do
		for j=0,ny-1 do
			for i=0,nx-1 do
				local srci = i - dx
				local srcj = j - dy
				local srck = k - dz
				if srci >= 0 and srci < voxColorMap:getWidth()
				and srcj >= 0 and srcj < voxColorMap:getHeight()
				and srck >= 0 and srck < voxColorMap:getDepth()
				then
					-- TODO or ffi.copy per-row to speed things up
					o:emplace_back()[0] = voxColorMap:getVoxelDataBlobPtr()[
						srci + voxColorMap:getWidth() * (
							srcj + voxColorMap:getHeight() * srck
						)
					]
				else
					o:emplace_back()[0] = voxColorMapEmptyValue		-- default type ... of 0, right?
				end
			end
		end
	end

	self.app.blobs[blobName][self.voxColorMapBlobIndex+1] = blobClass(o:dataToStr())

	self:updateBlobChanges()
end

function EditVoxelMap:popUndo(redo)
	local app = self.app
	local entry = self.undo:pop(redo)
	if not entry then return end
	app.blobs[blobName][self.voxColorMapBlobIndex+1] = blobClass(entry.data)
	self:updateBlobChanges()
end

return EditVoxelMap
