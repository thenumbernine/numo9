--#include vec/vec2.lua
--#include vec/box2.lua
--#include ext/class.lua
--#include ext/range.lua

math.randomseed(tstamp())

local sprites = {
	player = 0,
	enemy = 2,
	heart = 64,
	--hearthalf = 66,
	key = 66,
}

flagshift=table{
	'solid',	-- 1
}:mapi([k,i] (i-1,k)):setmetatable(nil)
flags=table(flagshift):map([v] 1<<v):setmetatable(nil)

mapTypes=table{
	[0]={name='empty'},				-- empty
	[2]={name='solid',flags=flags.solid},	-- solid
	[4]={
		name='chest',
		flags=flags.solid,
		touch = [:, o, x, y]do
			if o == player then
				mset(x,y,mapTypeForName.chest_open.index)
				player.keys += 1
			end
		end,
	},
	[6]={
		name='chest_open',
		flags=flags.solid,
	},
	[8]={
		name='door',
		flags=flags.solid,
		touch = [:, o, x, y]do
			if o == player then
				mset(x,y,mapTypeForName.empty.index)
			end
		end,
	},
	[10]={
		name='locked_door',
		flags=flags.solid,
		touch = [:, o, x, y]do
			if o == player
			and o.keys > 0
			then
				o.keys -= 1
				mset(x,y,mapTypeForName.door.index)
			end
		end,
	},
	[64]={name='spawn_player'},
	[66]={name='spawn_enemy'},
}
for k,v in pairs(mapTypes) do
	v.index = k
	v.flags ??= 0
end
mapTypeForName = mapTypes:map([v,k] (v, v.name))

mainloops=table()

--#include ext/class.lua

local mapwidth = 256
local mapheight = 256
objs=table()

Object=class()
Object.pos = vec2()
Object.vel = vec2()
Object.bbox = {min=vec2(-.3), max=vec2(.3)}
Object.init=[:,args]do
	for k,v in pairs(args) do self[k]=v end
	self.pos = self.pos:clone()
	self.vel = self.vel:clone()
	self.health = self.maxHealth
	objs:insert(self)
end
Object.update=[:]do
	-- draw
	spr(
		self.sprite,
		(self.pos.x - .5) * 16,
		(self.pos.y - .5) * 16,
		2, 2)

	-- move

	for bi=0,1 do	-- move horz then vert, so we can slide on walls or something
		local dx,dy = 0, 0
		if bi == 0 then
			dy = self.vel.y
		elseif bi == 1 then
			dx = self.vel.x
		end
		if dx ~= 0 or dy ~= 0 then
			local nx = self.pos.x + dx
			local ny = self.pos.y + dy
			local px1 = nx + self.bbox.min.x
			local py1 = ny + self.bbox.min.y
			local px2 = nx + self.bbox.max.x
			local py2 = ny + self.bbox.max.y
			local hit
			for by1=math.clamp(math.floor(py1), 0, mapheight-1), math.clamp(math.ceil(py2), 0, mapheight-1) do
				for bx1=math.clamp(math.floor(px1), 0, mapwidth-1), math.clamp(math.ceil(px2), 0, mapwidth-1) do
					local bx2, by2 = bx1 + 1, by1 + 1
					local ti = mget(bx1, by1)
					local t = mapTypes[ti]
					if t
					and px2 >= bx1 and px1 <= bx2
					and py2 >= by1 and py1 <= by2
					then
						-- do map hit
						if t.flags & flags.solid ~= 0 then
							hit = true
						end
						t?:touch(self, bx1, by1)
					end
				end
			end
			for _,o in ipairs(objs) do
				if o ~= self then
					local bx1, by1 = o.pos.x + o.bbox.min.x, o.pos.y + o.bbox.min.y
					local bx2, by2 = o.pos.x + o.bbox.max.x, o.pos.y + o.bbox.max.y
					if px2 >= bx1 and px1 <= bx2
					and py2 >= by1 and py1 <= by2
					then
						-- if not solid then
						hit = true
						self?:touch(o)
						o?:touch(self)
					end
				end
			end
			if not hit then
				self.pos:set(nx, ny)
				-- TODO bomberman slide ... if you push down at a corner then push player left/right to go around it ...
			end
		end
	end
