--[[
I think I'll put the tile-selection widget here,
and use it in mesh3d and voxelmap for tile preview/selection.
--]]
local assert = require 'ext.assert'
local class = require 'ext.class'
local vec2i = require 'vec-ffi.vec2i'

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

	self.pickOpen = false			-- if this is open or not
	self.posDown = vec2i()		-- mouseX/mouseY upon mouse left press
	self.posUp = vec2i()		-- mouseX/mouseY while dragging / waiting for a mouse left release
	self.pos = vec2i()			-- selected pos, upper-left of downPos/upPos
	self.size = vec2i(1,1)		-- selected size

	self.getMeshIndex = args.getMeshIndex	-- optional, for mesh overlay
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
	local pushPalBlobIndex = app.ram.paletteBlobIndex
	app.ram.paletteBlobIndex = edit.paletteBlobIndex or 0
	app:drawQuad(
		winX,
		winY,
		winW,
		winH,
		-- TODO scrollable pick area ... hmm ...
		-- or TODO use the same scrollable pick area for the sprite editor and the tile editor
		0,		-- tx
		0,		-- ty
		255,	-- tw
		255,	-- th
		0,		-- orientation2D
		edit.sheetBlobIndex,
		0,
		-1,
		0,
		0xff
	)
	app.ram.paletteBlobIndex = pushPalBlobIndex

	local spriteX = math.floor((mouseX - winX) / winW * spriteSheetSizeInTiles.x)
	local spriteY = math.floor((mouseY - winY) / winH * spriteSheetSizeInTiles.y)
	if spriteX >= 0 and spriteX < spriteSheetSizeInTiles.x
	and spriteY >= 0 and spriteY < spriteSheetSizeInTiles.y
	then
		if not edit.tooltip then
			edit:setTooltip(spriteX..','..spriteY, mouseX-8, mouseY-8, 0xfc, 0)
		end

		if leftButtonPress then
			-- TODO rect select
			self.posDown:set(spriteX, spriteY)
			self.posUp:set(spriteX, spriteY)
			self.pos:set(spriteX, spriteY)
			self.size:set(1, 1)
			if self.onSetTile then
				self:onSetTile()
			end
		elseif leftButtonDown then
			self.posUp:set(spriteX, spriteY)
			self.pos.x = math.min(self.posUp.x, self.posDown.x)
			self.pos.y = math.min(self.posUp.y, self.posDown.y)
			self.size.x = math.max(self.posUp.x, self.posDown.x) - self.pos.x + 1
			self.size.y = math.max(self.posUp.y, self.posDown.y) - self.pos.y + 1
		elseif leftButtonRelease then
			self.pickOpen = false
		end
	end

	self:drawSelected(winX, winY, winW, winH)
	return true
end

function TileSelect:drawSelected(winX, winY, winW, winH)
	local edit = self.edit
	local app = edit.app

	local colorIndex = 0x1f
	local thickness = math.max(1, app.width / 256)
	local function tc(vtx)
		return
			winX + winW * (tonumber(vtx.u + bit.lshift(edit.tileSel.pos.x, 3)) + .5) / tonumber(spriteSheetSize.x),
			winY + winH * (tonumber(vtx.v + bit.lshift(edit.tileSel.pos.y, 3)) + .5) / tonumber(spriteSheetSize.y)
	end
	-- draw the texcoords offset by the getMeshIndex tileSel.pos etc
	local mesh3DIndex = self:getMeshIndex()
	local mesh = app.blobs.mesh3d[mesh3DIndex+1]
	if not mesh then
		-- no mesh3d? just draw a rect
		app:drawBorderRect(
			winX + winW * self.pos.x * spriteSize.x / spriteSheetSize.x,
			winY + winH * self.pos.y * spriteSize.y / spriteSheetSize.y,
			winW * self.size.x * spriteSize.x / spriteSheetSize.x,
			winH * self.size.y * spriteSize.y / spriteSheetSize.y,
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
			app:drawSolidLine(u1, v1, u2, v2, colorIndex, thickness, app.paletteMenuTex)
			app:drawSolidLine(u2, v2, u3, v3, colorIndex, thickness, app.paletteMenuTex)
			app:drawSolidLine(u3, v3, u1, v1, colorIndex, thickness, app.paletteMenuTex)
		end
	end
end

return TileSelect
