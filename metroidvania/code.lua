--#include vec/vec2.lua
--#include vec/vec3.lua
--#include vec/box2.lua
--#include ext/class.lua
--#include ext/range.lua

-- TODO move this into ext.table?
table.pickWeighted = [t]do
	local sum = math.random() * math.max(1, table.values(t):sum())
	for k,v in pairs(t) do
		sum -= v
		if sum < 0 then return k end
	end
end

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

-- TODO order this like buttons ... right down left up ... so it's related to bitflags and so it follows exp map angle ...
-- tempting to do right left down up, i.e. x+ x- y+ y-, because that extends dimensions better
-- but as it is this way, we are 1:1 with the exponential-map, so there.
local dirvecs = table{
	[0] = vec2(1,0),
	[1] = vec2(0,1),
	[2] = vec2(-1,0),
	[3] = vec2(0,-1),
}
local opposite = {[0]=2,3,0,1}	-- opposite = [x]x~2
local dirForName = {right=0, down=1, left=2, up=3}

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
local keyColors	-- stores vectors, i'm going away from this
local keyColorIndexes	-- stores indexes, i'm going towards this

local sprites = {
	player = 0,
	player_spec = 1,
	heart = 32,
	hearthalf = 33,
	key = 34,
}

flagshift=table{
	'solid_right',	-- 1
	'solid_down',	-- 2
	'solid_left',	-- 4
	'solid_up',		-- 8
}:mapi([k,i] (i-1,k)):setmetatable(nil)
flags=table(flagshift):map([v] 1<<v):setmetatable(nil)

flags.solid = flags.solid_up | flags.solid_down | flags.solid_left | flags.solid_right

local tilemapFlags = {
	hflip = 1 << 14,
	vflip = 1 << 15,
}

mapTypes=table{
	[0] = {		-- empty
		name = 'empty',
		flags = 0,
	},
	[1] = {	-- solid
		name = 'solid',
		flags = flags.solid,
	},
	[2] = {
		name = 'dirt',
		flags = flags.solid,
		grows = 3,	-- grass
	},
	[3] = {
		name = 'grass',
		flags = 0,
	},
	[4] = {
		name = 'door',
		flags = flags.solid,
	},
	[5] = {	-- purely for rendering
		name = 'door_spec',
		flags = 0,
	},
	[6] = {	-- one-sided up (bitflags to flip down)
		name = 'solid_up',
		flags = flags.solid_up,
	},
	[7] = {	-- one-sided left (bitflags to flip right)
		name = 'solid_left',
		flags = flags.solid_left,
	},
	[8] = {
		name = 'spawn_player',
	},
	[6 | tilemapFlags.hflip] = {	-- one-sided up (bitflags to flip down)
		name = 'solid_down',
		flags = flags.solid_down,
	},
	[7 | tilemapFlags.vflip] = {	-- one-sided left (bitflags to flip right)
		name = 'solid_right',
		flags = flags.solid_right,
	},
}
-- tiles 32-47 are gonna be sides of solid
for i=32,47 do
	mapTypes[i] = table(mapTypes[1]):setmetatable(nil)
	mapTypes[i].name ..= '_'..i
end
-- door | (1..4) << 10 is also doors of dif colors
for i=1,4 do
	mapTypes[4 | (i << 10)] = table(mapTypes[4]):setmetatable(nil)
	mapTypes[4 | (i << 10)].name ..= '_'..i
end

for k,v in pairs(mapTypes) do
	v.index = k
	v.flags ??= 0
end
mapTypeForName = mapTypes:map([v,k] (v, v.name))

--#include ext/class.lua

local mapwidth = 256
local mapheight = 256


drawSpec=[colorSprite, specSprite, x, y, c, palIndex] do
	-- trying not to use blend ...
	-- TODO if you do palIndex/palShift then that's gonna shift the transparent channel as well ... hmmm ...
	-- palShift is only really useful as high-bits (as it was intended)
	-- I could set aside 16 different colors specifically ... I only really need 5 at the moment ...
	spr(colorSprite, x, y, 1, 1, palIndex)
	if specSprite then spr(specSprite, x, y) end
end

