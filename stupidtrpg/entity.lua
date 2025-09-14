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
		if self.battle and self.battle.currentEnt == self
		and (time() * 10) & 3 == 0 then
			rect(x,y,16,16,12)
			return
		end
		if self.dead then
			spr(self.sprite,x,y,2,2, 0x20)
		else
			spr(self.sprite,x,y,2,2)
		end
	end,
}
