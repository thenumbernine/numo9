--#include vec/vec2.lua
--#include vec/vec3.lua
--#include vec/box2.lua
--#include ext/class.lua
--#include ext/range.lua

local palAddr = ffi.offsetof('RAM', 'bank') + ffi.offsetof('ROM', 'palette')
local blendColorAddr = ffi.offsetof('RAM','blendColor')
local spriteSheetAddr = ffi.offsetof('RAM', 'bank') + ffi.offsetof('ROM', 'spriteSheet')

math.randomseed(tstamp())

-- TODO order this better? order all arrow keys better? maybe right left down up?
local dirvecs = table{
	vec2(0,-1),
	vec2(0,1),
	vec2(-1,0),
	vec2(1,0),
}
local opposite = {2,1,4,3}

--local blockBitSize = vec2(5,5)
local blockBitSize = vec2(4,4)
--local blockBitSize = vec2(3,3)

local blockSize = vec2(1 << blockBitSize.x, 1 << blockBitSize.y)
local worldSize = vec2(256,256)	-- full game
--local worldSize = vec2(64, 64)	-- 2x2 screens
--local worldSize = vec2(32, 32)	-- 1 screen

local worldSizeInBlocks = worldSize / blockSize

--[[
world.rooms
--]]
local world

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
	[0]={name='empty', flags=0},				-- empty
	[1]={name='solid',flags=flags.solid},	-- solid
	[2]={
		name='dirt',
		flags=flags.solid,
		grows=3,	-- grass
	},
	[3]={
		name='grass',
		flags=0,
	},
	[4]={
		name='door',
		flags=flags.solid,
	},
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
					if ti ~= 0	-- just skip 'empty' ... right ... ?
					and t
					and px2 >= bx1 and px1 <= bx2
					and py2 >= by1 and py1 <= by2
					then
						-- do world hit
						local hitThis = true
						if t?:touch(self, bx1, by1) == false then hitThis = false end
						if self?:touchMap(bx1, by1, t, ti) == false then hitThis = false end
						-- so block solid is based on solid flag and touch result ...
						if t.flags & flags.solid ~= 0 then
							hit = hit or hitThis
						end
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
						local hitThis = true
						if self?:touch(o) == false then hitThis = false end
						if o?:touch(self) == false then hitThis = false end
						hit = hit or hitThis
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
	spr(Key.sprite, x+1, y+1)
	blend(-1)
	spr(Key.sprite, x, y)

	blend(6)	-- subtract-with-constant

	local keyColor = keyColors[keyIndex]
	local negKeyColor = keyColor and (
		   math.floor((1 - keyColor.x) * 31)
		| (math.floor((1 - keyColor.y) * 31) << 5)
		| (math.floor((1 - keyColor.z) * 31) << 10)
		| 0x8000
	) or 0
	pokew(blendColorAddr, negKeyColor)

	spr(Key.sprite, x,y)

	blend(-1)
end

Health = Object:subclass()
Health.sprite = 32
Health.health = 1
Health.touch=[:,o]do
	if not Player:isa(o) then return end
	o.health += self.health
	self.removeMe = true
end


Key=Object:subclass()
Key.sprite = 34
Key.draw=[:]do
	drawKeyColor(
		(self.pos.x - .5)*8, (self.pos.y - .5)*8,
		self.keyIndex
	)
end
Key.touch=[:,o]do
	if not Player:isa(o) then return end
	o.hasKeys[self.keyIndex]=true
	self.removeMe = true
end

Shot=Object:subclass()
Shot.lifeTime = 3
Shot.damage = 1
Shot.init=[:,args]do
	Shot.super.init(self, args)
	self.endTime = time() + self.lifeTime
end
Shot.draw=[:]do
	drawWeapon(
		(self.pos.x - .5)*8,
		(self.pos.y - .5)*8,
		self.weapon)
end
Shot.update=[:]do
	Shot.super.update(self)
	if time() > self.endTime then self.removeMe = true end
end
Shot.touch=[:,o]do
	if o ~= self.shooter then 
		if o.takeDamage then
			o:takeDamage(self.damage)
			self.removeMe = true	-- alwyas or only upon hit?
		end
	end
	return false	-- 'false' means 'dont collide'