end

TakesDamage=Object:subclass()
TakesDamage.maxHealth=1
TakesDamage.takeDamageTime = 0
TakesDamage.takeDamageInvincibleDuration = 1
TakesDamage.takeDamage=[:,damage]do
	if time() < self.takeDamageTime then return end
	self.takeDamageTime = time() + self.takeDamageInvincibleDuration
	self.health -= damage
	if self.health <= 0 then self:die() end
end
TakesDamage.die=[:]do
	self.dead = true
	self.removeMe = true
end

Player=TakesDamage:subclass()
Player.sprite=sprites.player
Player.maxHealth=3
Player.keys=0
Player.update=[:]do

	self.vel:set(0,0)

	local speed = .1
	if btn'up' then self.vel.y -= speed end
	if btn'down' then self.vel.y += speed end
	if btn'left' then self.vel.x -= speed end
	if btn'right' then self.vel.x += speed end
	if btn'y' then self:attack() end

	Player.super.update(self)	-- draw and move
end

Player.attackTime = 0
Player.attackDelay = .3
Player.attackDist = 2
--Player.attackCosAngle = .5
Player.attackDamage = 1
Player.attack=[:]do
	if time() < self.attackTime then return end
	self.attackTime = time() + self.attackDelay
	mainloops:insert([]do
		elli((self.pos.x - self.attackDist)*16, (self.pos.y - self.attackDist)*16, 32*self.attackDist, 32*self.attackDist, 3)
	end)
	for _,o in ipairs(objs) do
		if o ~= self then
			local delta = o.pos - self.pos
			if delta:lenSq() < self.attackDist^2 then
				o:takeDamage(self.attackDamage)
			end
		end
	end
end

Enemy=TakesDamage:subclass()
Enemy.sprite=sprites.enemy
Enemy.attackDist = 3
Enemy.speed = .05
Enemy.update=[:]do
	self.vel:set(0,0)

	if player then
		local delta = player.pos - self.pos
		local deltaLenSq = delta:lenSq()
		if deltaLenSq < self.attackDist^2 then
			local dir = delta / math.max(1e-15, math.sqrt(deltaLenSq))
			self.vel = dir * self.speed
		end
	end

	Enemy.super.update(self)
end
Enemy.touch=[:,o]do
	if o == player then
		player:takeDamage(1)
	end
end

-- stole from stupid/code.lua
range=[a,b,c]do
	local t = table()
	if c then
		for x=a,b,c do t:insert(x) end
	elseif b then
		for x=a,b do t:insert(x) end
	else
		for x=1,a do t:insert(x) end
	end
	return t
end

