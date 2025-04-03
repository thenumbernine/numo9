--#include vec/vec2.lua
--#include vec/vec3.lua
--#include vec/box2.lua
--#include ext/class.lua
--#include ext/range.lua

local palAddr = ffi.offsetof('RAM', 'bank') + ffi.offsetof('ROM', 'palette')
local blendColorAddr = ffi.offsetof('RAM','blendColor')
local spriteSheetAddr = ffi.offsetof('RAM', 'bank') + ffi.offsetof('ROM', 'spriteSheet')

local setBlendColor = [c] pokew(blendColorAddr, c)

-- rgb [0,1]^3 vector to 5551 uint16
local rgb_to_5551 = [v] (
	   math.floor(v.x * 31)
	| (math.floor(v.y * 31) << 5)
	| (math.floor(v.z * 31) << 10)
	| 0x8000)

math.randomseed(tstamp())

local mainloops=table()	-- return 'true' to preserve

local wait = [delay, fn] do
	local endTime = time() + delay
	mainloops:insert([]do
		if time() < endTime then return true end	-- keep waiting
		fn()
	end)
end

-- TODO order this better? order all arrow keys better? maybe right left down up?
local dirvecs = table{
	vec2(0,-1),
	vec2(0,1),
	vec2(-1,0),
	vec2(1,0),
}
local opposite = {2,1,4,3}

--local blockSize = vec2(32,32)
local blockSize = vec2(16,16)
--local blockSize = vec2(12,12)
--local blockSize = vec2(8,8)

local worldSize = vec2(256,256)	-- full game
--local worldSize = vec2(64, 64)	-- 2x2 screens
--local worldSize = vec2(32, 32)	-- 1 screen

local worldSizeInBlocks = (worldSize / blockSize):floor()
worldSize = worldSizeInBlocks * blockSize

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
			local pxmin = nx + self.bbox.min.x
			local pymin = ny + self.bbox.min.y
			local pxmax = nx + self.bbox.max.x
			local pymax = ny + self.bbox.max.y
			local hit
			for bymin=math.clamp(math.floor(pymin), 0, mapheight-1), math.clamp(math.ceil(pymax), 0, mapheight-1) do
				for bxmin=math.clamp(math.floor(pxmin), 0, mapwidth-1), math.clamp(math.ceil(pxmax), 0, mapwidth-1) do
					local bxmax, bymax = bxmin + 1, bymin + 1
					local ti = mget(bxmin, bymin)
					local t = mapTypes[ti]
					if ti ~= 0	-- just skip 'empty' ... right ... ?
					and t
					and pxmax >= bxmin and pxmin <= bxmax
					and pymax >= bymin and pymin <= bymax
					then
						-- do world hit
						local hitThis = true
						if t?:touch(self, bxmin, bymin) == false then hitThis = false end
						if self?:touchMap(bxmin, bymin, t, ti) == false then hitThis = false end
						-- so block solid is based on solid flag and touch result ...
						if t.flags & flags.solid ~= 0 then
							hit = hit or hitThis
						end
					end
				end
			end
			for _,o in ipairs(objs) do
				if o ~= self then
					local bxmin, bymin = o.pos.x + o.bbox.min.x, o.pos.y + o.bbox.min.y
					local bxmax, bymax = o.pos.x + o.bbox.max.x, o.pos.y + o.bbox.max.y
					if pxmax >= bxmin and pxmin <= bxmax
					and pymax >= bymin and pymin <= bymax
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

local drawKeyColor=[keyIndex,x,y]do
	blend(6)	-- subtract-with-constant
	setBlendColor(0xffff)
	spr(Key.sprite, x-1, y-1)
	spr(Key.sprite, x+1, y+1)
	blend(-1)
	spr(Key.sprite, x, y)

	blend(6)	-- subtract-with-constant

	local keyColor = keyColors[keyIndex]
	setBlendColor(keyColor and rgb_to_5551(1 - keyColor) or 0)

	spr(Key.sprite, x, y)

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
		self.keyIndex,
		(self.pos.x - .5)*8,
		(self.pos.y - .5)*8
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
		self.weapon,
		(self.pos.x - .5)*8,
		(self.pos.y - .5)*8)
end
Shot.update=[:]do
	Shot.super.update(self)
	if time() > self.endTime then self.removeMe = true end
end
Shot.touch=[:,o]do
	if o ~= self.shooter then 
		if o.takeDamage then
			o:takeDamage(self.damage)
			self.removeMe = true	-- always or only upon hit?
		end
	end
	return false	-- 'false' means 'dont collide'
end
local checkBreakDoor 
checkBreakDoor = [keyIndex, x, y] do
	local blockcol = world.blocks[math.floor(x / blockSize.x)]
	local block = blockcol and blockcol[math.floor(y / blockSize.y)]
	if not block then return end
	local u = x % blockSize.x
	local v = y % blockSize.y
	local blockKeyIndex = block.doorKey[u][v]
	-- get the block this is in
	-- get the key that this is
	if keyIndex ~= blockKeyIndex then return end
	mset(x,y,mapTypeForName.empty.index)
	wait(.1, []do
		for _,dir in ipairs(dirvecs) do
			local ox, oy = x+dir.x, y+dir.y
			if mget(ox, oy) == mapTypeForName.door.index then
				checkBreakDoor(keyIndex, ox, oy)
			end
		end
	end)
	wait(3, []do
		mset(x,y,mapTypeForName.door.index)
	end)
