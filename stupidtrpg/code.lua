poke(ffi.offsetof('RAM','fontWidth'),8)

math.randomseed(tstamp())

new=[cl,...]do
	local o=setmetatable({},cl)
	o?:init(...)
	return o
end
isa=[cl,o]o.isaSet[cl]
classmeta = {__call=new}
class=[...]do
	local t=table(...)
	t.super=...
	t.__index=t
	t.subclass=class
	t.isaSet=table(table{...}:mapi([cl]cl.isaSet):unpack()):setmetatable(nil)
	t.isaSet[t]=true
	t.isa=isa
	setmetatable(t,classmeta)
	return t
end

getvalue=[x, dim]do
	if type(x) == 'number' then return x end
	if type(x) == 'table' then
		x = x[dim]
		if type(x) ~= 'number' then
			error("expected a table of numbers, got a table with index "..dim.." of "..type(x))
		end
		return x
	end
	error("tried to getvalue from an unknown type "..type(x))
end

vec2=class{
	dim=2,
	init=[v,x,y]do
		if x then
			v:set(x,y)
		else
			v:set(0,0)
		end
	end,
	set=[v,x,y]do
		if type(x) == 'table' then
			v[1] = x[1]
			v[2] = x[2]
		else
			v[1] = x
			if y then
				v[2] = y
			else
				v[2] = x
			end
		end
	end,
	volume=[v]v[1]*v[2],
	clamp=[v,a,b]do
		local mins = a
		local maxs = b
		if type(a) == 'table' and a.min and a.max then	
			mins = a.min
			maxs = a.max
		end
		v[1] = math.clamp(v[1], getvalue(mins, 1), getvalue(maxs, 1))
		v[2] = math.clamp(v[2], getvalue(mins, 2), getvalue(maxs, 2))
		return v
	end,
	map=[v,f]do
		v[1]=f(v[1],1)
		v[2]=f(v[2],2)
		return v
	end,
	floor=[v]v:map(math.floor),
	ceil=[v]v:map(math.ceil),
	l1Length=[v]math.abs(v[1])+math.abs(v[2]),
	lInfLength=[v]math.max(math.abs(v[1]),math.abs(v[2])),
	__add=[a,b]vec2(getvalue(a,1)+getvalue(b,1),getvalue(a,2)+getvalue(b,2)),
	__sub=[a,b]vec2(getvalue(a,1)-getvalue(b,1),getvalue(a,2)-getvalue(b,2)),
	__mul=[a,b]vec2(getvalue(a,1)*getvalue(b,1),getvalue(a,2)*getvalue(b,2)),
	__div=[a,b]vec2(getvalue(a,1)/getvalue(b,1),getvalue(a,2)/getvalue(b,2)),
	__eq=[a,b]a[1]==b[1]and a[2]==b[2],
	__tostring=[v]v[1]..','..v[2],
	__concat=[a,b]tostring(a)..tostring(b),
}

getminvalue=[x]do
	if x.min then return x.min end
	assert(x ~= nil, "getminvalue got nil value")
	return x
end

getmaxvalue=[x]do
	if x.max then return x.max end
	assert(x ~= nil, "getmaxvalue got nil value")
	return x
end

box2=class{
	dim=2,
	init=[:,a,b]do
		if type(a) == 'table' and a.min and a.max then
			self.min = vec2(a.min)
			self.max = vec2(a.max)
		else
			self.min = vec2(a)
			self.max = vec2(b)
		end
	end,
	stretch=[:,v]do
		if getmetatable(v) == box2 then
			self:stretch(v.min)
			self:stretch(v.max)
		else
			for i=1,self.dim do
				self.min[i] = math.min(self.min[i], v[i])
				self.max[i] = math.max(self.max[i], v[i])
			end
		end
	end,
	size=[:]self.max-self.min,
	floor=[:]do
		self.min:floor()
		self.max:floor()
		return self
	end,
	ceil=[:]do
		self.min:ceil()
		self.max:ceil()
		return self
	end,
	clamp=[:,b]do
		self.min:clamp(b)
		self.max:clamp(b)
		return self
	end,
	contains=[:,v]do
		if getmetatable(v) == box2 then
			return self:contains(v.min) and self:contains(v.max)
		else
			for i=1,v.dim do
				local x = v[i]
				if x < self.min[i] or x > self.max[i] then
					return false
				end
			end
			return true
		end
	end,
	map=[b,c]c*b:size()+b.min,
	__add=[a,b]box2(getminvalue(a)+getminvalue(b),getmaxvalue(a)+getmaxvalue(b)),
	__sub=[a,b]box2(getminvalue(a)-getminvalue(b),getmaxvalue(a)-getmaxvalue(b)),
	__mul=[a,b]box2(getminvalue(a)*getminvalue(b),getmaxvalue(a)*getmaxvalue(b)),
	__div=[a,b]box2(getminvalue(a)/getminvalue(b),getmaxvalue(a)/getmaxvalue(b)),
	__tostring=[b]b.min..'..'..b.max,
	__concat=[a,b]tostring(a)..tostring(b),
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

setFieldsByRange=[obj,fields]do
	for _,field in ipairs(fields) do
		local range = obj[field..'Range']
		if range then
			local lo, hi = table.unpack(range)
			assert(hi >= lo, "item "..obj.name.." field "..field.." has interval "..tostring(hi)..","..tostring(lo))
			obj[field] = math.random() * (hi - lo) + lo
		end
	end
end

capitalize=[s]s:sub(1,1):upper()..s:sub(2)

serializeTable=[obj]do
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
	},
	wall = {
		char = '0',
		solid = true,
	},
}

