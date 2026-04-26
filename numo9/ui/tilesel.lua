--[[
I think I'll put the tile-selection widget here,
and use it in mesh3d and voxelmap for tile preview/selection.

TODO if I separate the popup/window from teh content
then I can also put this in the sheet editor
and I can also embed it in the mesh3d for UV-editing ...

--]]
local assert = require 'ext.assert'
local class = require 'ext.class'
local math = require 'ext.math'
local vec2i = require 'vec-ffi.vec2i'
local vec2d = require 'vec-ffi.vec2d'

local numo9_rom = require 'numo9.rom'
local spriteSize = numo9_rom.spriteSize
local spriteSheetSize = numo9_rom.spriteSheetSize
local spriteSheetSizeInTiles = numo9_rom.spriteSheetSizeInTiles

local TileSelect = class()

--[[
args:
	edit = points to the editor panel using this ui
		used for:
		- edit.app to point back to the app
		- edit.paletteBlobIndex if present for determining what palette to use ...
		- edit.sheetBlobIndex if present for which sheet to use
	onSetTile (optional)
		set this for a callback when .pos changes.

	getMeshIndex = optional, function that returns 0-based mesh3d blob index, for drawing texcoord mesh overlay

TODO 'allowRect' since tilemap select allows a rectangle-box-select for stamping multiple tiles,
 meanwhile mesh3d and voxelmap just need a coordinate for offsetting mesh texture coordiantes.
--]]
function TileSelect:init(args)
	self.edit = assert.index(args, 'edit')
	self.onSetTile = args.onSetTile
	self.getMeshIndex = args.getMeshIndex	-- optional, for mesh overlay

	self.pickOpen = false		-- if this is open or not
	self.posDown = vec2d()		-- mouseX/mouseY upon mouse left press, in tiles
	self.posUp = vec2d()		-- mouseX/mouseY while dragging / waiting for a mouse left release, in tiles
	self.pos = vec2i()			-- selected pos, in tiles, upper-left of downPos/upPos
	self.size = vec2i(1,1)		-- selected size, in tiles

	self.panDownPos = vec2d()
	self.offset = vec2d()	-- for panning
	self.scale = 1			-- for zooming
end

function TileSelect:button(x, y)
	local edit = self.edit

	local tileIndex = bit.bor(self.pos.x, bit.lshift(self.pos.y, 5))
	if edit:guiButton('T', x, y, self.pickOpen, 'tile='..tileIndex) then
		self.pickOpen = not self.pickOpen
		return true
	end
end

