local fontWidthAddr = ramaddr'fontWidth'
for i=0,255 do
	poke(fontWidthAddr+i,8)
end

math.randomseed(tstamp())

--#include ext/class.lua
--#include vec/vec2.lua
--#include vec/box2.lua

mode(42)	-- 16:9 480x270x8bpp-indexed
local screenSize = vec2(480, 270)

tilemapTiles={
	floor = 80 | 0x400,
	wall =  0 | 0x400,
}

sprites={
	Player = 0,
	Spider = 2,
	Snake = 4,
	Lobster = 6,
	Cat = 8,
	Blob = 10,
	Imp = 12,
	Wolf = 14,
	Goblin = 16,
	Dwarf = 18,
	Human = 20,
	Elf = 22,
	Zombie = 24,
	Troll = 26,
	Gargoyle = 28,
	Golem = 30,
	Ogre = 1<<6,
	Bull = 1<<6 | 2,
	Lion = 1<<6 | 4,
	Liger = 1<<6 | 6,
	Giant = 1<<6 | 8,
	Dragon = 1<<6 | 10,
	['T-Rex'] = 1<<6 | 12,
	Treasure = 2<<6,
}

dirs = {
	'up',
	'down',
	'left',
	'right',
	up=vec2(0,-1),
	down=vec2(0,1),
	left=vec2(-1,0),
	right=vec2(1,0),
}

setFieldsByRange=|obj,fields|do
	for _,field in ipairs(fields) do
		local range = obj[field..'Range']
		if range then
			local lo, hi = range:unpack()
			assert(hi >= lo, "item "..obj.name.." field "..field.." has interval "..tostring(hi)..","..tostring(lo))
			obj[field] = math.random() * (hi - lo) + lo
		end
	end
end

capitalize=|s|s:sub(1,1):upper()..s:sub(2)

serializeTable=|obj|do
	local lines = table()
	lines:insert'{'
	for _,row in ipairs(obj) do
		local s = table()
		for k,v in pairs(row) do
			if type(k) ~= 'string' then k = '['..k..']' end
			v = ('%q'):format(tostring(v))
			s:insert(k..'='..v)
		end
		lines:insert('\t{'..s:concat'; '..'};')
	end
	lines:insert'}'
	return lines:concat'\n'
end
tiletypes = {
	floor = {
		char = '.',
		sprite = tilemapTiles.floor,
	},
	wall = {
		char = '0',
		solid = true,
		sprite = tilemapTiles.wall,
	},
}

con={
	locate=|x,y|do
		con.x=x
		con.y=y
	end,
	write=function(s)
		text(s,(con.x-1)<<3,(con.y-1)<<3,12,16)
		con.x+=#s
	end,
	clearline = function()
		rect(con.x<<3,con.y<<3,screenSize.x,8,16)
		con.x=1
		con.y+=8
	end,
}

Log=class{
	index=0,
	lines=table(),
	size=4,
	__call=|:,s|do
		local lines = string.split(s, '\n')
		for _,line in ipairs(lines) do
			line=self.index..'> '..line
			while #line>ui.size.x do
				self.lines:insert(line:sub(1,ui.size.x))
				line = line:sub(ui.size.x+1)
				self.index+=1
			end
			self.lines:insert(line)
			self.index+=1
		end
		while #self.lines > self.size do
			self.lines:remove(1)
		end
	end,
	render=|:|do
		for i=1,self.size do
			local line = self.lines[i]
			con.locate(1, ui.size.y+i)
			if line then
				con.write(line)
			end
			con.clearline()
		end
	end,
}
log=Log()

MapTile=class{
	init=|:|nil,
	isRevealed=|:|do
		local visibleTime=-math.log(0)
		return self.lastSeen and (game.time - self.lastSeen) < visibleTime
	end,
	getChar=|:|do
		return self.char or self.type.char
	end,
	addEnt=|:,ent|do
		if not self.ents then
			self.ents=table()
		end
		self.ents:insert(ent)
	end,
	removeEnt=|:,ent|do
		assert(self.ents)
		self.ents:removeObject(ent)
		if #self.ents == 0 then
			self.ents=nil
		end
	end,
	draw=|:,x,y|do
		spr(self.type.sprite,x,y,2,2)
	end,
}

map={}
map.size=vec2(256,256)
map.bbox=box2(1, map.size)
map.tiles={}				-- TOOD switch to tilemap, but that means switching all positions from 1-based to 0-based
for i=1,map.size.x do
	map.tiles[i]={}
	for j=1,map.size.y do
		local tile=MapTile()
		tile.type=tiletypes.floor
		map.tiles[i][j]=tile
	end
end

local seeds=table()
for i=1,math.floor(map.size:product()/13) do
	local seed={
		pos=vec2(math.random(map.size.x), math.random(map.size.y)),
	}
	seed.mins=seed.pos:clone()
	seed.maxs=seed.pos:clone()
	seeds:insert(seed)
	map.tiles[seed.pos.x][seed.pos.y].seed=seed
end

local modified
repeat
	modified = false
	for _,seed in ipairs(seeds) do
		local mins = (seed.mins - 1):clamp(map.bbox)
		local maxs = (seed.maxs + 1):clamp(map.bbox)
		local seedcorners = {seed.mins, seed.maxs}
		local corners = {mins, maxs}
		for i,corner in ipairs(corners) do
			local found

			found = nil
			for y=seed.mins.y,seed.maxs.y do
				if map.tiles[corner.x][y].seed then
					found = true
					break
				end
			end
			if not found then
				for y=seed.mins.y,seed.maxs.y do
					map.tiles[corner.x][y].seed = seed
				end
				seedcorners[i].x = corner.x
				modified = true
			end

			found = nil
			for x=seed.mins.x,seed.maxs.x do
				if map.tiles[x][corner.y].seed then
					found = true
					break
				end
			end
			if not found then
				for x=seed.mins.x,seed.maxs.x do
					map.tiles[x][corner.y].seed = seed
				end
				seedcorners[i].y = corner.y
				modified = true
			end
		end
	end
until not modified

for _,seed in ipairs(seeds) do
	local size = seed.maxs - seed.mins - 1
	if size.x < 1 then size.x = 1 end
	if size.y < 1 then size.y = 1 end
	local wall = vec2(
		math.random(size.x) + seed.mins.x,
		math.random(size.y) + seed.mins.y)

	if seed.mins.y > 1 then
		for x=seed.mins.x,seed.maxs.x do
			if x ~= wall.x then
				map.tiles[x][seed.mins.y].type = tiletypes.wall
			end
		end
	end
	if seed.mins.x > 1 then
		for y=seed.mins.y,seed.maxs.y do
			if y ~= wall.y then
				map.tiles[seed.mins.x][y].type = tiletypes.wall
			end
		end
	end
end

for x=1,map.size.x do
	for y=1,map.size.y do
		map.tiles[x][y].seed = nil
	end
end