end
Shot.touchMap = [:,x,y,t,ti] do
	if t == mapTypeForName.door then	
		if not Player:isa(self.shooter) then return end
		local blockcol = world.blocks[math.floor(x / blockSize.x)]
		local block = blockcol and blockcol[math.floor(y / blockSize.y)]
		if not block then return end
		local u = x % blockSize.x
		local v = y % blockSize.y
		local keyIndex = block?.doorKey[u][v]
		-- get the block this is in
		-- get the key that this is
		-- TODO use shot's properties for unlocking
		if not self.shooter.hasKeys[keyIndex] then return end
		mset(x,y,mapTypeForName.empty.index)
	end
	if t.flags & flags.solid ~= 0 then
		self.removeMe = true
	end
	return false	-- don't collide
end


drawWeapon=[x,y,weapon]do
	local index = (math.floor(time() * 10) % 4) + (64 + 32 * weapon)
	spr(index, x, y)
end
Weapon=Object:subclass()
Weapon.sprite = 64		-- \_ correlate these somehow or something
Weapon.weapon = 0		-- /
Weapon.draw = [:]do
	drawWeapon(
		(self.pos.x - .5)*8,
		(self.pos.y - .5)*8,
		self.weapon)
end
Weapon.touch=[:,o]do
	if not Player:isa(o) then return end
	o.hasWeapons[self.weapon] = true
	o.hasKeys[self.weapon] = true	-- TODO think through the door / key system more ...
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

Door = TakesDamage:subclass()
Door.sprite = 5
Door.maxHealth=1
-- Door.die=[:]do end -- TODO animate opening then remove

DoorHorz = Door:subclass()
DoorVert = Door:subclass()


Player=TakesDamage:subclass()
Player.sprite=sprites.player
Player.maxHealth=3
Player.useGravity = true
Player.selWeapon = 0
Player.init=[:,args]do
	Player.super.init(self, args)
	self.hasKeys = {[0]=true}
	self.hasWeapons = {[0]=true}
	self.aimDir = vec2(1,0)
end
Player.update=[:]do

	--self.vel:set(0,0)

--[[
	if self.isFlying then
		local speed = .15
		self.vel *= .5
		if btn(0) then self.vel.y -= speed end
		if btn(1) then self.vel.y += speed end
		if btn(2) then self.vel.x -= speed end
		if btn(3) then self.vel.x += speed end
	end
--]]

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

	if btn(0) then self.aimDir.y -= 1 end
	if btn(1) then self.aimDir.y += 1 end
	if btn(2) then self.aimDir.x -= 1 end
	if btn(3) then self.aimDir.x += 1 end
	self.aimDir = self.aimDir:unit()

	if btn(5)
	--and self.hitYP
	then
		local jumpVel = .35
		self.vel.y = -jumpVel
	end

	if btnp(6) then
		self.selWeapon = next(self.hasWeapons, self.selWeapon)
			or next(self.hasWeapons)
	end

	if btn(7) then self:attack() end



	Player.super.update(self)	-- draw and move
end

Player.attackTime = 0
Player.attackDelay = .1
Player.attackDist = 2
--Player.attackCosAngle = .5
Player.attackDamage = 1
Player.attack=[:]do
	if time() < self.attackTime then return end
	self.attackTime = time() + self.attackDelay
	mainloops:insert([]do
		elli((self.pos.x - self.attackDist)*8, (self.pos.y - self.attackDist)*8, 16*self.attackDist,16*self.attackDist, 3)
	end)
	-- [==[ projectile attack
	Shot{
		pos = self.pos,
		vel = self.aimDir,
		shooter = self,
		weapon = self.selWeapon,
	}
	--]==]
	--[==[ range attack
	for _,o in ipairs(objs) do
		if o ~= self
		and o.takeDamage
		then
			local delta = o.pos - self.pos
			if delta:lenSq() < self.attackDist^2 then
				o:takeDamage(self.attackDamage)
			end
		end
	end
	--]==]
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

--#include mapgen.lua

init=[]do
	reset()	-- reset rom

	objs=table()
	player = nil

	world = generateWorld()

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