-- returns true if handled ui, false if otherwise
function TileSelect:doPopup()
	local edit = self.edit
	local app = edit.app

	if not self.pickOpen then return false end

	-- TODO should this go here or in the caller:
	app:matMenuReset()

	local shift = app:key'lshift' or app:key'rshift'
	local leftButtonDown = app:key'mouse_left'
	local leftButtonPress = app:keyp'mouse_left'
	local leftButtonRelease = app:keyr'mouse_left'
	local mouseX, mouseY = app:invTransform(app.ram.mousePos:unpack())
	local lastMousePressX, lastMousePressY = app:invTransform(app.ram.lastMousePressPos:unpack())

	local winX = 2 * spriteSize.x
	local winY = 2 * spriteSize.y

	-- use menu coords which are odd and determined by matMenuReset
	-- height is 256, width is aspect ratio proportional
	-- TODO is it this or size / min(something)?
	--local ar = app.width / app.height
	--local winW = math.floor(256 * ar) - 2 * winX
	local winW = 256 - 2 * winX
	local winH = 256 - 2 * winY

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

	-- set the current selected palette via RAM registry to self.paletteBlobIndex
	edit:guiSetClipRect(winX, winY, winW, winH)	-- matrices do influence cliprect, so set cliprect first
	app:mattrans(winX, winY)
	app:matscale(self.scale, self.scale)
	app:mattrans(-self.offset.x, -self.offset.y)
	app:matscale(winW / 256, winH / 256)

	local pushPalBlobIndex = app.ram.paletteBlobIndex
	app.ram.paletteBlobIndex = edit.paletteBlobIndex or 0
	app:drawQuad(
		0,
		0,
		256,
		256,
		-- TODO scrollable pick area ... hmm ...
		-- or TODO use the same scrollable pick area for the sprite editor and the tile editor
		0,		-- tx
		0,		-- ty
		256,	-- tw
		256,	-- th
		0,		-- orientation2D
		edit.sheetBlobIndex,
		0,
		-1,
		0,
		0xff
	)
	app.ram.paletteBlobIndex = pushPalBlobIndex

	self:drawSelected()

	local spriteX, spriteY = app:invTransform(app.ram.mousePos:unpack())
	spriteX = spriteX / tonumber(spriteSize.x)
	spriteY = spriteY / tonumber(spriteSize.y)

	app:matMenuReset()
	edit:guiSetClipRect(-1000, 0, 3000, 256)

	if spriteX >= 0 and spriteX < spriteSheetSizeInTiles.x
	and spriteY >= 0 and spriteY < spriteSheetSizeInTiles.y
	then
		if not edit.tooltip then
			edit:setTooltip(math.floor(spriteX)..','..math.floor(spriteY), mouseX-8, mouseY-8, 0xfc, 0)
		end

		if leftButtonPress then
			-- TODO rect select
			self.posDown:set(spriteX, spriteY)
			self.posUp:set(spriteX, spriteY)
			self.pos:set(math.floor(spriteX), math.floor(spriteY))
			self.size:set(1, 1)
			if self.onSetTile then
				self:onSetTile()
			end
		elseif leftButtonDown then
			self.posUp:set(math.floor(spriteX), math.floor(spriteY))
			self.pos.x = math.min(math.floor(self.posUp.x), math.floor(self.posDown.x))
			self.pos.y = math.min(math.floor(self.posUp.y), math.floor(self.posDown.y))
			self.size.x = math.max(math.floor(self.posUp.x), math.floor(self.posDown.x)) - self.pos.x + 1
			self.size.y = math.max(math.floor(self.posUp.y), math.floor(self.posDown.y)) - self.pos.y + 1
		elseif leftButtonRelease then
			self.pickOpen = false
		end

		local function panWheel(dx,dy)	-- dx, dy in screen coords right?
			self.offset.x = self.offset.x + dx
			self.offset.y = self.offset.y + dy
		end

		if shift then
			if app.ram.mouseWheel.y ~= 0 then
				-- 128 is half 256 I guess, which is the sheet size in pixels I guess?
				panWheel(128 / self.scale, 128 / self.scale)
				self.scale = self.scale * math.exp(.1 * app.ram.mouseWheel.y)
				panWheel(-128 / self.scale, -128 / self.scale)
			end
		else
			if app.ram.mouseWheel.x ~= 0
			or app.ram.mouseWheel.y ~= 0
			then
				panWheel(
					-spriteSize.x * app.ram.mouseWheel.x,
					-spriteSize.y * app.ram.mouseWheel.y
				)
			end
		end

		local function fbToTileCoord(cx, cy)
			return
				(cx - winX) / (spriteSize.x * self.scale) + self.offset.x / spriteSize.x,
				(cy - winY) / (spriteSize.y * self.scale) + self.offset.y / spriteSize.y
		end

		local panHandled
		local function panClick(press)
			panHandled = true
			if press then
				self.panDownPos:set(mouseX, mouseY)
				self.panPressed = true
			else
				if self.panPressed then
					local tx1, ty1 = fbToTileCoord(mouseX, mouseY)
					local tx0, ty0 = fbToTileCoord(self.panDownPos:unpack())
					-- convert mouse framebuffer pixel movement to sprite texel movement
					local tx = tx1 - tx0
					local ty = ty1 - ty0
					if tx ~= 0 or ty ~= 0 then
						self.offset.x = self.offset.x - tx * spriteSize.x
						self.offset.y = self.offset.y - ty * spriteSize.y
						self.panDownPos:set(mouseX, mouseY)
					end
				end
			end
		end


		if app:key'space' then
			panClick(app:keyp'space')
		end

		if not panHandled then
			self.panPressed = false
		end
	end

	return true
end

function TileSelect:drawSelected()
	local edit = self.edit
	local app = edit.app

	local colorIndex = 0x1f
	local thickness = math.clamp(app.width / 256, 1, 2)
	local function tc(vtx)
		return
			tonumber(bit.band(0xff, vtx.u + bit.lshift(edit.tileSel.pos.x, 3))) + .5,
			tonumber(bit.band(0xff, vtx.v + bit.lshift(edit.tileSel.pos.y, 3))) + .5
	end
	-- draw the texcoords offset by the getMeshIndex tileSel.pos etc
	local mesh3DIndex = self.getMeshIndex and self:getMeshIndex()
	local mesh = mesh3DIndex and app.blobs.mesh3d[mesh3DIndex+1]
	if not mesh then
		-- no mesh3d? just draw a rect
		app:drawBorderRect(
			self.pos.x * spriteSize.x,
			self.pos.y * spriteSize.y,
			self.size.x * spriteSize.x,
			self.size.y * spriteSize.y,
			13,
			nil,
			app.paletteMenuTex
		)
	else
		-- mesh3d? draw its texcoords
		local vtxs = mesh:getVertexPtr()
		for ti=0,#mesh.triList-1 do
			local i,j,k = mesh.triList.v[ti]:unpack()
			local u1, v1 = tc(vtxs + i)
			local u2, v2 = tc(vtxs + j)
			local u3, v3 = tc(vtxs + k)
			local triColor = self.selectedTriIndexSet and self.selectedTriIndexSet[ti] and 0x1a or colorIndex
			app:drawSolidLine(u1, v1, u2, v2, triColor, thickness, app.paletteMenuTex)
			app:drawSolidLine(u2, v2, u3, v3, triColor, thickness, app.paletteMenuTex)
			app:drawSolidLine(u3, v3, u1, v1, triColor, thickness, app.paletteMenuTex)
		end
	end
end

return TileSelect
