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
			if self.wanderIdle 
			and math.random(4) == 4 
			and (time() * 10) & 3 == 0
			then
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