con={
	locate=[x,y]do
		con.x=x
		con.y=y
	end,
	write=function(s)
		text(s,(con.x-1)<<3,(con.y-1)<<3,0xfc,0xf0)
		con.x+=#s
	end,
	clearline = function()
		rect(con.x<<3,con.y<<3,256,8,0xf0)
		con.x=1
		con.y+=8
	end,
}

Log=class{
	index=0,
	lines=table(),
	size=4,
	__call=[:,s]do
		local lines = string.split(s, '\n')
		for _,line in ipairs(lines) do
			line=self.index..'> '..line
			while #line>32 do
				self.lines:insert(line:sub(1,32))
				line = line:sub(33)
				self.index+=1
			end
			self.lines:insert(line)
			self.index+=1
		end
		while #self.lines > self.size do
			self.lines:remove(1)
		end
	end,
	render=[:]do
		for i=1,self.size do
			local line = self.lines[i]
			con.locate(1, view.size[2]+i)
			if line then
				con.write(line)
			end
			con.clearline()
		end
	end,
}
log=Log()

MapTile=class{
	init=[:]nil,
	isRevealed=[:]do
		local visibleTime=-math.log(0)
		return self.lastSeen and (game.time - self.lastSeen) < visibleTime
	end,
	getChar=[:]do
		return self.char or self.type.char
	end,
	addEnt=[:,ent]do
		if not self.ents then
			self.ents=table()
		end
		self.ents:insert(ent)
	end,
	removeEnt=[:,ent]do
		assert(self.ents)
		self.ents:removeObject(ent)
		if #self.ents == 0 then
			self.ents=nil
		end
	end,
}

map={}
map.size=vec2(256,256)
map.bbox=box2(1, map.size)
map.tiles={}				-- TOOD switch to tilemap, but that means switching all positions from 1-based to 0-based
for i=1,map.size[1] do
	map.tiles[i]={}
	for j=1,map.size[2] do
		local tile=MapTile()
		tile.type=tiletypes.floor
		map.tiles[i][j]=tile
	end
end

local seeds=table()
for i=1,math.floor(map.size:volume()/13) do
	local seed={
		pos=vec2(math.random(map.size[1]), math.random(map.size[2])),
	}
	seed.mins=vec2(table.unpack(seed.pos))
	seed.maxs=vec2(table.unpack(seed.pos))
	seeds:insert(seed)
	map.tiles[seed.pos[1]][seed.pos[2]].seed=seed
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
			for y=seed.mins[2],seed.maxs[2] do
				if map.tiles[corner[1]][y].seed then
					found = true
					break
				end
			end
			if not found then
				for y=seed.mins[2],seed.maxs[2] do
					map.tiles[corner[1]][y].seed = seed
				end
				seedcorners[i][1] = corner[1]
				modified = true
			end

			found = nil
			for x=seed.mins[1],seed.maxs[1] do
				if map.tiles[x][corner[2]].seed then
					found = true
					break
				end
			end
			if not found then
				for x=seed.mins[1],seed.maxs[1] do
					map.tiles[x][corner[2]].seed = seed
				end
				seedcorners[i][2] = corner[2]
				modified = true
			end
		end
	end
until not modified

for _,seed in ipairs(seeds) do
	local size = seed.maxs - seed.mins - 1
	if size[1] < 1 then size[1] = 1 end
	if size[2] < 1 then size[2] = 1 end
	local wall = vec2(
		math.random(size[1]) + seed.mins[1],
		math.random(size[2]) + seed.mins[2])

	if seed.mins[2] > 1 then
		for x=seed.mins[1],seed.maxs[1] do
			if x ~= wall[1] then
				map.tiles[x][seed.mins[2]].type = tiletypes.wall
			end
		end
	end
	if seed.mins[1] > 1 then
		for y=seed.mins[2],seed.maxs[2] do
			if y ~= wall[2] then
				map.tiles[seed.mins[1]][y].type = tiletypes.wall
			end
		end
	end
end

for x=1,map.size[1] do
	for y=1,map.size[2] do
		map.tiles[x][y].seed = nil
	end
end

