--#include ext/class.lua
--#include vec/vec2.lua

-- in-place modify vec2 to work around Lua's weird 1-based indexing
vec2.modPlus1=|v,m|do
	for i,f in ipairs(vec2.fields) do
		v[f]-=1
		v[f]%=vec2_getvalue(m,i)
		v[f]+=1
	end
	return v
end

local screenw, screenh = 480, 270
mode(42)	-- 16:9 480x270x8bpp indexed

-- game font
local fontScale = 3

colorPalIndexes = {
	white = 12,
	cantPlay = 25,
}

sprites = {
	mouse = 0,
	tile = 4,
	circle = 12,
	cross = 20,
}

TileHolder=class{
	getTile=|:|self.tile,
	setTile=|:,tile|do
		self.tile?:setHolder(nil)
		self.tile = tile
		self.tile?:setHolder(self)
	end,
	draw=|:|self.tile?:draw(),
}

Place=TileHolder:subclass{
	FLASH_DURATION = 1,
	FLASH_PERIOD = .2,
	SPAN = .5,	--.45
	init=|:,grid,x,y|do
		self.rect = {}
		self.flashStartTime = -self.FLASH_DURATION
		self.canPlay = true
		self.grid = grid
		self.x = x
		self.y = y
		-- TODO change this to a sprite index
		--self.img = DOM('img', {src:'res/drawable/tile_empty.png'end)
		self.img = sprites.tile	-- TODO shift color to "empty"
	end,
	getGrid=|:|self.grid,
	getX=|:|self.x,
	getY=|:|self.y,
	getWorldX=|:|self.grid:getWorldX(self.x),
	getWorldY=|:|self.grid:getWorldY(self.y),
	getWorldScale=|:|self.grid.scale,
	setPos=|:,newX, newY|do
		self.x = newX
		self.y = newY
	end,
	containsPoint=|:,ptx,pty|do
		--global to local
		ptx -= self:getWorldX()
		ptx /= self:getWorldScale()
		pty -= self:getWorldY()
		pty /= self:getWorldScale()
		--local space compare
		return ptx >= -self.SPAN and pty >= -self.SPAN and ptx <= self.SPAN and pty <= self.SPAN
	end,
	draw=|:|do
		self.rect.left = self:getWorldX() - self.SPAN * self:getWorldScale()
		self.rect.right = self:getWorldX() + self.SPAN * self:getWorldScale()
		self.rect.top = self:getWorldY() - self.SPAN * self:getWorldScale()
		self.rect.bottom = self:getWorldY() + self.SPAN * self:getWorldScale()
		if not self.canPlay then
			rect(
				self.rect.left,
				self.rect.top,
				self.rect.right - self.rect.left,
				self.rect.bottom - self.rect.top,
				colorPalIndexes.cantPlay
			)
		else
			spr(
				self.img,
				self.rect.left,
				self.rect.top,
				8,8,
				nil, nil,	-- paletteIndex, transparentIndex
				nil, nil,	-- spriteBit, spriteMask
				(self.rect.right - self.rect.left) / 64,
				(self.rect.bottom - self.rect.top) / 64)
		end

		--draw any tile on us
		Place.super.draw(self)

		local deltaFlashTime = self.grid.game.gameTime - self.flashStartTime
		if deltaFlashTime >= 0 and deltaFlashTime <= self.FLASH_DURATION then
			if math.floor(deltaFlashTime / self.FLASH_PERIOD) & 1 == 0 then
				rect(
					self.rect.left,
					self.rect.top,
					self.rect.right - self.rect.left,
					self.rect.bottom - self.rect.top,
					colorPalIndexes.white
				)
			end
		end
	end,
}

Tile=class{
	TYPE_TILE = 1,
	TYPE_AREA = 2,
	TYPE_FILL = 3,
	spritesForTileTypes = {
		sprites.tile,
		sprites.cross,
		sprites.circle,
	},
	BASE_POINTS = 10,
	SPAN = .45,	--.4f
	init=|:,color,type|do
		self.rect = {}
		self.color = color
		self.type = type
	end,
	setHolder=|:,holder|do
		self.holder = holder
	end,
	getColor=|:|self.color,
	setColor=|:,color|do self.color=color end,
	canPlay=|:,board,x,y|true,
	getPoints=|:,level|level * self.BASE_POINTS,	--base
	-- whether playing self tile at thisX,thisY
	--	had something to do with whatever was at otherX,otherY
	playDependsOn=|:,thisX,thisY,otherX,otherY|false,
	draw=|:|do
		self.rect.left = self.holder:getWorldX() - self.SPAN * self.holder:getWorldScale()
		self.rect.right = self.holder:getWorldX() + self.SPAN * self.holder:getWorldScale()
		self.rect.top = self.holder:getWorldY() - self.SPAN * self.holder:getWorldScale()
		self.rect.bottom = self.holder:getWorldY() + self.SPAN * self.holder:getWorldScale()
		spr(
			Tile.spritesForTileTypes[self.type],
			self.rect.left,
			self.rect.top,
			8,8,
			self.color.paletteIndex-0xf0, nil,	-- paletteIndex, transparentIndex
			nil, nil,	-- spriteBit, spriteMask
			(self.rect.right - self.rect.left) / 64,
			(self.rect.bottom - self.rect.top) / 64)
	end,
}

Tile3x3=Tile:subclass{
	init=|:,color,tiletype,neighbors|do
		Tile3x3.super.init(self,color,tiletype)
		self.subrect = {}
		self.neighbors=neighbors
	end,
	canPlay=|:,board,x,y|do
		local e = 0
		for j=-1,1 do
			for i=-1,1 do
				e += 1
				local n=self.neighbors[e]
				if n then
					local u = ((i + x-1 + board.width) % board.width) + 1
					local v = ((j + y-1 + board.height) % board.height) + 1
					local place = board:getPlace(u,v)
					local tile = place:getTile()
					if tile:getColor() ~= n then return false end
				end
			end
		end
		return true
	end,
	-- point system ...
	getPoints=|:,level|do
		local nbhs = 0
		local colors = {}
		local numUniqueColors = 0
		for i=1,9 do
			local c = self.neighbors[i]
			if c then
				nbhs+=1
				if colors[c] then
					colors[c]+=1
				else
					colors[c] = 1
					numUniqueColors+=1
				end
			end
		end
		local pts = 1 + nbhs * numUniqueColors^2
		return level * pts * self.BASE_POINTS
	end,
	playDependsOn=|:,thisX,thisY,otherX,otherY|do
		local dx = otherX - thisX	---1 to 1
		local dy = otherY - thisY
		dx+=1	--0 to 2
		dy+=1
		if dx < 0 or dx > 2 or dy < 0 or dy > 2 then return false end
		return not not self.neighbors[1 + dx + 3 * dy]
	end,
	draw=|:|do
		Tile3x3.super.draw(self)
		local sx = self.rect.right - self.rect.left
		local sy = self.rect.bottom - self.rect.top
		local e = 0
		for j=1,3 do
			for i=1,3 do
				e += 1
				local n = self.neighbors[e]
				if n then
					self.subrect.left = sx * ((i-1) + .15) / 3 + self.rect.left
					self.subrect.right = sx * ((i-1) + .85) / 3 + self.rect.left
					self.subrect.top = sy * ((j-1) + .15) / 3 + self.rect.top
					self.subrect.bottom = sy * ((j-1) + .85) / 3 + self.rect.top
					spr(
						sprites.tile,
						self.subrect.left,
						self.subrect.top,
						8,8,
						n.paletteIndex-0xf0, nil,	-- paletteIndex, transparentIndex
						nil, nil,	-- spriteBit, spriteMask
						(self.subrect.right - self.subrect.left) / 64,
						(self.subrect.bottom - self.subrect.top) / 64)
				end
			end
		end
	end,
}

Grid=class{
	init=|:,game,width,height|do
		self.x = 0
		self.y = 0
		self.scale = 0
		self.game = game
		self.width = width
		self.height = height
		self.places = table()
		for i=1,self.width do
			self.places[i] = table()
			for j=1,self.height do
				self.places[i][j] = Place(self,i,j)
			end
		end
		self:refreshAllPlaces()
	end,
	getPlace=|:,x,y|self.places[x][y],
	getAllPlaces=|:|self.allPlaces,
	draw=|:|do
		for _,p in ipairs(self.allPlaces) do
			p:draw()
		end
	end,

	--so the whole idea of separating containsPoint from getPlaceAtPoint
	--was to allow for some basic grid area test optimizations...
	--...meh
	getPlaceAtPoint=|:,x,y|do
		for _,p in ipairs(self.allPlaces) do
			if p:containsPoint(x,y) then return p end
		end
	end,
	getWorldX=|:,px|do
		--if not px then return Grid.super.getWorldX(self) end
		return (px-1) * self.scale + self.x
	end,
	getWorldY=|:,py|do
		--if not py then return Grid.super.getWorldY(self) end
		return (py-1) * self.scale + self.y
	end,
	getScale=|:|self.scale,
	getWidth=|:|self.width,
	getHeight=|:|self.height,
	refreshAllPlaces=|:|do
		self.allPlaces = table()
		for i=1,self.width do
			for j=1,self.height do
				self.allPlaces:insert(self.places[i][j])
			end
		end
	end,
	flip=|:|do
		self.width, self.height = self.height, self.width
		--flip places
		local newPlaces = table()
		for i=1,self.width do
			newPlaces[i] = table()
			for j=1,self.height do
				local p = self.places[j][i]
				p:setPos(i,j)
				newPlaces[i][j] = p
			end
		end
		self.places = newPlaces
		self:refreshAllPlaces()
	end,
}

Board=Grid:subclass{
	init=|:,game, size|do
		Board.super.init(self, game, size, size)
	end,
	rotate=|:,dx,dy|do
		--rotate modulo the grid pieces about
		local newPlaces = table()
		for i=1,self.width do
			local ii = (((i-1) + dx) % self.width) + 1
			newPlaces[i] = table()
			for j=1,self.height do
				local jj = (((j-1) + dy) % self.height) + 1
				local p = self.places[ii][jj]
				p:setPos(i,j)
				newPlaces[i][j] = p
			end
		end
		self.places = newPlaces
		self:refreshAllPlaces()
	end,
}

Hand=Grid:subclass()

Color=class{
	init=|:,paletteIndex|do
		self.paletteIndex = paletteIndex
	end,
}

-- TODO when is this even used?
Cursor=TileHolder:subclass{
	init=|:,game, board, hand|do
		self.rect = {}
		self.onBoard = false--whether it's on the board or in the hand
		self.hidden = true
		self.game = game
		self.board = board
		self.hand = hand
		--self.img = DOM('img', {src:'res/drawable/cursor.png'end)
		self.x = hand.width / 2
		self.y = 0
		self.onBoard = false
	end,
	hide=|:|do
		self.hidden = true
	end,
	down=|:|do
		self.hidden = false
		self.y+=1
		if self.onBoard then
			if self.y > self.board.height then
				self.onBoard = false
				self.y = 1
				self.x = math.floor(self.x/(self.board.width-1)*(self.hand.width-1))
			end
		else
			if self.y > self.hand.height then
				self.y = self.hand.height
			end
		end
	end,
	up=|:|do
		self.hidden = false
		self.y-=1
		if self.y < 1 then
			if self.onBoard then
				self.y = 1
			else
				self.onBoard = true
				self.y = self.board.height
				self.x = math.floor(self.x/(self.hand.width-1)*(self.board.width-1))
			end
		end
	end,
	left=|:|do
		self.hidden = false
		self.x-=1
		if self.x < 1 then self.x = 1 end
	end,
	right=|:|do
		self.hidden = false
		self.x+=1
		if self.onBoard then
			if self.x > self.board.width then
				self.x = self.board.width
			end
		else
			if self.x > self.hand.width then
				self.x = self.hand.width
			end
		end
	end,
	--copied from Pointer
	returnTile=|:|do
		local oldTile = self:getTile()
		if self.grabbedFromPlace and oldTile then
			self:setTile(nil)
			self.grabbedFromPlace:setTile(self.getTile())
			self.grabbedFromPlace = nil
		end
	end,
	click=|:|do
		self.hidden = false
		--TODO - run self on the render thread
		--	- so we don't have skips in tiles being visible and what not
		if self.onBoard then
			local tile = self:getTile()
			if tile then
				if tile:canPlay(self.board,self.x,self.y) then
					self:setTile(nil)
					self.game:setBoardPlaceTileColor(self.x, self.y, tile, self.grabbedFromPlace)
					self.grabbedFromPlace = nil
				end
			end
		else
			local place = self.hand:getPlace(self.x, self.y)
			local oldTile = self.getTile()
			self:setTile(nil)
			local newTile = place:getTile()
			place:setTile(nil)
			if not oldTile then
				self.grabbedFromPlace = place
			end
			self:setTile(newTile)
			place:setTile(oldTile)
			self.game:refreshValidPlays()
		end
	end,
	currentGrid=|:|do
		return self.onBoard and self.board or self.hand
	end,
	getWorldX=|:|self:currentGrid():getWorldX(self.x),
	getWorldY=|:|self:currentGrid():getWorldY(self.y),
	getWorldScale=|:|self:currentGrid():getScale() * 1.2,
	draw=|:|do
		if self.hidden then return end
		Cursor.super.draw(self)
		local grid = self:currentGrid()
		local wx = grid:getWorldX(self.x)
		local wy = grid:getWorldY(self.y)
		self.rect.left = wx - .6 * grid.scale
		self.rect.top = wy - .6 * grid.scale
		self.rect.right = wx + .6 * grid.scale
		self.rect.bottom = wy + .6 * grid.scale
		spr(
			self.img,
			self.rect.left,
			self.rect.top,
			8,8,
			nil, nil,	-- paletteIndex, transparentIndex
			nil, nil,	-- spriteBit, spriteMask
			(self.rect.right - self.rect.left) / 64,
			(self.rect.bottom - self.rect.top) / 64)
	end,
}

Pointer=TileHolder:subclass{
	init=|:,game,hand|do
		self.visible = false
		self.x = 0
		self.y = 0
		self.game = game
		self.hand = hand
	end,
	isVisible=|:|self.visible,
	setVisible=|:,v|do self.visible = v end,
	hide=|:|self:setVisible(false),
	show=|:|self:setVisible(true),
	setGrabbedFromPlace=|:,place|do
		self.grabbedFromPlace = place
	end,
	--returns the tile to the place it was grabbed from
	returnTile=|:|do
		--assert(grabbedFromPlace.getTile() === nil)
		local oldTile = self:getTile()
		if self.grabbedFromPlace and oldTile then
			self:setTile(nil)
			self.grabbedFromPlace:setTile(oldTile)
			self.grabbedFromPlace = nil
		end
	end,
	--place a tile in the hand
	--i.e. just swap the contents of where we place self with where we came from
	playInHand=|:,place|do
		local oldTile = self:getTile()
		self:setTile(nil)
		local newTile = place:getTile()
		place:setTile(nil)
		--set newTile before setting oldTile because newTile may be nil (if it's the same place we're setting where we got our tile from)
		self.grabbedFromPlace:setTile(newTile)
		place:setTile(oldTile)
		self.game:refreshValidPlays()
	end,
	playInBoard=|:,board,i,j|do
		local tile = self:getTile()
		if tile:canPlay(board,i,j) then
			self:setTile(nil)
			self.game:setBoardPlaceTileColor(i,j,tile,self.grabbedFromPlace)
			self.grabbedFromPlace = nil
		else
			self:returnTile()
		end
	end,
	setPos=|:,x,y|do
		self.x = x
		self.y = y
	end,
	--used for clicking
	getPointerX=|:|self.x,
	getPointerY=|:|self.y,
	--used for rendering
	getWorldX=|:|self.x,
	getWorldY=|:|self.y,
	getWorldScale=|:|self.hand:getScale() * 1.2,
}

--init at global scope so i can preload all their images
allColors = table{
	Color(0x80),	-- red
	Color(0x90),	-- green
	Color(0xA0),	-- blue
	Color(0xB0),	-- yellow
	Color(0xC0),	-- purple
}


Game=class()
Game.started = false
Game.PLAYS_PER_LEVEL = 10
Game.START_LEVEL = 1
Game.BACKGROUND_FADE_DURATION = 1
Game.NUM_REDRAWS = 5
--[[ TODO
Game.backgroundsForLevel = {}
for (local i = 1; i <= 100; i++) {
	Game.backgroundsForLevel.push(DOM('img', {src:'res/drawable/bg'+i+'.jpg'end))
end
--]]

Game.start = |:,level|do
	self.started = true
	self.levelPlaysLeft = self.PLAYS_PER_LEVEL
	self.level = 1
	self.points = 0
	self.lastPlayX = -99
	self.lastPlayY = -99
	self.numPlays = 0
	self.draggingBoard = false
	self.backgroundFadeStartTime = -self.BACKGROUND_FADE_DURATION-1
	self.rect = {}
	self.lastCanvasWidth = -1
	self.lastCanvasHeight = -1
	self.level = level
	self.gameTime = time()
	self.colors = allColors
	local handSize = 8
	local boardSize = 4
	self.board = Board(self, boardSize)
	--self.hand = Hand(self, handSize/2, 2)
	self.hand = Hand(self, 2, handSize/2)
	self.cursor=Cursor(self, self.board, self.hand)
	self.handPointer = Pointer(self, self.hand)
	self.levelPlaysLeft = self.PLAYS_PER_LEVEL
	self:randomizeBoard()
	for _,p in ipairs(self.hand:getAllPlaces()) do
		self:resetHandPlace(p)
	end
	self:refreshValidPlays()
end

Game.refreshValidPlays = |:|do
	for _,p in ipairs(self.hand:getAllPlaces()) do
		p.canPlay = false
		for j=0,self.board:getHeight()-1 do
			for i=0,self.board:getWidth() do
				local tile = p:getTile()
				if tile then
					if tile:canPlay(self.board, i, j) then
						p.canPlay = true
						break
					end
				end
				if p.canPlay then break end
			end
			if p.canPlay then break end
		end
	end

--[[ TODO backgrounds
	local bgForLevelIndex = math.floor((self.level-1) / 10) + 1
	if bgForLevelIndex > 0
	and bgForLevelIndex <= #self.backgroundsForLevel
	then
		self.lastBackground = self.background
		self.backgroundFadeStartTime = time()
		self.background = self.backgroundsForLevel[bgForLevelIndex]
	end
--]]
end

Game.getNumColorsForLevel = |:|do
	if self.level <= 10 then return 3 end
	if self.level <= 100 then return 4 end
	return 5
end

Game.randomizeBoard = |:|do
	for _,p in ipairs(self.board:getAllPlaces()) do
		p:setTile(Tile(self:getRandomColor(self:getNumColorsForLevel()), Tile.TYPE_TILE))
	end
end

Game.getColorAt = |:,x,y|do
	x -= 1
	x %= self.board.width
	x += 1
	y -= 1
	y %= self.board.height
	y += 1
	return self.board:getPlace(x,y):getTile():getColor()
end

Game.setColorAt = |:,x,y,playedColor,cols,rows|do
	x -= 1
	x %= self.board.width
	x += 1
	y -= 1
	y %= self.board.height
	y += 1
	local playedOnPlace = self.board:getPlace(x,y)
	playedOnPlace:getTile():setColor(playedColor)
	cols[x] = true
	rows[y] = true
	playedOnPlace.flashStartTime = self.gameTime
end

Game.setBoardPlaceTileColor = |:,x,y,tile,grabbedFromPlace|do
	self:returnAllTiles()
	local playedColor = tile:getColor()
	local playedOnColor = self:getColorAt(x,y)
	local playedSameColor = playedOnColor == playedColor
	local rows = {}
	local cols = {}
trace('placing tile type', tile.type, 'at', x, y)		
	if tile.type == Tile.TYPE_TILE then
trace('placing tile at', x, y)		
		self:setColorAt(x,y,playedColor,cols,rows)
	elseif tile.type == Tile.TYPE_AREA then
trace('placing area at', x, y)		
		self:setColorAt(x, y, playedColor, cols, rows)
		self:setColorAt(x-1, y, playedColor, cols, rows)
		self:setColorAt(x+1, y, playedColor, cols, rows)
		self:setColorAt(x, y-1, playedColor, cols, rows)
		self:setColorAt(x, y+1, playedColor, cols, rows)
	elseif tile.type == Tile.TYPE_FILL then
trace('placing fill at', x, y)		
		local points = table{vec2(x,y)}
		local i = 1
		while i <= #points do
			local srcpt = points[i]
			for _,dir in pairs(dirvecs) do
				local alreadyDone = false
				local nbhdpt = vec2(srcpt.x + dir.x, srcpt.y + dir.y)
				--nbhdpt:modPlus1(self.board.size) -- TODO
				nbhdpt.x -= 1
				nbhdpt.x %= self.board.width
				nbhdpt.x += 1
				nbhdpt.y -= 1
				nbhdpt.y %= self.board.height
				nbhdpt.y += 1
				if self:getColorAt(nbhdpt.x, nbhdpt.y) == playedOnColor then
					for k=1,i-1 do
						if points[k] == nbhdpt then
							alreadyDone = true
							break
						end
					end
					if not alreadyDone then
						points:insert(nbhdpt)
					end
				end
			end
			i=i+1
		end
		for _,p in ipairs(points) do
			self:setColorAt(p.x, p.y, playedColor, cols, rows)
		end
	else
		error'here'
	end

	--make this place flash

	local numFilledRows = 0
	for row in pairs(rows) do
		local filledRow = true
		local matchColor = nil
		for i=1,self.board.width do
			local color = self.board:getPlace(i, row):getTile():getColor()
			if not matchColor then
				matchColor = color
			else
				if matchColor ~= color then
					filledRow = false
					break
				end
			end
		end
		if filledRow then
			numFilledRows+=1
			--then make the row flash
			for i=1,self.board.width do
				self.board:getPlace(i, row).flashStartTime = self.gameTime
			end
		end
	end
	local numFilledCols = 0
	for col in pairs(cols) do
		local filledCol = true
		local matchColor = nil
		for j=1,self.board.height do
			local color = self.board:getPlace(col, j):getTile():getColor()
			if not matchColor then
				matchColor = color
			else
				if matchColor ~= color then
					filledCol = false
					break
				end
			end
		end
		if filledCol then
			numFilledCols+=1
			--then make the col flash
			for j=1,self.board.height do
				self.board:getPlace(col, j).flashStartTime = self.gameTime
			end
		end
	end

	local filledAll = true
	do
		local matchColor = nil
		for _,p in ipairs(self.board:getAllPlaces()) do
			local color = p:getTile():getColor()
			if not matchColor then
				matchColor = color
			else
				if matchColor ~= color then
					filledAll = false
					break
				end
			end
		end
		if filledAll then
			for _,p in ipairs(self.board:getAllPlaces()) do
				p.flashStartTime = self.gameTime
			end
		end
	end

	--special case for 'filled all'
	if filledAll then
		self.points += 2000	--make it worthwhile for lower levels
		self.points *= 1.5	--add 50% to points
		self:randomizeBoard()
	else
		--calculate points
		local thisPlay = 1
		thisPlay *= tile:getPoints(self.level)
		--+20% if we're on the same color
		if playedSameColor then thisPlay += thisPlay * .2 end
		--+20% if we used the last tile
		if self.lastPlayX >= 1
		and self.lastPlayY >= 1
		and self.lastPlayX <= self.board.width
		and self.lastPlayY <= self.board.height
		then
			if tile:playDependsOn(
				x,y,self.lastPlayX,self.lastPlayY
			) then
				thisPlay += thisPlay * .2
				self.board:getPlace(self.lastPlayX, self.lastPlayY).flashStartTime = self.gameTime
			end
		end
		--... scale by the number of rows and columns plsu one
		thisPlay += thisPlay * .1 * (numFilledRows + numFilledCols)
		self.points += thisPlay
	end
	self.points = math.floor(self.points)

	self.levelPlaysLeft-=1
	if self.levelPlaysLeft <= 0 then
		self.levelPlaysLeft = self.PLAYS_PER_LEVEL
		self.level+=1
	end
	self:resetHandPlace(grabbedFromPlace)

	self.lastPlayX = x
	self.lastPlayY = y

	--call self after 'resetHandPlace' since that changes self
	self:refreshValidPlays()

	--if (numPlays == 0)
	--	end the game thread
	--	popup the scoreboard (with our score on it, maybe?)
	--	and start a new game
end

Game.resetHandPlace=|:,place|do
	local centers
	local div = 2
	local numColors = self:getNumColorsForLevel()
	if self.level <= 10 then
		centers = {-10, 0, 5, 10}
		div = 2
	elseif self.level <= 100 then
		centers = {-100, 11, 40, 80, 120}
		div = 20
	elseif self.level <= 1000 then
		centers = {-1000, 200, 400, 600, 800, 999}
		div = 200
	end

	local probs = table()
	for i=1,#centers do
		local del = (self.level - centers[i]) / div
		--probs[i] = math.exp(-del*del)
		probs[i] = 1.0 / (1.0 + math.exp(-del))
	end
	local numNeighbors = probs:pickWeighted()	-- key = pick, values = probability values

	--here's the only tile that gets a random type
	--...and it should vary with level(?)
	local tiletype = Tile.TYPE_TILE
	if math.random() < 1/20 then
		tiletype = Tile.TYPE_AREA
		if math.random() < 1/5 then
			tiletype = Tile.TYPE_FILL
		end
	end

	if numNeighbors == 0 then
		place:setTile(
			Tile(self:getRandomColor(numColors), tiletype)
		)
	else
		--randomly pick neighbors
		local neighbors=table()
		for i=1,numNeighbors do
			local index = -1
			repeat
				index = math.floor(math.random() * 9)
			until not neighbors[index+1]
			neighbors[index+1] = self:getRandomColor(numColors)
		end
		place:setTile(Tile3x3(self:getRandomColor(numColors), tiletype, neighbors))
	end
end

Game.getRandomColor = |:,numColors|
	self.colors[math.random(1, numColors)]

Game.update = |:|do
	self.gameTime = time()

	--key update moved to key handlers
	--mouse update moved to mouse handlers

	if self.draggingBoard then
		local dx = self.draggingBoardX - self.draggingBoardDownX
		local dy = self.draggingBoardY - self.draggingBoardDownY
		--if we surpass board.scale then offset the down's by that much
		local ofx = 0
		local ofy = 0
		--rotate right once
		if dx > self.board.scale then
			self.draggingBoardDownX += self.board.scale
			ofx-=1
		end
		if dx < -self.board.scale then
			self.draggingBoardDownX -= self.board.scale
			ofx+=1
		end
		if dy > self.board.scale then
			self.draggingBoardDownY += self.board.scale
			ofy-=1
		end
		if dy < -self.board.scale then
			self.draggingBoardDownY -= self.board.scale
			ofy+=1
		end
		if ofx ~= 0 or ofy ~= 0 then
			--rotate the board
			self:returnAllTiles();	--/just in case...
			self.board:rotate(ofx, ofy)
		end
	end
end

Game.showPointerWithEvent = |:,x,y|do
	--see if we're clicking on a tile
	--see if we're clicked on a tile in the hand...
	local place = self.hand:getPlaceAtPoint(x,y)
	if place then
		local tile = place:getTile()
		if tile then
			place:setTile(nil)
			self.handPointer:setPos(x,y)
			self.handPointer:setGrabbedFromPlace(place)
			self.handPointer:setTile(tile)
			self.handPointer:show()
			return
		end
	end

	--see if we're clicked on a tile in the board...
	--if so, set a magic flag that says 'dragging the board atm'
	--then...
	place = self.board:getPlaceAtPoint(x,y)
	if place then
		if not self.draggingBoard then	--only if not dragging already
			--better have a tile, it's on the board after all
			--so just remember the x,y
			--and deduce from there the dragged x,y distance or something ...
			self.draggingBoardDownX = x
			self.draggingBoardDownY = y
			self.draggingBoard = true
		end
		self.draggingBoardX = x
		self.draggingBoardY = y
	end

	self:returnAllTiles()
end

Game.returnAllTiles = |:|do
	self.handPointer:returnTile()
	self.handPointer:hide()
	self.cursor:returnTile()
end

Game.getPoints = |:|self.points
Game.getLevel = |:|self.level
Game.getPlaysLeft = |:|self.levelPlaysLeft

local lastGameScoreWidth = 0
Game.draw=|:|do
	if not self.hand then return end
	if not self.board then return end

	local gamePadding = 0	 --padding between fitted game size and canvas size

	if screenw ~= self.lastCanvasWidth
	or screenh ~= self.lastCanvasHeight
	then

		--readjust board and hand with screen size
		--especially important if the screen rotates
		local eps = 0--0.25;	//in units of tiles, what space between board and hand
		local gameSizeX, gameSizeY
		local boardPosFracX, boardPosFracY
		local handPosFracX, handPosFracY

		if screenw < screenh then	--hand beneath board

			--flip the hand if needed
			if self.hand.width < self.hand.height then self.hand:flip() end

			gameSizeX = math.max(self.board.width + 2, self.hand.width)
			gameSizeY = self.board.height + eps + self.hand.height + 2
			boardPosFracX = 1.5 / gameSizeX;	--TODO adjust these if the hand and board widths ever dont match up. then you'll have to do something with max's or min's or whatever.
			boardPosFracY = 1.5 / gameSizeY
			handPosFracX = 1.5 / gameSizeX
			handPosFracY = 1. - (self.hand.height --[[- .5]]) / gameSizeY
		else		--hand left of board

			--flip the hand if needed
			if self.hand.height < self.hand.width then self.hand:flip() end

			gameSizeX = self.board.width + self.hand.width + eps + 2
			gameSizeY = math.max(self.board.height, self.hand.height) + 2
			boardPosFracX = (self.hand.width + 1.5 + eps) / gameSizeX
			boardPosFracY = 1.5 / gameSizeY
			handPosFracX = .5 / gameSizeX
			handPosFracY = 1.5 / gameSizeY
		end

		--now find the appropriate scale such that gameSizeX, gameSizeY fits in width, height

		local tileScaleX = (screenw - 2 * gamePadding) / gameSizeX
		local tileScaleY = (screenh - 2 * gamePadding) / gameSizeY
		local tileScale = math.min(tileScaleX, tileScaleY)

		local fittedSizeX = tileScale * gameSizeX
		local fittedSizeY = tileScale * gameSizeY

		self.board.x = screenw * .5 - fittedSizeX * .5 + fittedSizeX * boardPosFracX
		self.board.y = screenh * .5 - fittedSizeY * .5 + fittedSizeY * boardPosFracY
		self.board.scale = tileScale

		self.hand.x = screenw * .5 - fittedSizeX * .5 + fittedSizeX * handPosFracX
		self.hand.y = screenh * .5 - fittedSizeY * .5 + fittedSizeY * handPosFracY
		self.hand.scale = tileScale

		self.lastCanvasWidth = screenw
		self.lastCanvasHeight = screenh
	end

	--do the actual drawing

--[[ TODO backgrounds
	map(
		self.background,
		0,
		0,
		screenw,
		screenh
	)
	if self.lastBackground then
		local deltaFadeTime = self.gameTime - self.backgroundFadeStartTime
		if deltaFadeTime >= 0 and deltaFadeTime <= self.BACKGROUND_FADE_DURATION then
			local globalAlpha = 1.0 - deltaFadeTime / self.BACKGROUND_FADE_DURATION
			fillp((1 << math.floor(math.clamp(globalAlpha, 0, 1) * 16)) - 1)
			--fadetime = 0 means we just started, so last background overlay alpha is 1
			--fadetime = duration means we're ending, so last background overlay alpha is 0
			map(
				self.lastBackground,
				0,
				0,
				screenw,
				screenh
			)
			fillp(0)
		end
	end
--]]

	self.board:draw()
	self.hand:draw()
	if self.handPointer:isVisible() then
		self.handPointer:draw()
	end
	self.cursor:draw()

	--TODO update strinsg here

	text(
		'Level '..self.level .. "." .. (self.PLAYS_PER_LEVEL - self.levelPlaysLeft),
		0,							-- x
		screenh - 8 * fontScale,	-- y
		nil,
		nil,
		fontScale, fontScale)

	lastGameScoreWidth = text(
		self.points..' Points',
		screenw - lastGameScoreWidth,
		screenh - 8 * fontScale,
		nil,
		nil,
		fontScale, fontScale)
end

Game.returnAllTiles = |:|do
	self.handPointer:returnTile()
	self.handPointer:hide()
	self.cursor:returnTile()
end

Game.done = |:|do
	while true do
		text'TODO'
		flip()
	end
	if confirm('are you sure?') then
		local done = ||do
			game.started = false
			--changePage(ids['scores-page'])
			scores:refresh()
		end
		local name = prompt("what's your name?")
		if name then
		--		'addscore.lua?name='+escape(name)
		--			+'&score='+self.points
		--			+'&level='+self.level
		end
		done()
	end
end

game=Game()


getpress=||do
	for i=0,7 do
		if btnp(i) then return i end
	end
end

startLevel=1
maxStartLevel = 50

page='splash'
splashMenuY=0
splashInputPass=table{0,0,0,0}
splashMenuPassX=0
update=||do
	cls()

	local mousex,mousey = mouse()

	if page == 'splash' then
		cls(0x10)
		local x,y = 24, 48
		local txt=|s|do text(s,x,y,0xc,-1) y+=8 end
		txt'Elemental'
		txt'A game by Sean Moore and Chris Moore'
		txt''
		txt'  Start'
		txt('  Level '..startLevel)
		txt'  Scores'
		txt'  Help'
		local b = getpress()
		if b == 3 then splashMenuY -= 1 end
		if b == 1 then splashMenuY += 1 end
		splashMenuY %= 4
		text('>', x, (splashMenuY+9)*8, 0xc, -1)
		if splashMenuY==0 then
			if b==4 or b==5 then
				-- start game
				page = 'game'
				game:start(startLevel)
				return
			end
		elseif splashMenuY==1 then
			if b == 2 or b == 6 or b == 7 then
				startLevel-=1
			elseif b == 0 or b == 4 or b == 5 then
				startLevel+=1
			end
			startLevel -= 1
			startLevel %= maxStartLevel
			startLevel += 1
		end
	elseif page == 'game' then
		-- else game page ... same as game.started?
		if game.started then
			-- keypresses
			if btnp'up' then
				game.cursor:up()
			elseif btnp'down' then
				game.cursor:down()
			elseif btnp'left' then
				game.cursor:left()
			elseif btnp'right' then
				game.cursor:right()
			end

			-- mouse down
			if key'mouse_left' then
				if not game.handPointer:isVisible()
				and not game.draggingBoard
				then
					game.cursor:hide()
					game:showPointerWithEvent(mousex,mousey)
				end
				--a kludge at the last second.  i know, i know, input is a mess...
				game.draggingBoardX = mousex
				game.draggingBoardY = mousey
				game.handPointer:setPos(mousex, mousey)
			end
			-- mouse up
			if keyr'mouse_left' then
				--try to place the tile
				if game.handPointer:isVisible() then
					local x = game.handPointer:getPointerX()
					local y = game.handPointer:getPointerY()
					local place = game.hand:getPlaceAtPoint(x,y)
					if place then
						game.handPointer:playInHand(place)
					else
						place = game.board:getPlaceAtPoint(x,y)
						if place then
							game.handPointer:playInBoard(game.board, place:getX(), place:getY())
						end
					end
				end
				game.draggingBoard = false
				game:returnAllTiles()
			end
		end
		game:update()
		game:draw()
	end

	spr(sprites.mouse, mousex, mousey)
end