-- stole from stupid/code.lua
local randomBoxPos=[box] vec2(math.random(box.min.x,box.max.x),math.random(box.min.y,box.max.y))
local genDungeonLevel=[avgRoomSize]do
	avgRoomSize ??= 20
	local targetMap = {}
	targetMap.size = vec2(32,32)
	targetMap.tiles = range(0,targetMap.size.y-1):mapi([i]
		(range(0,targetMap.size.x-1):mapi([j]
			({}, j)
		), i)
	)
	targetMap.bbox = box2(vec2(), targetMap.size-1)
	targetMap.wrapPos=[:,pos]do
		pos.y = math.floor(pos.y)
		pos.x = math.floor(pos.x)
		if self.wrap then
			pos.y = ((pos.y % self.size.y) + self.size.y) % self.size.y
			pos.x = ((pos.x % self.size.x) + self.size.x) % self.size.x
		else
			if pos.x < 0 or pos.y < 0
			or pos.x >= self.size.x or pos.y >= self.size.y
			then
				return false
			end
		end
		return true
	end
	targetMap.getTile=[:,x,y]do
		local pos = vec2(x,y)
		if not self:wrapPos(pos) then return end
		local t = self.tiles[pos.y][pos.x]
		t.solid = mapTypes[mget(x,y)].flags & flags.solid ~= 0
		return t
	end
	targetMap.setTileType=[:,x,y,mapType]do
		local pos = vec2(x,y)
		if not self:wrapPos(pos) then return end
		--local tile = mapType(pos)
		--self.tiles[pos.y][pos.x] = tile
		mset(pos.x,pos.y,mapType)--assert(table.pickRandom(tileTypes![tileType.name].tileIndexes)))
		return tile
	end

	local rooms = table()

	--trace("begin gen "+targetMap.name)

	local max = math.floor(targetMap.size.x * targetMap.size.y / avgRoomSize)
	for i=1,max do
		local room = {pos=randomBoxPos(targetMap.bbox)}
		room.bbox = box2(room.pos, room.pos)
		rooms:insert(room)
		targetMap.tiles[room.pos.y][room.pos.x].room = room
	end

	local modified
	repeat
		modified=false
		for j,room in ipairs(rooms) do
			local bbox = box2(room.bbox.min-1, room.bbox.max+1):clamp(targetMap.bbox)
			local roomcorners = {room.bbox.min, room.bbox.max}
			local corners = {bbox.min, bbox.max}
			for i,corner in ipairs(corners) do
				local found = false
				for y=room.bbox.min.y,room.bbox.max.y do
					if targetMap.tiles[y][corner.x].room then
						found = true
						break
					end
				end
				if not found then
					for y=room.bbox.min.y,room.bbox.max.y do
						targetMap.tiles[y][corner.x].room = room
					end
					roomcorners[i].x = corner.x
					modified = true
				end

				found = false
				for x=room.bbox.min.x,room.bbox.max.x do
					if targetMap.tiles[corner.y][x].room then
						found = true
						break
					end
				end
				if not found then
					for x=room.bbox.min.x,room.bbox.max.x do
						targetMap.tiles[corner.y][x].room = room
					end
					roomcorners[i].y = corner.y
					modified = true
				end
			end
		end
	until not modified

	--clear tile rooms for reassignment
	for y=0,targetMap.size.y-1 do
		for x=0,targetMap.size.x-1 do
			targetMap.tiles[y][x].room = nil
		end
	end

	--carve out rooms
	--console.log("carving out rooms")
	for i=#rooms,1,-1 do
		local room = rooms[i]
		room.bbox.min.x+=1
		room.bbox.min.y+=1

		--our room goes from min+1 to max-1
		--so if that distance is zero then we have no room
		local dead = (room.bbox.min.x > room.bbox.max.x) or (room.bbox.min.y > room.bbox.max.y)
		if dead then
			rooms:remove(i)
		else
			for y=room.bbox.min.y,room.bbox.max.y do
				for x=room.bbox.min.x,room.bbox.max.x do
					targetMap:setTileType(x,y,mapTypeForName.empty.index)
				end
			end

			--rooms
			for y=room.bbox.min.y,room.bbox.max.y do
				for x=room.bbox.min.x,room.bbox.max.x do
					targetMap.tiles[y][x].room = room
				end
			end
		end
	end


	local dimfields = {'x','y'}
	local minmaxfields = {'min','max'}
	--see what rooms touch other rooms
	--trace("finding neighbors")
	local pos = vec2()
	for _,room in ipairs(rooms) do
		room.neighbors = table()
		for dim,dimfield in ipairs(dimfields) do
			local dimnextfield = dimfields[dim%2+1]
			for minmax,minmaxfield in ipairs(minmaxfields) do
				local minmaxofs = minmax * 2 - 3
				pos[dimfield] = room.bbox[minmaxfield][dimfield] + minmaxofs
				for tmp=room.bbox.min[dimnextfield]+1,room.bbox.max[dimnextfield]-1 do
					pos[dimnextfield]=tmp
					--step twice to find our neighbor
					local nextpos = vec2(pos)
					nextpos[dimfield] += minmaxofs
					local tile = targetMap:getTile(nextpos.x,nextpos.y)
					if tile
					and tile.room
					then
						local neighborRoom = tile.room
						local neighborRoomIndex = assert(rooms:find(neighborRoom), "found unknown neighbor room")
						local _, neighbor = room.neighbors:find(nil, [neighbor] neighbor.room == neighborRoom)
						if not neighbor then
							neighbor = {room=neighborRoom, positions=table()}
							room.neighbors:insert(neighbor)
						end
						neighbor.positions:insert(vec2(pos))
					end
				end
			end
		end
	end

	--pick a random room as the start
	--TODO start in a big room.
	local startRoom = rooms:pickRandom()
	local lastRoom = startRoom

	local leafRooms = table()
	local usedRooms = table{startRoom}

	--trace("establishing connectivity")
	while true do
		local srcRoomOptions = usedRooms:filter([room]
			--if the room has no rooms that haven't been used,then don't consider it
			--so keep all of the neighbor's neighbors that haven't been used
			--if self has any good neighbors then consider it
			#room.neighbors:filter([neighborInfo]
				not usedRooms:find(neighborInfo.room)
			) > 0
		)
		if #srcRoomOptions == 0 then break end
		local srcRoom = srcRoomOptions:pickRandom()

		local leafRoomIndex = leafRooms:find(srcRoom)
		if leafRoomIndex ~= -1 then leafRooms:remove(leafRoomIndex) end

		--self is the same filter as is within the srcRoomOptions filter -=1 so if you want to cache self info, feel free
		local neighborInfoOptions = srcRoom.neighbors:filter([neighborInfo]
			not usedRooms:find(neighborInfo.room)
		)
		local neighborInfo = neighborInfoOptions:pickRandom()
		local dstRoom = neighborInfo.room
		lastRoom = dstRoom
		--so find dstRoom in srcRoom.neighbors
		local pos = neighborInfo.positions:pickRandom()
		targetMap:setTileType(pos.x, pos.y, mapTypeForName.empty.index)
		mset(pos.x, pos.y, mapTypeForName.door.index)
		usedRooms:insert(dstRoom)
		leafRooms:insert(dstRoom)
	end

	pickFreeRandomFixedPos=[args]do
		local targetMap = args.map
		local bbox = box2(args.bbox or targetMap.bbox)
		local classify = args.classify

		for attempt=1,1000 do
			local pos = randomBoxPos(bbox)
			local tile = targetMap:getTile(pos.x, pos.y)

			local good
			if classify then
				good = classify(tile)
			else
				good = not (tile.solid or tile.water)
			end
			if good then
				return pos
			end
		end
		trace"failed to find free position"
		return vec2()
	end


	--add treasure - after stairs so they get precedence
	for _,room in ipairs(usedRooms) do
		if room ~= startRoom
		and room ~= lastRoom
		and math.random() <= .5
		then
			local pos = pickFreeRandomFixedPos{map=targetMap, bbox=room.bbox}
			mset(pos.x, pos.y, mapTypeForName.chest.index)
		end
	end

	--trace("end gen "+targetMap.name)
