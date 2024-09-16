local vec2i = require 'vec-ffi.vec2i'

local App = require 'numo9.app'
local paletteSize = App.paletteSize
local spriteSize = App.spriteSize
local frameBufferSize = App.frameBufferSize
local frameBufferSizeInTiles = App.frameBufferSizeInTiles
local spriteSheetSize = App.spriteSheetSize
local spriteSheetSizeInTiles = App.spriteSheetSizeInTiles
local tilemapSize = App.tilemapSize
local tilemapSizeInSprites = App.tilemapSizeInSprites

local EditTilemap = require 'numo9.editor':subclass()

function EditTilemap:init(args)
	EditTilemap.super.init(self, args)

	self.drawGrid = true
	self.pickOpen = false
	self.spriteSelPos = vec2i()
	self.spriteSelSize = vec2i(1,1)
	self.drawMode = 'draw'	--TODO ui for this
	self.penSize = 1
end

function EditTilemap:update()
	local app = self.app

	local leftButtonLastDown = bit.band(app.lastMouseButtons, 1) == 1
	local leftButtonDown = bit.band(app.mouseButtons, 1) == 1
	local leftButtonPress = leftButtonDown and not leftButtonLastDown
	local leftButtonRelease = not leftButtonDown and leftButtonLastDown
	local mouseX, mouseY = app.mousePos:unpack()

	EditTilemap.super.update(self)

	-- title controls
	local x = 128
	local y = 0
	if self:guiButton(x, y, 'G', self.drawGrid, 'grid') then
		self.drawGrid = not self.drawGrid
	end
	x = x + 8
	if self:guiButton(x, y, 'T', self.pickOpen, 'tile') then
		self.pickOpen = not self.pickOpen
	end

	-- sprite edit method
	x = x + 16
	self:guiRadio(x, y, {'draw', 'dropper', 'pan'}, self.drawMode, function(result)
		self.drawMode = result
	end)


	local mapTex = app.mapTex

	-- draw map
	local mapX = 0
	local mapY = spriteSize.y
	local mapW = tilemapSizeInSprites.x
	local mapH = tilemapSizeInSprites.y
--print('map', require 'ext.string'.hexdump(require 'ffi'.string(mapTex.data, 16)))

	app:drawMap(
		0,			-- upper-left index in the tile tex
		0,
		tilemapSizeInSprites.x,	-- tiles wide
		tilemapSizeInSprites.y,	-- tiles high
		mapX,		-- pixel x
		mapY,		-- pixel y
		0			-- map index offset / high page
	)
	if self.drawGrid then
		for j=0,frameBufferSize.y-1,spriteSize.y do
			for i=0,frameBufferSize.x-1,spriteSize.x do
				app:drawBorderRect(i, j, spriteSize.x+1, spriteSize.y+1, self:color(1))
			end
		end
	end

	if self.pickOpen then
		local pickX = 2 * spriteSize.x
		local pickY = 2 * spriteSize.y
		local pickW = frameBufferSize.x - 2 * pickX
		local pickH = frameBufferSize.y - 2 * pickY
		app:drawBorderRect(
			pickX-1,
			pickY-1,
			pickW+2,
			pickH+2,
			self:color(10))
		app:drawSolidRect(
			pickX,
			pickY,
			pickW,
			pickH,
			self:color(0)
		)
		app:drawQuad(
			pickX,
			pickY,
			pickW,
			pickH,
			-- TODO scrollable pick area ... hmm ...
			-- or TODO use the same scrollable pick area for the sprite editor and the tile editor
			0,
			0,
			1,
			1,
			app.tileTex,
			0,
			-1,
			0,
			0xff
		)
		local spriteX = math.floor((mouseX - pickX) / pickW * spriteSheetSizeInTiles.x)
		local spriteY = math.floor((mouseY - pickY) / pickH * spriteSheetSizeInTiles.y)
		if spriteX >= 0 and spriteX < spriteSheetSizeInTiles.x
		and spriteY >= 0 and spriteY < spriteSheetSizeInTiles.y
		then
			if leftButtonPress then
				-- TODO rect select
				self.spriteSelPos:set(spriteX, spriteY)
				self.spriteSelSize:set(1, 1)
			elseif leftButtonDown then
				self.spriteSelSize.x = math.ceil((math.abs(mouseX - app.lastMousePressPos.x) + 1) / spriteSize.x)
				self.spriteSelSize.y = math.ceil((math.abs(mouseY - app.lastMousePressPos.y) + 1) / spriteSize.y)
			elseif leftButtonRelease then
				self.pickOpen = false
			end
		end

		app:drawBorderRect(
			pickX + self.spriteSelPos.x * spriteSize.x * pickW / spriteSheetSize.x,
			pickX + self.spriteSelPos.y * spriteSize.y * pickH / spriteSheetSize.y,
			spriteSize.x * self.spriteSelSize.x * pickW / spriteSheetSize.x,
			spriteSize.y * self.spriteSelSize.y * pickH / spriteSheetSize.y,
			self:color(13)
		)
	else
		-- TODO allow drawing while picking window is open, like tic80 does?
		-- maybe ... then i should disable the auto-close-on-select ...
		-- and I should also resize the pick tile area

		local tx = math.floor((mouseX - mapX) / mapW * tilemapSizeInSprites.x / spriteSize.x)
		local ty = math.floor((mouseY - mapY) / mapH * tilemapSizeInSprites.y / spriteSize.y)

		-- TODO pen size here
		if self.drawMode == 'dropper' then
			if leftButtonPress
			and 0 <= tx and tx < tilemapSize.x
			and 0 <= ty and ty < tilemapSize.y
			then
				local texelIndex = tx + tilemapSize.x * ty
				assert(0 <= texelIndex and texelIndex < tilemapSize:volume())
				local ptr = mapTex.image.buffer + texelIndex
				local tileSelIndex = ptr[0]
print('...reading mapTex at '..tx..', '..ty..' (index='..texelIndex..') as '..('$%04x'):format(tileSelIndex))
				self.spriteSelPos.x = tileSelIndex % spriteSheetSizeInTiles.x
				self.spriteSelPos.y = (tileSelIndex - self.spriteSelPos.x) / spriteSheetSizeInTiles.x
			end
		elseif self.drawMode == 'draw' then
			if leftButtonDown
			and 0 <= tx and tx < tilemapSize.x
			and 0 <= ty and ty < tilemapSize.y
			then
				local tx0 = tx - math.floor(self.penSize / 2)
				local ty0 = ty - math.floor(self.penSize / 2)
				assert(mapTex.image.buffer == mapTex.data)
				mapTex:bind()
				for dy=0,self.penSize-1 do
					local ty = ty0 + dy
					for dx=0,self.penSize-1 do
						local tx = tx0 + dx
						if 0 <= tx and tx < tilemapSize.x
						and 0 <= ty and ty < tilemapSize.y
						then
							local texelIndex = tx + tilemapSize.x * ty
							assert(0 <= texelIndex and texelIndex < tilemapSize:volume())
							local ptr = mapTex.image.buffer + texelIndex
							local tileSelIndex = self.spriteSelPos.x + spriteSheetSizeInTiles.x * self.spriteSelPos.y
							ptr[0] = tileSelIndex
print('...writing mapTex at '..tx..', '..ty..'( index='..texelIndex..') as '..('$%04x'):format(tileSelIndex))
							mapTex:subimage{
								xoffset = tx,
								yoffset = ty,
								width = 1,
								height = 1,
								data = ptr,
							}
						end
					end
				end
				mapTex:unbind()
			end
		end
	end
end

return EditTilemap
