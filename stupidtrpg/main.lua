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

--#include entity.lua
--#include army.lua
--#include unit.lua
--#include player.lua
--#include treasure.lua
--#include items.lua
--#include monster.lua
--#include ui.lua
--#include view.lua
--#include client.lua

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
