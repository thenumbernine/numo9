--[[
what to do with this ...

--]]

--#include ext/range.lua
--#include vec/vec2.lua

local dt = 1/60

math.randomseed(tstamp())

local mainloops=table()	-- return 'true' to preserve

local wait = |delay, fn| do
	local endTime = time() + delay
	mainloops:insert(||do
		if time() < endTime then return true end	-- keep waiting
		fn()
	end)
end

local drawBar = |x,y,w,h,f| do
	rectb(x, y, w, h, 12)		-- white border
	rect(x+1, y+1, w-2, h-2, 16)	-- black background
	rect(x+1, y+1, f * (w-2), h-2, 26)	-- green bar
end

-- why doesn't obj/sys use this?
local worldSize = vec2(256,256)	-- full game
-- obj/sys uses this:
local mapwidth = 256
local mapheight = 256

local sprites = {
	player = 0,
	plant = 1,
	vegetable = 2,
	heart = 32,
	hearthalf = 33,
}

flagshift=table{
	'solid_right',	-- 1
	'solid_down',	-- 2
	'solid_left',	-- 4
	'solid_up',		-- 8
	'vapor',		-- 16
	'liquid',		-- 32
}:mapi(|k,i| (i-1,k)):setmetatable(nil)
flags=table(flagshift):map(|v| 1<<v):setmetatable(nil)

flags.solid = flags.solid_up | flags.solid_down | flags.solid_left | flags.solid_right

local tilemapFlags = {
	hflip = 1 << 14,
	vflip = 1 << 15,
}

mapTypes=table{
	[0] = {
		name = 'empty',
		flags = 0,
	},
	{
		name = 'air',
		flags = flags.vapor,
	},
	{
		name = 'water',
		flags = flags.liquid,
	},	
	{
		name = 'stone',
		flags = flags.solid,
	},
	{
		name = 'dirt',
		flags = flags.solid,
	},
	{
		name = 'grass',
		flags = flags.solid,
	},
}

for k,v in pairs(mapTypes) do
	v.index = k
	v.flags ??= 0
end
mapTypeForName = mapTypes:map(|v,k| (v, v.name))

--#include obj/sys.lua

Object.useGravity = true	-- default everything uses gravity

--[[
ok new game idea
start in random noise level
some blocks are air, some are stone, some are vacuum, some are water ...
air blocks diffuse and if they are too small they disappear entirely ...
hmm need plants too for producing more air ...
then what.
--]]

TakesDamage = Object:subclass()
TakesDamage.maxHealth = 1
TakesDamage.takeDamageTime = 0
TakesDamage.takeDamageInvincibleDuration = 0
TakesDamage.takeDamage = |:,damage|do
	if time() < self.takeDamageTime then return end
	self.takeDamageTime = time() + self.takeDamageInvincibleDuration
	self.health -= damage
	if self.health <= 0 then self:die() end
end
TakesDamage.die=|:|do
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


Player = TakesDamage:subclass()
Player.sprite = sprites.player
Player.maxHealth = 7
Player.food = 1		-- how long until we starve
Player.breath = 1	-- how long can breathe
Player.takeDamageInvincibleDuration = 1
Player.init = |:,args| do
	Player.super.init(self, args)
	self.spriteSize = self.spriteSize:clone()
	self.aimDir = vec2(1,0)
end
Player.draw = |:| do
	if time() < self.takeDamageTime and (time() * 20) & 1 == 1 then return end
	Player.super.draw(self)
end
Player.update = |:| do
	local ti = mget(self.pos.x, self.pos.y)
	local t = mapTypes[ti]
	local inliquid = t?.flags & flags.liquid ~= 0

	if inliquid then
		sel.vel.x *= .9
		sel.vel.y *= .9
	end

	local speed = .15
	if self.hitSides & (1 << dirForName.down) ~= 0 then
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
		self.spriteSize.x = targetAimDir.x < 0 and -1 or 1
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
	
		or inliquid	-- swimming
	)
	then
		local jumpVel = .4
		self.vel.y = -jumpVel
	end

	-- breath
	if self.outside then
		self.breath -= .1 * dt
	else
		self.breath += 2 * dt
	end
	if self.breath < 0 then
		self.breath = 0
		self:takeDamage(1)
	elseif self.breath > Player.breath then
		self.breath = Player.breath
	end

	-- food
	self.food -= .02 * dt
	if self.food < 0 then
		self.food = 0
		self:takeDamage(1)
	end

	Player.super.update(self)	-- move and handle touch

	self.pos.x = math.clamp(self.pos.x, 0, 255.9999999)

	
	if self.holding then
		self.holding.pos = self.pos + vec2(0, -1)
		if btnp'y' then
			-- on press, throw
			self.holding.vel += .1 * self.aimDir
			self.holding.useGravity = nil	-- clear to default = true
			self.holding.solid = nil
			self.holding = nil
		end
		if btnp'a' then
			-- use to eat or something
			-- TODO callback or something
			self.holding:doPressA(self)
		end
	else
		if btn'y' then 
