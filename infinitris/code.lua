-- title = infinitris
-- saveid = infinitris
-- author = Chris Moore
-- description = block blast

math.randomseed(tstamp())

local class = require 'ext.class'
local vec2 = require 'vec.vec2'
local matpush = require 'numo9.matstack'.push
local matpop = require 'numo9.matstack'.pop

mode(0)	-- 256x256x16bpp
local screenWidth, screenHeight = require 'numo9.screen'.getScreenSize()

-- game config:
--mapwidth = 256 >> 3		-- screen size
mapwidth = 10				-- vanilla tetris
--mapheight = 256			-- so tiles-high is 256 <-> tilemap height
mapheight = 256 >> 3		-- screen size.  useful for seeing what's going on at the bottom
--mapheight = 20			-- vanilla tetris
--numEmptyRows = 10			-- infinitris
numEmptyRows = mapheight	-- vanilla tetris
numColors = 4	-- so 1 thru 4 are colored tiles
baseDropTime = 60
numPieceTypes = 7

local Player = class()
players = {}
conns = {}			-- conns[connID][playerID] = players[playerID]

-- game state:
local fillY, holeCol
local rowFlashes

board_dAbsY = 0
board_sumEmptyY = 0

local refreshMetrics=||do
	-- count deltas across top
	local lastTopY
	board_dAbsY = 0
	board_sumEmptyY = 0
	for x=0,mapwidth-1 do
		local topY
		local emptyY
		for y=0,mapheight-1 do
			if tget(0,x,y) ~= 0 then
				if not topY then topY = y end
			else
				-- count holes
				if emptyY
				and y > emptyY+1
				then
					board_sumEmptyY += y - (emptyY+1)
				end
				emptyY = y
			end
		end
		topY = topY or mapheight
		if lastTopY then
			board_dAbsY += math.abs(topY - lastTopY)
		end
		lastTopY = topY
	end
end

local fillRows=|fromRow|do
	for y=fromRow,mapheight-1 do
		fillY += 1
		for x=0,mapwidth-1 do
			if x == holeCol then
				tset(0, x,y,0)
			else
				local tileColor = numColors *
					math.sin((x+.5) * math.pi * 2 / 32)
					* math.sin((fillY+.5) * math.pi * 2 / 32)
				tileColor %= numColors
				tileColor += 1
				tset(0,x,y,tileColor)
			end
		end
		if math.random() < .25 then
			holeCol += math.random(1,3) * (math.random(0,1)*2-1)
			holeCol %= mapwidth
		end
	end
	refreshMetrics()
end

numNextPieces = 1
nextPieces = table()

Player.newPiece = |:|do
	self.rot = 0
	while #nextPieces < numNextPieces+1 do
		nextPieces:insert(math.random(0,numPieceTypes))
	end
	self.piece = nextPieces:remove(1)
	self.piecePos = vec2(math.floor(mapwidth/2), 1)
	self.pieceTilePos = vec2()
	self.dropTimer = baseDropTime

	-- copy our piece into a temp location and color it
	-- 256-4, numPieceTypes<<2 will be where our piece is
	self.pieceTilePos:set(256-4, (numPieceTypes + self.id)<<2)
	local pieceColor = math.random(1, numColors)
print('pieceColor', pieceColor)
	for j=0,3 do
		for i=0,3 do
			-- color our temp region
			local pieceTile = tget(0, 256-4+i, (self.piece<<2)+j) == 0 and 0 or pieceColor
			tset(0, self.pieceTilePos.x+i, self.pieceTilePos.y+j, pieceTile)
		end
	end
end

Player.testHit = |:|do
	for j=0,3 do
		for i=0,3 do
			-- if there's a tilemap entry on the piece
			if tget(0, self.pieceTilePos.x+i, self.pieceTilePos.y+j) ~= 0 then
				-- then rotate it and offset it
				-- and see if there's a tilemap entry in the map
				-- and if so then return true
				local x,y = i,j
				for k=0,self.rot-1 do
					x,y = 3-y,x
				end
				x += self.piecePos.x - 2
				y += self.piecePos.y - 2
				if x < 0 or x >= mapwidth then return true end
				if y >= mapheight then return true end
				if tget(0, x, y) ~= 0 then
					return true
				end
			end
		end
	end