Battle=class{
	radius=4,
	init=[:,args]do
		if args.bbox then
			self.bbox = box2(args.bbox)
		else
			self.pos=vec2(assert(args.pos))
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
	update=[:]do
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
	removeEnt=[:,ent]do
		self.ents:removeObject(ent)
		if self.currentEnt == ent then
			self.index = self.index - 1
			self:endTurn()
		end
	end,
	getCurrentEnt=[:]do
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
	enemiesOf=[:,ent]do
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
	endTurn=[:]do
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

entsAtPos=[pos]do
	if not map.bbox:contains(pos) then return table() end
	return table(map.tiles[pos[1]][pos[2]].ents)
end

entsAtPositions=[positions]do
	local es = table()
	for _,pos in ipairs(positions) do
		es:append(entsAtPos(pos))
	end
	return es
end

entsWithinRadius=[pos, radius]do
	assert(pos)
	assert(radius)
	local mins = (pos - radius):clamp(map.bbox)
	local maxs = (pos + radius):clamp(map.bbox)

	local closeEnts = table()
	for x=mins[1],maxs[1] do
		for y=mins[2],maxs[2] do
			closeEnts:append(entsAtPos(vec2(x,y)))
		end
	end
	return closeEnts
end

floodFillTiles=[pos, bbox]do
	bbox = box2(bbox):clamp(map.bbox)
	pos = vec2(table.unpack(pos))
	local positions = table{pos}
	local allpositionset = table()
	allpositionset[tostring(pos)] = true
	while #positions > 0 do
		local srcpos = positions:remove(1)
		for _,dir in ipairs(dirs) do
			local newpos = srcpos + dirs[dir]
			if bbox:contains(newpos)
			then
				local tile = map.tiles[newpos[1]][newpos[2]]
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
	return allpositionset:keys():map([v]
		vec2(table.unpack(string.split(v, ','):map([x] tonumber(x))))
	)
end

pathSearchToPoint=[args]do
	local bbox = assert(args.bbox)
	local start = assert(args.src)
	local dest = assert(args.dst)
	local entBlocking = args.entBlocking
	assert(bbox:contains(start))
	assert(bbox:contains(dest))
	local states = table{
		{pos = vec2(table.unpack(start))}
	}
	local allpositions = table()
	allpositions[tostring(vec2(table.unpack(start)))] = true
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
				local tile = map.tiles[newstate.pos[1]][newstate.pos[2]]
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
	speedLevelUpRange={0, .1},
	attackLevelUpRange={0, 1},
	defenseLevelUpRange={0, 1},
	hitChanceLevelUpRange={0, 1},
	evadeLevelUpRange={0,1},
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
	init=[:,args]do
		assert(args.pos)
		self.pos = vec2()
		self.lastpos = vec2()
		self:setPos(assert(args.pos))
		setFieldsByRange(self,self.statFields)
		ents:insert(self)
		assert(args.army):addEnt(self)
		self.hp = self:stat'hpMax'
	end,
	delete=[:]do
		self:setTile(nil)
		if self.army then self.army:removeEnt(self) end
		ents:removeObject(self)
		for _,battle in ipairs(battles) do
			battle:removeEnt(self)
		end
	end,
	addExp=[:,exp]do
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
						local lo, hi = table.unpack(range)
						assert(hi >= lo, "item "..obj.name.." field "..field.." has interval "..tostring(hi)..","..tostring(lo))
						self[field] = math.random() * (hi - lo) + lo
					end
				end
			end
			log(self.name..' is now at level '..math.floor(self.level))
		end
	end,
	getChar=[:]do
		local char = self.char
		if self.dead then char = 'd' end
		return char
	end,
	setPos=[:,pos]do
		assert(pos)
		self:setTile(nil)
		self.lastpos:set(self.pos)
		self.pos:set(pos)
		if map.bbox:contains(self.pos) then
			self:setTile(map.tiles[self.pos[1]][self.pos[2]])
		end
	end,
	setTile=[:,tile]do
		if self.tile then
			self.tile:removeEnt(self)
		end
		self.tile = tile
		if self.tile then
			self.tile:addEnt(self)
		end
	end,
	update=[:]do
		if self.dead then
			if self.battle and self.battle.currentEnt == self then
				self:endTurn()
			end
			return
		end
	end,
	setDead=[:,dead]do
		self.dead = dead
		self.attackable = not dead
		self:setSolid(not dead)
	end,
	setSolid=[:,solid]do
		self.solid = solid
		if not self.solid then
			self.zOrder = -1
		else
			self.zOrder = nil
		end
	end,
	walk=[:,dir]do
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
		local tiletype = map.tiles[newpos[1]][newpos[2]].type
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
	beginBattle=[:,battle]do
		self.battle = battle
		self.ct = 0
		self.hp = self:stat'hpMax'
		self.movesLeft = 0
	end,
	endBattle=[:]do
		self.battle = nil
	end,
	beginTurn=[:]do
		self.ct = 100
		self.movesLeft = self:stat'move'
		self.turnStartPos = vec2(table.unpack(self.pos))
		self.acted = false
		self.army.currentEnt = self
	end,
	endTurn=[:]do
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
	stat=[:,field]do
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
	attackDir=[:,dir]do
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
	attackTarget=[:,target]do
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
	getExpGiven=[:]do
		return self.level
	end,
	takeDamage=[:,dmg,inflicter]do
		self.hp = math.max(self.hp - dmg, 0)
		log(self.name..' receives '..dmg..' dmg and is at '..self.hp..' hp')
		if self.hp == 0 then
			log(self.name..' is dead')
			inflicter:addExp(self:getExpGiven())
			self:die()
		end
	end,
	die=[:]do
		self:setDead(true)
	end,
}

Army=class{
	gold=0,
	init=[:,args]do
		if args then
			self.affiliation = args.affiliation
		end
		self.ents = table()
		self.items = table()
	end,
	addEnt=[:,ent]do
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
	removeEnt=[:,ent]do
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
	deleteAll=[:]do
		assert(not self.battle, "i don't have deleting armies mid-battle done yet")
		for i=#self.ents,1,-1 do
			self.ents[i]:delete()
		end
	end,
	addItem=[:,item]do
		self.items:insert(item)
	end,
	removeItem=[:,item]do
		for _,ent in ipairs(self.ents) do
			for _,field in ipairs(ent.equipFields) do
				if ent[field] == item then
					ent[field] = nil
				end
			end
		end
		self.items:removeObject(item)
	end,
	addArmy=[:,army]do
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
	beginBattle=[:,battle]do
		self.battle = battle
	end,
	endBattle=[:]do
		self.battle = nil
	end,
}

