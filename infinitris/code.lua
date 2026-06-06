-- title = infinitris
-- saveid = infinitris
-- author = Chris Moore
-- description = block blast

math.randomseed(tstamp())

local vec2 = require 'vec.vec2'
local matpush = require 'numo9.matstack'.push
local matpop = require 'numo9.matstack'.pop

mode(0)	-- 256x256x16bpp

-- game config:
mapwidth, mapheight = 256 >> 3, 256	-- so tiles-high is 256 <-> tilemap height
--mapheight = (256>>3) - 1	-- for seeing what's going on at the bottom
numEmptyRows = 10
numColors = 4	-- so 1 thru 4 are colored tiles
baseDropTime = 60

-- game state:
local fillY, holeCol
local rowFlashes

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
end

local newPiece = ||do
	rot = 0
	piece = math.random(0,6)
	piecePos = vec2(math.floor(mapwidth/2), 1)
	pieceTilePos = vec2()
	dropTimer = baseDropTime

	-- copy our piece into a temp location and color it
	-- 256-4, 7<<2 will be where our piece is
	pieceTilePos:set(256-4, 7<<2)
	local pieceColor = math.random(1, numColors)
	for j=0,3 do
		for i=0,3 do
			-- color our temp region
			local pieceTile = tget(0, 256-4+i, (piece<<2)+j) * pieceColor
			tset(0, pieceTilePos.x+i, pieceTilePos.y+j, pieceTile)
		end
	end
end

local testHit = ||do
	for j=0,3 do
		for i=0,3 do
			-- if there's a tilemap entry on the piece
			if tget(0, pieceTilePos.x+i, pieceTilePos.y+j) ~= 0 then
				-- then rotate it and offset it
				-- and see if there's a tilemap entry in the map
				-- and if so then return true
				local x,y = i,j
				for k=0,rot-1 do
					x,y = 3-y,x
				end
				x += piecePos.x - 2
				y += piecePos.y - 2
				if x < 0 or x >= mapwidth then return true end
				if y >= mapheight then return true end
				if tget(0, x, y) ~= 0 then
					return true
				end
			end
		end
	end
end

local placePiece = ||do
	for j=0,3 do
		for i=0,3 do
			-- if there's a tilemap entry on the piece
			local tile = tget(0, pieceTilePos.x+i, pieceTilePos.y+j)
			if tile ~= 0 then
				-- then rotate it and offset it
				-- and see if there's a tilemap entry in the map
				-- and if so then return true
				local x,y = i,j
				for k=0,rot-1 do
					x,y = 3-y,x
				end
				x += piecePos.x - 2
				y += piecePos.y - 2
				tset(0, x, y, tile)
			end
		end
	end
	-- now check for lines....
	local gotLine
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
			gotLine = true
			--lastLineTime = time()
			points += mapwidth
		end
	end
	newPiece()
	return gotLine
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
	if firstNonEmptyRow > numEmptyRows then
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
	newPiece()
end
newGame()

update = ||do
	cls()

	tilemap(
		0,0,	-- tilex, tiley
		mapwidth, mapheight,	-- tileswide, tileshigh
		0, 0	-- screenx, screeny
	)

	-- pieces are 4x4's on the rhs of the tilemap
	matpush()
	mattrans(piecePos.x << 3, piecePos.y << 3)
	matrot(rot * math.pi/2)
	tilemap(
		pieceTilePos.x, pieceTilePos.y,
		4,4,
		-16,-16
	)
	matpop()

	text(tostring(points))

	if newGameTime then
		text('GAME OVER', 20, 100, 12, -1, 5, 5)
		if time() - newGameTime > 10 then
			newGame()
		end
	end

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

	local drop
	local oldPiecePosX = piecePos.x
	local oldPiecePosY = piecePos.y
	local oldRot = rot
	if btnp('left', 0, 10, 5) then
		piecePos.x -= 1
		if testHit() then
			piecePos.x = oldPiecePosX
		end
	elseif btnp('right', 0, 10, 5) then
		piecePos.x += 1
		if testHit() then
			piecePos.x = oldPiecePosX
		end
	elseif btnp('down', 0, 2, 2) then
		-- drop ...
		drop = true
	elseif btnp'a' or btnp'up' then
		rot += 1
		rot &= 3
		if testHit() then
			rot = oldRot
		end
	elseif btnp'b' then
		rot -= 1
		rot &= 3
		if testHit() then
			rot = oldRot
		end
	end

	dropTimer -= 1
	if dropTimer <= 0 then
		dropTimer = baseDropTime
		drop = true
	end
	if drop then
		piecePos.y += 1
		if testHit() then
			piecePos.y = oldPiecePosY
			local gotLine = placePiece()
			if testHit() then
print'gameover...'
				-- see if the initial piecePos will be stuck or not ...
				newGameTime = time()
			elseif not gotLine then
print("placed, didn't get line, checking for raise...")
				-- only if we placed a piece, and it wans't a line, and we previously got a line more than 5s ago...., then raise
				--if lastLineTime and time() - lastLineTime > 1 then
				--	lastLineTime = time()
print'raising...'
				checkForRaise()
				--end
			end
		end
	end
end