drawWeapon=[weapon,x,y]do
	local frame = math.floor(time() * 10) % 4
	drawSpec(
		64+frame,	-- color sprite
		96+frame,	-- spec sprite
		x, y,
		keyColors[weapon] or vec3(1,1,1),
		keyColorIndexes[weapon] or 0
	)
end

-- hmm keys ... jury is still out
drawKeyColor=[keyIndex,x,y]do
	-- draw shadow
	blend(6)	-- subtract-with-constant
	setBlendColor(0xffff)
	spr(Key.sprite, x-1, y-1)
	spr(Key.sprite, x+1, y+1)

	drawSpec(
		Key.sprite,
		nil,
		x, y,
		keyColors[keyIndex] or vec3(1,1,1),
		keyColorIndexes[keyIndex] or 0
	)
end

local dt = 1/60

--#include obj/sys.lua

Health = Object:subclass()
Health.sprite = 32
Health.health = 1
Health.touch=[:,o]do
	if not Player:isa(o) then return end
	o.health = math.min(o.health + self.health, o.maxHealth)
	self.removeMe = true
end


-- don't need this anymore, now that i'm using weapons for keys?
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
	if o ~= self.shooter
	and o.takeDamage
	then
		local damage = self.damage

		-- if shot or enemy has no color, or if they both have color and their colors don't match, then do damage
		-- TODO damage strong/weak
		--[[ damage matrix
				wh	bl	gr	re	bl
		white	1	.5	.25	4	2
		blue	2	1	.5	.25	4
		green	4	2	1	.5	.25
		red		.25	4	2	1	.5
		black	.5	.25	4	2	1
		--]]
		local w1 = self.weapon or 0
		local w2 = o.selWeapon or 0
		damage *= 2 ^ (((w2 - w1 + 2) % 5) - 2)
		o:takeDamage(damage)

		self.removeMe = true	-- always or only upon hit?
	end
	return false	-- 'false' means 'dont collide'
end
local checkBreakDoor
checkBreakDoor = [keyIndex, x, y, origMapType] do
	local doorColorIndex = (mget(x,y) >> 6) & 0xf0
	if keyColorIndexes[keyIndex] ~= doorColorIndex then return end
	mset(x,y,mapTypeForName.empty.index)
	wait(.1, []do
		for _,dir in pairs(dirvecs) do
			local ox, oy = x+dir.x, y+dir.y
			if mget(ox, oy) & 0x3ff == mapTypeForName.door.index then
				checkBreakDoor(keyIndex, ox, oy, origMapType)
			end
		end
	end)
	wait(3, []do
		mset(x,y,origMapType)
	end)
end
Shot.touchMap = [:,x,y,t,ti] do
	if ti & 0x3ff == mapTypeForName.door.index
	and Player:isa(self.shooter)
	then
		checkBreakDoor(self.weapon, x, y, ti)	-- conflating weapon and keyIndex once again ... one should be color, another should be attack-type
	end
	if t.flags & flags.solid ~= 0 then
		self.removeMe = true
	end
	return false	-- don't collide
end

--[[
ok what kinds of weapons should we have ...
	white
	blue
	green
	red
	black
- maybe i'll just have 3 upgrades, each increases # shots, spread range, distance, damage ... idk
--]]
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
TakesDamage.takeDamageInvincibleDuration = 0
TakesDamage.takeDamage=[:,damage]do
	if time() < self.takeDamageTime then return end
	self.takeDamageTime = time() + self.takeDamageInvincibleDuration
	self.health -= damage
	if self.health <= 0 then self:die() end
end
TakesDamage.die=[:]do
	if self.drops then
		local drop = table.pickWeighted(self.drops)
		if drop then
			drop.pos = self.pos
			drop:class()
		end
	end
	self.dead = true
	self.removeMe = true
end


local touchDealsDamage = [:,o] do
	if o == player then
		player:takeDamage(1)
	end
end

--[=[
Door = TakesDamage:subclass()
Door.sprite = 5
Door.maxHealth=1
-- Door.die=[:]do end -- TODO animate opening then remove
DoorHorz = Door:subclass()
DoorVert = Door:subclass()
--]=]