end
Shot.touchMap = [:,x,y,t,ti] do
	if t == mapTypeForName.door 
	and Player:isa(self.shooter) 
	then 
		checkBreakDoor(self.weapon, x, y)	-- conflating weapon and keyIndex once again ... one should be color, another should be attack-type
	end
	if t.flags & flags.solid ~= 0 then
		self.removeMe = true
	end
	return false	-- don't collide
end


drawWeapon=[weapon,x,y]do
	local frame = math.floor(time() * 10) % 4
	
	spr(64+frame, x, y)	-- draw white
	
	blend(6)	-- subtract-with-constant
	local keyColor = keyColors[weapon]
	setBlendColor(keyColor and rgb_to_5551(1 - keyColor) or 0)
	spr(64+frame, x, y)

	blend(-1)
	spr(96+frame, x, y)
end
Weapon=Object:subclass()
Weapon.sprite = 64		-- \_ correlate these somehow or something
Weapon.weapon = 0		-- /
Weapon.draw = [:]do
	drawWeapon(
		self.weapon,
		(self.pos.x - .5)*8,
		(self.pos.y - .5)*8)
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
	self.targetAimDir = vec2(1,0)
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

	local targetAimDir = vec2()
	if btn(0) then targetAimDir.y -= 1 end
	if btn(1) then targetAimDir.y += 1 end
	if btn(2) then targetAimDir.x -= 1 end
	if btn(3) then targetAimDir.x += 1 end
	if targetAimDir.x ~= 0 or targetAimDir.y ~= 0 then
		self.targetAimDir = targetAimDir:unit()
	end
	if self.targetAimDir:dot(self.aimDir) < -.1 then
		self.aimDir:set(self.targetAimDir:unpack())
	else
		self.aimDir += .1 * self.targetAimDir
		self.aimDir = self.aimDir:unit()
	end

	if btn(5)
	--and self.hitYP
	then
		local jumpVel = .35
		self.vel.y = -jumpVel
	end

	-- switch-weapon 
	-- TODO this can be the switch-color butotn, and another butotn for select-attack-in-skill-tree
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
		-- make these match the sprites
		-- or TODO render sprites with separate fg/bg and make their color with neg-blending
		keyColors[0] = vec3(1,1,1)
		keyColors[1] = vec3(0,0,1)
		for i=2,keyIndex do
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
local fadeInRoom, fadeOutRoom
local fadeInLevel, fadeOutLevel
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
			
					-- if we had an old fadeOutRoom then make sure its .seen is zero 
					if fadeOutRoom then
						for _,b in ipairs(fadeOutRoom.blocks) do b.seen = 0 end
					end
					-- set our fade out room
					fadeOutRoom = lastRoom
					fadeOutLevel = 1
				end
				if room then
					for _,b in ipairs(room.blocks) do
						-- spawn new
						for _,spawn in ipairs(b.spawns) do
							spawn:class()
						end
					end
					-- set this as our new fade-in room
					-- (if we had a previous fade-in room then it should now be the current fade-out room)
					fadeInRoom = room
					fadeInLevel = 0
				end
				
				lastRoom = room
			end
			lastBlock = block

			-- TODO update lum based on block flood fill dist from player
			--  ... stop at room boundaries
		end
	end

	if fadeInRoom then
		fadeInLevel = math.max(fadeInLevel + .05, 1)
		for _,b in ipairs(fadeInRoom.blocks) do b.seen = fadeInLevel end
		if fadeInLevel == 1 then fadeInRoom = nil fadeInLevel = nil end
	end
	if fadeOutRoom then
		fadeOutLevel = math.max(fadeOutLevel - .05, 0)
		for _,b in ipairs(fadeOutRoom.blocks) do b.seen = fadeOutLevel end
		if fadeOutLevel == 0 then fadeOutRoom = nil fadeOutLevel = nil end
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
				local negRoomColor = rgb_to_5551(1 - block.color)
				for v=0,blockSize.y-1 do
					for u=0,blockSize.x-1 do
						local x = (math.floor(ulpos.x / blockSize.x) + i) * blockSize.x + u
						local y = (math.floor(ulpos.y / blockSize.y) + j) * blockSize.y + v
						local ti = mget(x,y)
						if ti == mapTypeForName.solid.index then

							-- white with constant blend rect works
							setBlendColor(negRoomColor)

							rect(x * 8, y * 8, 8, 8, 13)
						elseif ti == mapTypeForName.door.index then
-- if there's a door then there should be a .doorKey and a keyColor ...
							local keyColor = keyColors[block.doorKey[u][v]]
							setBlendColor(rgb_to_5551(1 - keyColor))

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
			if block then
				local lum = 1 - block.seen
				setBlendColor(rgb_to_5551(vec3(lum, lum, lum)))
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
		if mainloops[i]() ~= true then
			mainloops:remove(i)
		end
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
			drawKeyColor(keyIndex, x, y)
			x += 8
		end
		for weaponIndex in pairs(player.hasWeapons) do
			drawWeapon(weaponIndex, x, y)
			x += 8
		end
	end
--]]
end
init()