ClientArmy=Army:subclass{
	init=[:,client]do
		ClientArmy.super.init(self)
		self.client = client
	end,
	addEnt=[:,ent]do
		ClientArmy.super.addEnt(self, ent)
		ent.client = client
	end,
	removeEnt=[:,ent]do
		ClientArmy.super.removeEnt(self, ent)
		ent.client = nil
	end,
	beginBattle=[:,battle]do
		ClientArmy.super.beginBattle(self, battle)
		self.client:removeToState(Client.mainCmdState)
		self.client:pushState(Client.battleCmdState)
	end,
	endBattle=[:,battle]do
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
			if baseType[rangeField][1] < min then baseType[rangeField][1] = min end
		end
	end
	for _,baseField in ipairs(Unit.statFields) do
		local field = baseField..'Range'
		if baseType[field] then
			if baseType[field][2] < baseType[field][1] then
				baseType[field][2] = baseType[field][1]
			end
		end
	end
	Unit.baseTypes[i] = baseType
	Unit.baseTypes[baseType.name] = baseType
end
Unit.init=[:,args]do
	if self.baseType then
		for _,baseField in ipairs(self.statFields) do
			local field = baseField..'Range'
			if self[field] or self.baseType[field] then
				self[field] = vec2(self[baseField] or 0) + vec2(self.baseType[field] or 0)
			end
		end
	end
	Unit.super.init(self, args)
end
Unit.update=[:]do
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
						local path, dist = pathSearchToPoint{
							src=self.pos,
							dst=enemy.pos,
							bbox=self.battle.bbox,
							entBlocking = [ent]ent.solid and ent.army.affiliation ~= self.army.affiliation,
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
				pathsForEnemies:sort([a,b] #a.path < #b.path)
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
					entBlocking = [ent]ent.solid and ent.army.affiliation ~= self.army.affiliation,
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
Unit.updateFog=[:]do
	local radius = 4
	local fogTiles = floodFillTiles(self.pos, box2(self.pos - radius, self.pos + radius))
	for _,pos in ipairs(fogTiles) do
		for _,dir in ipairs(dirs) do
			local ofspos = (dirs[dir] + pos):clamp(map.bbox)
			map.tiles[ofspos[1]][ofspos[2]].lastSeen = game.time
		end
	end
end
Unit.checkBattle=[:]do
	if self.battle then return end
	local searchRadius = 3
	local closeEnts = entsAtPositions(floodFillTiles(self.pos, box2(self.pos-searchRadius,self.pos+searchRadius)))
	closeEnts = closeEnts:filter([ent]
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
			local battleEnts = entsAtPositions(battlePositions):filter([ent]ent.canBattle and not ent.dead)
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
			for i=1,2 do
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
				map.tiles[ofspos[1]][ofspos[2]].lastSeen = game.time
			end
		end
	end
end
Unit.die=[:]do
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

Treasure.init=[:,args]do
	Treasure.super.init(self, args)
	if args.gold then
		self.army.gold = self.army.gold + tonumber(args.gold)
	end
	self.pickupRandom = args.pickupRandom
end

Treasure.get=[:,who]do
	if self.pickupRandom then
		for i=1,math.random(3) do
			local item = items[math.random(#items)]
			self.army:addItem(item(who.level))
		end
	end
	local gottext = table()
	if #self.army.items > 0 then
		gottext:insert(self.army.items:map([item]item.name):concat', ')
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
Item.__lt=[a,b]((items:find(getmetatable(a)) or 0)<(items:find(getmetatable(b)) or 0))

local Potion = Item:subclass()
Potion.name = 'Potion'
Potion.healRange = {20,30}
Potion.init=[:,...]do
	if Potion.super.init then Potion.super.init(self, ...) end
	setFieldsByRange(self, {'heal'})
	self.heal = math.floor(self.heal)
	self.name = self.name .. '(+'..self.heal..')'
end
Potion.use=[:,who]do
	who.hp = math.min(who.hp + self.heal, who:stat'hpMax')
end

local Equipment = Item:subclass{
	init=[:,maxLevel]do
		assert(self.baseTypes, "tried to instanciate an equipment of type "..self.name.." with no basetypes")
		local baseTypeOptions = table(self.baseTypes)
		local modifierOptions = table(self.modifiers)
		if maxLevel then
			local filter = [baseType]do
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
				if self[field] then range = range + vec2(self[field]) end
				if baseType[field] then range = range + vec2(baseType[field]) end
				if modifier[field] then range = range + vec2(modifier[field]) end
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
	weapon.attackRange = { math.floor(weapon.attackRange * .75), weapon.attackRange }
	weapon.hitChanceRange = { math.floor(weapon.hitChanceRange * .75), weapon.hitChanceRange }
end

local weaponModifiers = {
	{name="Plain ol'"},
	{name='Short', attackRange={0,5}, hitChanceRange={0,10}, dropLevel=0},
	{name='Long', attackRange={3,8}, hitChanceRange={5,15}, dropLevel=5},
	{name='Heavy', attackRange={3,8}, hitChanceRange={5,15}, dropLevel=10},
	{name='Bastard', attackRange={0,10}, hitChanceRange={10,20}, dropLevel=15},
	{name='Demon', attackRange={20,20}, hitChanceRange={30,35}, dropLevel=20},
	{name='Were', attackRange={20,25}, hitChanceRange={35,45}, dropLevel=25},
	{name='Rune', attackRange={30,35}, hitChanceRange={40,50}, dropLevel=30},
	{name='Dragon', attackRange={30,40}, hitChanceRange={40,50}, dropLevel=35},
	{name='Quick', attackRange={40,45}, hitChanceRange={90,100}, dropLevel=40},
}

local defenseModifiers = {
	{name="Cloth", defenseRange={1,2}, hpMaxRange={1,2}, evadeRange={1,2}, dropLevel=0},
	{name="Leather", defenseRange={2,3}, hpMaxRange={2,3}, evadeRange={2,3}, dropLevel=5},
	{name="Wooden", defenseRange={3,4}, hpMaxRange={3,4}, evadeRange={3,4}, dropLevel=10},
	{name="Chain", defenseRange={3,4}, hpMaxRange={3,4}, evadeRange={3,4}, dropLevel=15},
	{name="Plate", defenseRange={4,6}, hpMaxRange={4,6}, evadeRange={4,6}, dropLevel=20},
	{name="Copper", defenseRange={5,7}, hpMaxRange={5,7}, evadeRange={5,7}, dropLevel=25},
	{name="Iron", defenseRange={7,10}, hpMaxRange={7,10}, evadeRange={7,10}, dropLevel=30},
	{name="Bronze", defenseRange={9,13}, hpMaxRange={9,13}, evadeRange={9,13}, dropLevel=35},
	{name="Steel", defenseRange={12,16}, hpMaxRange={12,16}, evadeRange={12,16}, dropLevel=40},
	{name="Silver", defenseRange={15,21}, hpMaxRange={15,21}, evadeRange={15,21}, dropLevel=45},
	{name="Gold", defenseRange={21,28}, hpMaxRange={21,28}, evadeRange={21,28}, dropLevel=50},
	{name="Crystal", defenseRange={27,37}, hpMaxRange={27,37}, evadeRange={27,37}, dropLevel=55},
	{name="Opal", defenseRange={36,48}, hpMaxRange={36,48}, evadeRange={36,48}, dropLevel=60},
	{name="Platinum", defenseRange={48,64}, hpMaxRange={48,64}, evadeRange={48,64}, dropLevel=65},
	{name="Plutonium", defenseRange={63,84}, hpMaxRange={63,84}, evadeRange={63,84}, dropLevel=70},
	{name="Adamantium", defenseRange={82,110}, hpMaxRange={82,110}, evadeRange={82,110}, dropLevel=75},
	{name="Potassium", defenseRange={108,145}, hpMaxRange={108,145}, evadeRange={108,145}, dropLevel=80},
	{name="Osmium", defenseRange={143,191}, hpMaxRange={143,191}, evadeRange={143,191}, dropLevel=85},
	{name="Holmium", defenseRange={189,252}, hpMaxRange={189,252}, evadeRange={189,252}, dropLevel=90},
	{name="Mithril", defenseRange={249,332}, hpMaxRange={249,332}, evadeRange={249,332}, dropLevel=95},
	{name="Aegis", defenseRange={327,437}, hpMaxRange={327,437}, evadeRange={327,437}, dropLevel=100},
	{name="Genji", defenseRange={432,576}, hpMaxRange={432,576}, evadeRange={432,576}, dropLevel=105},
	{name="Pro", defenseRange={569,759}, hpMaxRange={569,759}, evadeRange={569,759}, dropLevel=110},
	{name="Diamond", defenseRange={750,1000}, hpMaxRange={750,1000}, evadeRange={750,1000}, dropLevel=115},
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
	{name='Shield', evadeRange={5,10}},
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
Monster.init=[:,...]do
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

local ViewSize = vec2(32,28)
View=class{
	size=ViewSize,
	bbox=box2(1, ViewSize),
	center=(ViewSize/2):ceil(),
	update=[:,mapCenter]do
		self.delta=mapCenter-self.center
	end,
	drawBorder=[:,b]do
		local mins = b.min
		local maxs = b.max
		for x=mins[1]+1,maxs[1]-1 do
			if mins[2] >= 1 and mins[2] <= view.size[2] then
				con.locate(x, mins[2])
				con.write'\151'	--'-'
			end
			if maxs[2] >= 1 and maxs[2] <= view.size[2] then
				con.locate(x, maxs[2])
				con.write'\156'	--'-'
			end
		end
		for y=mins[2]+1,maxs[2]-1 do
			if mins[1] >= 1 and mins[1] <= view.size[1] then
				con.locate(mins[1], y)
				con.write'\153'	--'|'
			end
			if maxs[1] >= 1 and maxs[1] <= view.size[1] then
				con.locate(maxs[1], y)
				con.write'\154'	--'|'
			end
		end
		local minmax = {mins, maxs}
		local asciicorner = {{'\150','\155'},{'\152','\157'}}
		for x=1,2 do
			for y=1,2 do
				local v = vec2(minmax[x][1], minmax[y][2])
				if view.bbox:contains(v) then
					con.locate(table.unpack(v))
					con.write(asciicorner[x][y])	--'+'
				end
			end
		end
	end,
	fillBox=[:,b]do
		b = box2(b):clamp(view.bbox)
		for y=b.min[2],b.max[2] do
			con.locate(b.min[1], y)
			con.write((' '):rep(b.max[1] - b.min[1] + 1))
		end
	end,
}
view=View()

Client=class{
	maxArmySize=4,
}

WindowLine=class{
	text='',
	init=[:,args]do
		if type(args) == 'string' then args = {text=args} end
		self.text = args.text
		self.cantSelect = args.cantSelect
		self.onSelect = args.onSelect
	end,
}

Window=class{
	init=[:,args]do
		self.fixed = args.fixed
		self.currentLine = 1
		self.firstLine = 1
		self.pos = vec2(args.pos or {1,1})
		self.size = vec2(args.size or {1,1})
		self:refreshBorder()
		self:setLines(args.lines or {})
	end,
	setPos=[:,pos]do
		self.pos:set(assert(pos))
		self:refreshBorder()
	end,
	refreshBorder=[:]do
		self.border = box2(self.pos, self.pos + self.size - 1)
	end,
	setLines=[:,lines]do
		self.lines = table.map(lines, [line]((WindowLine(line))))
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
			self.size = (vec2(self.textWidth + 1, #self.lines) + 2):clamp(view.bbox)
			self:refreshBorder()
		end
	end,
	moveCursor=[:,ch]do
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
			elseif row > self.firstLine + (self.size[2] - 3) then
				self.firstLine = row - (self.size[2] - 3)
			end
		end
	end,
	chooseCursor=[:]do
		if #self.selectableLines > 0 then
			self.currentLine = (self.currentLine - 1) % #self.selectableLines + 1
			local line = self.selectableLines[self.currentLine]
			if line.onSelect then line.onSelect() end
		end
	end,
	draw=[:]do
		view:drawBorder(self.border)
		local box = box2(self.border.min+1, self.border.max-1)
		view:fillBox(box)
		local cursor = vec2(box.min)
		local i = self.firstLine
		while cursor[2] < self.border.max[2]
		and i <= #self.lines
		do
			local line = self.lines[i]
			con.locate(table.unpack(cursor))
			if not self.noInteraction
			and line == self.selectableLines[self.currentLine]
			then
				con.write'>'
			else
				con.write' '
			end
			con.write(line.text)
			cursor[2] = cursor[2] + 1
			i = i + 1
		end
	end,
}

DoneWindow=Window:subclass{
	refresh=[:,text]do
		self:setLines{text}
	end,
}

QuitWindow=Window:subclass{
	init=[:,args]do
		local client = assert(args.client)
		QuitWindow.super.init(self, args)
		self:setLines{
			{text='Quit?', cantSelect=true},
			{text='-----', cantSelect=true},
			{text='Yes', onSelect=[]reset()},
			{text='No', onSelect=[]client:popState()},
		}
	end,
}

ClientBaseWindow=Window:subclass{
	init=[:,args]do
		ClientBaseWindow.super.init(self, args)
		self.client = assert(args.client)
		self.army = self.client.army
	end,
}

MoveFinishedWindow=ClientBaseWindow:subclass{
	refresh=[:]do
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
				onSelect = []do
					self.client.army.currentEnt.movesLeft = 0
					self.client:popState()
					self.client:popState()
				end,
			}
		end
		lines:insert{
			text='Cancel',
			onSelect=[]do
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
	init=[:,args]do
		MapOptionsWindow.super.init(self, args)
		self:refresh()
	end,
	refresh=[:]do
		local lines = table()
		lines:insert{
			text = 'Status',
			onSelect = []self.client:pushState(Client.armyCmdState),
		}
		lines:insert{
			text = 'Inspect',
			onSelect = []self.client:pushState(Client.inspectCmdState),
		}
		if #self.client.army.ents < Client.maxArmySize then
			lines:insert{
				text = 'Recruit',
				onSelect = []do
					if #self.client.army.ents < Client.maxArmySize then
						self.client:pushState(Client.recruitCmdState)
					end
				end,
			}
		end
		lines:insert{
			text = 'Quit',
			onSelect = []self.client:pushState(Client.quitCmdState),
		}
		lines:insert{
			text = 'Done',
			onSelect = []self.client:popState(),
		}
		self:setLines(lines)
	end,
}

refreshWinPlayers=[client]do
	local player = client.army.ents[client.armyWin.currentLine]
	for _,field in ipairs{'statWin','equipWin','itemWin'} do
		local win = client[field]
		win.player = player
	end
end

ArmyWindow=ClientBaseWindow:subclass{
	refresh=[:]do
		local lines = table()
		for _,ent in ipairs(self.army.ents) do
			lines:insert(ent.name)
		end
		self:setLines(lines)
	end,
	moveCursor=[:,ch]do
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
	refresh=[:,field,equip]do
		local recordStats=[dest]do
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
	refresh=[:]do
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

local refreshEquipStatWin=[client]do
	local item=client.itemWin.items[client.itemWin.currentLine]
	if item then
		local field=assert(client.itemWin.player.equipFields[client.equipWin.currentLine])
		if field then
			client.statWin:refresh(field, item)
		end
	end
end

ItemWindow=ClientBaseWindow:subclass{
	moveCursor=[:,ch]do
		ItemWindow.super.moveCursor(self, ch)
		if self.client.cmdstate==Client.chooseEquipCmdState then
			refreshEquipStatWin(self.client)
		end
	end,
	chooseCursor=[:]do
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
			client.equipWin:setPos(vec2(client.statWin.border.max[1]+1, client.statWin.border.min[2]))
			client.equipWin:refresh()
			client.itemWin:refresh([item]do
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
			--client.itemWin:setPos(vec2(client.equipWin.border.max[1]+1, client.equipWin.border.min[2]))
			client.itemWin:setPos(vec2(client.equipWin.border.min[1], client.equipWin.border.max[2]+1))
			refreshEquipStatWin(client)
		end
	end,
	refresh=[:,filter]do
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
	init=[:,args]do
		PlayerWindow.super.init(self, args)
		self:setLines{
			{
				text='Equip',
				onSelect=[]self.client:pushState(Client.equipCmdState),
			},
			{
				text='Use',
				onSelect=[]self.client:pushState(Client.itemCmdState),
			},
			{
				text='Drop',
				onSelect=[]self.client:pushState(Client.dropItemCmdState),
			},
		}
	end,
}

BattleWindow=ClientBaseWindow:subclass{
	refresh=[:]do
		local client=self.client
		local currentEnt=client.army.currentEnt
		local lines=table()
		if currentEnt.movesLeft > 0 then
			lines:insert{
				text='Move',
				onSelect=[]client:pushState(Client.battleMoveCmdState),
			}
		end
		if not currentEnt.acted then
			lines:insert{
				text='Attack',
				onSelect=[]client:pushState(Client.attackCmdState),
			}
			if #client.army.items > 0 then
				lines:insert{
					text='Use',
					onSelect=[]client:pushState(Client.itemCmdState),
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
				onSelect=[]do
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
			onSelect=[]currentEnt:endTurn(),
		}
		lines:insert{
			text='Party',
			onSelect=[]client:pushState(Client.armyCmdState),
		}
		lines:insert{
			text='Inspect',
			onSelect=[]self.client:pushState(Client.inspectCmdState),
		}
		lines:insert{
			text='Quit',
			onSelect=[]client:pushState(Client.quitCmdState),
		}
		self:setLines(lines)
	end,
}

local cmdPopState={
	name='Done',
	exec=[client,cmd,ch]client:popState(),
}

local makeCmdPushState=[name,state,disabled]do
	assert(state)
	return {
		name=name,
		exec=[:,cmd,ch]self:pushState(state),
		disabled=disabled,
	}
end

local makeCmdWindowMoveCursor=[winField]do
	return {
		name='Scroll',
		exec=[client,cmd,ch]do
			local win=assert(client[winField])
			win:moveCursor(ch)
		end,
	}
end

local makeCmdWindowChooseCursor=[winField]do
	return {
		name='Choose',
		exec=[client,cmd,ch]do
			local win=assert(client[winField])
			win:chooseCursor()
		end,
	}
end

local cmdMove={
	name='Move',
	exec=[client,cmd,ch]do
		if not client.army.battle then
			client.army.leader:walk(ch)
		else
			client.army.currentEnt:walk(ch)
		end
	end,
}

local refreshStatusToInspect=[client]do
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
	exec=[client,cmd,ch]do
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
	enter=[client, state]do
		client.inspectPos=vec2(client.army.leader.pos)
		client.statWin:setPos(vec2(1,1))
		refreshStatusToInspect(client)
	end,
	draw=[client, state]do
		local viewpos=client.inspectPos-view.delta
		if view.bbox:contains(viewpos) then
			con.locate(table.unpack(viewpos))
			con.write'X'
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
	enter=[client, state]do
		local player=client.equipWin.player
		local field=assert(player.equipFields[client.equipWin.currentLine])
		client.itemWin:refresh([item]do
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
		client.itemWin:setPos(vec2(client.equipWin.border.min[1], client.equipWin.border.max[2]+1))
	end,
	draw=[client, state]do
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
	enter=[client, state]do
		client.statWin:refresh()
		client.equipWin:setPos(vec2(client.statWin.border.max[1]+1, client.statWin.border.min[2]))
		client.equipWin:refresh()
	end,
	draw=[client, state]do
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
			exec=[client,cmd,ch]do
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
	enter=[client,state]do
		client.itemWin:setPos(vec2(1,1))
		client.itemWin:refresh()
	end,
	draw=[client,state]do
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
			exec=[client, cmd, ch]do
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
	enter=[client,state]do
		client.itemWin:setPos(vec2(1,1))
		client.itemWin:refresh()
	end,
	draw=[client,state]do
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
	enter=[client,state]do
		client.playerWin:setPos(vec2(client.statWin.border.max[1]+3, client.statWin.border.min[2]+1))
	end,
	draw=[client,state]do
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
	enter=[client, state]do
		refreshWinPlayers(client)
		client.statWin:refresh()
		client.armyWin:setPos(vec2(client.statWin.border.max[1]+1, client.statWin.border.min[2]))
		client.armyWin:refresh()
		game.paused=true
	end,
	draw=[client, state]do
		game.paused=false
		client.statWin:draw()
		client.armyWin:draw()
	end,
}

local cmdRecruit={
	name='Recruit',
	exec=[client, cmd, ch]do
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
	enter=[client, state]do
		client.doneWin:refresh'Cancel'
		client.doneWin:setPos(vec2(1,1))
	end,
	draw=[client, state]do
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
	enter=[client, state]do
		client.mapOptionsWin:setPos(vec2(1,1))
		client.mapOptionsWin:refresh()
	end,
	draw=[client, state]do
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
	exec=[client, cmd, ch]do
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
	enter=[client, state]do
		client.doneWin:refresh'Cancel'
		client.doneWin:setPos(vec2(1,1))
	end,
	draw=[client, state]do
		client.doneWin:draw()
	end,
}
Client.battleMoveCmdFinishedState={
	cmds={
		up=makeCmdWindowMoveCursor'moveFinishedWin',
		down=makeCmdWindowMoveCursor'moveFinishedWin',
		space=makeCmdWindowChooseCursor'moveFinishedWin',
	},
	draw=[client, state]do
		client.moveFinishedWin:refresh()
		client.moveFinishedWin:draw()
	end,
}

local cmdMoveDone={
	name='Done',
	exec=[client, cmd, ch]do
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
	enter=[client, state]do
		client.doneWin:refresh'Done'
		client.doneWin:setPos(vec2(1,1))
	end,
	draw=[client, state]do
		client.doneWin:draw()
	end,
}
Client.battleCmdState={
	cmds={
		up=makeCmdWindowMoveCursor'battleWin',
		down=makeCmdWindowMoveCursor'battleWin',
		space=makeCmdWindowChooseCursor'battleWin',
	},
	enter=[client, state]do
		client.battleWin:setPos(vec2(1,1))
	end,
	draw=[client, state]do
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
	draw=[client,state] client.quitWin:draw(),
}
Client.setState=[:,state]do
	if self.cmdstate and self.cmdstate.exit then
		self.cmdstate.exit(self, self.cmdstate)
	end
	self.cmdstate=state
	if self.cmdstate and self.cmdstate.enter then
		self.cmdstate.enter(self, self.cmdstate)
	end
end
Client.removeToState=[:,state]do
	assert(state)
	if state == self.cmdstate then return end
	local i=assert(self.cmdstack:find(state))
	for i=i,#self.cmdstack do
		self.cmdstack[i]=nil
	end
	self.cmdstate=state
end
Client.pushState=[:,state]do
	assert(state)
	self.cmdstack:insert(self.cmdstate)
	self:setState(state)
end
Client.popState=[:]do
	self:setState(self.cmdstack:remove())
end
Client.processCmdState=[:,state]do
	local ch
	repeat
		if btnp(0) then
			ch='up'
		elseif btnp(1) then
			ch='down'
		elseif btnp(2) then
			ch='left'
		elseif btnp(3) then
			ch='right'
		elseif btnp(4) then
			ch='enter'
		elseif btnp(5) then
			ch='space'
		elseif btnp(6) then
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
Client.init=[:]do
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
Client.update=[:]do
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

for i=1,math.floor(map.size:volume() / 131) do
	local e = Monster{
		pos=vec2( math.random(map.size[1]), math.random(map.size[2]) ),
		army = Army{affiliation='evil'..math.random(4)},
	}
	map.tiles[e.pos[1]][e.pos[2]].type = tiletypes.floor
end

for i=1,math.floor(map.size:volume() / 262) do
	local e = Treasure{
		pos=vec2( math.random(map.size[1]), math.random(map.size[2]) ),
		gold = math.random(100) + 10,
		army = Army(),
		pickupRandom = true,
	}
	map.tiles[e.pos[1]][e.pos[2]].type = tiletypes.floor
end

for i=1,math.floor(map.size:volume() / 500) do
	local e = Player{
		pos=vec2( math.random(map.size[1]), math.random(map.size[2]) ),
		gold = math.random(10),
		army = Army{affiliation='good'},
	}
	map.tiles[e.pos[1]][e.pos[2]].type = tiletypes.floor
end


render=[]do
	cls(0xf0)

	if client.army.currentEnt then
		view:update(client.army.currentEnt.pos)
	else
		view:update(client.army.leader.pos)
	end

	local v = vec2()
	for i=1,view.size[1] do
		v[1] = view.delta[1] + i
		for j=1,view.size[2] do
			v[2] = view.delta[2] + j

			if map.bbox:contains(v) then
				local tile = map.tiles[v[1]][v[2]]
				if tile:isRevealed() then
					con.locate(i,j)

					local topEnt
					if tile.ents then
						topEnt = assert(tile.ents[1])
						for k=2,#tile.ents do
							local ent = tile.ents[k]
							if ent.zOrder > topEnt.zOrder then
								topEnt = ent
							end
						end

						con.write(topEnt:getChar())
					else
						con.write(tile:getChar())
					end
				else
					con.locate(i,j)
					con.write' '
				end
			else
				con.locate(i,j)
				con.write' '
			end
		end
		con.clearline()
	end

	for _,battle in ipairs(battles) do
		local mins = battle.bbox.min - view.delta - 1
		local maxs = battle.bbox.max - view.delta + 1
		view:drawBorder(box2(mins,maxs))
	end

	local y = 1
	local printright=[s]do
		if s then
			con.locate(view.size[1]+2,y)
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

gameUpdate=[]do
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

update=[]do
	client:update()
	game.time = game.time + 1
	gameUpdate()
end

-- init draw
gameUpdate()