Player=TakesDamage:subclass()
Player.sprite=sprites.player
Player.maxHealth=7
Player.useGravity = true
Player.selWeapon = 0	-- TODO separate waepon-color from weapon-level selected
Player.takeDamageInvincibleDuration = 1
Player.init=[:,args]do
	Player.super.init(self, args)
	self.hasKeys = {[0]=true}
	self.hasWeapons = {[0]=true}
	self.aimDir = vec2(1,0)
end
Player.draw=[:]do
	if time() < self.takeDamageTime and (time() * 20) & 1 == 1 then return end
	drawSpec(
		0,
		1,
		(self.pos.x - .5) * 8,
		(self.pos.y - .5) * 8,
		keyColors[self.selWeapon] or vec3(1,1,1),
		keyColorIndexes[self.selWeapon] or 0
	)
end
Player.update=[:]do

	--self.vel:set(0,0)

--[[
	if self.isFlying then
		local speed = .15
		self.vel *= .5
		if btn'up' then self.vel.y -= speed end
		if btn'down' then self.vel.y += speed end
		if btn'left' then self.vel.x -= speed end
		if btn'right' then self.vel.x += speed end
	end
--]]

	local speed = .15
	if true then -- self.hitSides & (1 << dirForName.down) ~= 0 then
		self.vel.x *= .1	-- friction
		if btn'left' then
			self.left = true
			self.vel.x -= speed
		end
		if btn'right' then
			self.left = false
			self.vel.x += speed
		end
	else
		-- move in air? or nah, castlevania nes jumping. or nah, but constrain acceleration ...
		local maxAirSpeed = speed
		local speed = .05
		if btn'left' then
			self.left = true
			self.vel.x -= speed
			self.vel.x = math.clamp(self.vel.x, -maxAirSpeed, maxAirSpeed)
		end
		if btn'right' then
			self.left = false
			self.vel.x += speed
			self.vel.x = math.clamp(self.vel.x, -maxAirSpeed, maxAirSpeed)
		end
	end

	local targetAimDir = vec2()
	if btn'up' then targetAimDir.y -= 1 end
	if btn'down' then targetAimDir.y += 1 end
	if btn'left' then targetAimDir.x -= 1 end
	if btn'right' then targetAimDir.x += 1 end
	if targetAimDir.x ~= 0 or targetAimDir.y ~= 0 then
		local invlen = 1 / targetAimDir:len()
		self.aimDir.x = targetAimDir.x * invlen
		self.aimDir.y = targetAimDir.y * invlen
	else
		self.aimDir.x = self.left and -1 or 1
		self.aimDir.y = 0
	end

	if btn'b'
	and (
		-- we're on ground
		self.hitSides & (1 << dirForName.down) ~= 0
		-- ... or we have double-jump and haven't used our 2nd jump
		-- ... or we have space-jump
	)
	then
		local jumpVel = .4
		self.vel.y = -jumpVel
	end

	-- switch-weapon
	-- TODO this can be the switch-color butotn, and another butotn for select-attack-in-skill-tree
	if btnp'x' then
		self.selWeapon = next(self.hasWeapons, self.selWeapon)
			or next(self.hasWeapons)
	end

	if btn'y' then self:shoot() end

	Player.super.update(self)	-- draw and move
end

Player.nextShootTime = 0
Player.shootDelay = .1
Player.attackDist = 2
--Player.attackCosAngle = .5
Player.shoot=[:]do
	if time() < self.nextShootTime then return end
	self.nextShootTime = time() + self.shootDelay
	--mainloops:insert([]do
		local r = 2
		elli((self.pos.x - r)*8, (self.pos.y - r)*8, 16*r,16*r, 3)
	--end)
	Shot{
		pos = self.pos,
		vel = self.aimDir,
		shooter = self,
		weapon = self.selWeapon,
	}
end

-- TODO Player.takesDamage have invincible time and pain reaction


Crawler=TakesDamage:subclass()
Crawler.useGravity=true
Crawler.sprite = 2
Crawler.speed = .05
Crawler.maxHealth = 1	-- TODO pain frame or something
Crawler.update=[:]do
	self.angry = player and self.selWeapon ~= player.selWeapon
	self.speed = self.angry and .15 or .03

	local plusRot = self.left and -1 or 1
	local minusRot = -plusRot

	local oldPosX, oldPosY = self.pos.x, self.pos.y
	if not self.stickSide then
