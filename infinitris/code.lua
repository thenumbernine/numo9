-- title = infinitris
-- saveid = infinitris
-- author = Chris Moore
-- description = block blast

local vec2 = require 'vec.vec2'
local matpush = require 'numo9.matstack'.push
local matpop = require 'numo9.matstack'.pop

mode(0)	-- 256x256x16bpp
local w, h = 256, 256<<3
local tw, th = w >> 3, h >> 3
-- so tiles-high is 256 <-> tilemap height

do
	local hole = math.floor(tw/2)
	for y=10,th-1 do
		for x=0,tw-1 do
			if x ~= hole then
				tset(0,x,y,1)
			end
		end
		if math.random() < .1 then
			hole += math.random(1,3) * (math.random(0,1)*2-1)
		end
	end
end


local newPiece = ||do
	rot = 0
	piece = math.random(0,6)
	piecePos = vec2(math.floor(tw/2), 3)
	baseDropTime = 60
	dropTimer = baseDropTime
end

local testHit = ||do
	for j=0,3 do
		for i=0,3 do
			-- if there's a tilemap entry on the piece
			if tget(0, 256-4+i, (piece<<2) + j) ~= 0 then
				-- then rotate it and offset it
				-- and see if there's a tilemap entry in the map
				-- and if so then return true
				local x,y = i,j
				for k=0,rot-1 do
					x,y = 3-y,x
				end
				x += piecePos.x - 2
				y += piecePos.y - 2
				if x < 0 or x >= tw then return true end
				if y >= th then return true end
				if tget(0, x, y) ~= 0 then
					return true
				end
			end
		end
	end
end

rowFlashes = table()
local placePiece = ||do
	for j=0,3 do
		for i=0,3 do
			-- if there's a tilemap entry on the piece
			local tile = tget(0, 256-4+i, (piece<<2) + j)
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
	for y=0,th-1 do
		local line = true
		for x=0,tw-1 do
			if tget(0, x, y) == 0 then
				line = false
				break
			end
		end
		if line then
			-- copy all previous lines down over it
			for j=y-1,0,-1 do
				for x=0,tw-1 do
					tset(0,x,j+1,tget(0,x,j))
				end
			end
			-- erase the top
			for x=0,tw-1 do
				tset(0,x,0,0)
			end
			rowFlashes:insert{y=y, time=time()}
		end
	end
	newPiece()
end

newPiece()

update = ||do
	cls()

	tilemap(
		0,0,	-- tilex, tiley
		tw, th,	-- tileswide, tileshigh
		0, 0	-- screenx, screeny
	)

	-- pieces are 4x4's on the rhs of the tilemap
	matpush()
	mattrans(piecePos.x << 3, piecePos.y << 3)
	matrot(rot * math.pi/2)
	tilemap(
		256-4, piece<<2,
		4,4,
		-16,-16
	)
	matpop()

	for i=#rowFlashes,1,-1 do
		local f = rowFlashes[i]
		local dt = time() - f.time
		if dt > .5 then
			rowFlashes:remove(i)
		else
			if (dt * 12) % 1 < .5 then
				rect(0, f.y << 3, tw << 3, 1<<3, 12)
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
	elseif btnp('down', 0, 3, 3) then
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
			placePiece()
		end
	end
end