end

Player.placePiece = |:|do
	for j=0,3 do
		for i=0,3 do
			-- if there's a tilemap entry on the piece
			local tile = tget(0, self.pieceTilePos.x+i, self.pieceTilePos.y+j)
			if tile ~= 0 then
				-- then rotate it and offset it
				-- and see if there's a tilemap entry in the map
				-- and if so then return true
				local x,y = i,j
				for k=0,self.rot-1 do
					x,y = 3-y,x
				end
				x += self.piecePos.x - 2
				y += self.piecePos.y - 2
				tset(0, x, y, tile)
			end
		end
	end
	-- now check for lines....
	local numLines = 0
	for y=0,mapheight-1 do
		local line = true
		for x=0,mapwidth-1 do
			if tget(0, x, y) == 0 then
				line = false
				break
			end
		end
		if line then
			-- copy all previous lines down over it
			for j=y-1,0,-1 do
				for x=0,mapwidth-1 do
					tset(0,x,j+1,tget(0,x,j))
				end
			end
			-- erase the top
			for x=0,mapwidth-1 do
				tset(0,x,0,0)
			end
trace('got line at row',y)
			rowFlashes:insert{y=y, time=time()}
			numLines += 1
			--lastLineTime = time()
		end
	end
	refreshMetrics()

	self:newPiece()
	if numLines > 0 then
--[[
tetris ... 1 lines = 40, 2 lines = x2.5, 3 lines = x7.5, 4 lines = x30
f(0) = 0
f(1) = 1
f(2) = 2.5
f(3) = 7.5
f(4) = 30
--]]
		points += 40 * math.ceil(((numLines + 1) / 2) ^ numLines)	-- meh
		return true
	end
end

Player.update = |:|do
	local drop
	local oldPiecePosX = self.piecePos.x
	local oldPiecePosY = self.piecePos.y
	local oldRot = self.rot
	if btnp('left', self.id, 10, 5) then
		self.piecePos.x -= 1
		if self:testHit() then
			self.piecePos.x = oldPiecePosX
		end
	elseif btnp('right', self.id, 10, 5) then
		self.piecePos.x += 1
		if self:testHit() then
			self.piecePos.x = oldPiecePosX
		end
	elseif btnp('down', self.id, 2, 2) then
		-- drop ...
		drop = true
	elseif btnp('a', self.id) or btnp('up', self.id) then
		self.rot += 1
		self.rot &= 3
		if self:testHit() then
			self.rot = oldRot
		end
	elseif btnp('b', self.id) then
		self.rot -= 1
		self.rot &= 3
		if self:testHit() then
			self.rot = oldRot
		end
	end

	self.dropTimer -= 1
	if self.dropTimer <= 0 then
		self.dropTimer = baseDropTime
		drop = true
	end

	local gotHit, gotLine
	if drop then
		self.piecePos.y += 1
		if self:testHit() then
			gotHit = true
			self.piecePos.y = oldPiecePosY
			gotLine = self:placePiece()
			if self:testHit() then
print'gameover...'
				-- see if the initial piecePos will be stuck or not ...
				newGameTime = time()
				return
			end
		end
	end
	return gotHit, gotLine
end

local checkForRaise = ||do
	-- now see what the first non-empty row is and raise things up and fill in as we go
	local firstNonEmptyRow
	for y=0,mapheight-1 do
		local empty = true
		for x=0,mapwidth-1 do
			if tget(0,x,y) ~= 0 then
				empty = false
				break
			end
		end
		if not empty then
			firstNonEmptyRow = y
			break
		end
	end
	firstNonEmptyRow ??= mapheight
	if firstNonEmptyRow <= numEmptyRows then return end
print('firstNonEmptyRow', firstNonEmptyRow, 'vs numEmptyRows', numEmptyRows, '... moving up')
	--local moveUp = firstNonEmptyRow - numEmptyRows
	local moveUp = 1
	for y=firstNonEmptyRow,mapheight-1 do
		for x=0,mapwidth-1 do
			tset(0, x, y-moveUp, tget(0, x, y))
		end
	end
	fillRows(mapheight-moveUp)