--trace('not stuck, falling...')
		-- make us fall
		self.useGravity = true
		self.stickSide = nil
		-- do movement
		Crawler.super.update(self)
		-- see if we hit anything
		for i=0,3 do
			if self.hitSides & (1 << i) ~= 0 then
				self.useGravity = false
				self.stickSide = i
				break
			end
		end
--trace('... and now stuck to', self.stickSide)
		-- and if we did, I guess we will upate stuck to the wall next frame
		self.lastAirSide = nil
	else
		-- we are stuck ...
		local stickDist = .3	-- matches bbox radius (i think?)
		-- find the pos where we are stuck ...
		local stickPosX = self.pos.x + dirvecs[self.stickSide].x * stickDist
		local stickPosY = self.pos.y + dirvecs[self.stickSide].y * stickDist
--trace('stuck on', self.stickSide,'at pos', stickPosX, stickPosY)
		local moveDir = dirvecs[(self.stickSide + plusRot) & 3]
		-- try to move ...
		self.vel.x = .4 * dirvecs[self.stickSide].x + moveDir.x * self.speed
		self.vel.y = .4 * dirvecs[self.stickSide].y + moveDir.y * self.speed
--trace('...with vel', self.vel)
		Crawler.super.update(self)

		-- ... if we couldn't move then rotate +1
		if self.hitSides ~= 0 then
--trace('and now hit flags', self.hitSides)
			-- if we hit the next side ...
			local nextSide = (self.stickSide + plusRot) & 3
			if self.hitSides & (1 << nextSide) ~= 0 then
				-- try to re-stick on the next side
				self.stickSide = nextSide
				--local nextDir = dirvecs[nextSide]
				--self.pos:set(vec2(stickPosX, stickPosY) - nextDir * stickDist)
			elseif self.hitSides & (1 << self.stickSide) ~= 0 then
				--[[ stuck on old side -- preserve distance from wall?
				if self.stickSide & 1 == 0 then	-- left/right
					self.pos.y = stickPosY - dirvecs[self.stickSide].y * stickDist
				else							-- up/down
					self.pos.x = stickPosX - dirvecs[self.stickSide].x * stickDist
				end
				--]]
			end
			self.lastAirSide = nil
		else
			self.pos.x = oldPosX
			self.pos.y = oldPosY
			self.vel.x = 0
			self.vel.y = 0
--trace('and hit nothing, so trying to rotate around')
		-- ... if we could move and the next move didn't touch anything then re-stick ourselves to the next wall
			if self.lastAirSide == nil then self.lastAirSide = self.stickSide end
			self.stickSide = (self.stickSide + minusRot)&3
			if self.stickSide == self.lastAirSide then
				-- just un-stick at this point
				self.lastAirSide = nil
				self.stickSide = nil
				self.useGravity = true
			else
				-- reposition yourself
				local nextDir = dirvecs[self.stickSide]
				self.pos.x = stickPosX - nextDir.x * stickDist
				self.pos.y = stickPosY - nextDir.y * stickDist
			end
		end
--trace('and now stuck on', self.stickSide)
	end
end
Crawler.draw=[:]do
	-- [[
	local rate = self.angry and 6 or 3
	self.sprite = (math.floor(time() * rate) % 2) + 2
	--Crawler.super.draw(self)
	--]]
	-- [[ spec ? meh?  I need to do palette-shifting
	drawSpec(
		self.sprite,
		nil,
		(self.pos.x - .5) * 8,
		(self.pos.y - .5) * 8,
		keyColors[self.selWeapon] or vec3(1,1,1),
		keyColorIndexes[self.selWeapon] or 0
	)
	--]]
end
Crawler.touch = touchDealsDamage