Battle=class{
	radius=4,
	init=|:,args|do
		if args.bbox then
			self.bbox = box2(args.bbox)
		else
			self.pos=args.pos:clone()
			self.bbox=box2(self.pos-self.radius,self.pos+self.radius):clamp(map.bbox)
		end
		self.armies = table(assert(args.armies))
		self.ents = table()
		for _,army in ipairs(self.armies) do
			for _,ent in ipairs(army.ents) do
				self.ents:insert(ent)
			end
		end
		self.index = 1
		for _,army in ipairs(self.armies) do
			army:beginBattle(self)
		end
		battles:insert(self)
		for i,ent in ipairs(self.ents) do
			ent:beginBattle(self)
			local s = table{'name='..ent.name, 'affil='..tostring(ent.army.affiliation)}
			for _,field in ipairs(Entity.statFields) do
				s:insert(field..'='..ent:stat(field))
			end
			log('Entity '..i..': '..s:concat', ')
		end
		log'starting battle...'
	end,
	update=|:|do
		while not self.done do
			self:getCurrentEnt()
			if not self.currentEnt or self.currentEnt.client then break end
			if self.currentEnt and not self.currentEnt.client then
				while self.currentEnt do
					self.currentEnt:update()
				end
			end
		end
	end,
	removeEnt=|:,ent|do
		self.ents:removeObject(ent)
		if self.currentEnt == ent then
			self.index = self.index - 1
			self:endTurn()
		end
	end,
	getCurrentEnt=|:|do
		if not self.currentEnt then
			while true do
				local ent = self.ents[((self.index - 1) % #self.ents) + 1]
				self.index = (self.index % #self.ents) + 1
				ent.ct = math.min(ent.ct + ent:stat'speed', 100)
				if ent.ct == 100 then
					self.currentEnt = ent
					ent:beginTurn()
					break
				end
			end
		end
	end,
	enemiesOf=|:,ent|do
		local enemies = table()
		for _,army in ipairs(self.armies) do
			if army ~= ent.army then
				for _,enemy in ipairs(army.ents) do
					enemies:insert(enemy)
				end
			end
		end
		return enemies
	end,
	endTurn=|:|do
		self.currentEnt = nil
		local armiesForAffiliation = table()
		for _,army in ipairs(self.armies) do
			local affiliation = army.affiliation or 'nil'
			for _,ent in ipairs(army.ents) do
				if not ent.dead then
					local armies = armiesForAffiliation[affiliation]
					if not armies then
						armies = table()
						armiesForAffiliation[affiliation] = armies
					end
					armies:insert(army)
					break
				end
			end
		end
		local affiliationsAlive = armiesForAffiliation:keys()
		if #affiliationsAlive > 1 then return end
		log'ending battle'
		self.currentEnt = nil
		self.done = true
		for _,ent in ipairs(self.ents) do
			ent:endBattle()
		end
		for _,army in ipairs(self.armies) do
			army:endBattle(self)
		end
		battles:removeObject(self)
		if #affiliationsAlive == 1 then
			for _,affiliation in ipairs(affiliationsAlive) do
				for _,army in ipairs(armiesForAffiliation[affiliation]) do
					for _,ent in ipairs(army.ents) do
						if ent.dead then ent:setDead(false) end
					end
				end
			end
		end
	end,
}

entsAtPos=|pos|do
	if not map.bbox:contains(pos) then return table() end
	return table(map.tiles[pos.x][pos.y].ents)
end

entsAtPositions=|positions|do
	local es = table()
	for _,pos in ipairs(positions) do
		es:append(entsAtPos(pos))
	end
	return es
end

entsWithinRadius=|pos, radius|do
	assert(pos)
	assert(radius)
	local mins = (pos - radius):clamp(map.bbox)
	local maxs = (pos + radius):clamp(map.bbox)

	local closeEnts = table()
	for x=mins.x,maxs.x do
		for y=mins.y,maxs.y do
			closeEnts:append(entsAtPos(vec2(x,y)))
		end
	end
	return closeEnts
end

floodFillTiles=|pos, bbox|do
	bbox = box2(bbox):clamp(map.bbox)
	pos = pos:clone()
	local positions = table{pos}
	local allpositionset = table()
	allpositionset[tostring(pos)] = true
	while #positions > 0 do
		local srcpos = positions:remove(1)
		for _,dir in ipairs(dirs) do
			local newpos = srcpos + dirs[dir]
			if bbox:contains(newpos) then
				local tile = map.tiles[newpos.x][newpos.y]
				if not tile.type.solid then
					if not allpositionset[tostring(newpos)]
					then
						positions:insert(newpos)
						allpositionset[tostring(newpos)] = true
					end
				end
			end
		end
	end
	return allpositionset:keys():map(|v|
		vec2(table.unpack(string.split(v, ','):map(|x| tonumber(x))))
	)
end

pathSearchToPoint=|args|do
	local bbox = assert(args.bbox)
	local start = assert(args.src)
	local dest = assert(args.dst)
	local entBlocking = args.entBlocking
	assert(bbox:contains(start))		-- TODO error here
	assert(bbox:contains(dest))
	local states = table{
		{pos = start:clone()}
	}
	local allpositions = table()
	allpositions[tostring(start:clone())] = true
	local bestState
	local bestDist
	while bestDist ~= 0 and #states > 0 do
		local laststate = states:remove(1)
		for _,dir in ipairs(dirs) do
			local newstate = {
				pos = laststate.pos + dirs[dir],
				laststate = laststate,
				dir = dir,
			}
			local dist = (newstate.pos - dest):l1Length()
			if not bestDist or dist < bestDist then
				bestDist = dist
				bestState = newstate
				if bestDist == 0 then break end
			end
			if bbox:contains(newstate.pos)
			and map.bbox:contains(newstate.pos)
			then
				local tile = map.tiles[newstate.pos.x][newstate.pos.y]
				if not tile.type.solid then
					local blocked
					if tile.ents then
						for _,ent in ipairs(tile.ents) do
							if entBlocking(ent) then
								blocked = true
								break
							end
						end
					end
					if not blocked
					and not allpositions[tostring(newstate.pos)]
					then
						states:insert(newstate)
						allpositions[tostring(newstate.pos)] = true
					end
				end
			end
		end
	end
	local path
	if bestState then
		path = table()
		local state = bestState
		while state do
			path:insert(1, state)
			state = state.laststate
		end
		for i=1,#path-1 do
			path[i].dir = path[i+1].dir
		end
		path[#path].dir = nil
		path:remove()
	end
	return path, bestDist
end

Entity=class{
	name='Entity',
	ct=0,
	level=1,
	exp=0,
	hpMax=50,
	move=3.5,
	speed=7,
	attack=10,
	defense=10,
	hitChance=75,
	evade=5,
	speedLevelUpRange=vec2(0, .1),
	attackLevelUpRange=vec2(0, 1),
	defenseLevelUpRange=vec2(0, 1),
	hitChanceLevelUpRange=vec2(0, 1),
	evadeLevelUpRange=vec2(0,1),
	solid=true,
	attackable=true,
	zOrder=0,
	char='?',
	statFields={
		'level',
		'exp',
		'hpMax',
		'move',
		'speed',
		'attack',
		'defense',
		'hitChance',
		'evade',
	},
	equipFields={
		'weapon',
		'shield',
		'armor',
		'helmet',
	},
	init=|:,args|do
		assert(args.pos)
		self.pos = vec2()
		self.lastpos = vec2()
		self:setPos(assert(args.pos))
		setFieldsByRange(self,self.statFields)
		ents:insert(self)
		assert(args.army):addEnt(self)
		self.hp = self:stat'hpMax'
	
		self.sprite = sprites![self.name]
	end,
	delete=|:|do
		self:setTile(nil)
		if self.army then self.army:removeEnt(self) end
		ents:removeObject(self)
		for _,battle in ipairs(battles) do
			battle:removeEnt(self)
		end
	end,
	addExp=|:,exp|do
		assert(exp)
		exp = math.floor(exp)
		log(self.name..' got '..exp..' experience')
		self.exp = self.exp + exp
		local oldLevel = self.level
		self.level = 10 * math.log(self.exp + 1) / math.log(1.1) + 1
		if math.floor(self.level) > math.floor(oldLevel) then
			for level = math.floor(oldLevel) + 1, math.floor(self.level) do
				for _,field in ipairs(self.equipFields) do
					local range = self[field..'LevelUpRange']
					if range then
						local lo, hi = range:unpack()
						assert(hi >= lo, "item "..obj.name.." field "..field.." has interval "..tostring(hi)..","..tostring(lo))
						self[field] = math.random() * (hi - lo) + lo
					end
				end
			end
			log(self.name..' is now at level '..math.floor(self.level))
		end
	end,
	getChar=|:|do
		local char = self.char
		if self.dead then char = 'd' end
		return char
	end,
	setPos=|:,pos|do
		assert(pos)
		self:setTile(nil)
		self.lastpos:set(self.pos)
		self.pos:set(pos)
		if map.bbox:contains(self.pos) then
			self:setTile(map.tiles[self.pos.x][self.pos.y])
		end
	end,
	setTile=|:,tile|do
		if self.tile then
			self.tile:removeEnt(self)
		end
		self.tile = tile
		if self.tile then
			self.tile:addEnt(self)
		end
	end,
	update=|:|do
		if self.dead then
			if self.battle and self.battle.currentEnt == self then
				self:endTurn()
			end
			return
		end
	end,
	setDead=|:,dead|do
		self.dead = dead
		self.attackable = not dead
		self:setSolid(not dead)
	end,
	setSolid=|:,solid|do
		self.solid = solid
		if not self.solid then
			self.zOrder = -1
		else
			self.zOrder = nil
		end
	end,
	walk=|:,dir|do
		if self.dead then return end
		if self.battle then
			if self.battle.currentEnt ~= self then
				return
			else
				if self.movesLeft <= 0 then
					return
				end
			end
		end
		local newpos = self.pos + assert(dirs[dir], "failed to find dir "..tostring(dir))
		if self.battle then
			newpos:clamp(self.battle.bbox)
		else
			for _,battle in ipairs(battles) do
				if battle.bbox:contains(newpos) then
					return
				end
			end
		end
		newpos:clamp(map.bbox)
		local tiletype = map.tiles[newpos.x][newpos.y].type
		if tiletype.solid then return end
		for _,ent in ipairs(entsAtPos(newpos)) do
			if ent.army.affiliation ~= self.army.affiliation
			and ent.solid
			then
				return
			end
		end
		self:setPos(newpos)
		if self.battle then
			assert(self.battle.currentEnt == self)
			self.movesLeft = self.movesLeft - 1
		end
		return true
	end,
	beginBattle=|:,battle|do
		self.battle = battle
		self.ct = 0
		self.hp = self:stat'hpMax'
		self.movesLeft = 0
	end,
	endBattle=|:|do
		self.battle = nil
	end,
	beginTurn=|:|do
		self.ct = 100
		self.movesLeft = self:stat'move'
		self.turnStartPos = self.pos:clone()
		self.acted = false
		self.army.currentEnt = self
	end,
	endTurn=|:|do
		assert(self.battle)
		assert(self.battle.currentEnt == self)
		self.army.currentEnt = nil
		self.ct = 0
		if self.movesLeft == self:stat'move' then
			self.ct = self.ct + 20
		end
		if not self.acted then
			self.ct = self.ct + 20
		end
		self.battle:endTurn()
	end,
	stat=|:,field|do
		assert(table.find(self.statFields,field))
		local value = self[field]
		assert(type(value) == 'number', "expected stat "..field.." to be a number, but got "..type(value))
		local equipSources = table()
		if self.job then equipSources:insert(self.job) end
		for _,equipField in ipairs(self.equipFields) do
			local equip = self[equipField]
			if equip then equipSources:insert(equip) end
		end
		for _,src in ipairs(equipSources) do
			local equipValue = src[field]
			if equipValue then
				assert(type(equipValue) == 'number', "expected equipment "..equipValue.." stat "..field.." to be a number, but got "..type(equipValue))
				value = value + equipValue
			end
		end
		return math.floor(value)
	end,
	attackDir=|:,dir|do
		self.acted = true
		if self.movesLeft ~= self:stat'move' then self.movesLeft = 0 end
		assert(self.battle)
		assert(self.battle.currentEnt == self)
		local newpos = self.pos + dirs[dir]
		newpos:clamp(self.battle.bbox)
		for _,other in ipairs(entsAtPos(newpos)) do
			if other.attackable then
				self:attackTarget(other)
			end
		end
	end,
	attackTarget=|:,target|do
		local hitChance = math.clamp(self:stat'hitChance' - target:stat'evade', 5, 100)
		log(self.name..' attacks '..target.name..' with a '..hitChance..'% chance to hit')
		if math.random(100) > hitChance then
			log'...miss'
			return
		end
		local defense = target:stat'defense' - .5 * self:stat'attack'
		defense = 1 - math.clamp(defense, 0, 95) / 100
		local dmg = math.ceil(self:stat'attack' * defense)
		target:takeDamage(dmg, self)
	end,
	getExpGiven=|:|do
		return self.level
	end,
	takeDamage=|:,dmg,inflicter|do
		self.hp = math.max(self.hp - dmg, 0)
		log(self.name..' receives '..dmg..' dmg and is at '..self.hp..' hp')
		if self.hp == 0 then
			log(self.name..' is dead')
			inflicter:addExp(self:getExpGiven())
			self:die()
		end
	end,
	die=|:|do
		self:setDead(true)
	end,
	draw=|:,x,y|do
		if self.dead then
			spr(self.sprite,x,y,2,2, 0x20)
		else
			spr(self.sprite,x,y,2,2)
		end
	end,
}

Army=class{
	gold=0,
	init=|:,args|do
		if args then
			self.affiliation = args.affiliation
		end
		self.ents = table()
		self.items = table()
	end,
	addEnt=|:,ent|do
		if ent.army then
			ent.army:removeEnt(ent)
		end
		for _,field in ipairs(ent.equipFields) do
			if ent[field] then
				self:addItem(ent[field])
			end
		end
		ent.army = self
		self.ents:insert(ent)
		if not self.leader then
			self.leader = ent
		end
	end,
	removeEnt=|:,ent|do
		assert(self.ents:find(ent))
		self.ents:removeObject(ent)
		for _,field in ipairs(ent.equipFields) do
			local item = ent[field]
			if item then self:removeItem(item) end
		end
		if ent == self.leader then
			self.leader = self.ents[1]
		end
	end,
	deleteAll=|:|do
		assert(not self.battle, "i don't have deleting armies mid-battle done yet")
		for i=#self.ents,1,-1 do
			self.ents[i]:delete()
		end
	end,
	addItem=|:,item|do
		self.items:insert(item)
	end,
	removeItem=|:,item|do
		for _,ent in ipairs(self.ents) do
			for _,field in ipairs(ent.equipFields) do
				if ent[field] == item then
					ent[field] = nil
				end
			end
		end
		self.items:removeObject(item)
	end,
	addArmy=|:,army|do
		assert(army ~= self)
		for _,ent in ipairs(army.ents) do
			self:addEnt(ent)
		end
		for i=#army.items,1,-1 do
			local item = army.items[i]
			self:addItem(item)
			army.items:remove(i)
		end
	end,
	beginBattle=|:,battle|do
		self.battle = battle
	end,
	endBattle=|:|do
		self.battle = nil
	end,
}

ClientArmy=Army:subclass{
	init=|:,client|do
		ClientArmy.super.init(self)
		self.client = client
	end,
	addEnt=|:,ent|do
		ClientArmy.super.addEnt(self, ent)
		ent.client = client
	end,
	removeEnt=|:,ent|do
		ClientArmy.super.removeEnt(self, ent)
		ent.client = nil
	end,
	beginBattle=|:,battle|do
		ClientArmy.super.beginBattle(self, battle)
		self.client:removeToState(Client.mainCmdState)
		self.client:pushState(Client.battleCmdState)
	end,
	endBattle=|:,battle|do
		ClientArmy.super.endBattle(self, battle)
		assert(self.client.cmdstate == Client.battleCmdState, "expected client cmdstate to be battleCmdState")
		self.client:popState()
	end,
}

local sizes=table{
	'tiny',
	'small',
	'medium',
	'large',
	'giant',
	'super',
}

local elements=string.split(string.trim[[
water
frost
fire
earth
]], '\n')

local modifiers=string.split(string.trim[[
mud
great
humanoid
beast
arachnid
demon
undead
bone
magic
were
sea
]], '\n')

Unit=Entity:subclass()
Unit.canBattle=true
Unit.name='Unit'
Unit.char='U'
Unit.baseTypes=table{
	{name='Spider', bodyType='arachnid', size='tiny', weight=.1},
	{name='Snake', bodyType='reptile', size='small', weight=.5},
	{name='Lobster', bodyType='crustacean', size='tiny', weight=1},
	{name='Cat', bodyType='beast', size='small', weight=10},
	{name='Blob', bodyType='gelatinous', size='small', weight=10},
	{name='Imp', bodyType='humaniod', size='medium', weight=50},
	{name='Wolf', bodyType='beast', size='medium', weight=85},
	{name='Goblin', bodyType='humaniod', size='medium', weight=120},
	{name='Dwarf', bodyType='humaniod', size='medium', weight=150},
	{name='Human', bodyType='humaniod', size='medium', weight=150},
	{name='Elf', bodyType='humaniod', size='medium', weight=140},
	{name='Zombie', bodyType='humaniod', size='medium', weight=150},
	{name='Troll', bodyType='humanoid', size='medium', weight=250},
	{name='Gargoyle', bodyType='bird', size='large', weight=10000},
	{name='Golem', bodyType='humanoid', size='large', weight=300},
	{name='Ogre', bodyType='humanoid', size='large', weight=300},
	{name='Bull', bodyType='beast', size='large', weight=1000},
	{name='Lion', bodyType='beast', size='large', weight=550},
	{name='Liger', bodyType='beast', size='giant', weight=1800},
	{name='Giant', bodyType='humanoid', size='giant', weight=1500},
	{name='Dragon', bodyType='reptile', size='super', weight=7500},
	{name='T-rex', bodyType='reptile', size='super', weight=15000},
}
for i=1,#Unit.baseTypes do
	local baseType=Unit.baseTypes[i]
	for _,stat in ipairs(Unit.statFields) do
		if stat~='level'
		and stat~='exp'
		then
			baseType[stat..'Range']=vec2(
				-math.random() * Unit[stat] * .1,
				math.random() * Unit[stat] * .1
			)
		end
	end
	for _,baseField in ipairs(Unit.statFields) do
		local rangeField=baseField..'Range'
		if baseType[rangeField] then
			local min=1 - (Unit[baseField] or 0)
			if baseType[rangeField].x < min then baseType[rangeField].x = min end
		end
	end
	for _,baseField in ipairs(Unit.statFields) do
		local field = baseField..'Range'
		if baseType[field] then
			if baseType[field].y < baseType[field].x then
				baseType[field].y = baseType[field].x
			end
		end
	end
	Unit.baseTypes[i] = baseType
	Unit.baseTypes[baseType.name] = baseType
end
Unit.init=|:,args|do
	if self.baseType then
		for _,baseField in ipairs(self.statFields) do
			local field = baseField..'Range'
			if self[field] or self.baseType[field] then
				self[field] = (self[baseField] or vec2()) + (self.baseType[field] or vec2())
			end
		end
	end
	Unit.super.init(self, args)
end
Unit.update=|:|do
	Unit.super.update(self)
	if self.dead then return end
	if not self.client then
		if self.battle then
			if self.battle.currentEnt == self then
				local pathsForEnemies = table()
				for _,enemy in ipairs(self.battle:enemiesOf(self)) do
					if not enemy.dead
					and enemy.army.affiliation ~= self.army.affiliation
					then
						local path, dist = pathSearchToPoint{	-- TODO error pathSearchToPoint contains self.pos or enemy.pos
							src=self.pos,
							dst=enemy.pos,
							bbox=self.battle.bbox,
							entBlocking = |ent|ent.solid and ent.army.affiliation ~= self.army.affiliation,
						}
						pathsForEnemies:insert{
							enemy = enemy,
							path = path,
						}
					end
				end
				if #pathsForEnemies == 0 then
					self:endTurn()
					return
				end
				pathsForEnemies:sort(|a,b| #a.path < #b.path)
				local path = pathsForEnemies[1].path
				if path then
					if #path > 1 then
						self:walk(path:remove(1).dir)
					end
					if #path == 1 then
						self:attackDir(path:remove(1).dir)
					end
					if self.acted or self.movesLeft == 0 or #path == 0 then
						self:endTurn()
					end
				else
					log("*** failed to find path ***")
					self:endTurn()
				end
			end
		else
			if self.wanderIdle and math.random(4) == 4 then
				self:walk(dirs[math.random(#dirs)])
			end
		end
	else
		if not self.battle then
			if self.army.leader ~= self then
				local i = self.army.ents:find(self)
				assert(i > 1)
				local followme = assert(self.army.ents[i-1])
				local followBox = box2(self.pos)
				followBox:stretch(followme.pos)
				followBox.min = followBox.min - 5
				followBox.max = followBox.max + 5

				local path, dist = pathSearchToPoint{
					src = self.pos,
					dst = followme.pos,
					bbox = followBox,
					entBlocking = |ent|ent.solid and ent.army.affiliation ~= self.army.affiliation,
				}
				if #path > 1 then
					self:walk(path:remove(1).dir)
				end
			end
			local getEnts = entsAtPos(self.pos)
			if getEnts then
				for _,ent in ipairs(getEnts) do
					if ent.get then
						ent:get(self)
					end
				end
			end
		end
		self:checkBattle()
		self:updateFog()
	end
end
Unit.updateFog=|:|do
	local radius = 4
	local fogTiles = floodFillTiles(self.pos, box2(self.pos - radius, self.pos + radius))
	for _,pos in ipairs(fogTiles) do
		for _,dir in ipairs(dirs) do
			local ofspos = (dirs[dir] + pos):clamp(map.bbox)
			map.tiles[ofspos.x][ofspos.y].lastSeen = game.time
		end
	end
end
Unit.checkBattle=|:|do
	if self.battle then return end
	local searchRadius = 3
	local closeEnts = entsAtPositions(floodFillTiles(self.pos, box2(self.pos-searchRadius,self.pos+searchRadius)))
	closeEnts = closeEnts:filter(|ent|
		ent.canBattle
			and not ent.dead
			and ent.army.affiliation ~= self.army.affiliation
	)
	if #closeEnts > 0 then
		local battleBox = box2(self.pos - Battle.radius, self.pos + Battle.radius)
		local armies = table()
		local battlePositions
		while true do
			battlePositions = floodFillTiles(self.pos, battleBox)
			local battleEnts = entsAtPositions(battlePositions):filter(|ent|ent.canBattle and not ent.dead)
			local stretchedBBox
			armies = table()
			for _,ent in ipairs(battleEnts) do
				armies:insertUnique(ent.army)
				if not stretchedBBox then
					stretchedBBox = box2(ent.pos, ent.pos)
				else
					stretchedBBox:stretch(ent.pos)
				end
			end
			local size = stretchedBBox:size()
			for _,i in ipairs(vec2.fields) do
				local width = 2 * Battle.radius + 1
				if size[i] < width then
					local diff = width - size[i]
					size[i] = width
					stretchedBBox.min[i] = stretchedBBox.min[i] - math.floor(diff / 2)
					stretchedBBox.max[i] = stretchedBBox.max[i] + math.ceil(diff / 2)
				end
			end
			if not battleBox:contains(stretchedBBox) then
				battleBox:stretch(stretchedBBox)
			else
				break
			end
		end
		Battle{armies=armies, bbox=battleBox}
		for _,pos in ipairs(battlePositions) do
			for _,dir in ipairs(dirs) do
				local ofspos = (dirs[dir] + pos):clamp(map.bbox)
				map.tiles[ofspos.x][ofspos.y].lastSeen = game.time
			end
		end
	end
end
Unit.die=|:|do
	Unit.super.die(self)
	local lastToDie = true
	for _,ent in ipairs(self.army.ents) do
		if ent ~= self and not ent.dead then
			lastToDie = false
			break
		end
	end
	local t = Treasure{
		pos = self.pos,
		army = Army(),
	}
	if lastToDie then
		t.army.gold = self.army.gold
		self.army.gold = 0
	end
	for _,equip in ipairs(self.equipFields) do
		local item = self[equip]
		if item then
			self.army:removeItem(item)
			t.army:addItem(item)
		end
	end
	if lastToDie then
		for i=#self.army.items,1,-1 do
			local item = self.army.items[i]
			self.army:removeItem(item)
			t.army:addItem(item)
		end
	end
end

Player = Unit:subclass()
Player.name = 'Player'
Player.char = 'P'
Player.baseType = Unit.baseTypes.Human

Treasure = Entity:subclass()
Treasure.name = 'Treasure'
Treasure.char = '$'
Treasure.solid = false
Treasure.attackable = false
Treasure.zOrder = -.5

Treasure.init=|:,args|do
	Treasure.super.init(self, args)
	if args.gold then
		self.army.gold = self.army.gold + tonumber(args.gold)
	end
	self.pickupRandom = args.pickupRandom
end

Treasure.get=|:,who|do
	if self.pickupRandom then
		for i=1,math.random(3) do
			local item = items[math.random(#items)]
			self.army:addItem(item(who.level))
		end
	end
	local gottext = table()
	if #self.army.items > 0 then
		gottext:insert(self.army.items:map(|item|item.name):concat', ')
	end
	if self.army.gold > 0 then
		gottext:insert(self.army.gold..' gold')
	end
	if #gottext > 0 then
		log(who.name..' got '..gottext:concat', ')
	end
	for _,item in ipairs(self.army.items) do
		who.army:addItem(item)
	end
	who.army.gold = who.army.gold + self.army.gold
	self.army:deleteAll()
end

local Item = class()
Item.__lt=|a,b|((items:find(getmetatable(a)) or 0)<(items:find(getmetatable(b)) or 0))

local Potion=Item:subclass()
Potion.name='Potion'
Potion.healRange = vec2(20,30)
Potion.init=|:,...|do
	if Potion.super.init then Potion.super.init(self, ...) end
	setFieldsByRange(self, {'heal'})
	self.heal = math.floor(self.heal)
	self.name = self.name .. '(+'..self.heal..')'
end
Potion.use=|:,who|do
	who.hp = math.min(who.hp + self.heal, who:stat'hpMax')
end

local Equipment = Item:subclass{
	init=|:,maxLevel|do
		assert(self.baseTypes, "tried to instanciate an equipment of type "..self.name.." with no basetypes")
		local baseTypeOptions = table(self.baseTypes)
		local modifierOptions = table(self.modifiers)
		if maxLevel then
			local filter = |baseType|do
				return not baseType.dropLevel or baseType.dropLevel <= maxLevel
			end
			baseTypeOptions = baseTypeOptions:filter(filter)
			modifierOptions = modifierOptions:filter(filter)
		end
		local baseType = baseTypeOptions[math.random(#baseTypeOptions)]
		local modifier = modifierOptions[math.random(#modifierOptions)]
		self.name = modifier.name
		if self.name ~= '' then self.name = self.name..' ' end
		self.name = self.name..baseType.name
		for _,baseField in ipairs(Entity.statFields) do
			if table.find(self.modifierFields, baseField) then
				local field = baseField..'Range'
				local range = vec2()

				if self[field] then range += self[field] end
				if baseType[field] then range += baseType[field] end
				if modifier[field] then range += modifier[field] end
				self[field] = range
			end
		end
		setFieldsByRange(self,Entity.statFields)
	end,
}

local weaponBaseTypes = {
	{name='Derp', attackRange=5, hitChanceRange=5, dropLevel=0},
	{name='Dagger', attackRange=10, hitChanceRange=10, dropLevel=1},
	{name='Sword', attackRange=15, hitChanceRange=15, dropLevel=2},
	{name='Flail', attackRange=20, hitChanceRange=20, dropLevel=3},
	{name='Axe', attackRange=25, hitChanceRange=25, dropLevel=4},
	{name='Boomerang', attackRange=30, hitChanceRange=30, dropLevel=5},
	{name='Bow', attackRange=35, hitChanceRange=35, dropLevel=6},
	{name='Star', attackRange=40, hitChanceRange=40, dropLevel=7},
	{name='Bow', attackRange=45, hitChanceRange=45, dropLevel=8},
}
for _,weapon in ipairs(weaponBaseTypes) do
	weapon.attackRange = vec2(math.floor(weapon.attackRange * .75), weapon.attackRange)
	weapon.hitChanceRange = vec2(math.floor(weapon.hitChanceRange * .75), weapon.hitChanceRange)
end

local weaponModifiers = {
	{name="Plain ol'"},
	{name='Short', attackRange=vec2(0,5), hitChanceRange=vec2(0,10), dropLevel=0},
	{name='Long', attackRange=vec2(3,8), hitChanceRange=vec2(5,15), dropLevel=5},
	{name='Heavy', attackRange=vec2(3,8), hitChanceRange=vec2(5,15), dropLevel=10},
	{name='Bastard', attackRange=vec2(0,10), hitChanceRange=vec2(10,20), dropLevel=15},
	{name='Demon', attackRange=vec2(20,20), hitChanceRange=vec2(30,35), dropLevel=20},
	{name='Were', attackRange=vec2(20,25), hitChanceRange=vec2(35,45), dropLevel=25},
	{name='Rune', attackRange=vec2(30,35), hitChanceRange=vec2(40,50), dropLevel=30},
	{name='Dragon', attackRange=vec2(30,40), hitChanceRange=vec2(40,50), dropLevel=35},
	{name='Quick', attackRange=vec2(40,45), hitChanceRange=vec2(90,100), dropLevel=40},
}

local defenseModifiers = {
	{name="Cloth", defenseRange=vec2(1,2), hpMaxRange=vec2(1,2), evadeRange=vec2(1,2), dropLevel=0},
	{name="Leather", defenseRange=vec2(2,3), hpMaxRange=vec2(2,3), evadeRange=vec2(2,3), dropLevel=5},
	{name="Wooden", defenseRange=vec2(3,4), hpMaxRange=vec2(3,4), evadeRange=vec2(3,4), dropLevel=10},
	{name="Chain", defenseRange=vec2(3,4), hpMaxRange=vec2(3,4), evadeRange=vec2(3,4), dropLevel=15},
	{name="Plate", defenseRange=vec2(4,6), hpMaxRange=vec2(4,6), evadeRange=vec2(4,6), dropLevel=20},
	{name="Copper", defenseRange=vec2(5,7), hpMaxRange=vec2(5,7), evadeRange=vec2(5,7), dropLevel=25},
	{name="Iron", defenseRange=vec2(7,10), hpMaxRange=vec2(7,10), evadeRange=vec2(7,10), dropLevel=30},
	{name="Bronze", defenseRange=vec2(9,13), hpMaxRange=vec2(9,13), evadeRange=vec2(9,13), dropLevel=35},
	{name="Steel", defenseRange=vec2(12,16), hpMaxRange=vec2(12,16), evadeRange=vec2(12,16), dropLevel=40},
	{name="Silver", defenseRange=vec2(15,21), hpMaxRange=vec2(15,21), evadeRange=vec2(15,21), dropLevel=45},
	{name="Gold", defenseRange=vec2(21,28), hpMaxRange=vec2(21,28), evadeRange=vec2(21,28), dropLevel=50},
	{name="Crystal", defenseRange=vec2(27,37), hpMaxRange=vec2(27,37), evadeRange=vec2(27,37), dropLevel=55},
	{name="Opal", defenseRange=vec2(36,48), hpMaxRange=vec2(36,48), evadeRange=vec2(36,48), dropLevel=60},
	{name="Platinum", defenseRange=vec2(48,64), hpMaxRange=vec2(48,64), evadeRange=vec2(48,64), dropLevel=65},
	{name="Plutonium", defenseRange=vec2(63,84), hpMaxRange=vec2(63,84), evadeRange=vec2(63,84), dropLevel=70},
	{name="Adamantium", defenseRange=vec2(82,110), hpMaxRange=vec2(82,110), evadeRange=vec2(82,110), dropLevel=75},
	{name="Potassium", defenseRange=vec2(108,145), hpMaxRange=vec2(108,145), evadeRange=vec2(108,145), dropLevel=80},
	{name="Osmium", defenseRange=vec2(143,191), hpMaxRange=vec2(143,191), evadeRange=vec2(143,191), dropLevel=85},
	{name="Holmium", defenseRange=vec2(189,252), hpMaxRange=vec2(189,252), evadeRange=vec2(189,252), dropLevel=90},
	{name="Mithril", defenseRange=vec2(249,332), hpMaxRange=vec2(249,332), evadeRange=vec2(249,332), dropLevel=95},
	{name="Aegis", defenseRange=vec2(327,437), hpMaxRange=vec2(327,437), evadeRange=vec2(327,437), dropLevel=100},
	{name="Genji", defenseRange=vec2(432,576), hpMaxRange=vec2(432,576), evadeRange=vec2(432,576), dropLevel=105},
	{name="Pro", defenseRange=vec2(569,759), hpMaxRange=vec2(569,759), evadeRange=vec2(569,759), dropLevel=110},
	{name="Diamond", defenseRange=vec2(750,1000), hpMaxRange=vec2(750,1000), evadeRange=vec2(750,1000), dropLevel=115},
}

local Weapon = Equipment:subclass()
Weapon.name = 'Weapon'
Weapon.equip = 'weapon'
Weapon.baseTypes = weaponBaseTypes
Weapon.modifiers = weaponModifiers
Weapon.modifierFields = {'attack','hitChance'}

local Armor = Equipment:subclass()
Armor.name = 'Armor'
Armor.equip = 'armor'
Armor.baseTypes = {
	{name='Armor'},
}
Armor.modifiers = defenseModifiers
Armor.modifierFields = {'defense','hpMax'}

local Helmet = Equipment:subclass()
Helmet.name = 'Helmet'
Helmet.equip = 'helmet'
Helmet.baseTypes = {
	{name='Helmet'},
}
Helmet.modifiers = defenseModifiers
Helmet.modifierFields = {'defense'}

local Shield = Equipment:subclass()
Shield.name = 'Shield'
Shield.equip = 'shield'
Shield.baseTypes = {
	{name='Buckler'},
	{name='Shield', evadeRange=vec2(5,10)},
}
Shield.modifiers = defenseModifiers
Shield.modifierFields = {'defense','evade'}

items = table{
	Potion,
	Weapon,
	Armor,
	Helmet,
	Shield,
}

for _,item in ipairs(items) do
	items[assert(item.name)] = item
end

Monster = Unit:subclass()
Monster.wanderIdle = true
Monster.init=|:,...|do
	local smallest
	for _,baseType in ipairs(Unit.baseTypes) do
		local v = -math.log(baseType.weight)
		smallest = math.min(smallest or v, v)
	end
	local weight = 0
	for _,baseType in ipairs(Unit.baseTypes) do
		weight = weight + (-math.log(baseType.weight) - smallest)
	end
	weight = math.random() * weight
	for _,baseType in ipairs(Unit.baseTypes) do
		weight = weight - (-math.log(baseType.weight) - smallest)
		if weight < 0 then
			self.baseType = baseType
			break
		end
	end
	self.name = self.baseType.name
	self.char = self.name:sub(1,1)
	Monster.super.init(self, ...)
	self.army.gold = self.army.gold + (math.random(11) - 1) * 10
end

-- divide 8 cuz font size is 8
local UISize = (screenSize/8-vec2(0,4)):floor()
UI=class{
	size=UISize,
	bbox=box2(1, UISize),
	center=(UISize/2):ceil(),
	-- used for both game and ui
	drawBorder=|:,b|do
		local mins = b.min
		local maxs = b.max
		for x=mins.x+1,maxs.x-1 do
			if mins.y >= 1 and mins.y <= ui.size.y then
				con.locate(x, mins.y)
				con.write'\151'	--'-'
			end
			if maxs.y >= 1 and maxs.y <= ui.size.y then
				con.locate(x, maxs.y)
				con.write'\156'	--'-'
			end
		end
		for y=mins.y+1,maxs.y-1 do
			if mins.x >= 1 and mins.x <= ui.size.x then
				con.locate(mins.x, y)
				con.write'\153'	--'|'
			end
			if maxs.x >= 1 and maxs.x <= ui.size.x then
				con.locate(maxs.x, y)
				con.write'\154'	--'|'
			end
		end
		local minmax = {mins, maxs}
		local asciicorner = {{'\150','\155'},{'\152','\157'}}
		for x=1,2 do
			for y=1,2 do
				local v = vec2(minmax[x].x, minmax[y].y)
				if ui.bbox:contains(v) then
					con.locate(v:unpack())
					con.write(asciicorner[x][y])	--'+'
				end
			end
		end
	end,
	fillBox=|:,b|do
		b = box2(b):clamp(ui.bbox)
		for y=b.min.y,b.max.y do
			con.locate(b.min.x, y)
			con.write((' '):rep(b.max.x - b.min.x + 1))
		end
	end,
}
ui=UI()

View=class()
View.size=(screenSize/16):floor()
View.bbox=box2(1,View.size)
View.center = (View.size/2):ceil()
View.update=|:,mapCenter|do
	self.delta= mapCenter - self.center
end
View.drawBorder=|:,b|do
	rectb(
		16 * b.min.x,
		16 * b.min.y,
		16 * (b.max.x - b.min.x),
		16 * (b.max.y - b.min.y),
		12
	)
end
view = View()

Client=class{
	maxArmySize=4,
}

WindowLine=class{
	text='',
	init=|:,args|do
		if type(args) == 'string' then args = {text=args} end
		self.text = args.text
		self.cantSelect = args.cantSelect
		self.onSelect = args.onSelect
	end,
}

Window=class{
	init=|:,args|do
		self.fixed = args.fixed
		self.currentLine = 1
		self.firstLine = 1
		self.pos = (args.pos or vec2(1,1)):clone()
		self.size = (args.size or vec2(1,1)):clone()
		self:refreshBorder()
		self:setLines(args.lines or {})
	end,
	setPos=|:,pos|do
		self.pos:set(assert(pos))
		self:refreshBorder()
	end,
	refreshBorder=|:|do
		self.border = box2(self.pos, self.pos + self.size - 1)
	end,
	setLines=|:,lines|do
		self.lines = table.map(lines, |line|((WindowLine(line))))
		self.textWidth = 0
		self.selectableLines = table()
		for index,line in ipairs(self.lines) do
			self.textWidth = math.max(self.textWidth, #line.text)
			line.row = index
			if not line.cantSelect then
				self.selectableLines:insert(line)
			end
		end
		if not self.fixed then
			self.size = (vec2(self.textWidth + 1, #self.lines) + 2):clamp(ui.bbox)
			self:refreshBorder()
		end
	end,
	moveCursor=|:,ch|do
		if #self.selectableLines == 0 then
			self.currentLine = 1
		else
			if ch == 'down' then
				self.currentLine = self.currentLine % #self.selectableLines + 1
			elseif ch == 'up' then
				self.currentLine = (self.currentLine - 2) % #self.selectableLines + 1
			end
			local row = self.selectableLines[self.currentLine].row
			if row < self.firstLine then
				self.firstLine = row
			elseif row > self.firstLine + (self.size.y - 3) then
				self.firstLine = row - (self.size.y - 3)
			end
		end
	end,
	chooseCursor=|:|do
		if #self.selectableLines > 0 then
			self.currentLine = (self.currentLine - 1) % #self.selectableLines + 1
			local line = self.selectableLines[self.currentLine]
			if line.onSelect then line.onSelect() end
		end
	end,
	draw=|:|do
		ui:drawBorder(self.border)
		local box = box2(self.border.min+1, self.border.max-1)
		ui:fillBox(box)
		local cursor = box.min:clone()
		local i = self.firstLine
		while cursor.y < self.border.max.y
		and i <= #self.lines
		do
			local line = self.lines[i]
			con.locate(cursor:unpack())
			if not self.noInteraction
			and line == self.selectableLines[self.currentLine]
			then
				con.write'>'
			else
				con.write' '
			end
			con.write(line.text)
			cursor.y += 1
			i += 1
		end
	end,
}

DoneWindow=Window:subclass{
	refresh=|:,text|do
		self:setLines{text}
	end,
}

QuitWindow=Window:subclass{
	init=|:,args|do
		local client = assert(args.client)
		QuitWindow.super.init(self, args)
		self:setLines{
			{text='Quit?', cantSelect=true},
			{text='-----', cantSelect=true},
			{text='Yes', onSelect=||do
				-- TODO exit to title or something
			end},
			{text='No', onSelect=||client:popState()},
		}
	end,
}

ClientBaseWindow=Window:subclass{
	init=|:,args|do
		ClientBaseWindow.super.init(self, args)
		self.client = assert(args.client)
		self.army = self.client.army
	end,
}

MoveFinishedWindow=ClientBaseWindow:subclass{
	refresh=|:|do
		local lines = table()
		local solidfound
		for _,e in ipairs(entsAtPos(self.client.army.currentEnt.pos)) do
			if e ~= self.client.army.currentEnt and e.solid then
				solidfound = true
				break
			end
		end
		if not solidfound then
			lines:insert{
				text = 'Ok',
				onSelect = ||do
					self.client.army.currentEnt.movesLeft = 0
					self.client:popState()
					self.client:popState()
				end,
			}
		end
		lines:insert{
			text='Cancel',
			onSelect=||do
				local currentEnt=self.client.army.currentEnt
				currentEnt:setPos(currentEnt.turnStartPos)
				currentEnt.movesLeft=currentEnt:stat'move'
				self.client:popState()
				self.client:popState()
			end,
		}
		self:setLines(lines)
	end,
}

MapOptionsWindow=ClientBaseWindow:subclass{
	init=|:,args|do
		MapOptionsWindow.super.init(self, args)
		self:refresh()
	end,
	refresh=|:|do
		local lines = table()
		lines:insert{
			text = 'Status',
			onSelect = ||self.client:pushState(Client.armyCmdState),
		}
		lines:insert{
			text = 'Inspect',
			onSelect = ||self.client:pushState(Client.inspectCmdState),
		}
		if #self.client.army.ents < Client.maxArmySize then
			lines:insert{
				text = 'Recruit',
				onSelect = ||do
					if #self.client.army.ents < Client.maxArmySize then
						self.client:pushState(Client.recruitCmdState)
					end
				end,
			}
		end
		lines:insert{
			text = 'Quit',
			onSelect = ||self.client:pushState(Client.quitCmdState),
		}
		lines:insert{
			text = 'Done',
			onSelect = ||self.client:popState(),
		}
		self:setLines(lines)
	end,
}

refreshWinPlayers=|client|do
	local player = client.army.ents[client.armyWin.currentLine]
	for _,field in ipairs{'statWin','equipWin','itemWin'} do
		local win = client[field]
		win.player = player
	end
end

ArmyWindow=ClientBaseWindow:subclass{
	refresh=|:|do
		local lines = table()
		for _,ent in ipairs(self.army.ents) do
			lines:insert(ent.name)
		end
		self:setLines(lines)
	end,
	moveCursor=|:,ch|do
		ArmyWindow.super.moveCursor(self, ch)
		refreshWinPlayers(self.client)
		self.client.statWin:refresh()
	end,
}

local shorthandStat={
	level='Lv. ',
	exp='Exp.',
	hpMax='HP  ',
	speed='Spd.',
	attack='Atk.',
	defense='Def.',
	hitChance='Hit%',
	evade='Ev.%',
}
StatWindow=ClientBaseWindow:subclass{
	noInteraction=true,
	refresh=|:,field,equip|do
		local recordStats=|dest|do
			local stats=table()
			for _,field in ipairs(self.player.statFields) do
				stats[field]=self.player:stat(field)
			end
			return stats
		end
		local currentStats=recordStats()
		local equipStats
		if field then
			local lastEquip=self.player[field]
			self.player[field]=equip
			equipStats=recordStats()
			self.player[field]=lastEquip
		end
		local lines=table()
		for _,field in ipairs(self.player.statFields) do
			local fieldName=shorthandStat[field]or field
			local value=currentStats[field]
			if equipStats and equipStats[field] then
				local dif=equipStats[field] - currentStats[field]
				if dif ~= 0 then
					local sign=dif>0 and'+'or''
					value='('..sign..dif..')'
				end
			end
			if self.client.army.battle and field == 'hpMax' then
				value=self.player.hp..'/'..value
			end
			local s=fieldName..' '..value
			lines:insert(s)
		end
		lines:insert('gold '..self.client.army.gold)

		self:setLines(lines)
	end,
}

local shorthandFields={
	weapon='\132',
	shield='\141',
	armor='\143',
	helmet='\142',
}
EquipWindow=ClientBaseWindow:subclass{
	refresh=|:|do
		local lines=table()
		local width=0
		for _,field in ipairs(self.player.equipFields) do
			local fieldName=shorthandFields[field]or field
			width=math.max(width, #fieldName)
		end
		for _,field in ipairs(self.player.equipFields) do
			local fieldName=shorthandFields[field]or field
			local s=(' '):rep(width - #fieldName)..fieldName..': '
			local equip=self.player[field]
			if equip then
				s..=equip.name
			else
				s..='[Empty]'
			end
			lines:insert(s)
		end
		self:setLines(lines)
	end,
}

local refreshEquipStatWin=|client|do
	local item=client.itemWin.items[client.itemWin.currentLine]
	if item then
		local field=assert(client.itemWin.player.equipFields[client.equipWin.currentLine])
		if field then
			client.statWin:refresh(field, item)
		end
	end
end

ItemWindow=ClientBaseWindow:subclass{
	moveCursor=|:,ch|do
		ItemWindow.super.moveCursor(self, ch)
		if self.client.cmdstate==Client.chooseEquipCmdState then
			refreshEquipStatWin(self.client)
		end
	end,
	chooseCursor=|:|do
		ItemWindow.super.chooseCursor(self)
		if self.client.cmdstate==Client.chooseEquipCmdState then
			local player=client.equipWin.player
			local field=assert(player.equipFields[client.equipWin.currentLine])
			local equip=client.itemWin.items[client.itemWin.currentLine]
			if player[field] == equip then
				player[field]=nil
			else
				player[field]=equip
			end
			client.equipWin:setPos(vec2(client.statWin.border.max.x+1, client.statWin.border.min.y))
			client.equipWin:refresh()
			client.itemWin:refresh(|item|do
				if item.equip ~= field then return false end
				for _,p2 in ipairs(client.army.ents) do
					if p2 ~= player then
						for _,f2 in ipairs(p2.equipFields) do
							if p2[f2] == item then return false end
						end
					end
				end
				return true
			end)
			--client.itemWin:setPos(vec2(client.equipWin.border.max.x+1, client.equipWin.border.min.y))
			client.itemWin:setPos(vec2(client.equipWin.border.min.x, client.equipWin.border.max.y+1))
			refreshEquipStatWin(client)
		end
	end,
	refresh=|:,filter|do
		local lines=table()
		self.items=table()
		for _,item in ipairs(self.client.army.items) do
			local good=true
			if filter then good=filter(item) end
			if good then
				self.items:insert(item)
				lines:insert(item.name)
			end
		end
		for _,player in ipairs(self.client.army.ents) do
			for _,field in ipairs(player.equipFields) do
				if player[field] then
					local index=self.items:find(player[field])
					if index then lines[index]=lines[index] .. ' (E)' end
				end
			end
		end
		self:setLines(lines)
	end,
}

PlayerWindow=ClientBaseWindow:subclass{
	init=|:,args|do
		PlayerWindow.super.init(self, args)
		self:setLines{
			{
				text='Equip',
				onSelect=||self.client:pushState(Client.equipCmdState),
			},
			{
				text='Use',
				onSelect=||self.client:pushState(Client.itemCmdState),
			},
			{
				text='Drop',
				onSelect=||self.client:pushState(Client.dropItemCmdState),
			},
		}
	end,
}

BattleWindow=ClientBaseWindow:subclass{
	refresh=|:|do
		local client=self.client
		local currentEnt=client.army.currentEnt
		local lines=table()
		if currentEnt.movesLeft > 0 then
			lines:insert{
				text='Move',
				onSelect=||client:pushState(Client.battleMoveCmdState),
			}
		end
		if not currentEnt.acted then
			lines:insert{
				text='Attack',
				onSelect=||client:pushState(Client.attackCmdState),
			}
			if #client.army.items > 0 then
				lines:insert{
					text='Use',
					onSelect=||client:pushState(Client.itemCmdState),
				}
			end
		end
		local getEnt
		for _,ent in ipairs(entsAtPos(currentEnt.pos)) do
			if ent.get then
				getEnt=true
				break
			end
		end
		if getEnt then
			lines:insert{
				text='Get',
				onSelect=||do
					for _,ent in ipairs(entsAtPos(currentEnt.pos)) do
						if ent.get then
							currentEnt.movesLeft=0
							ent:get(currentEnt)
						end
					end
				end,
			}
		end
		lines:insert{
			text='End Turn',
			onSelect=||currentEnt:endTurn(),
		}
		lines:insert{
			text='Party',
			onSelect=||client:pushState(Client.armyCmdState),
		}
		lines:insert{
			text='Inspect',
			onSelect=||self.client:pushState(Client.inspectCmdState),
		}
		lines:insert{
			text='Quit',
			onSelect=||client:pushState(Client.quitCmdState),
		}
		self:setLines(lines)
	end,
}

local cmdPopState={
	name='Done',
	exec=|client,cmd,ch|client:popState(),
}

local makeCmdPushState=|name,state,disabled|do
	assert(state)
	return {
		name=name,
		exec=|:,cmd,ch|self:pushState(state),
		disabled=disabled,
	}
end

local makeCmdWindowMoveCursor=|winField|do
	return {
		name='Scroll',
		exec=|client,cmd,ch|do
			local win=assert(client[winField])
			win:moveCursor(ch)
		end,
	}
end

local makeCmdWindowChooseCursor=|winField|do
	return {
		name='Choose',
		exec=|client,cmd,ch|do
			local win=assert(client[winField])
			win:chooseCursor()
		end,
	}
end

local cmdMove={
	name='Move',
	exec=|client,cmd,ch|do
		if not client.army.battle then
			client.army.leader:walk(ch)
		else
			client.army.currentEnt:walk(ch)
		end
	end,
}

local refreshStatusToInspect=|client|do
	local ents=entsAtPos(client.inspectPos)
	if #ents>0 then
		local ent=ents[tstamp()%#ents+1]
		client.statWin.player=ent
		client.statWin:refresh()
	else
		client.statWin:setLines{'>Close'}
	end
end

local cmdInspectMove={
	name='Move',
	exec=|client,cmd,ch|do
		client.inspectPos=client.inspectPos+dirs[ch]
		refreshStatusToInspect(client)
	end,
}

Client.inspectCmdState={
	cmds={
		up=cmdInspectMove,
		down=cmdInspectMove,
		left=cmdInspectMove,
		right=cmdInspectMove,
		space=cmdPopState,
	},
	enter=|client, state|do
		client.inspectPos=client.army.leader.pos:clone()
		client.statWin:setPos(vec2(1,1))
		refreshStatusToInspect(client)
	end,
	draw=|client, state|do
		local viewpos=client.inspectPos-view.delta
		if view.bbox:contains(viewpos) then
			text('X', viewpos.x * 16 + 4, viewpos.y * 16 + 4, 12, 16)
		end
		client.statWin:draw()
	end,
}
Client.chooseEquipCmdState={
	cmds={
		left=cmdPopState,
		up=makeCmdWindowMoveCursor'itemWin',
		down=makeCmdWindowMoveCursor'itemWin',
		space=makeCmdWindowChooseCursor'itemWin',
	},
	enter=|client, state|do
		local player=client.equipWin.player
		local field=assert(player.equipFields[client.equipWin.currentLine])
		client.itemWin:refresh(|item|do
			if item.equip ~= field then return false end
			for _,p2 in ipairs(client.army.ents) do
				if p2 ~= player then
					for _,f2 in ipairs(p2.equipFields) do
						if p2[f2] == item then return false end
					end
				end
			end
			return true
		end)
		client.itemWin.currentLine=1
		if player[field] then
			client.itemWin.items:find(player[field])
		end
		refreshEquipStatWin(client)
		client.itemWin:setPos(vec2(client.equipWin.border.min.x, client.equipWin.border.max.y+1))
	end,
	draw=|client, state|do
		client.itemWin:draw()
	end,
}
Client.equipCmdState={
	cmds={
		e=cmdPopState,
		left=cmdPopState,
		up=makeCmdWindowMoveCursor'equipWin',
		down=makeCmdWindowMoveCursor'equipWin',
		space=makeCmdPushState('Choose', Client.chooseEquipCmdState),
		right=makeCmdPushState('Choose', Client.chooseEquipCmdState),
	},
	enter=|client, state|do
		client.statWin:refresh()
		client.equipWin:setPos(vec2(client.statWin.border.max.x+1, client.statWin.border.min.y))
		client.equipWin:refresh()
	end,
	draw=|client, state|do
		client.statWin:draw()
		client.equipWin:draw()
	end,
}
Client.itemCmdState={
	cmds={
		up=makeCmdWindowMoveCursor'itemWin',
		down=makeCmdWindowMoveCursor'itemWin',
		left=cmdPopState,
		space={
			name='Use',
			exec=|client,cmd,ch|do
				local player=client.itemWin.player
				if #client.itemWin.items == 0 then return end
				client.itemWin.currentLine=(client.itemWin.currentLine - 1) % #client.itemWin.items + 1
				local item=client.itemWin.items[client.itemWin.currentLine]
				if item.use then
					item:use(player)
					player.army:removeItem(item)
					client.itemWin:refresh()
				end
			end,
		},
	},
	enter=|client,state|do
		client.itemWin:setPos(vec2(1,1))
		client.itemWin:refresh()
	end,
	draw=|client,state|do
		client.itemWin:draw()
	end,
}
Client.dropItemCmdState={
	cmds={
		up=makeCmdWindowMoveCursor'itemWin',
		down=makeCmdWindowMoveCursor'itemWin',
		left=cmdPopState,
		space={
			name='Drop',
			exec=|client, cmd, ch|do
				if #client.army.items == 0 then return end
				client.itemWin.currentLine=(client.itemWin.currentLine - 1) % #client.army.items + 1
				local item=client.itemWin.items[client.itemWin.currentLine]
				client.army:removeItem(item)
				if #client.army.items > 0 then
					client.itemWin.currentLine=(client.itemWin.currentLine - 1) % #client.army.items + 1
				end
				client.itemWin:refresh()
			end,
		},
	},
	enter=|client,state|do
		client.itemWin:setPos(vec2(1,1))
		client.itemWin:refresh()
	end,
	draw=|client,state|do
		client.itemWin:draw()
	end,
}
Client.playerCmdState={
	cmds={
		left=cmdPopState,
		up=makeCmdWindowMoveCursor'playerWin',
		down=makeCmdWindowMoveCursor'playerWin',
		right=makeCmdWindowChooseCursor'playerWin',
		space=makeCmdWindowChooseCursor'playerWin',
	},
	enter=|client,state|do
		client.playerWin:setPos(vec2(client.statWin.border.max.x+3, client.statWin.border.min.y+1))
	end,
	draw=|client,state|do
		client.playerWin:draw()
	end,
}
Client.armyCmdState={
	cmds={
		left=cmdPopState,
		up=makeCmdWindowMoveCursor'armyWin',
		down=makeCmdWindowMoveCursor'armyWin',
		right=makeCmdPushState('Player', Client.playerCmdState),
		space=makeCmdPushState('Player', Client.playerCmdState),
	},
	enter=|client, state|do
		refreshWinPlayers(client)
		client.statWin:refresh()
		client.armyWin:setPos(vec2(client.statWin.border.max.x+1, client.statWin.border.min.y))
		client.armyWin:refresh()
		game.paused=true
	end,
	draw=|client, state|do
		game.paused=false
		client.statWin:draw()
		client.armyWin:draw()
	end,
}

local cmdRecruit={
	name='Recruit',
	exec=|client, cmd, ch|do
		if #client.army.ents >= Client.maxArmySize then
			log("party is full")
		else
			local pos=client.army.leader.pos + dirs[ch]
			if map.bbox:contains(pos) then
				local armies=table()
				for _,ent in ipairs(entsAtPos(pos)) do
					if ent.army ~= client.army
					and ent.army.affiliation == client.army.affiliation
					then
						armies:insertUnique(ent.army)
					end
				end
				if #armies then
					for _,army in ipairs(armies) do
						client.army:addArmy(army)
					end
				end
			end
		end
		client:popState()
	end,
}
Client.recruitCmdState={
	cmds={
		up=cmdRecruit,
		down=cmdRecruit,
		left=cmdRecruit,
		right=cmdRecruit,
		space=cmdPopState,
	},
	enter=|client, state|do
		client.doneWin:refresh'Cancel'
		client.doneWin:setPos(vec2(1,1))
	end,
	draw=|client, state|do
		client.doneWin:draw()
	end,
}
Client.mapOptionsCmdState={
	cmds={
		left=cmdPopState,
		up=makeCmdWindowMoveCursor'mapOptionsWin',
		down=makeCmdWindowMoveCursor'mapOptionsWin',
		right=makeCmdWindowChooseCursor'mapOptionsWin',
		space=makeCmdWindowChooseCursor'mapOptionsWin',
	},
	enter=|client, state|do
		client.mapOptionsWin:setPos(vec2(1,1))
		client.mapOptionsWin:refresh()
	end,
	draw=|client, state|do
		client.mapOptionsWin:refresh()
		client.mapOptionsWin:draw()
	end,
}
Client.mainCmdState={
	cmds={
		up=cmdMove,
		down=cmdMove,
		left=cmdMove,
		right=cmdMove,
		space=makeCmdPushState('Party', Client.mapOptionsCmdState),
	},
}

local cmdAttack={
	name='Attack',
	exec=|client, cmd, ch|do
		client.army.currentEnt:attackDir(ch)
		client:popState()
	end,
}

Client.attackCmdState={
	cmds={
		up=cmdAttack,
		down=cmdAttack,
		left=cmdAttack,
		right=cmdAttack,
		space=cmdPopState,
	},
	enter=|client, state|do
		client.doneWin:refresh'Cancel'
		client.doneWin:setPos(vec2(1,1))
	end,
	draw=|client, state|do
		client.doneWin:draw()
	end,
}
Client.battleMoveCmdFinishedState={
	cmds={
		up=makeCmdWindowMoveCursor'moveFinishedWin',
		down=makeCmdWindowMoveCursor'moveFinishedWin',
		space=makeCmdWindowChooseCursor'moveFinishedWin',
	},
	draw=|client, state|do
		client.moveFinishedWin:refresh()
		client.moveFinishedWin:draw()
	end,
}

local cmdMoveDone={
	name='Done',
	exec=|client, cmd, ch|do
		client:pushState(Client.battleMoveCmdFinishedState)
	end,
}

Client.battleMoveCmdState={
	cmds={
		up=cmdMove,
		down=cmdMove,
		left=cmdMove,
		right=cmdMove,
		space=cmdMoveDone,
	},
	enter=|client, state|do
		client.doneWin:refresh'Done'
		client.doneWin:setPos(vec2(1,1))
	end,
	draw=|client, state|do
		client.doneWin:draw()
	end,
}
Client.battleCmdState={
	cmds={
		up=makeCmdWindowMoveCursor'battleWin',
		down=makeCmdWindowMoveCursor'battleWin',
		space=makeCmdWindowChooseCursor'battleWin',
	},
	enter=|client, state|do
		client.battleWin:setPos(vec2(1,1))
	end,
	draw=|client, state|do
		client.battleWin:refresh()
		client.battleWin:draw()
	end,
}
Client.quitCmdState={
	cmds={
		left=cmdPopState,
		up=makeCmdWindowMoveCursor'quitWin',
		down=makeCmdWindowMoveCursor'quitWin',
		space=makeCmdWindowChooseCursor'quitWin',
	},
	draw=|client,state| client.quitWin:draw(),
}
Client.setState=|:,state|do
	if self.cmdstate and self.cmdstate.exit then
		self.cmdstate.exit(self, self.cmdstate)
	end
	self.cmdstate=state
	if self.cmdstate and self.cmdstate.enter then
		self.cmdstate.enter(self, self.cmdstate)
	end
end
Client.removeToState=|:,state|do
	assert(state)
	if state == self.cmdstate then return end
	local i=assert(self.cmdstack:find(state))
	for i=i,#self.cmdstack do
		self.cmdstack[i]=nil
	end
	self.cmdstate=state
end
Client.pushState=|:,state|do
	assert(state)
	self.cmdstack:insert(self.cmdstate)
	self:setState(state)
end
Client.popState=|:|do
	self:setState(self.cmdstack:remove())
end
Client.processCmdState=|:,state|do
	local ch
	repeat
		if btnp'up' then
			ch='up'
		elseif btnp'down' then
			ch='down'
		elseif btnp'left' then
			ch='left'
		elseif btnp'right' then
			ch='right'
		elseif btnp'a' then
			ch='enter'
		elseif btnp'b' then
			ch='space'
		elseif btnp'x' then
			ch='e' -- equipCmdState has 'e'
		else
			flip()
		end
	until ch
	if self.dead then
		if self.cmdstate ~= Client.quitCmdState then
			self:pushState(Client.quitCmdState)
		end
	end
	if self.dead and self.cmdstate ~= Client.quitCmdState then return end
	if state then
		local cmd = state.cmds[ch]
		if cmd then
			if not (cmd.disabled and cmd.disabled(self, cmd)) then
				cmd.exec(self, cmd, ch)
			end
		end
	end
end
Client.init=|:|do
	self.army = ClientArmy(self)
	self.cmdstack = table()
	self:setState(Client.mainCmdState)
	self.armyWin = ArmyWindow{client=self}
	self.statWin = StatWindow{client=self}
	self.equipWin = EquipWindow{client=self}
	self.itemWin = ItemWindow{client=self}
	self.quitWin = QuitWindow{client=self}
	self.playerWin = PlayerWindow{client=self}
	self.battleWin = BattleWindow{client=self}
	self.doneWin = DoneWindow{client=self}
	self.mapOptionsWin = MapOptionsWindow{client=self}
	self.moveFinishedWin = MoveFinishedWindow{client=self}
end
Client.update=|:|do
	if self.cmdstate and self.cmdstate.update then
		self.cmdstate.update(self, self.cmdstate)
	end
	self:processCmdState(self.cmdstate)
end

game = {
	time = 0,
	done = false,
	paused = false,
}

ents = table()
battles = table()

client = Client()
client.army.affiliation = 'good'
Player{pos=(map.size/2):floor(), army=client.army}

for i=1,math.floor(map.size:product() / 131) do
	local e = Monster{
		pos=vec2( math.random(map.size.x), math.random(map.size.y) ),
		army = Army{affiliation='evil'..math.random(4)},
	}
	map.tiles[e.pos.x][e.pos.y].type = tiletypes.floor
end

for i=1,math.floor(map.size:product() / 262) do
	local e = Treasure{
		pos=vec2( math.random(map.size.x), math.random(map.size.y) ),
		gold = math.random(100) + 10,
		army = Army(),
		pickupRandom = true,
	}
	map.tiles[e.pos.x][e.pos.y].type = tiletypes.floor
end

for i=1,math.floor(map.size:product() / 500) do
	local e = Player{
		pos=vec2( math.random(map.size.x), math.random(map.size.y) ),
		gold = math.random(10),
		army = Army{affiliation='good'},
	}
	map.tiles[e.pos.x][e.pos.y].type = tiletypes.floor
end


render=||do
	cls(0xf0)

	if client.army.currentEnt then
		view:update(client.army.currentEnt.pos)
	else
		view:update(client.army.leader.pos)
	end

	local v = vec2()
	for i=1,view.size.x do
		v.x = view.delta.x + i
		for j=1,view.size.y do
			v.y = view.delta.y + j

			if map.bbox:contains(v) then
				local tile = map.tiles[v.x][v.y]
				if tile:isRevealed() then
					tile:draw(i * 16, j * 16)

					local topEnt
					if tile.ents then
						topEnt = assert(tile.ents[1])
						for k=2,#tile.ents do
							local ent = tile.ents[k]
							if ent.zOrder > topEnt.zOrder then
								topEnt = ent
							end
						end

						topEnt:draw(i * 16, j * 16)
					end
				end
			end
		end
	end

	for _,battle in ipairs(battles) do
		local mins = battle.bbox.min - view.delta - 1
		local maxs = battle.bbox.max - view.delta + 1
		view:drawBorder(box2(mins,maxs))
	end

	local y = 1
	local printright=|s|do
		if s then
			con.locate(ui.size.x+2,y)
			con.write(s)
		end
		y = y + 1
	end

	if client.army.battle then
		printright'Battle:'
		printright'-------'
		for _,ent in ipairs(client.army.ents) do
			printright('hp '..ent.hp..'/'..ent:stat'hpMax')
			printright('move '..ent.movesLeft..'/'..ent:stat'move')
			printright('ct '..ent.ct..'/100')
			printright()
		end
	end

	printright'Commands:'
	printright'---------'

	if client.cmdstate then
		for k,cmd in pairs(client.cmdstate.cmds) do
			if not (cmd.disabled and cmd.disabled(client, cmd)) then
				printright(k..' = '..cmd.name)
			end
		end
	end

	for _,state in ipairs(client.cmdstack) do
		if state and state.draw then
			state.draw(client, state)
		end
	end
	if client.cmdstate and client.cmdstate.draw then
		client.cmdstate.draw(client, client.cmdstate)
	end

	log:render()
end

gameUpdate=||do
	if not game.paused then
		for _,ent in ipairs(ents) do
			ent:update()
		end

		for _,battle in ipairs(battles) do
			battle:update()
		end
	end
	render()
end

update=||do
	client:update()
	game.time = game.time + 1
	gameUpdate()
end

-- init draw
gameUpdate()
render()
flip()
render()