end


init=[]do
	reset()	-- reset rom

	--genDungeonLevel()

	objs=table()
	player = nil
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
end

local viewPos = vec2()
update=[]do
	-- hmm mode() at global level doesn't seem to work ...
	--local screenw, screenh = 256,256
	--local screenw, screenh = 336, 189 mode(18)	-- 16:9 336x189x16bpp-RGB565
	local screenw, screenh = 480, 270 mode(42)	-- 16:9 480x270x8bpp-indexed

	cls(4)
	matident()
	mattrans(screenw*.5-viewPos.x*16, screenh*.5-viewPos.y*16)
	map(0,0,256,256,0,0,0,1)

	if player then
		viewPos:set(player.pos)
	end

	for _,o in ipairs(objs) do
		o:update()
	end

	for i=#mainloops,1,-1 do
		mainloops[i]()
		mainloops[i] = nil
	end

	matident()

	-- draw gui
	if player then
		for i=1,player.health do
			spr(sprites.heart, (i-1)<<4, screenh - 16, 2, 2)
		end
		for i=1,player.keys do
			spr(sprites.key, screenw - (i<<4), screenh - 16, 2, 2)
		end
	end

	-- remove dead
	for i=#objs,1,-1 do
		if objs[i].removeMe then objs:remove(i) end
	end
end
init()