Jumper=TakesDamage:subclass()
Jumper.sprite = 4
Jumper.useGravity=true
Jumper.maxHealth = 3	-- TOOD health depends on color?
Jumper.update=[:]do
	if player then
		self.left = player.pos.x < self.pos.x
	else
		self.left = math.random(2) == 2
	end

	self.angry = player and self.selWeapon ~= player.selWeapon

	-- jump at player
	if not self.nextJumpTime then
		self.nextJumpTime = time() + .3
	end
	if time() > self.nextJumpTime then
		if self.hitSides & (1 << dirForName.down) ~= 0 then
			-- TODO once we're on-ground then change-frame, wait 0.2 or so, and then jump
			local f = self.angry and .35 or .1
			if math.random(2) == 2 then f *= .5 end
			self.vel.y = -f
			self.vel.x = self.left and -f or f
			self.nextJumpTime = time() + (self.angry and 1.5 or 2.5)
		end
	else
		if self.hitSides & (1 << dirForName.down) ~= 0 then
			self.vel.x *= .1
		end
	end
	Jumper.super.update(self)
end
Jumper.draw=[:]do
	-- [[ spec ? meh?  I need to do palette-shifting
	drawSpec(
		self.sprite,
		nil,
		(self.pos.x - .5) * 8,
		(self.pos.y - .5) * 8,
		keyColors[self.selWeapon] or vec3(1,1,1),
		keyColorIndexes[self.selWeapon] or 0
	)
	--]]
end
Jumper.touch = touchDealsDamage


-- fly back and forth and bounce off walls


-- fly straight at player and go through walls (ghost)


-- fly through walls and inchfwd then stop, repeat (worm boss from zelda or whatever)


-- blocks that fall on player


-- shoot at player ...
-- TODO dif weapons ...
-- 	... shoot directly
-- 	... shoot in arch (and thru walls, i.e. bone toss)
Shooter=TakesDamage:subclass()
Shooter.sprite=sprites.enemy
Shooter.chaseDist = 5
Shooter.speed = .05
Shooter.selWeapon = 0
Shooter.update=[:]do
	self.vel:set(0,0)

	-- TODO instead of appraoch...
	-- 1) give warning (like flash or something)
	-- 2) shoot at player
	if player
	and player.selWeapon ~= self.selWeapon
	then
		-- give a warning
		if not self.nextShootTime then
			self.nextShootTime = time() + 1 + 1 * math.random()
		else
			local f = self.nextShootTime - time()

			if .3 < f and f < .6 then
				-- flash
				do--if 1 & (time() * 20) == 1 then
					local r = 2
					blend(0)
					elli((self.pos.x - r)*8, (self.pos.y - r)*8, 16*r,16*r, 12)
					blend(-1)
				end
			elseif 0 < f and f < .3 then
				-- shoot
				if 1 & (time() * 20) == 1 then
					Shot{
						pos = self.pos,
						vel = .5 * (player.pos - self.pos):unit(),
						shooter = self,
						weapon = self.selWeapon,
					}
				end
			elseif f < 0 then
				self.nextShootTime = nil
			end
		end

		local delta = player.pos - self.pos
		local deltaLenSq = delta:lenSq()
		if deltaLenSq < self.chaseDist^2 then
			local dir = delta / math.max(1e-15, math.sqrt(deltaLenSq))
			self.vel = dir * self.speed
		end
	end

	Shooter.super.update(self)
end
Shooter.draw=[:]do
	drawSpec(
		0,
		1,
		(self.pos.x - .5) * 8,
		(self.pos.y - .5) * 8,
		keyColors[self.selWeapon] or vec3(1,1,1),
		keyColorIndexes[self.selWeapon] or 0
	)