end

local newGame = ||do
	for y=0,mapheight-1 do
		for x=0,mapwidth-1 do
			tset(0,x,y,0)
		end
	end
	newGameTime = nil
	points = 0
	fillY = 0
	holeCol = math.floor(mapwidth/2)
	fillRows(numEmptyRows)
	rowFlashes = table()
end
newGame()

onconnect=|connID|do	-- FC API:
	conns[connID] = {}
end

-- FC API
draw = |connID, ...|do
	local conn = conns[connID]
	if not conn then
		trace'I LOST THE PLAYER'
		return
	end
	-- add players and set their last update time
	for i=1,select('#', ...) do
		local playerID = select(i, ...)
		local player = players[playerID]
		if not player then
			player = Player()
			player.id = playerID
			player:newPiece()
			players[playerID] = player
		end
		conn[playerID] = player
		player.drawTime = time()
	end
	-- remove disconnected players from conn
	for playerID,player in pairs(conn) do
		if conn[playerID].drawTime ~= t then
			conn[playerID] = nil
		end
	end
	-- TODO remove players from players[] that disconnect...

	cls()

-- [[ draw field
	matpush()
	mattrans(
		(screenWidth >> 1) - (mapwidth << 2),	-- center x
		(screenHeight >> 1) - (mapheight << 2)	-- center y ... TODO clamp to top
	)
	rectb(-1, -1, (mapwidth << 3) + 2, (mapheight << 3) + 2, 12)

	tilemap(
		0,0,	-- tilex, tiley
		mapwidth, mapheight,	-- tileswide, tileshigh
		0, 0	-- screenx, screeny
	)

	-- pieces are 4x4's on the rhs of the tilemap
	for _,player in pairs(players) do
		matpush()
		mattrans(player.piecePos.x << 3, player.piecePos.y << 3)
		matrot(player.rot * math.pi/2)
		tilemap(
			player.pieceTilePos.x, player.pieceTilePos.y,
			4,4,
			-16,-16
		)
		matpop()
	end

	-- draw row flashes
	for i=#rowFlashes,1,-1 do
		local f = rowFlashes[i]
		local dt = time() - f.time
		if dt > .5 then
			rowFlashes:remove(i)
		else
			if (dt * 12) % 1 < .5 then
				rect(0, f.y << 3, mapwidth << 3, 1<<3, 12)
			end
		end
	end

	matpop()
--]] end draw field

	-- next piece in upper-right
	do
		blend(3)
		rect(screenWidth - (4<<3), 0, 4<<3, #nextPieces<<5, 16)
		blend(-1)
		for i,p in ipairs(nextPieces) do
			tilemap(
				256-4, p<<2,
				4, 4,
				screenWidth - (4<<3), (i-1)<<5
			)
		end
		rectb(screenWidth - (4<<3) - 1, -1, (4<<3) + 2, (#nextPieces<<5) + 2, 12)
	end

	-- points in upper-left
	text(tostring(points))
	text(tostring(board_dAbsY), 0, 8)
	text(tostring(board_sumEmptyY), 0, 16)

	if newGameTime then
		text('GAME OVER', 20, 100, 12, -1, 5, 5)
	end
end

-- FC API
update = ||do
	if newGameTime then
		if time() - newGameTime > 10 then
			newGame()
		end
		return
	end

	local gotHit, gotLine
	for _,player in pairs(players) do
		local playerHit, playerLine = player:update()
		gotHit = gotHit or playerHit
		gotLine = gotLine or playerLine
	end

	if not newGameTime and gotHit and not gotLine then
print("placed, didn't get line, checking for raise...")
		-- only if we placed a piece, and it wans't a line, and we previously got a line more than 5s ago...., then raise
		--if lastLineTime and time() - lastLineTime > 1 then
		--	lastLineTime = time()
print'raising...'
		checkForRaise()
		--end
	end
end
