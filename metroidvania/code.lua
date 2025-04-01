--#include vec/vec2.lua
--#include vec/vec3.lua
--#include vec/box2.lua
--#include ext/class.lua
--#include ext/range.lua

local palAddr = ffi.offsetof('RAM', 'bank') + ffi.offsetof('ROM', 'palette')
local blendColorAddr = ffi.offsetof('RAM','blendColor')
local spriteSheetAddr = ffi.offsetof('RAM', 'bank') + ffi.offsetof('ROM', 'spriteSheet')

math.randomseed(tstamp())

--local roomSize = vec2(32,32)
--local roomSize = vec2(16,16)
local roomSize = vec2(8,8)
--local mapInRooms = vec2(256,256) / roomSize	-- full game
local mapInRooms = vec2(32, 32) / roomSize
local rooms
local keyIndex
local keyColors

local sprites = {
	player = 0,
	enemy = 1,
	heart = 32, 
	hearthalf = 33,
	key = 34,
}

flagshift=table{
	'solid',	-- 1
}:mapi([k,i] (i-1,k)):setmetatable(nil)
flags=table(flagshift):map([v] 1<<v):setmetatable(nil)

mapTypes=table{
	[0]={name='empty'},				-- empty
	[1]={name='solid',flags=flags.solid},	-- solid
	[2]={
		name='chest',
		flags=flags.solid,
		touch = [:, o, x, y]do
			if o == player then
				mset(x,y,mapTypeForName.chest_open.index)
				player.keys += 1
			end
		end,
	},
	[3]={
		name='chest_open',
		flags=flags.solid,
	},
	[4]={
		name='door',
		flags=flags.solid,
		touch = [:, o, x, y]do
			if o == player then
				local roomcol = rooms[math.floor(x / roomSize.x)]
				local room = roomcol[math.floor(y / roomSize.y)]
				local u = x % roomSize.x
				local v = y % roomSize.y
				local keyIndex = room.doorKey[u][v]
				-- get the room this is in
				-- get the key that this is
trace('touching door keyIndex', keyIndex)				
				if o.hasKeys[keyIndex] then
					mset(x,y,mapTypeForName.empty.index)
				end
			end
		end,
	},
	[5]={
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
	[32]={name='spawn_player'},
	[33]={name='spawn_enemy'},
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
Object.draw=[:]do
	spr(self.sprite, (self.pos.x - .5)*8, (self.pos.y - .5)*8)
end
Object.update=[:]do

	-- move

	self.hitXP = false
	self.hitYP = false
	self.hitXN = false
	self.hitYN = false
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
			else
				if bi == 0 then
					if self.vel.y > 0 then
						self.hitYP = true
					else
						self.hitYN = true
					end
					self.vel.y = 0
				else
					if self.vel.x > 0 then
						self.hitXP = true
					else
						self.hitXN = true
					end				
					self.vel.x = 0
				end
			end
		end
	end

	local dt = 1/60
	if self.useGravity then
		local gravity = 1
		self.vel.y += dt * gravity
	end
end

local drawKeyColor=[x,y,keyIndex]do
	blend(6)	-- subtract-with-constant
	spr(Key.sprite, x-1, y-1)
	blend(-1)
	spr(Key.sprite, x, y)
	
	blend(6)	-- subtract-with-constant
	
	local keyColor = keyColors[keyIndex]
	local negKeyColor = 
		   math.floor((1 - keyColor.x) * 31)
		| (math.floor((1 - keyColor.y) * 31) << 5)
		| (math.floor((1 - keyColor.z) * 31) << 10)
		| 0x8000
	pokew(blendColorAddr, negKeyColor)

	spr(Key.sprite, x,y)
	
	blend(-1)
end

Key = Object:subclass()
Key.sprite = 34
Key.draw=[:]do
	drawKeyColor(
		(self.pos.x - .5)*8, (self.pos.y - .5)*8,
		self.keyIndex
	)
end
Key.touch=[:,o]do
	player.hasKeys[self.keyIndex]=true
	self.removeMe = true
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
Player.useGravity = true
Player.init=[:,args]do
	Player.super.init(self, args)
	self.hasKeys = {[0]=true}
end
Player.update=[:]do

	--self.vel:set(0,0)

	--if btn(0) then self.vel.y -= speed end
	--if btn(1) then self.vel.y += speed end
	local speed = .15
	if self.hitYP then
		self.vel.x *= .1	-- friction
		if btn(2) then self.vel.x -= speed end
		if btn(3) then self.vel.x += speed end
	else
		-- move in air? or nah, castlevania nes jumping. or nah, but constrain acceleration ...
		local maxAirSpeed = speed
		local speed = .05
		if btn(2) then 
			self.vel.x -= speed 
			self.vel.x = math.clamp(self.vel.x, -maxAirSpeed, maxAirSpeed)
		end
		if btn(3) then 
			self.vel.x += speed 
			self.vel.x = math.clamp(self.vel.x, -maxAirSpeed, maxAirSpeed)
		end
	end
	if btn(5)
	--and self.hitYP 
	then
		local jumpVel = .35
		self.vel.y = -jumpVel
	end
	if btn(7) then self:attack() end

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
		elli((self.pos.x - self.attackDist)*8, (self.pos.y - self.attackDist)*8, 16*self.attackDist,16*self.attackDist, 3)
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


local pickRandomColor = []
	vec3(math.random(), math.random(), math.random()):unit()

local advanceColor = [v] do
	v = v:clone()
	v.x += .2 * (math.random() * 2 - 1)
	v.y += .2 * (math.random() * 2 - 1)
	v.z += .2 * (math.random() * 2 - 1)
	v = v:map([x] math.clamp(x, 0, 1))
	return v
end


init=[]do
	reset()	-- reset rom
	
	objs=table()
	player = nil

-- [[ procedural level
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
				color = pickRandomColor(),
			}, j)
		), i)
	)

	local dirvecs = table{
		vec2(0,-1),
		vec2(0,1),
		vec2(-1,0),
		vec2(1,0),
	}
	local opposite = {2,1,4,3}
	
	keyIndex = 0

	local posinfos = table()
	local start = (mapInRooms / 2):floor()
	do
		local srcroom = rooms[start.x][start.y]
		for dirindex,dir in ipairs(dirvecs) do
			local nextpos = start + dir
			local nextroom = rooms[nextpos.x][nextpos.y]
			posinfos:insert{pos=nextpos}
			srcroom.dirs[dirindex] = true
			nextroom.prevRoom = srcroom
			nextroom.dirs[opposite[dirindex]] = true
			nextroom.color = advanceColor(srcroom.color)
			if math.random() < .5 then
				srcroom.doors[dirindex] = keyIndex
				nextroom.doors[opposite[dirindex]] = keyIndex
			end
		end
	end
	while true do
		if #posinfos == 0 then break end
		local posinfoindex = math.random(1, #posinfos)
		local pos = posinfos[posinfoindex].pos
		local srcroom = rooms[pos.x][pos.y]
		if srcroom.set then
			-- it's already set then someone's already moved into it, so don't bother
			posinfos:remove(posinfoindex)
		else
			-- not set yet - set it and grow off of it
			srcroom.set = true

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
				--local p = validDirs:pickRandom()
				for _,p in ipairs(validDirs) do
					local dirindex = p.dirindex
					local dir = p.dir
					local nbhdpos = pos + dir
					local nextroom = rooms[nbhdpos.x][nbhdpos.y]
					posinfos:insert{pos=nbhdpos}
					srcroom.dirs[dirindex] = true
					nextroom.prevRoom = srcroom
					nextroom.dirs[opposite[dirindex]] = true
					nextroom.color = advanceColor(srcroom.color)
					
					-- if we are making a key-door then make sure to drop a key somewhere in the .prevRoom chain
					-- ... and it'd be nice to put the key behind the last-greatest key-door used
					if math.random() < .5 then
						
						-- what if there's already a key-door there?
						-- will there ever be one?
						srcroom.doors[dirindex] = math.random(0, keyIndex)
						nextroom.doors[opposite[dirindex]] = math.random(0, keyIndex)
					
						if math.random() < .5 then 
							keyIndex += 1 
							-- put the key after the next room
							nextroom.items ??= table()
							--nextroom.items:insert ...
							local key = Key{
								pos=(nextroom.pos + .5)*roomSize,
								keyIndex = keyIndex,
							}
							trace('drawing key at '..key.pos)
						end
					end
				end
			end
		end
	end
	for i=0,mapInRooms.x-1 do
		for j=0,mapInRooms.y-1 do
			local room = rooms[i][j]
			
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

	keyColors = {}
	do
		local c = pickRandomColor()
		for i=0,keyIndex do
			keyColors[i] = c
			c = advanceColor(c)
		end
	end
end

local viewPos = vec2()
local lastScreenPos = vec2(-1, -1)
update=[]do
	cls()

	if player then
		viewPos:set(player.pos)
	end

	local screenPos = ((viewPos-.5)/32):floor()

--[[
	if screenPos ~= lastScreenPos then
		lastScreenPos = screenPos
		-- TODO reset state here
		-- regenerate the overlay ... or not ... just draw a solid color maybe?
	end
--]]

	matident()
	mattrans(-screenPos.x*32*8, -screenPos.y*32*8)

	--[[ draw all
	map(0,0,256,256,0,0)
	--]]
	-- [[ draw one screen
	map(screenPos.x*32, screenPos.y*32, 32, 32, screenPos.x*32*8, screenPos.y*32*8)
	--]]
	-- [[ instead of coloring per tile, solid-shade per-room
	--blend(1)	-- average
	--blend(2)	-- subtract
	blend(6)	-- subtract-with-constant
	for i=0,math.floor(32/roomSize.x)-1 do
		for j=0,math.floor(32/roomSize.y)-1 do
			local roomcol = rooms[math.floor(screenPos.x * 32 / roomSize.x) + i]
			local room = roomcol[math.floor(screenPos.y * 32 / roomSize.y) + j]
			local negRoomColor = math.floor((1 - room.color.x) * 31)
				| (math.floor((1 - room.color.y) * 31) << 5)
				| (math.floor((1 - room.color.z) * 31) << 10)
				| 0x8000
			for v=0,roomSize.y-1 do
				for u=0,roomSize.x-1 do
					local x = screenPos.x * 32 + i * roomSize.x + u
					local y = screenPos.y * 32 + j * roomSize.y + v
					local ti = mget(x,y)
					if ti == mapTypeForName.solid.index then
						
						-- white with constant blend rect works 
						pokew(blendColorAddr, negRoomColor)

						rect(x * 8, y * 8, 8, 8, 13)
					elseif ti == mapTypeForName.door.index then
						local keyColor = keyColors[room.doorKey[u][v]]
						local negKeyColor = 
							   math.floor((1 - keyColor.x) * 31)
							| (math.floor((1 - keyColor.y) * 31) << 5)
							| (math.floor((1 - keyColor.z) * 31) << 10)
							| 0x8000
						pokew(blendColorAddr, negKeyColor)
						
						rect(x * 8, y * 8, 8, 8, 13)
					end
				end
			end
		end
	end
	blend(-1)
	--]]
	-- that's great, now draw all the non-map-colored things ...

	for _,o in ipairs(objs) do
		o:draw()
	end
	for _,o in ipairs(objs) do
		o:update()
	end

	for i=#mainloops,1,-1 do
		mainloops[i]()
		mainloops[i] = nil
	end

	-- draw gui
	if player then
		for i=1,player.health do
			spr(sprites.heart, (i-1)<<3, 248)
		end
		for i=1,player.keys do
			spr(sprites.key, 248-((i-1)<<3), 248)
		end
	end

	-- remove dead
	for i=#objs,1,-1 do
		if objs[i].removeMe then objs:remove(i) end
	end

-- [[ gui
	if player then
		matident()
		for keyIndex,v in pairs(player.hasKeys) do
			drawKeyColor(8 * keyIndex, 1, keyIndex)
		end
	end
--]]
end
init()