end
-- [[ should touching enemies hurt?
Shooter.touch = touchDealsDamage
--]]


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

	-- decide the number of colors up front ... no more dynamic colors
	keyColors = {}
	keyColorIndexes = {}
	do
		-- make these match the sprites
		-- or TODO render sprites with separate fg/bg and make their color with neg-blending
		keyColors[0] = vec3(1,1,1)	keyColorIndexes[0] = 0
		keyColors[1] = vec3(0,0,1)	keyColorIndexes[1] = 0x10
		keyColors[2] = vec3(0,1,0)	keyColorIndexes[2] = 0x20
		keyColors[3] = vec3(1,0,0)	keyColorIndexes[3] = 0x30
		keyColors[4] = vec3(0,0,0)	keyColorIndexes[4] = 0x40

		local c = pickRandomColor()
		for i=5,255 do
			keyColors[i] = c
			keyColorIndexes[i] = math.random(0,255)	-- TODO and set the color? maybe? idk?
			--c = advanceColor(c)
			c = pickRandomColor()
		end
	end

	local room = {
		blocks = table(),
	}

	world = {
		blocks = range(0,worldSizeInBlocks.x-1):mapi([i]
			(range(0,worldSizeInBlocks.y-1):mapi([j]do
					local block = {
						pos = vec2(i,j),
						dirs = range(0,3):mapi([i] (false, i)),
						doors = range(0,3):mapi([i] (false, i)),
						spawns = table(),
						color = pickRandomColor(),
						seen = 0,
					}
					block.room = room
					room.blocks:insert(block)
					return block, j
				end
			), i)
		),
	}

	for y=0,255 do
		for x=0,255 do
			local ti = mget(x,y)
			if ti == mapTypeForName.spawn_player.index then
				player = Player{
					pos = vec2(x,y)+.5,
				}
				mset(x,y,0)
			end
		end
	end
end

local viewPos = vec2()
local lastScreenPos = vec2(-1, -1)
local lastBlock
local lastRoom
local fadeInRoom, fadeOutRoom
local fadeInLevel, fadeOutLevel
local fadeRate = .05
local fogLum = .5
--local roomColorIndex = 0
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
						for _,b in ipairs(fadeOutRoom.blocks) do
							b.seen = fogLum
						end
					end
					-- set our fade out room
					fadeOutRoom = lastRoom
					fadeOutLevel = 1
					for _,b in ipairs(fadeOutRoom.blocks) do
						b.seen = 1
					end
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
					for _,b in ipairs(fadeInRoom.blocks) do
						b.seen = math.min(b.seen, fogLum)
					end
--					roomColorIndex = room.colorIndex
--trace('roomColorIndex', roomColorIndex)
				end

				lastRoom = room
			end
			lastBlock = block

			-- TODO update lum based on block flood fill dist from player
			--  ... stop at room boundaries
		end
	end

if fadeInRoom then assert.ne(fadeInRoom, fadeOutRoom, 'fade rooms match!') end
	if fadeInRoom then
		fadeInLevel = math.min(fadeInLevel + fadeRate, 1)
		for _,b in ipairs(fadeInRoom.blocks) do b.seen = fadeInLevel end
		if fadeInLevel == 1 then fadeInRoom = nil fadeInLevel = nil end
	end
	if fadeOutRoom then
		fadeOutLevel = math.max(fadeOutLevel - fadeRate, fogLum)
		for _,b in ipairs(fadeOutRoom.blocks) do b.seen = fadeOutLevel end
		if fadeOutLevel == fogLum then fadeOutRoom = nil fadeOutLevel = nil end
	end

	local ulpos = viewPos - 16

	matident()
	mattrans(-math.floor(ulpos.x*8), -math.floor(ulpos.y*8))

	map(
		math.floor(ulpos.x),
		math.floor(ulpos.y),
		33,
		33,
		math.floor(ulpos.x)*8,
		math.floor(ulpos.y)*8
	)

	for _,o in ipairs(objs) do
		o:draw()
	end

	-- only now, erase/fade world blocks we haven't seen
	blend(6)	-- subtract-with-constant
	for i=0,math.floor(32/blockSize.x)+1 do
		for j=0,math.floor(32/blockSize.y)+1 do
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
		local x = 1
		local y = 248
		for i=2,player.health,2 do
			spr(sprites.heart, x, y)
			x += 8
		end
		if player.health & 1 == 1 then
			spr(sprites.hearthalf, x, y)
			x += 8
		end

		local x = 8
		local y = 1
		--[[ TODO no more keys, just weapon colors
		for keyIndex in pairs(player.hasKeys) do
			drawKeyColor(keyIndex, x, y)
			x += 8
		end
		--]]
		for weaponIndex in pairs(player.hasWeapons) do
			drawWeapon(weaponIndex, x, y)
			x += 8
		end
	end
--]]
end
init()
