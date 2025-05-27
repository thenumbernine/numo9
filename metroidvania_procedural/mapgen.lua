--#include ext/range.lua
--#include vec/vec2.lua
--#include simplexnoise/2d.lua
--[[ procedural level
reads:
	dirvecs, opposite
	blockSize, worldSizeInBlocks
	mapTypeForName
writes:
	world.blocks
	keyIndex
	keyColors
	...the tilemap
--]]
-- [====[ old system, guarantees every block is filled, but not so good at what goes where...
generateWorld=||do
	for y=0,255 do
		for x=0,255 do
			mset(x,y,1)	-- solid
		end
	end

	local blocks = range(0,worldSizeInBlocks.x-1):mapi(|i|
		(range(0,worldSizeInBlocks.y-1):mapi(|j|do
				local block = {
					pos = vec2(i,j),
					dirs = range(0,3):mapi(|i| (false, i)),
					doors = range(0,3):mapi(|i| (false, i)),
					spawns = table(),
					color = pickRandomColor(),
					seen = 0,
				}
				block.room = {
					blocks = table{block},
					--colorIndex = math.random(0,255),
				}
				return block, j
			end
		), i)
	)

	keyIndex = 0

	--[[ replace 'keyIndex' stuff with this ...
	TODO color = ,
	then make weaponType= for whatever dif types,
	then make dif shaped blocks correspond with what weapon needs to unlock them ...

	what kinds of weapons should we allow per-color?
		star =  small bombs
		clubs =  big bombs
		diamond = grappling block per-color? hmm
			wall grab per color or nah? speed boost per color too or nah?
			- and then like 3 or so dif beam types... per-color ... each color can have different ...
			... or should i just have one single grappling and make it a sub-weapon of some certain color ...
		spades = beam #1
		triangle = beam #2
		square = beam #3
	--]]
	local itemProgress = table{
		-- start with white shot
		-- ... blue shots
		{
			class = Weapon,
			weapon = 1,
		},
		-- ... green shots
		{
			class = Weapon,
			weapon = 2,
		},
		-- ... red shots
		{
			class = Weapon,
			weapon = 3,
		},
		-- .. black shots
		{
			class = Weapon,
			weapon = 4,
		},
	}
	--[[ how about a progression of items and enemies to place in rooms ...
	items:
		bombs
		high-jump
		wall-jump
		spider-ball
		speed-booster
		speed-ball
		grappling-hook
		double-jump
		space-jump

		energy tanks ... x how many

		shield upgrades ... x how many

		white gun (starts with?)
		+ skiltree upgrades
		blue gun
		green gun
		red gun
		black gun

	monsters:
		crawls on ground
		jumps on floor/ceiling
		flies in waves back and forth
		dive bombs you
		grabs and pulls you
		stands and shoots at you, and walks slowly back and forth


	hhmmmmm....


	1) start room, is empty, has weapon-0 door

	2) build N rooms (looks like old map-building method), then plop down weapon #1 ... or boss #1 ... or boss #1 then immediately after is weapon #1 ...
		- in each of the N room leading up to it, add monsters for weapon #0
		- maybe even do a progression of 5 new monster types for each 1 new story item/boss or something, idk.
		- then take maybe 5 or so aux item upgrades, like health, armor, ammo, etc and scatter them in those N rooms.  hide in break-blocks.

	3) then spin off a prev room, a door #1, and then repeat N rooms to weapon #2 etc

	--]]

	local posinfos = table()
	local start = (worldSizeInBlocks / 2):floor()
	local startblock = blocks[start.x][start.y]
	startblock.set = true
	posinfos:insert{pos=startblock.pos}
	while #posinfos > 0 do
		local posinfoindex = math.random(1, #posinfos)
		local pos = posinfos[posinfoindex].pos
		local srcblock = blocks[pos.x][pos.y]
		local validDirs = dirvecs:map(|dir, dirindex, t| do
			local nbhdpos = pos + dir
			if nbhdpos.x >= 0 and nbhdpos.x < worldSizeInBlocks.x
			and nbhdpos.y >= 0 and nbhdpos.y < worldSizeInBlocks.y
			then
				local nextblock = blocks[nbhdpos.x][nbhdpos.y]
				if not nextblock.set
				and not posinfos:find(nil, |info| info.pos == nbhdpos) then
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
			local nextblock = blocks[nbhdpos.x][nbhdpos.y]
			posinfos:insert{pos=nbhdpos}
			srcblock.dirs[dirindex] = true
			nextblock.set = true
			nextblock.prevRoom = srcblock
			nextblock.dirs[opposite[dirindex]] = true
			nextblock.color = advanceColor(srcblock.color)
			-- monsters?
			-- no monsters in the start room
			-- TODO room classifiers ... start room, save room, heal room, item room, boss room, etc
			if srcblock ~= startblock then
				for i=1,math.random(0,3) do
					-- store spawn info, spawn when screen changes
					-- hmm good reason to mset() so objs dont overlap
					-- or just reposition them later
					nextblock.spawns:insert{
						class=table{
							assert(Crawler),
							assert(Jumper),
							assert(Shooter),
						}:pickRandom(),	-- TODO weighted?
						left = math.random(2) == 2,

						-- gravity is just fo jumpers..
						gravity = math.random(2) == 2 and vec2(0,-1) or nil,

						drops={
							[{
								class=assert(Health),
							}] = .15,
						},
						pos = ((nextblock.pos + math.random())*blockSize):floor() + .5,
						selWeapon = math.random(0,keyIndex),
					}
				end
			else -- test enemy
				srcblock.spawns:insert{
					class=assert(Crawler),
					pos=((srcblock.pos+.5)*blockSize):floor(),
					selWeapon = math.random(0,keyIndex),
				}
			end

			if math.random() < .5 then
				--[[ hide health in blocks? in monsters?
				nextblock.spawns:insert{
					class=assert(Health),
					pos=(nextblock.pos + .5)*blockSize,
				}
				--]]
			end

			-- TODO powerups?

			-- if we are making a key-door then make sure to drop a key somewhere in the .prevRoom chain
			-- ... and it'd be nice to put the key behind the last-greatest key-door used
			if math.random() < .5
			or srcblock == startblock -- always a door from the start room
			then

				-- what if there's already a key-door there?
				-- will there ever be one?
				local doorKeyIndex = math.random(0, keyIndex)
				srcblock.doors[dirindex] = doorKeyIndex
				nextblock.doors[opposite[dirindex]] = doorKeyIndex

				if math.random() < .2 then
					keyIndex += 1
					-- put the key after the next block
					nextblock.spawns:insert{
						class=assert(Weapon),
						pos=(nextblock.pos + .5)*blockSize,
						weapon=keyIndex,
					}
				end
			else
				-- no door = merge rooms
				nextblock.room = srcblock.room
				srcblock.room.blocks:insert(nextblock)
			end

			-- only one door out of the start room
			if srcblock == startblock then
				-- remove posinfos
				posinfos:remove(posinfoindex)
			end
		end
	end


	--[[
	TODO room types ...
	cave room - wind in a circle
	spike floor rooms you have to jump across
	--]]
	for i=0,worldSizeInBlocks.x-1 do
		for j=0,worldSizeInBlocks.y-1 do
			local block = blocks[i][j]

			--[=[ make some empty hallways ... TODO room type is spikes for walls / ceiling / floor or something
			for dirindex,dir in pairs(dirvecs) do
				if block.dirs[dirindex] and not block.doors[dirindex]
				and block.dirs[opposite[dirindex]] and not block.doors[opposite[dirindex]]
				then
					local w = math.floor(blockSize.x*.5)-1
					for x=-math.floor(blockSize.x*.5),math.floor(blockSize.x*.5) do
						for y=0,2*w-1 do
							mset(
								math.floor((i + .5) * blockSize.x + dir.x * x + dir.y * (y + .5 - w)),
								math.floor((j + .5) * blockSize.y + dir.y * x - dir.x * (y + .5 - w)),
								0)
						end
					end
				end
			end
			--]=]

			for x=0,blockSize.x-1 do
				local dx = x + .5 - blockSize.x*.5
				for y=0,blockSize.y-1 do
					local dy = y + .5 - blockSize.y*.5
					if dx^2 + dy^2 <= (blockSize.x*.4)^2 then
						mset(i*blockSize.x+x, j*blockSize.y+y, 0)
					end
				end
			end

			-- [[
			for dirindex,dir in pairs(dirvecs) do
				if block.dirs[dirindex] then
					local xmax = math.floor(blockSize.x*.5)
					--local w = math.floor(blockSize.x*.1)	-- good for blockSize=16
					local w = math.floor(blockSize.x*.2)
					for x=0,xmax do
						for y=0,2*w-1 do
							mset(
								math.floor((i + .5) * blockSize.x + dir.x * x + dir.y * (y + .5 - w)),
								math.floor((j + .5) * blockSize.y + dir.y * x - dir.x * (y + .5 - w)),
								0)
						end
					end
					local doorKey = block.doors[dirindex]
					if doorKey then
						for dh=0,2*w-1 do
							local mx = math.floor(i * blockSize.x + blockSize.x * .5 + dir.x * (xmax - .5) + dir.y * (dh + .5 - w))
							local my = math.floor(j * blockSize.y + blockSize.y * .5 + dir.y * (xmax - .5) - dir.x * (dh + .5 - w))

							mset(
								mx,
								my,
								-- bake in color
								mapTypeForName.door.index | (keyColorIndexes[doorKey] << 6)
							)
						end
					end
				end
			end
			--]]
		end
	end

	-- erode but don't dissolve walls
	for i=1,worldSizeInBlocks.x-1 do
		for j=1,worldSizeInBlocks.y-1 do
			-- for each
			local empty = 0
			for _,dir in pairs(dirvecs) do
				if mget(
					(i + .5 * dir.x) * blockSize.x,
					(j + .5 * dir.y) * blockSize.y) == 0
				then
					empty += 1
				end
			end
			if empty >= 3 then
				for u = 0,blockSize.x-1 do
					for v=0,blockSize.y-1 do
						mset(
							(i - .5) * blockSize.x + u,
							(j - .5) * blockSize.y + v, 0)
					end
				end
			end
		end
	end

	-- [[ add some platforms
	for i=0,worldSizeInBlocks.x-1 do
		for j=0,worldSizeInBlocks.y-1 do
			local block = blocks[i][j]
			for yofs=0,blockSize.y-1,2 do
				local alt = (yofs >> 1) & 1
				for xofs=-1,0 do
					local x = math.floor((i + .5) * blockSize.x + xofs + (2 * alt - 1))
					local y = math.floor(j * blockSize.y + yofs)
					if mget(x,y) == 0 then
						mset(x, y, mapTypeForName.solid_up.index)
					end
				end
			end
		end
	end
	--]]

	trace'====='
	for dj=0,worldSizeInBlocks.y*3-1 do
		trace(range(0,worldSizeInBlocks.x*3-1):mapi(|di| do
			local i = tonumber(di // 3)
			local j = tonumber(dj // 3)
			local u = (di % 3) - 1
			local v = (dj % 3) - 1
			local block = blocks[i][j]
			local dirindex = dirvecs:find(nil, |dir| dir == vec2(u,v))
			if block.dirs[dirindex] then
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

	player = Player{
		pos=((start.x + .5) * blockSize + vec2(0,3)):floor(),
	}
--]]

	-- TODO place enemies here only in empty places
	-- or better yet, for all enemies in spawns in blocks, move them to a free space
	-- since the block gen didn't happen when object-placement happened
	for i=0,worldSizeInBlocks.x-1 do
		for j=0,worldSizeInBlocks.y-1 do
			local block = blocks[i][j]
			for _,s in ipairs(block.spawns) do
				for try=1,20 do
					local u = math.random(0,blockSize.x-1)
					local v = math.random(0,blockSize.y-1)
					local px = i * blockSize.x + u
					local py = j * blockSize.y + v
					if mget(px, py) == 0 then
						-- side on one side
						local side

						-- TODO dif spanws have dif sides they want to stick to
						-- flying enemies = no sides (heck, walk-through-walls enemies don't even care if it's solid or not)
						-- items = stick to floor
						-- crawlers = stick to any wall
						for dirindex,dir in pairs(dirvecs) do
							if mget(px+dir.x,py+dir.y) ~= 0 then
								side = dirindex
								break
							end
						end
						if side then
							s.pos:set(px + .5, py + .5)
							s.stickSide = side
							-- TODO for the Crawler, stickSide should point to the side next to it
							break
						end
					end
				end
			end
		end
	end

	-- now replace all mapType==1 with 32-47 based on neighbor flags
	for j=0,worldSize.y-1 do
		for i=0,worldSize.x-1 do
			local ti = mget(i,j)
			if ti == 1 then
				local sideflags = 0
				for side,dir in pairs(dirvecs) do
					local i2, j2 = i + dir.x, j + dir.y
					local oob = i2 < 0 or j2 < 0 or i2 >= worldSize.x or j2 >= worldSize.y
					local neighborSolid = oob	-- T or F whether you want the tiles on the map edge or not
					if not oob then
						local ti2 = mget(i2,j2)
						if ti2 == 1
						or (ti2 >= 32 and ti2 < 48)
						then
							neighborSolid = true
						end
					end
					if not neighborSolid then
						sideflags |= 1 << side
					end
				end
				mset(i,j,32 + sideflags)
				if sideflags == 0 then
					-- TODO here count L1-dist to first empty tile
					-- and color 64 65 66 accordingly, dither out tiles
				end
			end
		end
	end

	return {
		blocks = blocks,
	}
end
--]====]
--[====[ new (really older) system, based on my old voxel-metroidvania zeta3d game ...

local doorsize = 4		-- diameter
local doorthickness = 2	-- short axis ... not yet implemented ...

local WorldBlock = class()
WorldBlock.init = |:,x,y|do
	self.pos = vec2(x,y)
	self.spawns = table()
	self.walls = range(0,3):mapi(|i| (false, i))	-- index corresponds with dirvecs' index
	self.doors = range(0,3):mapi(|i| (false, i)) 	-- same
	self.color = pickRandomColor()
	self.seen = 0	-- luminance
	--self.doorKeys = {}		-- table for door offsets <_> has what key they are
trace('creating new WorldBlock at '..self.pos)
end

local WorldRoom = class()
WorldRoom.init=|:|do
	self.blocks = table()
trace('creating new WorldRoom')
end
WorldRoom.addblock=|:,block|do
	assert(not block.room, "hmm, somehow a block got added twice...")
	block.room = self
	self.blocks:insert(block)
	if not self.min or not self.max then	-- inclusive
		self.min = block.pos:clone()
		self.max = block.pos:clone()
	else
		-- TODO use box2 ... self.bbox:stretch(block.pos)
		for _,n in ipairs(vec2.fields) do
			self.min[n] = math.min(self.min[n], block.pos[n])
			self.max[n] = math.max(self.max[n], block.pos[n])
		end
	end
end



local World = class()
World.init=|:|do
	self.blocks = range(0,worldSizeInBlocks.x-1):mapi(|i|
		(range(0,worldSizeInBlocks.y-1):mapi(|j|
			(WorldBlock(i,j), j)
		), i)
	)

	self.rooms = table()	-- list of rooms, rooms are collections of blocks
	--self.startroom = start room
end

local timeprint
do
	local lasttime
	timeprint = |...| do
--[[
		local thistime = time() / 60
		if lasttime then
			trace('...'..(thistime-lasttime)..' seconds')
		end
		lasttime = thistime
		trace(...)
--]]
	end
end

local levelCarveDoors = |world, room| do
	local placeDoor = |x, y, n, keyIndex| do
		local n1 = n == 'x' and 'y' or 'x'
		local halfdoorsize = math.floor(doorsize/2)
		local doorextrusion = blockSize[n]*.5
		local src = vec2(x,y)
		local v = vec2()
		for k=-doorextrusion,doorextrusion do
			for i=0,doorsize-1 do
--[[
				local adcx = (doorsize-1)/2 - math.abs(math.max(i-(doorsize-1)/2))
				local adcy = (doorsize-1)/2 - math.abs(math.max(j-(doorsize-1)/2))
				if adcx + adcy > 1 then	-- allow 1-l1len round corners
--]] do
					local ofsi = i - halfdoorsize
					v[n] = src[n] + k
					v[n1] = src[n1] + ofsi

					if -2 <= k and k < 2 then

						local bx = math.floor(v.x/blockSize.x)
						local by = math.floor(v.y/blockSize.y)
						local block = world.blocks[bx][by]
						local ofx = v.x - bx * blockSize.x
						local ofy = v.y - by * blockSize.y
						block.doorKey ??= {}
						block.doorKey[ofx] ??= {}
						block.doorKey[ofx][ofy] = keyIndex

						mset(v.x, v.y, mapTypeForName.door.index)
					else
						mset(v.x, v.y, 0)
					end
				end
			end
		end
	end

	for x=room.min.x,room.max.x+1 do
		for y=room.min.y,room.max.y+1 do

			local block = world.blocks[x]?[y]
			if block then

				-- for each element, 'x', 'y', 'z' refers to the previous side
				--that means if a dimension is at its maximal then the only door axis flags that can be used are the maximal dimension
				--... and not two nor three will allow any
				local v = vec2(x,y)
				for _,n in ipairs(vec2.fields) do
					local nv = v:clone()
					nv[n] -= 1
					local nbhdblock = world.blocks[nv.x]?[nv.y]

					local n1 = n == 'x' and 'y' or 'x'
					local keyIndex = block['door'..n]
					if keyIndex
					--  only if block's room == room or the prev block along the n'th axis's room == room
					and (block.room == room or (nbhdblock and nbhdblock.room == room))
					then
						local dv = v * blockSize
						dv[n1] += blockSize[n1] / 2
						placeDoor(dv.x, dv.y, n, keyIndex)

						--[[ option #1, make doors entities
						local doorClass = assert(n == 'x' and DoorHorz or DoorVert)
						if block.room == room then
							local doorpos = dv:clone()
							--doorpos[n] = doorpos[n] + 0
							block.spawns:insert{class=doorClass, pos=doorpos, keyIndex=keyIndex}
						end
						if nbhdblock.room == room then
							local doorpos = dv:clone()
							doorpos[n] = doorpos[n] - 2.5
							nbhdblock.spawns:insert{class=doorClass, pos=doorpos, keyIndex=keyIndex}
						end
						--]]
						-- [[ option #2, make doors tiles ... built into placeDoor
						--]]
					end
				end
			end
		end
	end
end

local fillBlock = |rx,ry,index| do
trace('fillBlock', rx, ry, index)
	rx = math.floor(rx)
	ry = math.floor(ry)
	-- rx,ry,rz = block coordinates
	for i=0,blockSize.x-1 do
		for j=0,blockSize.y-1 do
			mset(
				i + (rx * blockSize.x),
				j + (ry * blockSize.y),
				index)
		end
	end
end

local levelInitSimplexRoom = |world, room| do
	assert(world)
	assert(room)

	local solidWrites = 0

	local halfWorldBlockSize = blockSize * .5

	for _,block in ipairs(room.blocks) do
		local rx,ry = block.pos:unpack()
		fillBlock(rx,ry,mapTypeForName.empty.index)
	end

	timeprint('levelInitSimplexRoom',room,'range is',room.min,'to',room.max)
	for rx=room.min.x,room.max.x do
		for ry=room.min.y,room.max.y do
			local rv = vec2(rx,ry)

			-- for every room, look at the neighbors ...
			-- if it has a neighbor on one side then

			local block = world.blocks[rx]?[ry]
			if block and block.room == room then
				local nbhdblocks = {}
				solidWrites = 0
				for _,n in ipairs(vec2.fields) do
					local v = vec2(rx,ry)
					v[n] += 1
					if v[n] >= 0
					and v[n] < worldSizeInBlocks[n]
					then
						nbhdblocks[n] = world.blocks[v.x]?[v.y]
					end
				end
				for by=0,blockSize.y-1 do
					for bx=0,blockSize.x-1 do

						local x = (rx * blockSize.x) + bx
						local y = (ry * blockSize.y) + by

						local bv = vec2(bx, by)


						-- TODO pick walls first, then iterate per-voxel once we find what kind of border to use

						local lensq = 0

						-- single-influences
						for ni,n in ipairs(vec2.fields) do
							local wallindex = 5-2*ni	-- 1 = x, 2 = y ...maps to... 3 = left, 1 = up
							if block.walls[wallindex]
							and bv[n] < halfWorldBlockSize[n]
							then
								local distsq
								--if n == 2 then	--min side, n=2, that means we're the floor ...
								--	distsq = (halfWorldBlockSize[n] - bv[n] + halfWorldBlockSize[n] - doorsize)^2 / (halfWorldBlockSize[n] * halfWorldBlockSize[n])
								--else
									distsq = (halfWorldBlockSize[n] - bv[n])^2 / (halfWorldBlockSize[n] * halfWorldBlockSize[n])
								--end
								lensq += distsq
							end
							if nbhdblocks[n]
							and nbhdblocks[n].walls[wallindex]
							and bv[n] >= halfWorldBlockSize[n]
							then
								lensq += (bv[n] - halfWorldBlockSize[n])^2 / halfWorldBlockSize[n]^2
							end
						end

						local len = math.sqrt(lensq)

						-- only allow the simplex noise to add to the isovalue, so rescale it from [-1,1] to [c,0]
						local noise = (simplexNoise2D(x/blockSize.x, y/blockSize.y)+1)*.5
						noise = .5 * noise
						len += noise

						local edgedist = 1 - 2/blockSize.x	-- 1-dimensional normalized distance of the edge

						--if (bv - (halfWorldBlockSize - vec2(0,0,doorsize))):lInfLength() < 5 then len = 1 end

						if len >= edgedist^2 then
							solidWrites += 1
							if len >= 1.5*edgedist*edgedist
							or (block.walls[dirForName.left] and x == block.pos.x * blockSize.x)
							or (block.walls[dirForName.up] and y == block.pos.y * blockSize.y)
							or (nbhdblocks.x and nbhdblocks.x.walls[dirForName.left] and x == (block.pos.x + 1) * blockSize.x - 1)
							or (nbhdblocks.y and nbhdblocks.y.walls[dirForName.up] and y == (block.pos.y + 1) * blockSize.y - 1)
							then
								mset(x,y,mapTypeForName.solid.index)
							else
								mset(x,y,mapTypeForName.dirt.index)
							end
						end
					end
				end
				--trace('room',rx,ry,rz,'had solidWrites',solidWrites)
			end
		end
	end
	timeprint("done")

-- [[
	local grassBlocks = table()
	timeprint("building grass")
	for rx=room.min.x,room.max.x do
		for ry=room.min.y,room.max.y do
			local rv = vec2(rx,ry)

			-- for every room, look at the neighbors ...
			-- if it has a neighbor on one side then

			local block = world.blocks[rx]?[ry]
			if block and block.room == room then
				for by=0,blockSize.y-1 do
					for bx=0,blockSize.x-1 do
						local x = rx * blockSize.x + bx
						local y = ry * blockSize.y + by
						local typ = mapTypes[mget(x,y+1)]
						local tyn = mapTypes[mget(x,y-1)]
						local grows = typ?.grows or tyn?.grows
						if mget(x,y) == mapTypeForName.empty.index
						and grows
						and simplexNoise2D(
							tonumber(x)/tonumber(blockSize.x)+1001,
							tonumber(y)/tonumber(blockSize.y)+1001
						) > .01
						-- and place it randomly
						then
							mset(x,y, grows)
							grassBlocks:insert(vec2(x,y))
						end
					end
				end
			end
		end
	end

	local dirindexes = table()
	for i=0,3 do dirindexes:insert((i&1)+2) end	-- add some x dir growth
	for i=4,9 do dirindexes:insert((i&1)+0) end	-- add more y dir growth

	for i=1,#grassBlocks * 4 do
		local r = grassBlocks:remove(math.random(#grassBlocks))
		if not r then break end

		local randdir = table()
		for i=1,#dirindexes do
			randdir:insert(dirindexes:remove(math.random(#dirindexes)))
		end
		dirindexes = randdir

		for _,dirindex in ipairs(dirindexes) do
			local n = r + dirvecs[dirindex]
			local blocktype = mget(n:unpack())
			if blocktype == mapTypeForName.empty.index
			--or blocktype == mapTypeForName.dirt.index	-- grass grows into dirt? nah?
			then
				if mget(n.x,n.y-1) ~= 0
				or mget(n.x,n.y+1) ~= 0
				then
					mset(n.x, n.y, mget(r.x, r.y))
					grassBlocks:insert(n)
					break
				end
			end
		end
	end
--]]

	timeprint("done")
end

local roomGenVoxels = |world, room| do
	assert(world)
	assert(room)

	for _,block in ipairs(room.blocks) do
		block.color = room.color:clone()
	end

	-- room gen methods:
	levelInitSimplexRoom(world, room)
	--levelInitRoom(level)

	-- NOTICE do this after all doors have been spawned off a room, or else it won't carve them out correctly
	levelCarveDoors(world, room)

	return level
end

------------------------------------------------ enemy gen ------------------------------------------------

local roomAddEnemies = |world, room| do

	for _,block in ipairs(room.blocks) do
		local numspawns = 1
		for i=1,numspawns do

			local found
			local pos
			for try=1,10 do
				pos = ((block.pos + vec2(math.random(), math.random())) * blockSize):floor()

				-- TODO test entire bounds of the desired type ... and keep them out of doors too
				local blocktype = mget(pos:unpack())
				if blocktype == 0 then
					found = true
					break
				end
			end

			if not found then
				trace("failed to find spawn point for enemy")
			else
				block.spawns:insert{
					class=assert(Shooter),
					pos=pos,
					--[[
					how to do enemy + color ...
					if color absorbs ...
					we dont want the first enemy to absorb anythign ...
					should I separate absorb-color versus shot-color?
					then first enemy will have no absorb-color ... and no shot color?
					--]]
					--selWeapon = math.random(0,room.maxKeyIndex),
				}
			end
		end
	end
end

------------------------------------------------ world gen ------------------------------------------------

-- TODO as you're building the room, constrain the area the room covers to maxWorldBlocksPerLevel ??? or forget about maxWorldBlocksPerLevel
local mapBuildRoomFrom = |world, room, keyIndex| do
trace('mapBuildRoomFrom begin')
	keyIndex = keyIndex or 0

	local newroom = WorldRoom()
	world.rooms:insert(newroom)

	local roomwalls = table()
	for _,block in ipairs(room.blocks) do
		for ni,n in ipairs(vec2.fields) do
			local wallindex = 5-2*ni	-- 1 = x, 2 = y ...maps to... 3 = left, 1 = up
			local nextblockpos = block.pos:clone()
			nextblockpos[n] -= 1
			if nextblockpos[n] >= 0 then
				if block.walls[wallindex]
				and not block['door'..n]
				then
					roomwalls:insert{
						pos=block.pos,
						axis=n,
						minmax=0,
						nextpos=nextblockpos,
					}
				end
			end

			local nextblockpos = block.pos:clone()
			nextblockpos[n] += 1
			local nextblock
			if nextblockpos[n] < worldSizeInBlocks[n] then
				nextblock = world.blocks[nextblockpos.x]?[nextblockpos.y]
			end

			-- only if we have a wall with no door that doesn't belong to a room
			if nextblock
			and nextblock.walls[wallindex]
			and not nextblock['door'..n]
			and not nextblock.room
			then
				roomwalls:insert{
					pos=block.pos,
					axis=n,
					minmax=1,
					nextpos=nextblockpos,
				}
			end
		end
	end

	if #roomwalls == 0 then
		error('ran out of walls to build off of ... done!')
		return
	end

	local wall = roomwalls:pickRandom()
	local blockPos = wall.nextpos
	local block = world.blocks[blockPos.x]?[blockPos.y]
	if not block then
		error("failed to create new block ... blockPos went OOB: "..blockPos)
	end
	assert(not block.room, "can't extend into that block, it already has a room!")

	-- put a door between them
	if wall.minmax == 0 then
		-- ?[]= is an expression not a statement and therefore needs to be assigned or passed to something
		local _ = world.blocks[wall.pos.x]?[wall.pos.y]?['door'..wall.axis] = keyIndex
	else
		local _ = world.blocks[wall.nextpos.x]?[wall.nextpos.y]?['door'..wall.axis] = keyIndex
	end


	local F, Finv
	do
		F = |x| 69/259 * math.log(x)
		Finv = |x| math.exp(x)^(259/69)
	end
	local roomminsize = 1
	--local roommaxsize = 50
	local roommaxsize = 5
	local roomsize = math.ceil(Finv(F(roomminsize-.99) + math.random() * (F(roommaxsize-.01) - F(roomminsize-.99))))

	for i=1,roomsize do
		newroom:addblock(block)

		local nbhdoptions = table()

		-- TODO why is minmax -1/1 here and 0/1 elsewhere ...
		for minmax=-1,1,2 do
			for axisindex,axis in ipairs(vec2.fields) do
				local wallindex = 5-2*axisindex	-- 1 = x, 2 = y ...maps to... 3 = left, 1 = up
				local nbhdpos = block.pos:clone()
				nbhdpos[axis] += minmax
				if nbhdpos[axis] >= 0
				and nbhdpos[axis] < worldSizeInBlocks[axis]
				then

					local nbhdblock = world.blocks[nbhdpos.x]?[nbhdpos.y]
					if not nbhdblock
					or nbhdblock.room == nil
					then
						if minmax == -1 then
							block.walls[wallindex] = true
						else
							-- positive, but the wall might not be there ...
							if not nbhdblock then
								nbhdblock = world.blocks[nbhdpos.x]?[nbhdpos.y]
							end
							nbhdblock.walls[wallindex] = true
						end
					end
					if nbhdblock and nbhdblock.room == block.room then	-- remove walls between worldblocks in the same room
						if minmax == -1 then
							block.walls[wallindex] = false
						else
							nbhdblock.walls[wallindex] = false
						end
					end
					if not nbhdblock or nbhdblock.room == nil then
						nbhdoptions:insert(nbhdpos:clone())
					end
				end
			end
		end
		-- TODO weight nbhdoptions towards the last moved direction

		-- now step in a random direction

		if i == roomsize then break end	-- come around for another pass

		if #nbhdoptions == 0 then
			timeprint("room ran out of options -- breaking out")
			break
		end

		local nbhdpos = nbhdoptions:pickRandom()
		blockPos = nbhdpos:clone()

		-- why are we giving away rooms already owned?
		local oldblock = world.blocks[blockPos.x]?[blockPos.y]
		if oldblock and oldblock.room then
			error("ERROR -- giving away room...")
		end

		block = world.blocks[blockPos.x]?[blockPos.y]
	end

	return newroom
end

local mapAddBlockWalls = |world, block|do
	for minmax=0,1 do
		for ni,n in ipairs(vec2.fields) do
			local wallindex = 5-2*ni	-- 1 = x, 2 = y ...maps to... 3 = left, 1 = up
			local wallblockpos = block.pos:clone()
			wallblockpos[n] += minmax
			local wallblock = world.blocks[wallblockpos.x]?[wallblockpos.y]
			local roomblockpos = block.pos:clone()
			roomblockpos[n] += minmax * 2 - 1
			local roomblock = world.blocks[roomblockpos.x]?[roomblockpos.y]
			-- if the rooms match then clear the wall
			if roomblock and roomblock.room == block.room then
				if wallblock then
					wallblock.walls[wallindex] = false
				end
			else	-- otherwise set the wall
				if not wallblock then
					wallblock = world.blocks[wallblockpos.x]?[wallblockpos.y]
					--if not wallblock then
					--	error("failed to create block at pos "..tostring(wallblockpos))
					--end
				end
				if wallblock then
					wallblock.walls[wallindex] = true
				end
			end
		end
	end
end

local generateWorld = |dir| do

	timeprint('generateWorld')

	local world = World()

	local center = (worldSizeInBlocks / 2):floor()
	local roomsize = vec2(1,1)	--vec2(2,2)	--maxWorldBlocksPerLevel / 2
	local roommin = (center - roomsize / 2):ceil()
	local roommax = roommin + roomsize - 1

	local room = WorldRoom()
	world.rooms:insert(room)
	world.startroom = room
	room.color = pickRandomColor()

	-- iterate one past the max (for adding doors to the max side)
	for y=roommin.y,roommax.y do
		for x=roommin.x,roommax.x do
			local block = world.blocks[x]?[y] or error("failed to get block at "..vec2(x,y))
			room:addblock(block)
			mapAddBlockWalls(world, block)
		end
	end

	-- add voxels
	--trace('roomGenVoxels',room)
	--roomGenVoxels(world, world.startroom)
	-- add enemies ... not in the first room

	--local numrooms = 10	-- num rooms to next item
	--local numrooms = 3 -- num rooms to next item
	local numrooms = 2 -- num rooms to next item

	-- add rooms to missile tank
	keyIndex = 0
	do
		local currentRoom = assert.index(world, 'startroom')
		for i=1,numrooms do
			local nextRoom = mapBuildRoomFrom(world, currentRoom, keyIndex)
			if nextRoom then
				nextRoom.maxKeyIndex = keyIndex
				nextRoom.color = advanceColor(currentRoom.color)
				currentRoom = nextRoom
				keyIndex = 0
			end
		end

		-- now add a goal-item in the middle of lastblock ...
		local lastblock = currentRoom.blocks:last()
		lastblock.spawns:insert{
			pos=(lastblock.pos + .5) * blockSize,
			class=assert(Weapon),
			weapon=keyIndex+1,
		}
		-- and carve out area around the missileitem
	end

	-- and rooms to next item
	while keyIndex < 5 do
		keyIndex += 1
		local currentRoom = assert.index(
			world.rooms,
			math.random(math.ceil(#world.rooms/2)),
			"starting room to next item -- couldn't find a room to start at!"
		)
		for i=1,numrooms do
			local nextRoom = mapBuildRoomFrom(world, currentRoom, keyIndex)
			nextRoom.maxKeyIndex = keyIndex
			nextRoom.color = advanceColor(currentRoom.color)
			currentRoom = nextRoom
			if i < numrooms then
				assert(currentRoom, "mapBuildRoomFrom didn't return a room!")
			end
		end

		-- now add a goal-item in the middle of lastblock ...
		local lastblock = currentRoom.blocks:last()
		lastblock.spawns:insert{
			pos=(lastblock.pos + .5) * blockSize,
			class=assert(Weapon),
			weapon=keyIndex+1,
		}
		-- and carve out area around the missileitem
	end

	-- leave keyIndex at its max so we can generate keyColors

	for _,room in ipairs(world.rooms) do
		-- add voxels after all doors are defined (so they can carve around doors correctly
		trace('roomGenVoxels',room)
		roomGenVoxels(world, room)
		-- ... should we add enemies first then carve around them?
		if room ~= world.startroom then
			roomAddEnemies(world, room)
		end
	end

	--colorVoxels(world)

	-- create player ...
	local startBlock = room.blocks:last()
	player = Player{pos=(startBlock.pos + .5) * blockSize}

	startBlock.spawns:insert{
		pos=player.pos + vec2(0,-2),
		class=assert(Weapon),
		weapon=0,
	}

	return world
end

--]====]