--trace'pressing y'	
			--self:shoot() 
			-- TODO
			-- if we were touching a plant...
			-- ... pull it up
			-- hold onto it
			-- push another button to throw it down somewhere else
			-- push another button to eat plants
			if self.pickupTouching then
--trace'pickup touching'				
				if not self.pickupStartTime then
--trace'setting pickupStartTime'					
					self.pickupStartTime = time()
				else
--trace'progressing pickupStartTime'
					local pickupDuration = .5
					
					drawBar(
						player.pos.x * 8 - 4,
						player.pos.y * 8 - 16,
						16,
						4,
						(time() - self.pickupStartTime) / pickupDuration
					)

					if time() > self.pickupStartTime + pickupDuration then
--trace'picked up'
						-- do the pick up
						self.pickupTouching:doPickUp(self)
					end
				end
			end
		end
	end
	
	if not btn'y' then 
		self.pickupStartTime = nil
	end

--trace'clearing pickupTouching'
	self.pickupTouching = nil
end

Player.nextShootTime = 0
Player.shootDelay = .1
Player.attackDist = 2
--Player.attackCosAngle = .5
Player.shoot=|:|do
	if time() < self.nextShootTime then return end
	self.nextShootTime = time() + self.shootDelay
	--mainloops:insert(||do
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

CanPickUp = Object:subclass()
CanPickUp.solid = false
CanPickUp.touch = |:, o| do
	if o == player then
--trace'setting pickupTouching'		
		o.pickupTouching = self
	end
	return self.solid	-- don't block
end
CanPickUp.doPickUp = |:, o| do	-- default = hold this object
	o.holding = self
	self.useGravity = false
end

Plant = CanPickUp:subclass()	-- TakesDamage or nah?
Plant.sprite = sprites.plant
Plant.doPickUp = |:, o| do
	--[[ pick this plant up
	Plant.super.doPickUp(self, o)
	--]]
	-- [[ pick up a fruit obj
	o.holding = Vegetable{
		pos = self.pos,
	}
	o.holding.useGravity = false
	o.holding.solid = false
	self.removeMe = true
	--]]
end

Vegetable = CanPickUp:subclass()
Vegetable.solid = true	-- veggies block by default
Vegetable.sprite = sprites.vegetable

-- how to eat veggies you are holding onto ...
-- 2nd button for using item you are holding?
Vegetable.foodGiven = .2
Vegetable.doPressA = |:, o| do
	o.food += self.foodGiven
	o.food = math.min(o.food, Player.food)	-- .maxFood?
	self.removeMe = true
end


--#include simplexnoise/2d.lua

local skyHeight = table()	-- height of tallest block
init = || do
	reset()	-- reset rom

	objs=table()
	
--[[ random everything
	player = Player{
		pos=(worldSize * .5):floor(),
	}

	for j=0,worldSize.y-1 do
		for i=0,worldSize.x-1 do
			mset(i, j, mapTypeForName![table{
				empty = 4,
				water = 2,
				air = 1,
				stone = .5,
				dirt = .25,
				grass = .125,
			}:pickWeighted()].index)
		end
	end
--]]
-- [[ give some sort of semblance of terraria caves or something idk
	local homeRadius = 4	
	local freq = 1/16	-- as long as 1/freq >= ground, then our ground gadient won't break our surface isobar
	local ground = 16
	local groundGrad = 1/4
	player = Player{
		pos=vec2(
			worldSize.x * .5, 
			ground + 8
		):floor(),
	}
	local circles = table{
		-- dig a hole for the player to start
		{pos=player.pos, radius=homeRadius},
		-- also passage to surface maybe ... 
	}:append(range(10):mapi(|i|
		{pos=player.pos + i * vec2(2, -1), radius=2}
	))

	bi = math.random(0xffffffff)
	bj = math.random(0xffffffff)
	for j=0,worldSize.y-1 do
		for i=0,worldSize.x-1 do
			local phi = simplexNoise2D(bi + i * freq, bj + j * freq) + (j - ground) * groundGrad
			for _,c in ipairs(circles) do
				phi -= 20 * math.max(0, 1 - (vec2(i,j) - c.pos):len() / c.radius)
			end
			-- different isobars = different content ...
			mset(i, j, 
				phi > 0 and mapTypeForName.stone.index
				or mapTypeForName.empty.index)
		end
	end
	
	-- determine sky level
	for i=0,worldSize.x-1 do
		for j=0,worldSize.y-1 do
			if mget(i,j) ~= mapTypeForName.empty.index then
				skyHeight[i] = j - 1
				break
			end
		end
	end
	
	-- I feel like I should be using circ() or something to draw on the tilemap...
	
--]]
end
-- level main loop ...
mainloops:insert(||do
	-- make sure there's so many plants or whatever growing in the map at any one time ...
	plants = plants or range(20):mapi(|i|do
		local x = math.random(0,255)
		local y = skyHeight[x]
		Plant{
			pos = vec2(x, y + .5),
		}
	end)
end)


local viewPos = vec2()

local clearColor = 16
local clearColorPrev
local clearColorFadeStart = -math.huge
local clearColorFadeTime = 1	-- second
local fadeToColor = |newClearColor| do
	if newClearColor == clearColor then return end
	clearColorFadeStart = time()
	clearColorPrev = clearColor 
	clearColor = newClearColor
end

update = || do
	local t = time()
	local f = (t - clearColorFadeStart) / clearColorFadeTime
	if f < 1 then
		-- fade from start to next color
		cls(clearColorPrev)
		fillp((1 << math.floor(math.clamp(1 - f, 0, 1) * 16)) - 1)
		cls(clearColor)
		fillp(0)
	else
		-- done fading
		clearColorPrev = clearColor
		cls(clearColor)
	end

	if not player then
		trace'player is dead!'
	end

	if player then
		viewPos:set(player.pos)
	end
	local ulpos = viewPos - 16	-- TODO consider mode resolution
	ulpos.x = math.clamp(ulpos.x, 0, 256 - 32)	-- TODO modes

	matident()
	mattrans(-math.floor(ulpos.x*8), -math.floor(ulpos.y*8))

	local mx = math.clamp(math.floor(ulpos.x), 0, 255)
	local my = math.clamp(math.floor(ulpos.y), 0, 255)
	local mw = math.clamp(33, 0, 255 - mx)	-- TODO 33 should be screen width in tiles + 1
	local mh = math.clamp(33, 0, 255 - my)
	local msx = mx * 8
	local msy = my * 8
	map(mx, my, mw, mh, msx, msy)

	for _,o in ipairs(objs) do
		o:draw()
	end

	for _,o in ipairs(objs) do
		o:update()
	end

	-- map update around the player ...
	if player then
		local pi = math.floor(player.pos.x)
		local pj = math.floor(player.pos.y)
		for i=math.clamp(pi-16, 0, mapwidth-1),math.clamp(pi+16,0,mapwidth-1) do
			for j=math.clamp(pj-16, 0, mapheight-1),math.clamp(pj+16,0,mapheight-1) do
				--[[ do the update
				water is pulled to water
				air is pulled to air
				... anything else?
				... what's our automata rules?
				... poisson solver?
				... how ...
				relative to ul pos, only one screen size worth ...
				--]]
			end
		end

		-- draw some wind or whatever
		if pj <= (skyHeight[pi] or math.huge) then
			-- do some particles or something
			if not winddots then
				winddots = range(20):mapi(|| {math.huge, math.huge})
			end
			for _,w in ipairs(winddots) do
				rect(8 * w[1], 8 * w[2], 2, 2, 12)	-- rect vs pset ... pset is exact fb loc and causes gpu flushes, rect is transformable (mat*) and doesn't
				--spr(0, w[1], w[2])
				w[1] += math.random() * 1
				w[2] += math.random() * 1
				if w[1] < ulpos.x	-- TODO consider mode and screen tile size
				or w[1] > ulpos.x + 33 
				or w[2] < ulpos.y 
				or w[2] > ulpos.y + 33
				then
					w[1] = ulpos.x + 33 * math.random()
					w[2] = ulpos.y + 33 * math.random()
				end
			end
		
			
			fadeToColor(15)
			player.outside = true
		else
			fadeToColor(16)
			player.outside = false
		end
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

		drawBar(127, 246, 34, 10, player.breath)
		drawBar(161, 246, 34, 10, player.food)
	end
--]]
end

init()
