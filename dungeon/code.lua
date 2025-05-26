--#include vec/vec2.lua
--#include vec/box2.lua
--#include ext/class.lua
--#include ext/range.lua
--#include ext/class.lua

math.randomseed(tstamp())

local sprites = {
	player = 0,
	enemy = 2,
	heart = 64,
	--hearthalf = 66,
	key = 66,
	target = 68,
	shot = 70,
}

flagshift=table{
	'solid_right',	-- 1
	'solid_down',	-- 2
	'solid_left',	-- 4
	'solid_up',		-- 8
}:mapi([k,i] (i-1,k)):setmetatable(nil)
flags=table(flagshift):map([v] 1<<v):setmetatable(nil)

flags.solid = flags.solid_up | flags.solid_down | flags.solid_left | flags.solid_right

mapTypes=table{
	[0]={			-- empty
		name = 'empty',
	},	
	[2]={	-- solid
		name='solid',
		flags=flags.solid,
	},
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


local viewPos = vec2()	-- set
local ulPos = vec2()	-- calculated
local mousePos = vec2()	-- mouse coords in-game

local Weapon = class()

local Pistol = Weapon:subclass() 
Pistol.attack=[:,attacker,target] do
	-- traceline, ignore attacker, see what you hit ...
	-- or just fire projectiles?
end

-- tilemap size in tiles
local mapwidth = 256
local mapheight = 256

--#include obj/sys.lua
Object.tileSize.x = 2	-- for 16x16
Object.tileSize.y = 2



Shot=Object:subclass()
Shot.sprite = sprites.shot
Shot.lifeTime = 3
Shot.damage = 1
Shot.init=[:,args]do
	Shot.super.init(self, args)
	self.endTime = time() + self.lifeTime
end
Shot.update=[:]do
	Shot.super.update(self)
	if time() > self.endTime then self.removeMe = true end
end
Shot.touch=[:,o]do
	if o ~= self.shooter
	and o.takeDamage
	then
		o:takeDamage(self.damage)
		self.removeMe = true	-- always or only upon hit?
	end
	return false	-- 'false' means 'dont collide'
end
Shot.touchMap = [:,x,y,t,ti] do
	if ti & 0x3ff == mapTypeForName.door.index
	and Player:isa(self.shooter)
	then
--		checkBreakDoor(self.weapon, x, y, ti)	-- conflating weapon and keyIndex once again ... one should be color, another should be attack-type
	end
	if t.flags & flags.solid ~= 0 then
		self.removeMe = true
	end
	return false	-- don't collide
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
Player.weapon = Pistol()
Player.update=[:]do

	self.vel:set(0,0)

	local speed = .1

	-- TODO how customizable should this be?
	-- and on that matter, should games get their own custom config?
	if btn'up' then self.vel.y -= speed end
	if btn'down' then self.vel.y += speed end
	if btn'left' then self.vel.x -= speed end
	if btn'right' then self.vel.x += speed end
	if key'mouse_left' then
		self:attack(mousePos:unpack())
	end

	Player.super.update(self)	-- draw and move
end

Player.attackTime = 0
Player.attackDelay = .1
Player.attackDist = 2
--Player.attackCosAngle = .5
Player.attackDamage = 1
Player.attack=[:, targetX, targetY]do
	if time() < self.attackTime then return end
	self.attackTime = time() + self.attackDelay
	mainloops:insert([]do
		elli(
			(self.pos.x - self.attackDist)*16,
			(self.pos.y - self.attackDist)*16,
			32*self.attackDist,
			32*self.attackDist,
			3)
	end)
--[[ radius damage
	for _,o in ipairs(objs) do
		if o ~= self then
			local delta = o.pos - self.pos
			if delta:lenSq() < self.attackDist^2 then
				o:takeDamage(self.attackDamage)
			end
		end
	end
--]]
-- [[
	local aimDir = (vec2(targetX, targetY) - self.pos):unit()
	Shot{
		pos = self.pos,
		vel = aimDir,
		shooter = self,
	}
--]]
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

update=[]do
	-- hmm mode() at global level doesn't seem to work ...
	--local screenw, screenh = 256,256
	--local screenw, screenh = 336, 189 mode(18)	-- 16:9 336x189x16bpp-RGB565
	local screenw, screenh = 480, 270 mode(42)	-- 16:9 480x270x8bpp-indexed

	cls(4)	-- how did black end up as 4?
	matident()

	ulPos:set(-screenw*.5+viewPos.x*16, -screenh*.5+viewPos.y*16)
	mattrans(-ulPos.x, -ulPos.y)
	map(0,0,256,256,0,0,0,1)

	if player then
		viewPos:set(player.pos)
	end

	for _,o in ipairs(objs) do
		o:update()
	end
	
	for _,o in ipairs(objs) do
		o:draw()
	end

	for i=#mainloops,1,-1 do
		mainloops[i]()
		mainloops[i] = nil
	end
	
	local mx, my = mouse()
	mousePos.x = (mx + ulPos.x) / 16
	mousePos.y = (my + ulPos.y) / 16
	spr(sprites.target, mousePos.x * 16 - 8, mousePos.y * 16 - 8, 2, 2)

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
