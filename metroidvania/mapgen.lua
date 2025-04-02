--#include ext/range.lua
--#include vec/vec2.lua
--[[ procedural level
reads:
	dirvecs, opposite
	roomSize, mapInRooms
	mapTypeForName
writes:
	rooms
	keyIndex
	keyColors
	...the tilemap
--]]
generateMap=[]do
	for y=0,255 do
		for x=0,255 do
			mset(x,y,1)	-- solid
		end
	end

	rooms = range(0,mapInRooms.x-1):mapi([i]
		(range(0,mapInRooms.y-1):mapi([j]
			({
				pos = vec2(i,j),
				dirs = table(),
				doors = table(),
				spawns = table(),
				color = pickRandomColor(),
			}, j)
		), i)
	)

	keyIndex = 0

	local posinfos = table()
	local start = (mapInRooms / 2):floor()
	local startroom = rooms[start.x][start.y]
	startroom.set = true
	posinfos:insert{pos=startroom.pos}
	while #posinfos > 0 do
		local posinfoindex = math.random(1, #posinfos)
		local pos = posinfos[posinfoindex].pos
		local srcroom = rooms[pos.x][pos.y]
		local validDirs = dirvecs:mapi([dir, dirindex, t] do
			local nbhdpos = pos + dir
			if nbhdpos.x >= 0 and nbhdpos.x < mapInRooms.x
			and nbhdpos.y >= 0 and nbhdpos.y < mapInRooms.y
			then
				local nextroom = rooms[nbhdpos.x][nbhdpos.y]
				if not nextroom.set
				and not posinfos:find(nil, [info] info.pos == nbhdpos) then
					return {dir=dir, dirindex=dirindex}, #t+1
				end
			end
		end)

		if #validDirs == 0 then
			-- remove posinfos
			posinfos:remove(posinfoindex)
		else
			-- TODO only move once so levels are longer or something
			local p = validDirs:pickRandom()
			local dirindex = p.dirindex
			local dir = p.dir
			local nbhdpos = pos + dir
			local nextroom = rooms[nbhdpos.x][nbhdpos.y]
			posinfos:insert{pos=nbhdpos}
			srcroom.dirs[dirindex] = true
			nextroom.set = true
			nextroom.prevRoom = srcroom
			nextroom.dirs[opposite[dirindex]] = true
			nextroom.color = advanceColor(srcroom.color)

			-- monsters?
			if math.random() < .5 then
				-- store spawn info, spawn when screen changes
				nextroom.spawns:insert{
					class=Enemy,
					pos=(nextroom.pos + .5)*roomSize,
				}
			else
				nextroom.spawns:insert{
					class=Health,
					pos=(nextroom.pos + .5)*roomSize,
				}
			end

			-- TODO powerups?

			-- if we are making a key-door then make sure to drop a key somewhere in the .prevRoom chain
			-- ... and it'd be nice to put the key behind the last-greatest key-door used
			if math.random() < .5 then

				-- what if there's already a key-door there?
				-- will there ever be one?
				local doorKeyIndex = math.random(0, keyIndex)
				srcroom.doors[dirindex] = doorKeyIndex
				nextroom.doors[opposite[dirindex]] = doorKeyIndex

				if math.random() < .2 then
					keyIndex += 1
					-- put the key after the next room
					nextroom.spawns:insert{
						class=Key,
						pos=(nextroom.pos + .5)*roomSize,
						keyIndex = keyIndex,
					}
				end
			end
		end
	end

	for i=0,mapInRooms.x-1 do
		for j=0,mapInRooms.y-1 do
			local room = rooms[i][j]

			-- [=[
			for dirindex,dir in ipairs(dirvecs) do
				if room.dirs[dirindex] and not room.doors[dirindex]
				and room.dirs[opposite[dirindex]] and not room.doors[opposite[dirindex]]
				then
					local w = math.floor(roomSize.x*.5)-1
					for x=-math.floor(roomSize.x*.5),math.floor(roomSize.x*.5) do
						for y=0,2*w-1 do
							mset(
								math.floor((i + .5) * roomSize.x + dir.x * x + dir.y * (y + .5 - w)),
								math.floor((j + .5) * roomSize.y + dir.y * x - dir.x * (y + .5 - w)),
								0)
						end
					end
				end
			end
			--]=]

			for x=0,roomSize.x-1 do
				local dx = x + .5 - roomSize.x*.5
				for y=0,roomSize.y-1 do
					local dy = y + .5 - roomSize.y*.5
					if dx^2 + dy^2 <= (roomSize.x*.4)^2 then
						mset(i*roomSize.x+x, j*roomSize.y+y, 0)
					end
				end
			end

			-- [[
			for dirindex,dir in ipairs(dirvecs) do
				if room.dirs[dirindex] then
					local xmax = math.floor(roomSize.x*.5)
					--local w = math.floor(roomSize.x*.1)	-- good for roomSize=16
					local w = math.floor(roomSize.x*.2)
					for x=0,xmax do
						for y=0,2*w-1 do
							mset(
								math.floor((i + .5) * roomSize.x + dir.x * x + dir.y * (y + .5 - w)),
								math.floor((j + .5) * roomSize.y + dir.y * x - dir.x * (y + .5 - w)),
								0)
						end
					end
					local doorKey = room.doors[dirindex]
					if doorKey then
						room.doorKey ??= {}
						for y=0,2*w-1 do
							local mx = math.floor(i * roomSize.x + roomSize.x * .5 + dir.x * (xmax - .5) + dir.y * (y + .5 - w))
							local my = math.floor(j * roomSize.y + roomSize.y * .5 + dir.y * (xmax - .5) - dir.x * (y + .5 - w))
							room.doorKey[mx % roomSize.x] ??= {}
							room.doorKey[mx % roomSize.x][my % roomSize.y] = doorKey
							mset(mx, my, mapTypeForName.door.index)
						end
					end
				end
			end
			--]]

			for ofs=-1,0 do
				mset(
					math.floor((i + .5) * roomSize.x + ofs),
					math.floor((j + .5) * roomSize.y + 1),
					1
				)
			end

		end
	end
	trace'====='
	for dj=0,mapInRooms.y*3-1 do
		trace(range(0,mapInRooms.x*3-1):mapi([di] do
			local i = tonumber(di // 3)
			local j = tonumber(dj // 3)
			local u = (di % 3) - 1
			local v = (dj % 3) - 1
			local room = rooms[i][j]
			local dirindex = dirvecs:find(nil, [dir] dir == vec2(u,v))
			if room.dirs[dirindex] then
				return math.abs(u) > math.abs(v) and '━' or '┃'
			elseif u == 0 and v == 0 then
				return '╋'
			else
				return ' '
			end
		end):concat())
	end
	trace'====='
	trace('made '..keyIndex..' keys')

	local sx,sy = ((start.x + .5) * roomSize):floor():unpack()
	mset(sx, sy, mapTypeForName.spawn_player.index)
--]]

	for y=0,255 do
		for x=0,255 do
			local ti = mget(x,y)
			if ti == mapTypeForName.spawn_player.index then
				player = Player{pos=vec2(x,y)+.5}
				mset(x,y,0)
			elseif ti == mapTypeForName.spawn_enemy.index then
				Enemy{pos=vec2(x,y)+.5}
				mset(x,y,0)
			end
		end
	end
	if not player then
		trace"WARNING! dind't spawn player"
	end

	-- erode but don't dissolve walls
	for i=1,mapInRooms.x-1 do
		for j=1,mapInRooms.y-1 do
			-- for each 
			local empty = 0
			for _,dir in ipairs(dirvecs) do
				if mget(
					(i + .5 * dir.x) * roomSize.x,
					(j + .5 * dir.y) * roomSize.y) == 0
				then
					empty += 1
				end
			end
			if empty >= 3 then
				for u = 0,roomSize.x-1 do
					for v=0,roomSize.y-1 do
						mset(
							(i - .5) * roomSize.x + u,
							(j - .5) * roomSize.y + v, 0)
					end
				end
			end
		end
	end

	keyColors = {}
	do
		local c = pickRandomColor()
		for i=0,keyIndex do
			keyColors[i] = c
			--c = advanceColor(c)
			c = pickRandomColor()
		end
	end
end
