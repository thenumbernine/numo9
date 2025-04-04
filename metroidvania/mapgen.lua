--#include ext/range.lua
--#include vec/vec2.lua
--#include simplexnoise/2d.lua
--[[ procedural level
reads:
	dirvecs, opposite
	blockSize, worldSizeInBlocks
	mapTypeForName
writes:
	blocks
	keyIndex
	keyColors
	...the tilemap
--]]
--[====[ old system, guarantees every block is filled, but not so good at what goes where...
generateWorld=[]do
	for y=0,255 do
		for x=0,255 do
			mset(x,y,1)	-- solid
		end
	end

	blocks = range(0,worldSizeInBlocks.x-1):mapi([i]
		(range(0,worldSizeInBlocks.y-1):mapi([j]
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
	local start = (worldSizeInBlocks / 2):floor()
	local startroom = blocks[start.x][start.y]
	startroom.set = true
	posinfos:insert{pos=startroom.pos}
	while #posinfos > 0 do
		local posinfoindex = math.random(1, #posinfos)
		local pos = posinfos[posinfoindex].pos
		local srcroom = blocks[pos.x][pos.y]
		local validDirs = dirvecs:mapi([dir, dirindex, t] do
			local nbhdpos = pos + dir
			if nbhdpos.x >= 0 and nbhdpos.x < worldSizeInBlocks.x
			and nbhdpos.y >= 0 and nbhdpos.y < worldSizeInBlocks.y
			then
				local nextroom = blocks[nbhdpos.x][nbhdpos.y]
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
			local nextroom = blocks[nbhdpos.x][nbhdpos.y]
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
					pos=(nextroom.pos + .5)*blockSize,
				}
			else
				nextroom.spawns:insert{
					class=Health,
					pos=(nextroom.pos + .5)*blockSize,
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
						pos=(nextroom.pos + .5)*blockSize,
						keyIndex = keyIndex,
					}
				end
			end
		end
	end

	for i=0,worldSizeInBlocks.x-1 do
		for j=0,worldSizeInBlocks.y-1 do
			local room = blocks[i][j]

			-- [=[
			for dirindex,dir in ipairs(dirvecs) do
				if room.dirs[dirindex] and not room.doors[dirindex]
				and room.dirs[opposite[dirindex]] and not room.doors[opposite[dirindex]]
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
			for dirindex,dir in ipairs(dirvecs) do
				if room.dirs[dirindex] then
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
					local doorKey = room.doors[dirindex]
					if doorKey then
						room.doorKey ??= {}
						for y=0,2*w-1 do
							local mx = math.floor(i * blockSize.x + blockSize.x * .5 + dir.x * (xmax - .5) + dir.y * (y + .5 - w))
							local my = math.floor(j * blockSize.y + blockSize.y * .5 + dir.y * (xmax - .5) - dir.x * (y + .5 - w))
							room.doorKey[mx % blockSize.x] ??= {}
							room.doorKey[mx % blockSize.x][my % blockSize.y] = doorKey
							mset(mx, my, mapTypeForName.door.index)
						end
					end
				end
			end
			--]]

			for ofs=-1,0 do
				mset(
					math.floor((i + .5) * blockSize.x + ofs),
					math.floor((j + .5) * blockSize.y + 1),
					1
				)
			end

		end
	end
	trace'====='
	for dj=0,worldSizeInBlocks.y*3-1 do
		trace(range(0,worldSizeInBlocks.x*3-1):mapi([di] do
			local i = tonumber(di // 3)
			local j = tonumber(dj // 3)
			local u = (di % 3) - 1
			local v = (dj % 3) - 1
			local room = blocks[i][j]
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

	local sx,sy = ((start.x + .5) * blockSize):floor():unpack()
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
	for i=1,worldSizeInBlocks.x-1 do
		for j=1,worldSizeInBlocks.y-1 do
			-- for each
			local empty = 0
			for _,dir in ipairs(dirvecs) do
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
end
--]====]
-- [====[ new (really older) system, based on my old voxel-metroidvania zeta3d game ...

local doorsize = 4		-- diameter
local doorthickness = 2	-- short axis ... not yet implemented ...

local WorldBlock = class()
WorldBlock.init = [:,x,y]do
	self.pos = vec2(x,y)
	self.spawns = table()
	self.walls = table()	-- index corresponds with dirvecs' index
	self.doors = table()	-- same
	self.color = pickRandomColor()
	self.seen = 0	-- luminance
	--self.doorKeys = {}		-- table for door offsets <_> has what key they are
	-- also has fields wallx wally doorx doory ... TODO replace that with dirs[] and doors[] ? or nah? idk?
trace('creating new WorldBlock at '..self.pos)
end

local WorldRoom = class()
WorldRoom.init=[:]do
	self.blocks = table()
trace('creating new WorldRoom')
end
WorldRoom.addblock=[:,block]do
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
World.init=[:]do
	self.blocks = range(0,worldSizeInBlocks.x-1):mapi([i]
		(range(0,worldSizeInBlocks.y-1):mapi([j]
			(WorldBlock(i,j), j)
		), i)
	)

	self.rooms = table()	-- list of rooms, rooms are collections of blocks
	--self.startroom = start room
end

local timeprint
do
	local lasttime
	timeprint = [...] do
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

local levelCarveDoors = [world, room] do
	local placeDoor = [x, y, n, keyIndex] do
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

local fillBlock = [rx,ry,index] do
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

local levelInitSimplexRoom = [world, room] do
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
						for _,n in ipairs(vec2.fields) do
							if block['wall'..n] and bv[n] < halfWorldBlockSize[n] then
								local distsq
								--if n == 2 then	--min side, n=2, that means we're the floor ...
								--	distsq = (halfWorldBlockSize[n] - bv[n] + halfWorldBlockSize[n] - doorsize)^2 / (halfWorldBlockSize[n] * halfWorldBlockSize[n])
								--else
									distsq = (halfWorldBlockSize[n] - bv[n])^2 / (halfWorldBlockSize[n] * halfWorldBlockSize[n])
								--end
								lensq += distsq
							end
							if nbhdblocks[n]
							and nbhdblocks[n]['wall'..n]
							and bv[n] >= halfWorldBlockSize[n]
							then
								lensq += (bv[n] - halfWorldBlockSize[n])^2 / halfWorldBlockSize[n]^2
							end
						end

						local len = math.sqrt(lensq)

						-- double-influences aren't visible since the single-influences go up to the wall
						-- which means we have hard edges at walls

						--[[
						-- triple influences:
						-- for each pertrusion +/- in each axis ...
						for nxminmax=0,1 do
							for nyminmax=0,1 do
								local nminmaxs = vec2(nxminmax, nyminmax)

								-- if (for all n) axis n offset by minmax[n] has walls on the minmax[n1] and minmax[n2] sides
								-- then round this corner
								for _,n in ipairs(vec2.fields) do
									local n1 = n == 'x' and 'y' or 'x'
									local wallblockpos = vec2(rx,ry)
									wallblockpos[n] += nminmaxs[n]

									-- first make sure there's no wall on the n'th axis
									local wallblock = world.blocks[wallblockpos.x]?[wallblockpos.y]
									if not (wallblock and wallblock['wall'..n]) then
										-- now make sure there are walls on its n1 and n2'th axii

										-- get the pos of the non-wall'd side
										local roomblockpos = vec2(rx,ry)
										roomblockpos[n] += nminmaxs[n]*2-1

										-- get its n1'th and n2'th wall

										local wall1blockpos = roomblockpos:clone()
										wall1blockpos[n1] += nminmax[n1]

										local wall1block = world.blocks[wall1blockpos.x]?[wall1blockpos.y]

										if wall1block and wall1block['wall'..n1] then

											-- ... then we put a curved corner at the nminmaxs corner of rx,ry,rz

											local cornerlensq = 0
											for _,n in ipairs(vec2.fields) do
												if nminmaxs[n] == 0 then
													cornerlensq += (rv[n]/halfWorldBlockSize[n])^2
												else
													cornerlensq += ((blockSize[n] - rv[n])/halfWorldBlockSize[n])^2
												end
											end
											if cornerlensq >
										end
									end

									local n1 = (n+1)%3
									-- if offset n wall n1 is solid and offset n1 wall n is solid then add our round edge between the two
									if minsidesolid[n] and bv[n] < halfWorldBlockSize[n]
									and minsidesolid[n+1] and bv:ptr[n] < halfWorldBlockSize[n+1]
									then
										todo ...
									end
								end
							end
						end
						--]]

						-- only allow the simplex noise to add to the isovalue, so rescale it from [-1,1] to [c,0]
						local noise = (simplexNoise2D(x/blockSize.x, y/blockSize.y)+1)*.5
						noise = .5 * noise
						len += noise

						local edgedist = 1 - 2/blockSize.x	-- 1-dimensional normalized distance of the edge

						--if (bv - (halfWorldBlockSize - vec2(0,0,doorsize))):lInfLength() < 5 then len = 1 end

						if len >= edgedist^2 then
							solidWrites += 1
							if len >= 1.5*edgedist*edgedist
							or (block.wallx and x == block.pos.x * blockSize.x)
							or (block.wally and y == block.pos.y * blockSize.y)
							or (nbhdblocks.x and nbhdblocks.x.wallx and x == (block.pos.x + 1) * blockSize.x - 1)
							or (nbhdblocks.y and nbhdblocks.y.wally and y == (block.pos.y + 1) * blockSize.y - 1)
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
	for i=1,4 do dirindexes:insert((i&1)+3) end	-- add some x dir growth
	for i=5,10 do dirindexes:insert((i&1)+1) end	-- add more y dir growth

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

--[=[
local levelInitRoom = [level] do
	local world, room = level.world, level.room
	for rx=room.min.x,room.max.x do
		for ry=room.min.y,room.max.y do
			for rz=room.min.z,room.max.z do
				local rv = vec2(rx,ry,rz)

				local block = world.blocks[rx]?[ry]
				if block and block.room == room then

					-- for each side ...
					-- if it's a wall ...
					-- seal it off

--[[
					for m=0,1 do
						for n=0,2 do
							local wallpos = vec2():set(rv)
							wallpos[n] = wallpos[n] + m

							local wallblock = world.blocks[wallpos.x]?[wallpos.y]
							if not wallblock or wallblock['wall'..n] then

								local wallthickness = blockSize[n] / 6

								local n1 = (n+1)%3
								local n2 = (n+2)%3
								for u=0,blockSize[n1]-1 do
									for v=0,blockSize[n2]-1 do
										for w=0,wallthickness-1 do
											local x = vec2()
											if m == 0 then
												x[n] = w
											else
												x[n] = blockSize[n] - 1 - w
											end
											x[n1] = u
											x[n2] = v
											x = x + rv * blockSize
											level:writeget(x.x, x.y, x.z).type = ffi.C.BLOCK_solid
										end
									end
								end
							end
						end
					end
--]]

--[[
					-- add some random platforms
					local platformSize = 2
					for platform=1,5 do
						local px = math.random(blockSize.x-platformSize)-1
						local py = math.random(blockSize.y-platformSize)-1
						local pz = math.random(blockSize.z)-1

						for x=0,platformSize-1 do
							for y=0,platformSize-1 do
								for z=0,math.ceil(platformSize/2)-1 do
									level:writeget(
										rv.x * blockSize.x + px + x,
										rv.y * blockSize.y + py + y,
										rv.z * blockSize.z + pz + z).type = ffi.C.BLOCK_solid
								end
							end
						end
					end
--]]
				end
			end
		end
	end
end
--]=]

local roomGenVoxels = [world, room] do
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

local roomAddEnemies = [world, room] do

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
					class=assert(Enemy),
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
local mapBuildRoomFrom = [world, room, keyIndex] do
trace('mapBuildRoomFrom begin')
	keyIndex = keyIndex or 0

	local newroom = WorldRoom()
	world.rooms:insert(newroom)

	local roomwalls = table()
	for _,block in ipairs(room.blocks) do
		for _,n in ipairs(vec2.fields) do

			local nextblockpos = block.pos:clone()
			nextblockpos[n] -= 1
			if nextblockpos[n] >= 0 then
				if block['wall'..n] and not block['door'..n] then
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
			and nextblock['wall'..n]
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

	-- put a door between them
	if wall.minmax == 0 then
		-- ?[]= is an expression not a statement and therefore needs to be assigned or passed to something
		local _ = world.blocks[wall.pos.x]?[wall.pos.y]?['door'..wall.axis] = keyIndex
	else
		local _ = world.blocks[wall.nextpos.x]?[wall.nextpos.y]?['door'..wall.axis] = keyIndex
	end


	local F, Finv
	do
		F = [x] 69/259 * math.log(x)
		Finv = [x] math.exp(x)^(259/69)
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
			for _,axis in ipairs(vec2.fields) do
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
							block['wall'..axis] = true
						else
							-- positive, but the wall might not be there ...
							if not nbhdblock then
								nbhdblock = world.blocks[nbhdpos.x]?[nbhdpos.y]
							end
							nbhdblock['wall'..axis] = true
						end
					end
					if nbhdblock and nbhdblock.room == block.room then	-- remove walls between worldblocks in the same room
						if minmax == -1 then
							block['wall'..axis] = nil
						else
							nbhdblock['wall'..axis] = nil
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

local mapAddBlockWalls = [world, block]do
	for minmax=0,1 do
		for _,n in ipairs(vec2.fields) do
			local wallblockpos = block.pos:clone()
			wallblockpos[n] += minmax
			local wallblock = world.blocks[wallblockpos.x]?[wallblockpos.y]
			local roomblockpos = block.pos:clone()
			roomblockpos[n] += minmax * 2 - 1
			local roomblock = world.blocks[roomblockpos.x]?[roomblockpos.y]
			-- if the rooms match then clear the wall
			if roomblock and roomblock.room == block.room then
				if wallblock then
					wallblock['wall'..n] = nil
				end
			else	-- otherwise set the wall
				if not wallblock then
					wallblock = world.blocks[wallblockpos.x]?[wallblockpos.y]
					--if not wallblock then
					--	error("failed to create block at pos "..tostring(wallblockpos))
					--end
				end
				if wallblock then
					wallblock['wall'..n] = true
				end
			end
		end
	end
end

local generateWorld = [dir] do

	timeprint('generateWorld')

	local world = World()

	local center = worldSizeInBlocks / 2	-- floor too?
	local roomsize = vec2(2,2)	--maxWorldBlocksPerLevel / 2
	local roommin = center - roomsize / 2
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