local viewPos = vec2()
local lastScreenPos = vec2(-1, -1)
local lastBlock
local lastRoom
update=[]do
	cls()

	if not player then
		trace'player is dead!'
	end

	if player then
		viewPos:set(player.pos)

		local x, y = math.floor(player.pos.x / blockSize.x), math.floor(player.pos.y / blockSize.y)
		local blockcol = world.blocks[x]
		local block = blockcol and blockcol[y]
		if block ~= lastBlock then
			local room = block.room
			if room ~= lastRoom then
			
				if lastRoom then
					-- unspawn old
					for i=#objs,1,-1 do
						if not Player:isa(objs[i]) then
							objs[i].removeMe = true
						end
					end
					-- hide old
					for _,b in ipairs(lastRoom.blocks) do
						b.seen = false
					end
				end
				if room then
					for _,b in ipairs(room.blocks) do
						-- spawn new
						for _,spawn in ipairs(b.spawns) do
							spawn:class()
						end
						-- reveal new
						b.seen = true
					end
				end
				
				lastRoom = room
			end
			lastBlock = block

			-- TODO update lum based on block flood fill dist from player
			--  ... stop at room boundaries
		end
	end

	local ulpos = viewPos - 16

	matident()
	mattrans(-math.floor(ulpos.x*8), -math.floor(ulpos.y*8))

	--[[ draw all
	map(0,0,256,256,0,0)
	--]]
	-- [[ draw one screen
	map(math.floor(ulpos.x), math.floor(ulpos.y), 33, 33, math.floor(ulpos.x)*8, math.floor(ulpos.y)*8)
	--]]
	-- [[ instead of coloring per tile, solid-shade per-block
	--blend(1)	-- average
	--blend(2)	-- subtract
	blend(6)	-- subtract-with-constant
	for i=0,math.floor(32/blockSize.x) do
		for j=0,math.floor(32/blockSize.y) do
			local blockcol = world.blocks[math.floor(ulpos.x / blockSize.x) + i]
			local block = blockcol and blockcol[math.floor(ulpos.y / blockSize.y) + j]
			if block then
				local negRoomColor = math.floor((1 - block.color.x) * 31)
					| (math.floor((1 - block.color.y) * 31) << 5)
					| (math.floor((1 - block.color.z) * 31) << 10)
					| 0x8000
				for v=0,blockSize.y-1 do
					for u=0,blockSize.x-1 do
						local x = (math.floor(ulpos.x / blockSize.x) + i) * blockSize.x + u
						local y = (math.floor(ulpos.y / blockSize.y) + j) * blockSize.y + v
						local ti = mget(x,y)
						if ti == mapTypeForName.solid.index then

							-- white with constant blend rect works
							pokew(blendColorAddr, negRoomColor)

							rect(x * 8, y * 8, 8, 8, 13)
						elseif ti == mapTypeForName.door.index then
-- if there's a door then there should be a .doorKey and a keyColor ...
							local keyColor = keyColors[block.doorKey[u][v]]
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
	end
	blend(-1)
	--]]
	-- that's great, now draw all the non-map-colored things ...

	for _,o in ipairs(objs) do
		o:draw()
	end

	-- only now, erase world.blocks we haven't seen
	blend(6)	-- subtract-with-constant
	for i=0,math.floor(32/blockSize.x) do
		for j=0,math.floor(32/blockSize.y) do
			local blockcol = world.blocks[math.floor(ulpos.x / blockSize.x) + i]
			local block = blockcol and blockcol[math.floor(ulpos.y / blockSize.y) + j]
			if block and not block.seen then
				local negRoomColor = 0xffff
				pokew(blendColorAddr, negRoomColor)
				rect(
					(math.floor(ulpos.x / blockSize.x) + i) * blockSize.x * 8,
					(math.floor(ulpos.y / blockSize.y) + j) * blockSize.y * 8,
					blockSize.x * 8,
					blockSize.y * 8,
					13)
			end
		end
	end
	blend(-1)

	for _,o in ipairs(objs) do
		o:update()
	end

	for i=#mainloops,1,-1 do
		mainloops[i]()
		mainloops[i] = nil
	end

	-- remove dead
	for i=#objs,1,-1 do
		if objs[i].removeMe then objs:remove(i) end
	end


-- [[ gui
	if player then
		matident()
		text(player.pos:clone():floor(), 200, 0)
		for i=1,player.health do
			spr(sprites.heart, (i-1)<<3, 248)
		end
		local x = 8
		local y = 1
		for keyIndex in pairs(player.hasKeys) do
			drawKeyColor(x, y, keyIndex)
			x += 8
		end
		for weaponIndex in pairs(player.hasWeapons) do
			drawWeapon(x, y, weaponIndex)
			x += 8
		end
	end
--]]
end
init()
