--#include vec/vec2.lua
--#include vec/box2.lua
--#include ext/class.lua
--#include ext/range.lua

math.randomseed(tstamp())

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
				mset(x,y,mapTypeForName.empty.index)
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
Object.update=[:]do
	-- draw
	spr(self.sprite, (self.pos.x - .5)*8, (self.pos.y - .5)*8)

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
	local gravity = 1
	self.vel.y += dt * gravity
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

	--self.vel:set(0,0)

	--if btn'up' then self.vel.y -= speed end
	--if btn'down' then self.vel.y += speed end
	local speed = .15
	if self.hitYP then
		self.vel.x *= .1	-- friction
		if btn'left' then self.vel.x -= speed end
		if btn'right' then self.vel.x += speed end
	else
		-- move in air? or nah, castlevania nes jumping. or nah, but constrain acceleration ...
		local maxAirSpeed = speed
		local speed = .05
		if btn'left' then 
			self.vel.x -= speed 
			self.vel.x = math.clamp(self.vel.x, -maxAirSpeed, maxAirSpeed)
		end
		if btn'right' then 
			self.vel.x += speed 
			self.vel.x = math.clamp(self.vel.x, -maxAirSpeed, maxAirSpeed)
		end
	end
	if btn'b' and self.hitYP then
		local jumpVel = .35
		self.vel.y = -jumpVel
	end
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

init=[]do
	reset()	-- reset rom

-- [[ procedural level
	for y=0,255 do
		for x=0,255 do
			mset(x,y,0) -- (~y) & 1)
		end
	end
	for x=0,255 do
		mset(x,255,mapTypeForName.solid.index)
	end

	local jumpHeight = 3
	local nextStep
	nextStep = [x,y,dir]do
		if x < 0 or x > 255 or y < 0 or y > 255 then return end
		if mget(x,y) ~= 0 then return end	-- already charted
		mset(x,y,1)
		-- move options?
		-- walk in dir
		-- jump
		-- if last move was jump then dir can change
		if math.random() < .1 then	-- jump up
			dir = table{-1, 1}:pickRandom()
			local nx = x + dir * math.random(1,jumpHeight)
			local ny = y - jumpHeight
			nextStep(nx, ny, dir)
			-- [[
			if math.random() < .05 then -- fork
				dir = -dir
				local nx = x + dir
				local ny = y - jumpHeight
				return nextStep(nx, ny, dir)
			end
			--]]
		elseif math.random() < .1 then -- jump over
			local nx = x + dir * math.random(1,jumpHeight)
			nextStep(nx, y, dir)
		else
			x += dir
			return nextStep(x, y, dir)
		end
	end
	nextStep(127, 254, 1)
	mset(127,254,mapTypeForName.spawn_player.index)

--]]

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
	cls(17)

	if player then
		viewPos:set(player.pos)
	end
	
	matident()
	mattrans(128-viewPos.x*8, 128-viewPos.y*8)

	map(0,0,256,256,0,0)
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

	if player then
		matident()
		text(tostring(math.floor(player.pos.y)), 220, 0, 13, 0)
	end
end
init()
